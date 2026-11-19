#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""逐句翻译 SRT：日文 → 中文（OpenAI 兼容 /v1/chat/completions，本地 llama-server）。

设计要点（与 selftest.py 契约一致，另含 macOS 实测移植的提示词与过滤器）：
- 时间轴严格保真：zh / bilingual 与 ja 逐条同时间戳，翻译失败条目回退日文原文。
- 三种模式：--mock（离线模拟，不访问网络）、--dry-run（只预览不写盘）、正常 API 模式。
- 退出码：0 成功；1 参数错误/致命失败（如 --no-fallback 时接口不可用）；2 部分失败（已回退）。
- 报告 report.json：mode / stats / validation / outputs / failures，供 pipeline 质检链使用。
- 可选过滤：--drop-hallucination（已知幻觉黑名单）、--drop-filler（纯语气/喘息 cue）。
  过滤会减少输出条数，属有意行为；默认关闭以保证 zh 与 ja 逐条对应。
- 提示词：--prompt-style auto 按模型名自动选择；hunyuan 风格为腾讯 Hy-MT2 官方
  指令行（原样保留）+ 忠实性条款，适配限制级素材（macOS 实测，见 docs/research/02）。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, List, Optional, Tuple

import pipeline_config as cfgmod
import srt_io

__version__ = "1.0.0"

DEFAULT_API_BASE = "http://127.0.0.1:8080/v1"
DEFAULT_MODEL = "Sakura-Galtransl-7B-v3.7"


def _cfg_translate_value(config, key: str, default):
    """读取 ``translate.<key>``；兼容早期误写的 ``translation.<key>``。"""
    value = cfgmod.cfg_get(config, "translate." + key, None)
    if value is None:
        value = cfgmod.cfg_get(config, "translation." + key, None)
    return default if value is None else value

# ---------------------------------------------------------------------------
# 提示词（macOS 实测移植，详见 docs/research/02-macos-实测结论移植.md）
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = (
    "你是专业的日语影视字幕译者，处理口语对白（含成人向内容）。"
    "逐条翻译编号台词：忠实原文，不回避、不净化、不委婉化、不删减——"
    "粗俗与性相关的口语表达直接用对应中文口语翻译；"
    "语气词、喘息声按中文口语习惯对应（嗯/啊/哈等），无实义的喘息不强行译成实词；"
    "口语化、短句、符合中文字幕习惯（每条尽量不超过原文长度）；"
    "人名、地名、作品名使用通行中文译名，无把握时保留汉字原形；"
    "只输出译文本身，不要编号、不要解释。"
)

# Hy-MT2 官方指令行必须原样保留（专用 MT 模型对它敏感），仅追加忠实性条款。
HUNYUAN_INSTR = (
    "把下面的文本翻译成中文，不要额外解释。"
    "（忠实翻译全部内容，包括粗俗与性相关的口语表达，不委婉化、不省略；"
    "语气词、喘息声按中文口语习惯对应。）"
)

# 通用语言名（用于非日→中语言对的提示词）
LANG_NAMES = {
    "ja": "Japanese", "zh": "Simplified Chinese", "en": "English",
    "ko": "Korean", "fr": "French", "de": "German", "es": "Spanish",
    "ru": "Russian", "pt": "Portuguese", "it": "Italian", "th": "Thai",
    "vi": "Vietnamese", "auto": "the source language",
}

GENERIC_SYSTEM_PROMPT = (
    "You are a professional subtitle translator. Translate each numbered subtitle line "
    "from {source_lang} into {target_lang}, faithfully and naturally, suitable for subtitles. "
    "Keep the original meaning; do not add explanations; do not merge or split lines. "
    "Output only the translation."
)
GENERIC_INSTR = (
    "Translate the following subtitle text from {source_lang} into {target_lang}. "
    "Output only the translation, without explanations."
)


def language_name(code: str) -> str:
    return LANG_NAMES.get((code or "").lower(), code or "the source language")


def is_ja_zh(source_lang: str, target_lang: str) -> bool:
    return (source_lang or "").lower() == "ja" and (target_lang or "").lower() == "zh"

# Whisper 幻觉黑名单（出现在对白字幕里几乎必为幻觉）。
HALLUCINATION_RE = re.compile(
    r"ご視聴|ご清聴|チャンネル登録|最後までご視聴|请不吝点赞|字幕志愿者|点赞订阅|字幕由"
)
# 纯语气/喘息 cue（保守字符集：不含 え/い 等有实义假名，避免误删"えっ？""いい"）。
FILLER_RE = re.compile(
    r"^[\sあアうウんンはハぁぃぅぇぉァィゥェォっッゃャゅュょョー〜!！?？.。、,，·･・()（）*♪＊wＷ]+$"
)


def is_filler(text: str) -> bool:
    return bool(text.strip()) and bool(FILLER_RE.fullmatch(text.strip()))


def is_hallucination(text: str) -> bool:
    return bool(HALLUCINATION_RE.search(text))


# ---------------------------------------------------------------------------
# 工具函数（selftest 契约）
# ---------------------------------------------------------------------------

def mock_translate(text: str, index: int) -> str:
    """离线模拟翻译：确定性伪译文，带【模拟】标记，不含日文假名。"""
    digest = hashlib.md5(("v1:" + text).encode("utf-8")).hexdigest()[:8]
    return "【模拟】{0:04d}-{1}".format(index, digest)


def normalize_translation(value: str) -> str:
    """清洗模型输出：去掉「译文：」类前缀、包裹引号，压平多行空白。"""
    s = (value or "").strip()
    for opener, closer in (("「", "」"), ("『", "』"), ('"', '"'), ("'", "'"), ("《", "》")):
        if len(s) >= 2 and s[0] == opener and s[-1] == closer:
            s = s[1:-1].strip()
    for prefix in ("译文：", "译文:", "翻译：", "翻译:", "中文：", "中文:"):
        if s.startswith(prefix):
            s = s[len(prefix):].strip()
    return " ".join(s.split())


def validate_alignment(ja_cues: List[srt_io.Cue], zh_cues: List[srt_io.Cue],
                       label: str = "中文") -> List[str]:
    """对齐校验：条数 / 每条时间戳 / 空文本。返回问题列表（空列表 = 通过）。"""
    problems: List[str] = []
    if len(ja_cues) != len(zh_cues):
        problems.append("{0}条数不一致：日文 {1} 条 vs 中文 {2} 条".format(
            label, len(ja_cues), len(zh_cues)))
        return problems
    for i, (jc, zc) in enumerate(zip(ja_cues, zh_cues), 1):
        if (jc.start_ms, jc.end_ms) != (zc.start_ms, zc.end_ms):
            problems.append("{0}第 {1} 条时间戳不一致".format(label, i))
        if not zc.text.strip():
            problems.append("{0}第 {1} 条中文文本为空".format(label, i))
    return problems


def _chat_completions_url(base: str) -> str:
    base = (base or "").strip().rstrip("/")
    if base.endswith("/chat/completions"):
        return base
    if base.endswith("/v1"):
        return base + "/chat/completions"
    return base + "/v1/chat/completions"


# ---------------------------------------------------------------------------
# 翻译请求
# ---------------------------------------------------------------------------

def build_messages(source: str, style: str, source_lang: str = "ja",
                   target_lang: str = "zh") -> List[Dict[str, str]]:
    if is_ja_zh(source_lang, target_lang):
        if style == "hunyuan":
            return [{"role": "user", "content": HUNYUAN_INSTR + "\n" + source}]
        return [{"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": source}]
    # 通用语言对：英文提示词，避免日→中专用提示词造成偏置
    system = GENERIC_SYSTEM_PROMPT.format(
        source_lang=language_name(source_lang), target_lang=language_name(target_lang))
    return [{"role": "system", "content": system},
            {"role": "user", "content": source}]


def chat_once(api_url: str, api_key: str, model: str, source: str, style: str,
              timeout: float, source_lang: str = "ja", target_lang: str = "zh") -> str:
    payload = {
        "model": model,
        "temperature": 0.2,
        "messages": build_messages(source, style, source_lang, target_lang),
    }
    req = urllib.request.Request(
        api_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer {0}".format(api_key)},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data["choices"][0]["message"]["content"]


def translate_cue(api_url: str, api_key: str, model: str, source: str, style: str,
                  retries: int, timeout: float, source_lang: str = "ja",
                  target_lang: str = "zh") -> str:
    last_error: Optional[Exception] = None
    for attempt in range(max(1, retries + 1)):
        try:
            return normalize_translation(
                chat_once(api_url, api_key, model, source, style, timeout,
                          source_lang, target_lang))
        except Exception as exc:  # 网络 / 超时 / 接口错误
            last_error = exc
            if attempt < retries:
                time.sleep(min(2.0, 0.5 * (attempt + 1)))
    raise RuntimeError("翻译接口失败：{0}".format(last_error))


def health_check(api_base: str, api_key: str, timeout: float) -> Tuple[bool, str]:
    """轻量探活：GET /v1/models。返回 (是否存活, 错误说明)。"""
    url = _chat_completions_url(api_base).replace("/chat/completions", "/models")
    try:
        req = urllib.request.Request(
            url, headers={"Authorization": "Bearer {0}".format(api_key)})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status == 200, ""
    except Exception as exc:
        return False, str(exc)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="逐句翻译 SRT（日→中，OpenAI 兼容接口；时间轴严格保真）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--input", required=True, help="日文 SRT 路径")
    parser.add_argument("--output-dir", required=True, help="产物目录（zh.srt / bilingual.srt / report.json）")
    parser.add_argument("--config", "-c", default=None, help="配置文件路径（默认自动定位 pipeline.json）")
    parser.add_argument("--api-base", default=None, help="OpenAI 兼容接口基址（默认读配置，回退 {0}）".format(DEFAULT_API_BASE))
    parser.add_argument("--api-key", default=None, help="API Key（本地服务可用任意值）")
    parser.add_argument("--model", default=None, help="翻译模型名（默认读配置）")
    parser.add_argument("--prompt-style", default="auto",
                        choices=["auto", "generic", "hunyuan"],
                        help="auto：模型名含 hy-mt/hunyuan-mt 且语言对为 ja→zh 时用官方模板")
    parser.add_argument("--source-lang", default=None,
                        help="源语言（默认读配置 languages.source，缺省 ja）")
    parser.add_argument("--target-lang", default=None,
                        help="目标语言（默认读配置 languages.target，缺省 zh）")
    parser.add_argument("--report", default="report.json",
                        help="报告文件名（默认 report.json；02-translate.ps1 会传 translate-report.json）")
    parser.add_argument("--mock", action="store_true", help="离线模拟：不访问网络，产出带【模拟】标记")
    parser.add_argument("--dry-run", action="store_true", help="只预览计划，不写任何文件（与 --mock 互斥）")
    parser.add_argument("--no-health-check", action="store_true", help="跳过翻译服务探活")
    parser.add_argument("--retries", type=int, default=2, help="单条请求重试次数")
    parser.add_argument("--timeout", type=float, default=60.0, help="单条请求超时（秒）")
    parser.add_argument("--no-fallback", action="store_true", help="禁止回退日文原文：失败即整体失败（退出码 1）")
    parser.add_argument("--concurrency", type=int, default=4, help="并发请求数")
    parser.add_argument("--drop-hallucination", action="store_true", help="丢弃命中幻觉黑名单的 cue")
    parser.add_argument("--drop-filler", action="store_true", help="丢弃纯语气词/喘息 cue（输出条数会少于输入）")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)

    if args.mock and args.dry_run:
        print("[错误] --mock 与 --dry-run 互斥，请二选一。", file=sys.stderr)
        return 1
    if args.concurrency < 1 or args.retries < 0 or args.timeout <= 0:
        print("[错误] --concurrency / --retries / --timeout 取值非法。", file=sys.stderr)
        return 1

    config, config_path = cfgmod.load_pipeline_config(args.config)
    api_base = args.api_base or _cfg_translate_value(config, "api_base", DEFAULT_API_BASE)
    api_key = args.api_key or _cfg_translate_value(config, "api_key", "local")
    model = args.model or _cfg_translate_value(config, "model", DEFAULT_MODEL)
    source_lang = (args.source_lang or cfgmod.cfg_get(config, "languages.source", "ja") or "ja").lower()
    target_lang = (args.target_lang or cfgmod.cfg_get(config, "languages.target", "zh") or "zh").lower()
    style = args.prompt_style
    if style == "auto":
        low = model.lower()
        if ("hy-mt" in low or "hunyuan-mt" in low) and is_ja_zh(source_lang, target_lang):
            style = "hunyuan"
        else:
            style = "generic"
    elif style == "hunyuan" and not is_ja_zh(source_lang, target_lang):
        print("[提示] hunyuan 模板仅适用于 ja→zh，已回退 generic。", file=sys.stderr)
        style = "generic"
    encoding, newline = cfgmod.srt_writer_options(config)
    bilingual_mode, bilingual_sep = cfgmod.bilingual_options(config)

    if not os.path.isfile(args.input):
        print("[错误] 输入文件不存在：{0}".format(args.input), file=sys.stderr)
        return 1
    ja_cues = srt_io.read_srt(args.input)
    if not ja_cues:
        print("[错误] 输入 SRT 没有可翻译的字幕条目。", file=sys.stderr)
        return 1
    total = len(ja_cues)

    if args.drop_hallucination:
        before = len(ja_cues)
        ja_cues = [c for c in ja_cues if not is_hallucination(c.text)]
        print("[过滤] 幻觉黑名单：移除 {0} 条".format(before - len(ja_cues)), file=sys.stderr)
    if args.drop_filler:
        before = len(ja_cues)
        ja_cues = [c for c in ja_cues if not is_filler(c.text)]
        print("[过滤] 纯语气词/喘息：移除 {0} 条".format(before - len(ja_cues)), file=sys.stderr)
    if not ja_cues:
        print("[错误] 过滤后没有剩余字幕条目。", file=sys.stderr)
        return 1

    print("[输入] {0}（{1} 条，配置 {2}）".format(args.input, len(ja_cues), config_path))

    if args.dry_run:
        print("[预览] 模式={0} 模型={1} 接口={2} 并发={3} 条目={4}".format(
            "mock" if args.mock else "api", model, api_base, args.concurrency, len(ja_cues)))
        print("[预览] 输出目录：{0}（将写出 zh.srt / bilingual.srt / report.json）".format(
            args.output_dir))
        print("[预览] 未写任何文件。")
        return 0

    zh_texts: List[str] = []
    failures: List[Dict[str, object]] = []
    mode = "mock"

    if args.mock:
        print("[模式] 离线模拟（--mock，不访问网络）", file=sys.stderr)
        zh_texts = [mock_translate(c.text, i) for i, c in enumerate(ja_cues)]
    else:
        mode = "api"
        if not args.no_health_check:
            ok, detail = health_check(api_base, api_key, min(args.timeout, 8.0))
            if not ok:
                if args.no_fallback:
                    print("[错误] 翻译服务探活失败（--no-fallback 生效）：{0}".format(detail),
                          file=sys.stderr)
                    return 1
                print("[警告] 翻译服务探活失败，将继续尝试；失败条目将回退日文原文。", file=sys.stderr)
            else:
                print("[探活] 翻译服务正常：{0}".format(api_base), file=sys.stderr)

        api_url = _chat_completions_url(api_base)
        print("[翻译] 接口={0} 模型={1} 语言={2}->{3} 风格={4} 并发={5}".format(
            api_url, model, source_lang, target_lang, style, args.concurrency), file=sys.stderr)

        def work(idx: int, cue: srt_io.Cue) -> str:
            return translate_cue(api_url, api_key, model, cue.text, style,
                                 args.retries, args.timeout, source_lang, target_lang)

        zh_texts = [""] * len(ja_cues)
        aborted = False
        with ThreadPoolExecutor(max_workers=max(1, args.concurrency)) as pool:
            futures = {pool.submit(work, i, c): i for i, c in enumerate(ja_cues)}
            done = 0
            for future in list(futures):
                idx = futures[future]
                try:
                    zh_texts[idx] = future.result()
                except Exception as exc:
                    if args.no_fallback:
                        print("[错误] 第 {0} 条翻译失败且 --no-fallback 生效：{1}".format(
                            idx + 1, exc), file=sys.stderr)
                        aborted = True
                        pool.shutdown(wait=True, cancel_futures=True)
                        break
                    cue = ja_cues[idx]
                    zh_texts[idx] = cue.text  # 回退日文原文
                    failures.append({
                        "index": idx + 1,
                        "start_ms": cue.start_ms,
                        "end_ms": cue.end_ms,
                        "error": str(exc),
                    })
                done += 1
                if done % 50 == 0 or done == len(ja_cues):
                    print("[进度] {0}/{1}".format(done, len(ja_cues)), file=sys.stderr)
        if aborted:
            print("[错误] 翻译中止，未写出任何产物。", file=sys.stderr)
            return 1

    # ---- 组装产物 ----
    zh_cues = [srt_io.Cue(c.start_ms, c.end_ms, zh) for c, zh in zip(ja_cues, zh_texts)]
    bilingual_cues: List[srt_io.Cue] = []
    for jc, zc in zip(ja_cues, zh_cues):
        if bilingual_mode == "ja_top":
            text = jc.text + "\n" + zc.text
        elif bilingual_mode == "same_line":
            text = zc.text + bilingual_sep + jc.text
        else:  # zh_top（默认：中文在上）
            text = zc.text + "\n" + jc.text
        bilingual_cues.append(srt_io.Cue(jc.start_ms, jc.end_ms, text))

    out_dir = args.output_dir
    os.makedirs(out_dir, exist_ok=True)
    zh_path = os.path.abspath(os.path.join(out_dir, "zh.srt"))
    bilingual_path = os.path.abspath(os.path.join(out_dir, "bilingual.srt"))
    report_path = os.path.abspath(os.path.join(out_dir, os.path.basename(args.report or "report.json")))
    srt_io.write_srt(zh_path, zh_cues, encoding=encoding, newline=newline)
    srt_io.write_srt(bilingual_path, bilingual_cues, encoding=encoding, newline=newline)

    zh_problems = validate_alignment(ja_cues, zh_cues, "中文")
    bi_problems = validate_alignment(ja_cues, bilingual_cues, "双语")
    zh_ok, bi_ok = (not zh_problems), (not bi_problems)
    kana_residue = sum(1 for c in zh_cues if srt_io.has_kana(c.text))
    print("[校验] 中文条数与时间戳：{0}".format("通过" if zh_ok else "失败"))
    print("[校验] 双语条数与时间戳：{0}".format("通过" if bi_ok else "失败"))
    for p in zh_problems + bi_problems:
        print("[校验] " + p, file=sys.stderr)

    report = {
        "mode": mode,
        "model": model,
        "api_base": api_base if mode == "api" else "",
        "prompt_style": style,
        "source_lang": source_lang,
        "target_lang": target_lang,
        "stats": {
            "input_cues": total,
            "translated": len(ja_cues) - len(failures),
            "failed": len(failures),
            "fallback_to_source": len(failures),
            "kana_residue_cues": kana_residue,
        },
        "validation": {
            "zh_count_matches_input": zh_ok and len(zh_cues) == len(ja_cues),
            "zh_timestamps_match_input": all(
                (jc.start_ms, jc.end_ms) == (zc.start_ms, zc.end_ms)
                for jc, zc in zip(ja_cues, zh_cues)),
            "bilingual_count_matches_input": bi_ok and len(bilingual_cues) == len(ja_cues),
            "bilingual_timestamps_match_input": all(
                (jc.start_ms, jc.end_ms) == (bc.start_ms, bc.end_ms)
                for jc, bc in zip(ja_cues, bilingual_cues)),
            "zh_kana_residue_cues": kana_residue,
        },
        "outputs": {"zh": zh_path, "bilingual": bilingual_path, "report": report_path},
        "failures": failures,
    }
    with open(report_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2)

    print("[输出] {0}".format(zh_path))
    print("[输出] {0}".format(bilingual_path))
    print("[输出] {0}".format(report_path))
    if failures:
        print("[结果] 部分失败：{0} 条回退日文原文，详见 {1}".format(len(failures), os.path.basename(report_path)))
        return 2
    print("[完成] 翻译 {0} 条，零失败。".format(len(ja_cues)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
