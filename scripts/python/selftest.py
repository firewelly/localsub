#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""字幕流水线 Python 部分自检（不依赖模型、不联网、不调用 PowerShell）。

覆盖范围：
- SRT 解析容错（BOM/CRLF/点号毫秒/缺序号/脏块）与严格序列化；
- 双语合并三种排版、条数/时间戳不一致的报错路径；
- 配置文件合法性与“缺失自动复制”行为；
- 翻译脚本 --mock 端到端（产物条数/时间戳逐条一致、双语排版正确、可重复）；
- 翻译失败路径（接口不可用 → 非零退出码；回退原文 → 退出码 2 且报告记录）；
- 质检正常/异常/--strict 三种路径；
- 各脚本命令行 --help 可用。

用法（在项目根下）：
    python3 scripts/python/selftest.py            # 全部测试
    python3 scripts/python/selftest.py --verbose  # 额外打印每项断言
退出码：0 全绿；1 有失败项。
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import pipeline_config as cfgmod  # noqa: E402
import srt_io  # noqa: E402

EXAMPLE_CONFIG = os.path.join(PROJECT_ROOT, "config", "pipeline.example.json")
VERBOSE = "--verbose" in sys.argv

if sys.stdout.isatty() and os.environ.get("NO_COLOR") is None:
    GREEN = "\033[32m"
    RED = "\033[31m"
    YELLOW = "\033[33m"
    RESET = "\033[0m"
else:
    GREEN = RED = YELLOW = RESET = ""

CHECKS_PASSED = 0
CHECKS_FAILED = 0
FAILURES: List[Dict[str, str]] = []
TESTS: List[Callable[[], None]] = []

# 内置样例：6 条日语字幕（用于解析/合并/翻译/质检测试）
SAMPLE_JA = """1
00:00:00,000 --> 00:00:02,500
おはようございます。

2
00:00:03,000 --> 00:00:05,500
今日はいい天気ですね。

3
00:00:06,000 --> 00:00:09,000
そうですね、散歩に行きましょう。

4
00:00:09,500 --> 00:00:12,000
ちょっと待ってください。

5
00:00:12,500 --> 00:00:15,000
すぐに準備します。

6
00:00:15,500 --> 00:00:18,000
ありがとうございます。
"""

# 与 SAMPLE_JA 条数、时间戳完全一致的“正常中文译文”
SAMPLE_ZH = """1
00:00:00,000 --> 00:00:02,500
早上好。

2
00:00:03,000 --> 00:00:05,500
今天天气真不错。

3
00:00:06,000 --> 00:00:09,000
是啊，我们去散步吧。

4
00:00:09,500 --> 00:00:12,000
请稍等一下。

5
00:00:12,500 --> 00:00:15,000
我马上准备。

6
00:00:15,500 --> 00:00:18,000
谢谢您。
"""


# ---------------------------------------------------------------------------
# 极简测试框架
# ---------------------------------------------------------------------------

class CheckFailure(AssertionError):
    """断言失败。"""


def check(condition: bool, description: str, detail: str = "") -> None:
    global CHECKS_PASSED, CHECKS_FAILED
    if condition:
        CHECKS_PASSED += 1
        if VERBOSE:
            print("      " + GREEN + "· 通过" + RESET + "：" + description)
        return
    CHECKS_FAILED += 1
    raise CheckFailure("{0}{1}".format(description, ("（{0}）".format(detail)) if detail else ""))


def check_eq(actual: Any, expected: Any, description: str) -> None:
    check(actual == expected, description,
          "期望 {0!r}，实际 {1!r}".format(expected, actual))


def check_in(item: Any, container: Any, description: str) -> None:
    check(item in container, description, "未找到 {0!r}".format(item))


def check_not_in(item: Any, container: Any, description: str) -> None:
    check(item not in container, description, "不应出现 {0!r}".format(item))


def expect_error(func: Callable[[], Any], exception_type: Any, description: str) -> None:
    """断言调用会抛出指定异常；抛其他异常或没抛都算失败。"""
    try:
        func()
    except exception_type:
        check(True, description)
    except Exception as exc:  # noqa: BLE001 - 断言辅助，需区分“抛错类型不对”
        check(False, description, "抛出了其他异常：{0}: {1}".format(
            type(exc).__name__, exc))
    else:
        check(False, description, "未抛出异常")


def test(func: Callable[[], None]) -> Callable[[], None]:
    TESTS.append(func)
    return func


@contextlib.contextmanager
def temp_dir():
    path = tempfile.mkdtemp(prefix="localsub-selftest-")
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


def write_file(path: str, content: str, encoding: str = "utf-8") -> str:
    with open(path, "w", encoding=encoding, newline="") as fh:
        fh.write(content)
    return path


def run_cli(script: str, args: List[str], timeout: float = 120.0) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    return subprocess.run(
        [sys.executable, os.path.join(HERE, script)] + list(args),
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        env=env,
    )


def cli_output(completed: subprocess.CompletedProcess) -> str:
    return (completed.stdout or "") + "\n" + (completed.stderr or "")


def run_test(func: Callable[[], None]) -> None:
    before = CHECKS_PASSED
    try:
        func()
    except CheckFailure as exc:
        print("{0}[FAIL]{1} {2}".format(RED, RESET, func.__name__))
        print("      断言失败：{0}".format(exc))
        FAILURES.append({"test": func.__name__, "reason": str(exc)})
    except Exception as exc:  # noqa: BLE001 - 测试框架需要收集所有异常
        print("{0}[FAIL]{1} {2}（非预期异常）".format(RED, RESET, func.__name__))
        print("      异常：{0}: {1}".format(type(exc).__name__, exc))
        traceback.print_exc(limit=3)
        FAILURES.append({"test": func.__name__, "reason": "{0}: {1}".format(
            type(exc).__name__, exc)})
    else:
        print("{0}[PASS]{1} {2}（{3} 项断言）".format(
            GREEN, RESET, func.__name__, CHECKS_PASSED - before))


# ---------------------------------------------------------------------------
# 测试 1~6：SRT 解析/序列化/编码
# ---------------------------------------------------------------------------

@test
def test_01_时间戳格式化与解析() -> None:
    check_eq(srt_io.format_timestamp(0), "00:00:00,000", "0ms 格式化为 00:00:00,000")
    check_eq(srt_io.format_timestamp(1234), "00:00:01,234", "1234ms -> 00:00:01,234")
    check_eq(srt_io.format_timestamp(61234), "00:01:01,234", "61234ms -> 00:01:01,234")
    check_eq(srt_io.format_timestamp(3600000), "01:00:00,000", "1 小时格式化")
    check_eq(srt_io.format_timestamp(360000000), "100:00:00,000", "100 小时保持三位小时")
    check_eq(srt_io.parse_timestamp("00:00:01,234"), 1234, "标准毫秒解析")
    check_eq(srt_io.parse_timestamp("00:00:01.234"), 1234, "点号毫秒解析")
    check_eq(srt_io.parse_timestamp("00:00:01,23"), 1230, "两位毫秒按 10ms 解析")
    check_eq(srt_io.parse_timestamp("00:00:01,2"), 1200, "一位毫秒按 100ms 解析")
    check_eq(srt_io.parse_timestamp("00:00:01,2345"), 1234, "四位毫秒截断到三位")
    check_eq(srt_io.parse_timestamp("0:0:1,234"), 1234, "缺位数的时间戳可解析")
    check_eq(srt_io.parse_timestamp(" 00:00:01,234  "), 1234, "前后空格可解析")
    for value in (0, 999, 1000, 59999, 3600000, 35999999, 360000000):
        check_eq(srt_io.parse_timestamp(srt_io.format_timestamp(value)), value,
                 "时间戳 round-trip：{0}".format(value))
    for value in ("abc", "", "00:00:01", "00:61:00,000", "00:00:61,000"):
        expect_error(lambda v=value: srt_io.parse_timestamp(v),
                     srt_io.SrtParseError,
                     "非法时间戳应报错：{0!r}".format(value))
    expect_error(lambda: srt_io.format_timestamp(-1), srt_io.SrtParseError,
                 "负数毫秒应报错")


@test
def test_02_标准样例解析() -> None:
    cues = srt_io.parse_srt(SAMPLE_JA)
    check_eq(len(cues), 6, "样例 SRT 解析出 6 条")
    check_eq([c.start_ms for c in cues],
             [0, 3000, 6000, 9500, 12500, 15500], "起始时间戳解析正确")
    check_eq([c.end_ms for c in cues],
             [2500, 5500, 9000, 12000, 15000, 18000], "结束时间戳解析正确")
    check_eq(cues[0].text, "おはようございます。", "第 1 条文本正确")
    check_eq(cues[0].index, 1, "输出序号从 1 开始")
    check_eq(cues[5].index, 6, "最后一条序号为 6")
    check_eq(cues[0].duration_ms(), 2500, "时长计算正确")
    check_eq(cues[2].text_lines(), ["そうですね、散歩に行きましょう。"], "文本行拆分正确")
    check_eq(srt_io.visible_char_count(" 中 文 "), 2, "可见字符统计排除空白")


@test
def test_03_容错解析_BOM_CRLF_脏行() -> None:
    tolerant = (
        "\ufeff1\r\n"
        "00:00:00.500 --> 00:00:02,25\r\n"
        "こんにちは\r\n\r\n"
        "00:00:02,500-->00:00:05,000\r\n"
        "元気ですか\r\n\r\n"
        "GARBAGE LINE\r\n\r\n"
        "3\r\n"
        "00:00:05,001 --> 00:00:07,999\r\n"
        "本文\r\n"
    )
    warnings: List[str] = []
    cues = srt_io.parse_srt(tolerant, warnings=warnings)
    check_eq(len(cues), 3, "脏块被跳过，保留 3 条")
    check_eq((cues[0].start_ms, cues[0].end_ms), (500, 2250), "点号毫秒/两位毫秒解析")
    check_eq((cues[1].start_ms, cues[1].end_ms), (2500, 5000), "箭头无空格可解析")
    check_eq((cues[2].start_ms, cues[2].end_ms), (5001, 7999), "第三条时间戳解析")
    check_eq(cues[1].text, "元気ですか", "缺序号块的正文正确")
    check_eq(len(warnings), 2, "记录 2 条解析警告")
    check(any("缺少时间轴" in w for w in warnings), "警告包含缺少时间轴：{0}".format(warnings))
    check(any("缺少序号行" in w for w in warnings), "警告包含缺少序号行")

    # 多个连续空行不应切碎条
    extra_blank = SAMPLE_JA.replace("\n\n2\n", "\n\n\n2\n")
    check_eq(len(srt_io.parse_srt(extra_blank)), 6, "多余空行不影响解析")

    warnings2: List[str] = []
    blank = "\ufeff\r\n\r\n"
    check_eq(srt_io.parse_srt(blank, warnings=warnings2), [], "只有空白的文件解析为 0 条")
    check_eq(srt_io.parse_srt(""), [], "空字符串解析为 0 条")
    check_eq(srt_io.serialize_srt([]), "", "0 条序列化为空字符串")


@test
def test_04_严格序列化() -> None:
    cues = srt_io.parse_srt(SAMPLE_JA)
    output = srt_io.serialize_srt(cues)
    check(output.endswith("\n"), "序列化结果以换行结尾")
    check_not_in("\r", output, "默认输出不含 CR")
    blocks = output.strip("\n").split("\n\n")
    check_eq(len(blocks), 6, "序列化得到 6 个块")
    check_eq(blocks[0].split("\n")[0], "1", "第一块序号为 1")
    for block in blocks:
        lines = block.split("\n")
        check_eq(len(lines), 3, "普通块为 3 行（序号/时间轴/文本）")
        start_text, end_text = lines[1].split(" --> ")
        check(srt_io.is_strict_timestamp(start_text), "起始时间戳严格格式：{0}".format(start_text))
        check(srt_io.is_strict_timestamp(end_text), "结束时间戳严格格式：{0}".format(end_text))
    reparse = srt_io.parse_srt(output)
    check_eq([(c.start_ms, c.end_ms, c.text) for c in reparse],
             [(c.start_ms, c.end_ms, c.text) for c in cues], "序列化后 round-trip 一致")

    crlf = srt_io.serialize_srt(cues, newline="\r\n")
    check_eq(crlf.count("\r\n"), crlf.count("\n"), "CRLF 模式下无孤立 LF")
    expect_error(lambda: srt_io.serialize_srt(cues, newline="bad"),
                 srt_io.SrtError, "非法换行参数应报错")

    multiline = srt_io.Cue(0, 3000, "第一行\n第二行")
    text = srt_io.serialize_srt([multiline])
    parsed = srt_io.parse_srt(text)
    check_eq(parsed[0].text, "第一行\n第二行", "多行文本可 round-trip")


@test
def test_05_文件读写与编码() -> None:
    cues = srt_io.parse_srt(SAMPLE_JA)
    with temp_dir() as tmp:
        utf8_path = os.path.join(tmp, "utf8.srt")
        srt_io.write_srt(utf8_path, cues)
        with open(utf8_path, "rb") as fh:
            raw = fh.read()
        check(not raw.startswith(b"\xef\xbb\xbf"), "默认输出 UTF-8 无 BOM")
        check_in("おはようございます。".encode("utf-8"), raw, "UTF-8 内容可读")

        bom_path = os.path.join(tmp, "bom.srt")
        srt_io.write_srt(bom_path, cues, encoding="utf-8-sig")
        with open(bom_path, "rb") as fh:
            bom_raw = fh.read()
        check(bom_raw.startswith(b"\xef\xbb\xbf"), "utf-8-sig 输出带 BOM")
        read_back, encoding, _ = srt_io.read_srt_with_meta(bom_path)
        check_eq(encoding, "utf-8-sig", "BOM 文件被识别为 utf-8-sig")
        check_eq(read_back[0].text, "おはようございます。", "BOM 文件读取不残留 BOM 字符")

        cp932_path = os.path.join(tmp, "cp932.srt")
        write_file(cp932_path, SAMPLE_JA, encoding="cp932")
        read_cp932, encoding_cp932, _ = srt_io.read_srt_with_meta(cp932_path)
        check_eq(len(read_cp932), 6, "Shift_JIS 文件可解析")
        check_eq(read_cp932[0].text, "おはようございます。", "Shift_JIS 文本正确")
        check(encoding_cp932 in ("cp932", "shift_jis"),
              "Shift_JIS 编码被识别：{0}".format(encoding_cp932))

        crlf_path = os.path.join(tmp, "crlf.srt")
        write_file(crlf_path, SAMPLE_JA.replace("\n", "\r\n"))
        check_eq(len(srt_io.read_srt(crlf_path)), 6, "CRLF 文件可解析")

        expect_error(lambda: srt_io.read_srt(os.path.join(tmp, "not-exist.srt")),
                     srt_io.SrtParseError, "读取不存在的 SRT 应报错")


@test
def test_06_双语合并三种排版() -> None:
    ja = srt_io.parse_srt(SAMPLE_JA)
    zh = srt_io.parse_srt(SAMPLE_ZH)
    for mode in ("zh_top", "ja_top", "same_line"):
        merged, warnings = srt_io.merge_bilingual(ja, zh, mode=mode, separator=" | ")
        check_eq(len(merged), 6, "{0} 模式条数正确".format(mode))
        check_eq(warnings, [], "{0} 模式无警告".format(mode))
        if mode == "zh_top":
            check_eq(merged[0].text.split("\n"), ["早上好。", "おはようございます。"],
                     "zh_top：中文在上、日文在下")
        elif mode == "ja_top":
            check_eq(merged[0].text.split("\n"), ["おはようございます。", "早上好。"],
                     "ja_top：日文在上、中文在下")
        else:
            check_eq(merged[0].text, "早上好。 | おはようございます。",
                     "same_line：同一行并用分隔符")
        check_eq([(c.start_ms, c.end_ms) for c in merged],
                 [(c.start_ms, c.end_ms) for c in ja], "{0} 模式时间轴以日文为准".format(mode))

    try:
        srt_io.merge_bilingual(ja, zh, mode="not-a-mode")
    except srt_io.SrtMergeError as exc:
        check("不支持的双语排版模式" in str(exc), "非法模式报中文错误")
    else:
        check(False, "非法双语模式应报错")

    same_line_empty = srt_io.Cue(0, 1000, "中文")
    same_line_only_ja = srt_io.Cue(0, 1000, "日本語")
    merged_one, _ = srt_io.merge_bilingual([same_line_only_ja], [same_line_empty],
                                           mode="same_line", separator=" / ")
    check_eq(merged_one[0].text, "中文 / 日本語", "same_line 空行处理正常")


# ---------------------------------------------------------------------------
# 测试 7~9：合并失败路径 / 配置
# ---------------------------------------------------------------------------

@test
def test_07_双语合并不一致报错() -> None:
    ja = srt_io.parse_srt(SAMPLE_JA)
    zh_short = srt_io.parse_srt(SAMPLE_ZH)[:5]
    try:
        srt_io.merge_bilingual(ja, zh_short)
        check(False, "条数不一致应报错")
    except srt_io.SrtMergeError as exc:
        check("条数不一致" in str(exc), "条数不一致错误信息为中文")
    merged, warnings = srt_io.merge_bilingual(ja, zh_short, allow_mismatch=True)
    check_eq(len(merged), 6, "allow_mismatch 保留全部日文条目")
    check_eq(merged[-1].text, ja[-1].text, "缺中文的条目用日文占位")
    check(any("条数不一致" in w for w in warnings), "allow_mismatch 记录条数警告")

    zh_aligned = srt_io.parse_srt(SAMPLE_ZH)
    zh_aligned[2].end_ms = zh_aligned[2].end_ms + 500
    try:
        srt_io.merge_bilingual(ja, zh_aligned)
        check(False, "时间戳不一致应报错")
    except srt_io.SrtMergeError as exc:
        check("时间戳不一致" in str(exc), "时间戳不一致错误信息为中文")
    merged2, warnings2 = srt_io.merge_bilingual(ja, zh_aligned, allow_mismatch=True)
    check_eq(len(merged2), 6, "allow_mismatch 仍产出全部条目")
    check(any("时间戳不一致" in w for w in warnings2), "allow_mismatch 记录时间戳警告")

    with temp_dir() as tmp:
        ja_path = write_file(os.path.join(tmp, "ja.srt"), SAMPLE_JA)
        zh_path = write_file(os.path.join(tmp, "zh.srt"), SAMPLE_ZH)
        out_path = os.path.join(tmp, "bilingual.srt")
        count, warnings3 = srt_io.merge_srt_files(
            ja_path, zh_path, out_path, mode="zh_top",
            encoding="utf-8", newline="\n")
        check_eq(count, 6, "merge_srt_files 输出 6 条")
        check_eq(warnings3, [], "merge_srt_files 无警告")
        check_eq(len(srt_io.read_srt(out_path)), 6, "双语文件可再次解析")


@test
def test_08_配置样例与自动复制() -> None:
    cfg, path = cfgmod.load_pipeline_config(EXAMPLE_CONFIG)
    check(str(path).endswith("pipeline.example.json"), "显式配置路径被采用")
    check_eq(cfg.get("paths", {}).get("input_dir"), "input", "paths.input_dir")
    check_eq(cfg.get("tools", {}).get("ffmpeg"), "tools/windows/ffmpeg/ffmpeg.exe",
             "tools.ffmpeg")
    check_eq(cfg.get("tools", {}).get("whisper_cli"),
             "tools/windows/whisper/whisper-cli.exe", "tools.whisper_cli")
    check_eq(cfg.get("tools", {}).get("llama_server"),
             "tools/windows/llama/llama-server.exe", "tools.llama_server")
    check_eq(cfg.get("models", {}).get("whisper"), "models/whisper/ggml-large-v3.bin",
             "models.whisper")
    check("models/translation" in cfg.get("models", {}).get("translation", ""),
          "models.translation 指向 models/translation")
    check_eq(cfg.get("audio", {}).get("sample_rate"), 16000, "audio.sample_rate 16000")
    check_eq(cfg.get("audio", {}).get("channels"), 1, "audio.channels 1")
    check_eq(cfg.get("llama", {}).get("port"), 8080, "llama.port 8080")
    check_eq(cfg.get("llama", {}).get("n_gpu_layers"), 99, "llama.n_gpu_layers 99")
    check_eq(cfg.get("translate", {}).get("api_base"), "http://127.0.0.1:8080/v1",
             "translate.api_base")
    check_eq(cfg.get("translate", {}).get("concurrency"), 2, "translate.concurrency")
    check_eq(cfg.get("translate", {}).get("context_size"), 4, "translate.context_size")
    check_in("{context}", cfg.get("translate", {}).get("user_template", ""),
             "prompt 模板含 {context} 占位符")
    check_in("{text}", cfg.get("translate", {}).get("user_template", ""),
             "prompt 模板含 {text} 占位符")
    check_in(cfg.get("bilingual", {}).get("mode"), srt_io.BILINGUAL_MODES,
             "bilingual.mode 合法")
    check_eq(cfg.get("qc", {}).get("max_cps"), 15.0, "qc.max_cps")
    check_eq(cfg.get("srt", {}).get("encoding"), "utf-8", "srt.encoding 默认 UTF-8 无 BOM")
    check_eq(cfg.get("srt", {}).get("newline"), "lf", "srt.newline 默认 LF")
    check(isinstance(cfg.get("input_extensions"), list)
          and len(cfg.get("input_extensions")) >= 8, "input_extensions 收录常见音视频后缀")
    check("mp4" not in cfg.get("input_extensions"), "扩展名带点（.mp4）")

    # 自动复制：临时“项目根”下只有 example，应复制出 pipeline.json 并提示
    with temp_dir() as tmp:
        cfg_dir = os.path.join(tmp, "config")
        os.makedirs(cfg_dir)
        shutil.copyfile(EXAMPLE_CONFIG, os.path.join(cfg_dir, "pipeline.example.json"))
        stderr_buffer = io.StringIO()
        with contextlib.redirect_stderr(stderr_buffer):
            copied_path, copied = cfgmod.ensure_config(root=Path(tmp))
        check(copied, "缺失 pipeline.json 时自动复制")
        check(os.path.isfile(str(copied_path)), "自动复制后的配置文件存在")
        check("自动复制" in stderr_buffer.getvalue(), "自动复制时输出中文提示")
        _, copied_again = cfgmod.ensure_config(root=Path(tmp))
        check(not copied_again, "第二次调用不再复制")
        loaded, _ = cfgmod.load_pipeline_config(root=Path(tmp))
        check_eq(loaded.get("tools", {}).get("ffmpeg"), "tools/windows/ffmpeg/ffmpeg.exe",
                 "自动复制的配置可正常加载")

    with temp_dir() as tmp:
        bad_path = os.path.join(tmp, "bad.json")
        write_file(bad_path, "{ 不是合法 JSON }")
        try:
            cfgmod.load_pipeline_config(bad_path)
        except cfgmod.ConfigError as exc:
            check("不是合法 JSON" in str(exc), "非法 JSON 配置报中文错误")
        else:
            check(False, "非法 JSON 配置应报错")


# ---------------------------------------------------------------------------
# 测试 10~12：翻译 --mock 端到端 / 失败路径
# ---------------------------------------------------------------------------

@test
def test_09_mock_伪译文确定性() -> None:
    import translate_srt as tr
    first = tr.mock_translate("おはよう", 1)
    second = tr.mock_translate("おはよう", 1)
    check_eq(first, second, "同一输入 mock 译文完全一致")
    check(not srt_io.has_kana(first), "mock 译文不含日文假名")
    check(tr.normalize_translation("「译文：你好」").startswith("你好"),
          "normalize_translation 去掉前缀与包裹引号")
    check_eq(tr.normalize_translation("  第一行\n第二行  "), "第一行 第二行",
             "normalize_translation 压平多行")
    check_eq(tr.validate_alignment([], [], "测试"), [], "空列表对齐校验通过")
    ja = srt_io.parse_srt(SAMPLE_JA)
    broken = [srt_io.Cue(c.start_ms + 100, c.end_ms, c.text) for c in ja]
    errors = tr.validate_alignment(ja, broken, "中文")
    check(errors and "时间戳不一致" in errors[0], "validate_alignment 能发现时间戳错误")
    check_eq(tr._chat_completions_url("http://127.0.0.1:8080"),
             "http://127.0.0.1:8080/v1/chat/completions", "接口地址自动补 /v1")
    check_eq(tr._chat_completions_url("http://127.0.0.1:8080/v1"),
             "http://127.0.0.1:8080/v1/chat/completions", "已带 /v1 不重复拼接")
    # 回归：翻译参数必须读 translate.*（早期误读 translation.*，导致模型名/接口不生效）
    cfg_example, _ = cfgmod.load_pipeline_config(EXAMPLE_CONFIG)
    check_eq(tr._cfg_translate_value(cfg_example, "model", "默认"), "Hy-MT2-7B-Q8_0",
             "translate.model 从 translate.* 读取")
    check_eq(tr._cfg_translate_value({"translation": {"model": "旧写法"}}, "model", "默认"),
             "旧写法", "兼容旧 translation.* 写法")
    check_eq(tr._cfg_translate_value({}, "model", "默认"), "默认", "缺失配置时用默认值")


@test
def test_10_翻译_mock_端到端() -> None:
    with temp_dir() as tmp:
        ja_path = write_file(os.path.join(tmp, "ja.srt"), SAMPLE_JA)
        out_dir = os.path.join(tmp, "out1")
        completed = run_cli("translate_srt.py", [
            "--input", ja_path, "--output-dir", out_dir,
            "--config", EXAMPLE_CONFIG, "--mock",
        ])
        output = cli_output(completed)
        check_eq(completed.returncode, 0, "--mock 退出码 0")
        for marker in ("[校验] 中文条数与时间戳", "[校验] 双语条数与时间戳",
                       "[完成]", "离线模拟"):
            check(marker in output, "输出包含：{0}".format(marker))

        zh_path = os.path.join(out_dir, "zh.srt")
        bilingual_path = os.path.join(out_dir, "bilingual.srt")
        report_path = os.path.join(out_dir, "report.json")
        for path in (zh_path, bilingual_path, report_path):
            check(os.path.isfile(path), "产物存在：{0}".format(os.path.basename(path)))

        ja = srt_io.read_srt(ja_path)
        zh = srt_io.read_srt(zh_path)
        bilingual = srt_io.read_srt(bilingual_path)
        check_eq(len(zh), len(ja), "中文条数与日文逐条一致")
        check_eq(len(bilingual), len(ja), "双语条数与日文逐条一致")
        check_eq([(c.start_ms, c.end_ms) for c in zh],
                 [(c.start_ms, c.end_ms) for c in ja], "中文时间戳与日文逐条一致")
        check_eq([(c.start_ms, c.end_ms) for c in bilingual],
                 [(c.start_ms, c.end_ms) for c in ja], "双语时间戳与日文逐条一致")
        check(all(c.text.strip() for c in zh), "中文每条都有内容")
        check(all(not srt_io.has_kana(c.text) for c in zh), "mock 中文不含日文假名")
        check(all(c.text != ja[i].text for i, c in enumerate(zh)), "mock 译文与原文不同")
        check(all("【模拟】" in c.text for c in zh), "mock 译文带模拟标记，避免误当真译文")
        for index, cue in enumerate(bilingual):
            lines = cue.text.split("\n")
            check_eq(len(lines), 2, "双语第 {0} 条为两行".format(index + 1))
            check_eq(lines[0], zh[index].text, "双语第 {0} 条第一行为中文".format(index + 1))
            check_eq(lines[1], ja[index].text, "双语第 {0} 条第二行为日文".format(index + 1))

        with open(report_path, "r", encoding="utf-8") as fh:
            report = json.load(fh)
        check_eq(report.get("mode"), "mock", "报告 mode=mock")
        check_eq(report.get("stats", {}).get("input_cues"), 6, "报告记录输入条数")
        check_eq(report.get("stats", {}).get("failed"), 0, "报告记录 0 失败")
        validation = report.get("validation", {})
        for key in ("zh_count_matches_input", "zh_timestamps_match_input",
                    "bilingual_count_matches_input", "bilingual_timestamps_match_input"):
            check_eq(validation.get(key), True, "报告校验字段：{0}".format(key))
        check(isinstance(report.get("outputs", {}).get("zh"), str), "报告含中文输出路径")
        check_eq(report.get("stats", {}).get("fallback_to_source"), 0, "报告回退数为 0")

        # 结果可重复：再跑一次，中文文件字节一致
        out_dir2 = os.path.join(tmp, "out2")
        completed2 = run_cli("translate_srt.py", [
            "--input", ja_path, "--output-dir", out_dir2,
            "--config", EXAMPLE_CONFIG, "--mock",
        ])
        check_eq(completed2.returncode, 0, "第二次 --mock 退出码 0")
        with open(zh_path, "rb") as fh:
            first_bytes = fh.read()
        with open(os.path.join(out_dir2, "zh.srt"), "rb") as fh:
            second_bytes = fh.read()
        check_eq(first_bytes, second_bytes, "--mock 产物可重复（字节一致）")

        # 方案B 配置回归：model 含 Hy-MT2 → 自动套 hunyuan 提示词，且报告记录真实模型名
        with open(EXAMPLE_CONFIG, "r", encoding="utf-8") as fh:
            planb_cfg = json.load(fh)
        planb_cfg["translate"]["model"] = "Hy-MT2-7B-Q8_0"
        planb_path = os.path.join(tmp, "pipeline.planB.json")
        with open(planb_path, "w", encoding="utf-8") as fh:
            json.dump(planb_cfg, fh, ensure_ascii=False, indent=2)
        out_planb = os.path.join(tmp, "out_planb")
        completed_b = run_cli("translate_srt.py", [
            "--input", ja_path, "--output-dir", out_planb,
            "--config", planb_path, "--mock",
        ])
        check_eq(completed_b.returncode, 0, "方案B 配置 --mock 退出码 0")
        with open(os.path.join(out_planb, "report.json"), "r", encoding="utf-8") as fh:
            report_b = json.load(fh)
        check_eq(report_b.get("model"), "Hy-MT2-7B-Q8_0",
                 "方案B 报告记录 translate.model")
        check_eq(report_b.get("prompt_style"), "hunyuan",
                 "方案B 自动选用 hunyuan 提示词")

        # --dry-run：不写产物
        out_dir3 = os.path.join(tmp, "dry")
        completed3 = run_cli("translate_srt.py", [
            "--input", ja_path, "--output-dir", out_dir3,
            "--config", EXAMPLE_CONFIG, "--dry-run",
        ])
        output3 = cli_output(completed3)
        check_eq(completed3.returncode, 0, "--dry-run 退出码 0")
        check("[预览]" in output3, "--dry-run 打印预览")
        check(not os.path.isdir(out_dir3) or not os.listdir(out_dir3),
              "--dry-run 不写任何文件")

    # mock 与 dry-run 互斥
    with temp_dir() as tmp:
        ja_path = write_file(os.path.join(tmp, "ja.srt"), SAMPLE_JA)
        completed4 = run_cli("translate_srt.py", [
            "--input", ja_path, "--output-dir", os.path.join(tmp, "x"),
            "--config", EXAMPLE_CONFIG, "--mock", "--dry-run",
        ])
        check_eq(completed4.returncode, 1, "--mock 与 --dry-run 同时使用退出码 1")
        check("[错误]" in cli_output(completed4), "互斥参数报中文错误")


@test
def test_11_翻译失败路径_接口不可用() -> None:
    dead_api = "http://127.0.0.1:59999/v1"
    with temp_dir() as tmp:
        ja_path = write_file(os.path.join(tmp, "ja.srt"), SAMPLE_JA)
        # 不启用回退：应直接非零失败
        completed = run_cli("translate_srt.py", [
            "--input", ja_path, "--output-dir", os.path.join(tmp, "no_fallback"),
            "--config", EXAMPLE_CONFIG, "--api-base", dead_api,
            "--no-health-check", "--retries", "0", "--timeout", "2",
            "--no-fallback", "--concurrency", "2",
        ])
        output = cli_output(completed)
        check_eq(completed.returncode, 1, "接口不可用且禁止回退时退出码 1")
        check("[错误]" in output, "接口不可用输出中文错误")
        check("失败" in output or "错误" in output, "错误信息为中文")

        # 启用回退：产物写出，退出码 2，报告中记录失败
        out_dir = os.path.join(tmp, "with_fallback")
        completed2 = run_cli("translate_srt.py", [
            "--input", ja_path, "--output-dir", out_dir,
            "--config", EXAMPLE_CONFIG, "--api-base", dead_api,
            "--no-health-check", "--retries", "0", "--timeout", "2",
            "--concurrency", "2",
        ])
        check_eq(completed2.returncode, 2, "接口不可用但启用回退时退出码 2")
        output2 = cli_output(completed2)
        check("[结果] 部分失败" in output2, "回退模式提示部分失败")
        zh_path = os.path.join(out_dir, "zh.srt")
        report_path = os.path.join(out_dir, "report.json")
        check(os.path.isfile(zh_path), "回退模式仍写出中文文件")
        check(os.path.isfile(report_path), "回退模式仍写出报告")
        zh = srt_io.read_srt(zh_path)
        ja = srt_io.read_srt(ja_path)
        check_eq(len(zh), len(ja), "回退后条数仍一致")
        check_eq([(c.start_ms, c.end_ms) for c in zh],
                 [(c.start_ms, c.end_ms) for c in ja], "回退后时间戳仍逐条一致")
        check_eq([c.text for c in zh], [c.text for c in ja], "回退内容为日文原文")
        with open(report_path, "r", encoding="utf-8") as fh:
            report = json.load(fh)
        check_eq(report.get("stats", {}).get("failed"), 6, "报告记录 6 条失败")
        check_eq(report.get("stats", {}).get("fallback_to_source"), 6, "报告记录 6 条回退")
        check(len(report.get("failures", [])) == 6, "报告 failures 明细完整")
        check(report.get("validation", {}).get("zh_kana_residue_cues") == 6,
              "报告统计中文文件含假名条数")


# ---------------------------------------------------------------------------
# 测试 13~16：质检 / 命令行冒烟
# ---------------------------------------------------------------------------

def _qc_arguments(input_path: str, report_path: str,
                  reference_path: Optional[str] = None,
                  extra: Optional[List[str]] = None) -> List[str]:
    args = ["--input", input_path, "--report", report_path, "--config", EXAMPLE_CONFIG]
    if reference_path:
        args.extend(["--reference", reference_path])
    if extra:
        args.extend(extra)
    return args


@test
def test_12_质检_正常文件通过() -> None:
    with temp_dir() as tmp:
        ja_path = write_file(os.path.join(tmp, "ja.srt"), SAMPLE_JA)
        zh_path = write_file(os.path.join(tmp, "zh.srt"), SAMPLE_ZH)
        report_path = os.path.join(tmp, "report.json")
        completed = run_cli("qc_srt.py", _qc_arguments(zh_path, report_path, ja_path))
        output = cli_output(completed)
        check_eq(completed.returncode, 0, "正常中文字幕质检退出码 0")
        check("[结果] 质检通过" in output, "打印质检通过")
        check(os.path.isfile(report_path), "写出质检 JSON 报告")
        with open(report_path, "r", encoding="utf-8") as fh:
            report = json.load(fh)
        check_eq(report.get("summary", {}).get("cues"), 6, "报告条数 6")
        check_eq(report.get("summary", {}).get("errors"), 0, "报告 0 错误")
        check_eq(report.get("summary", {}).get("warnings"), 0, "报告 0 警告")
        check_eq(report.get("summary", {}).get("passed"), True, "报告结论通过")
        check_eq(report.get("reference", {}).get("count"), 6, "报告记录参考条数")
        check_eq(report.get("reference", {}).get("timestamp_mismatch_count"), 0,
                 "报告无时间戳不一致")
        metrics = report.get("metrics", {})
        for key in ("cps_max", "cps_mean", "duration_min_ms", "duration_max_ms",
                    "total_duration_ms"):
            check(key in metrics, "报告包含指标字段：{0}".format(key))
        check_eq(metrics.get("duration_max_ms"), 3000, "最长时长 3000ms")


@test
def test_13_质检_异常文件报错() -> None:
    bad_zh = """1
00:00:00,000 --> 00:00:02,500
早上好。

2
00:00:02,000 --> 00:00:05,500
今天天气真不错。

3
00:00:06,000 --> 00:00:06,000
待ってください

4
00:00:09,500 --> 00:00:12,000
 
5
00:00:12,500 --> 00:00:15,000
这是一个故意写得很长很长很长很长很长很长很长很长很长很长的句子用来触发每秒字符数上限检查。

6
00:00:15,500 --> 00:00:15,800
谢谢您。

7
00:00:18,000 --> 00:00:20,000
多余的句子。
"""
    with temp_dir() as tmp:
        ja_path = write_file(os.path.join(tmp, "ja.srt"), SAMPLE_JA)
        bad_path = write_file(os.path.join(tmp, "zh.srt"), bad_zh)
        report_path = os.path.join(tmp, "report.json")
        completed = run_cli("qc_srt.py", _qc_arguments(bad_path, report_path, ja_path))
        output = cli_output(completed)
        check_eq(completed.returncode, 1, "异常字幕退出码 1")
        check("[结果] 质检不通过" in output, "打印质检不通过")
        with open(report_path, "r", encoding="utf-8") as fh:
            report = json.load(fh)
        codes = [item["code"] for item in report.get("issues", [])]
        for code in ("count_mismatch", "timestamp_mismatch", "overlap",
                     "invalid_duration", "empty_text", "kana_residue",
                     "cps_over", "duration_too_short"):
            check_in(code, codes, "质检报告包含问题码：{0}".format(code))
        severities = {item["code"]: item["severity"] for item in report.get("issues", [])}
        check_eq(severities.get("overlap"), "error", "重叠为 error")
        check_eq(severities.get("kana_residue"), "error", "日文残留为 error")
        check_eq(severities.get("cps_over"), "warning", "CPS 超限为 warning")
        check(report.get("summary", {}).get("passed") is False, "异常报告 passed=false")
        check(report.get("summary", {}).get("errors", 0) >= 5, "报告错误项数量合理")


@test
def test_14_质检_strict_模式() -> None:
    # 只有 CPS 警告：时间戳、条数、时长、文本均正常
    long_text = "这是一个很长的句子" * 6
    warning_zh = """1
00:00:00,000 --> 00:00:03,000
{0}

2
00:00:03,000 --> 00:00:06,000
第二句正常。
""".format(long_text)
    ref = """1
00:00:00,000 --> 00:00:03,000
参考一。

2
00:00:03,000 --> 00:00:06,000
参考二。
"""
    with temp_dir() as tmp:
        ja_path = write_file(os.path.join(tmp, "ja.srt"), ref)
        zh_path = write_file(os.path.join(tmp, "zh.srt"), warning_zh)
        report_path = os.path.join(tmp, "report.json")
        completed = run_cli("qc_srt.py", _qc_arguments(zh_path, report_path, ja_path))
        check_eq(completed.returncode, 0, "仅有警告时默认退出码 0")
        with open(report_path, "r", encoding="utf-8") as fh:
            report = json.load(fh)
        check_eq(report.get("summary", {}).get("errors"), 0, "仅有警告：0 错误")
        check(report.get("summary", {}).get("warnings", 0) >= 1, "仅有警告：至少 1 项警告")
        codes = [item["code"] for item in report.get("warnings", [])]
        check_in("cps_over", codes, "警告中包含 CPS 超限")

        report_path2 = os.path.join(tmp, "report_strict.json")
        completed2 = run_cli("qc_srt.py",
                             _qc_arguments(zh_path, report_path2, ja_path, ["--strict"]))
        check_eq(completed2.returncode, 1, "--strict 下警告导致退出码 1")
        check("--strict" in cli_output(completed2), "--strict 模式有中文提示")


@test
def test_15_合并脚本_命令行() -> None:
    with temp_dir() as tmp:
        ja_path = write_file(os.path.join(tmp, "ja.srt"), SAMPLE_JA)
        zh_path = write_file(os.path.join(tmp, "zh.srt"), SAMPLE_ZH)
        out_path = os.path.join(tmp, "bilingual.srt")
        completed = run_cli("merge_srt.py", [
            "--ja", ja_path, "--zh", zh_path, "--out", out_path,
            "--config", EXAMPLE_CONFIG,
        ])
        output = cli_output(completed)
        check_eq(completed.returncode, 0, "合并脚本退出码 0")
        check("[校验] 双语文件条数与时间戳" in output, "合并脚本打印校验通过")
        check(os.path.isfile(out_path), "合并产物存在")
        merged = srt_io.read_srt(out_path)
        check_eq(len(merged), 6, "合并产物 6 条")
        check_eq(merged[0].text.split("\n"), ["早上好。", "おはようございます。"],
                 "合并产物为中文在上日文在下")
        check_eq([(c.start_ms, c.end_ms) for c in merged],
                 [(c.start_ms, c.end_ms) for c in srt_io.read_srt(ja_path)],
                 "合并产物时间轴与日文一致")

        # 条数不一致：退出码 2 + 中文错误，且不写输出文件
        zh_bad_path = write_file(os.path.join(tmp, "zh_bad.srt"),
                                 "1\n00:00:00,000 --> 00:00:02,500\n早上好。\n")
        out_bad = os.path.join(tmp, "bilingual_bad.srt")
        completed2 = run_cli("merge_srt.py", [
            "--ja", ja_path, "--zh", zh_bad_path, "--out", out_bad,
            "--config", EXAMPLE_CONFIG,
        ])
        check_eq(completed2.returncode, 2, "条数不一致时合并脚本退出码 2")
        check("条数不一致" in cli_output(completed2), "合并失败输出中文错误")
        check(not os.path.isfile(out_bad), "合并失败不写输出文件")


@test
def test_16_命令行_help_与_srt_io_冒烟() -> None:
    for script in ("translate_srt.py", "merge_srt.py", "qc_srt.py", "srt_io.py",
                   "pipeline_config.py"):
        completed = run_cli(script, ["--help"])
        check_eq(completed.returncode, 0, "{0} --help 可用".format(script))

    with temp_dir() as tmp:
        ja_path = write_file(os.path.join(tmp, "ja.srt"), SAMPLE_JA)
        completed = run_cli("srt_io.py", [ja_path, "--json"])
        check_eq(completed.returncode, 0, "srt_io 排查模式退出码 0")
        payload = json.loads(completed.stdout)
        check_eq(payload.get("count"), 6, "srt_io --json 条数正确")
        check_eq(payload.get("encoding"), "utf-8", "srt_io 检测出 UTF-8 编码")
        check(isinstance(payload.get("cues"), list), "srt_io --json 输出条列表")


@test
def test_17_分片合并与清洗() -> None:
    with temp_dir() as tmp:
        parts_dir = os.path.join(tmp, "parts")
        os.makedirs(parts_dir)
        write_file(os.path.join(parts_dir, "ja.part000.srt"),
                   "1\n00:00:01,000 --> 00:00:02,000\nおはようございます。\n")
        write_file(os.path.join(parts_dir, "ja.part001.srt"),
                   "1\n00:00:01,000 --> 00:00:02,000\nご視聴ありがとうございました\n\n"
                   "2\n00:00:03,000 --> 00:00:04,000\nあっ\n\n"
                   "3\n00:00:05,000 --> 00:00:06,000\n今日はいい天気ですね。\n")
        write_file(os.path.join(parts_dir, "ja.part002.srt"), "")
        write_file(os.path.join(parts_dir, "ja.part003.srt"),
                   "1\n00:00:02,000 --> 00:00:03,000\n♪\n\n2\n00:00:04,000 --> 00:00:05,000\n→→\n")
        out_path = os.path.join(tmp, "ja.srt")
        report_path = os.path.join(tmp, "transcribe-report.json")
        completed = run_cli("merge_srt_parts.py", [
            "--parts-dir", parts_dir, "--prefix", "ja.part", "--chunk-seconds", "600",
            "--out", out_path, "--report", report_path,
        ])
        output = cli_output(completed)
        check_eq(completed.returncode, 0, "分片合并退出码 0")
        check("[分片] 4 片" in output, "合并打印分片数")
        cues = srt_io.read_srt(out_path)
        check_eq(len(cues), 2, "清洗后保留 2 条（幻觉/语气词/纯符号/空分片被丢弃）")
        check_eq(cues[0].text, "おはようございます。", "第 0 片时间戳不平移，文本保留")
        check_eq(cues[0].start_ms, 1000, "第 0 片起始时间不变")
        check_eq(cues[1].start_ms, 600000 + 5000, "第 1 片时间戳平移 600 秒")
        check_eq(cues[1].text, "今日はいい天気ですね。", "第 1 片有效对白保留")
        with open(report_path, "r", encoding="utf-8") as fh:
            report = json.load(fh)
        check_eq(report.get("parts"), 4, "报告分片数 4")
        check_eq(report.get("raw_cues"), 6, "报告原始条数 6")
        check_eq(report.get("kept_cues"), 2, "报告保留条数 2")
        check_eq(report.get("dropped", {}).get("hallucination"), 1, "报告丢弃幻觉 1")
        check_eq(report.get("dropped", {}).get("filler"), 2, "报告丢弃纯语气 2（あっ、♪）")
        check_eq(report.get("dropped", {}).get("symbol_only"), 1, "报告丢弃纯符号 1")

        # --no-clean：保留全部原始条目（空分片仍为 0 条）
        out_raw = os.path.join(tmp, "ja_raw.srt")
        completed2 = run_cli("merge_srt_parts.py", [
            "--parts-dir", parts_dir, "--chunk-seconds", "600",
            "--out", out_raw, "--no-clean",
        ])
        check_eq(completed2.returncode, 0, "--no-clean 退出码 0")
        check_eq(len(srt_io.read_srt(out_raw)), 6, "--no-clean 保留全部 6 条")

        # 错误路径：目录不存在 / 无匹配分片 / 非法片长
        completed3 = run_cli("merge_srt_parts.py", [
            "--parts-dir", os.path.join(tmp, "not-exist"),
            "--out", os.path.join(tmp, "x.srt"),
        ])
        check_eq(completed3.returncode, 1, "分片目录不存在时退出码 1")
        check("分片目录不存在" in cli_output(completed3), "分片目录错误信息为中文")

        empty_dir = os.path.join(tmp, "empty")
        os.makedirs(empty_dir)
        completed4 = run_cli("merge_srt_parts.py", [
            "--parts-dir", empty_dir, "--out", os.path.join(tmp, "y.srt"),
        ])
        check_eq(completed4.returncode, 1, "没有匹配分片时退出码 1")

        completed5 = run_cli("merge_srt_parts.py", [
            "--parts-dir", parts_dir, "--chunk-seconds", "0",
            "--out", os.path.join(tmp, "z.srt"),
        ])
        check_eq(completed5.returncode, 1, "片长为 0 时退出码 1")


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def main() -> int:
    print("=" * 62)
    print("LocalSub 字幕流水线 Python 自检（不依赖模型 / 不联网）")
    print("Python 版本：{0}".format(sys.version.split()[0]))
    print("项目根目录：{0}".format(PROJECT_ROOT))
    print("配置样例：{0}".format(EXAMPLE_CONFIG))
    print("=" * 62)
    for func in TESTS:
        run_test(func)

    print("-" * 62)
    total = len(TESTS)
    passed = total - len(FAILURES)
    summary = "通过 {0}/{1} 项测试，共 {2} 项断言通过".format(passed, total, CHECKS_PASSED)
    if CHECKS_FAILED or FAILURES:
        print("{0}结果：FAIL{1}（{2}，{3} 项断言失败）".format(
            RED, RESET, summary, CHECKS_FAILED))
        for failure in FAILURES:
            print("  - {0}：{1}".format(failure["test"], failure["reason"]))
        return 1
    print("{0}结果：PASS{1}（{2}，0 项失败）".format(GREEN, RESET, summary))
    return 0


if __name__ == "__main__":
    if not os.path.isfile(EXAMPLE_CONFIG):
        print("错误：找不到配置样例 {0}，无法继续自检。".format(EXAMPLE_CONFIG),
              file=sys.stderr)
        sys.exit(1)
    sys.exit(main())
