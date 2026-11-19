#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SRT 字幕解析 / 序列化 / 双语合并基础模块。

设计目标：
- 解析宽容：容忍 UTF-8 BOM、CRLF、点号毫秒、缺序号、箭头两侧多余空格、
  毫秒位数不足/超长等非标准写法；无法解析的块跳过并记录警告。
- 序列化严格：时间戳统一为 ``HH:MM:SS,mmm``（小时至少两位），条与条之间空一行。
- 双语合并：日文时间轴为准，按条号严格对齐；条数或时间戳不一致时默认报错，
  可通过 ``allow_mismatch=True`` 降级为“按最小条数对齐 + 警告”。

本模块只依赖 Python 标准库，兼容 Python 3.8+。
"""

from __future__ import annotations

import io
import os
import re
import shutil
import tempfile
from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

__version__ = "1.0.0"

# ---------------------------------------------------------------------------
# 常量与正则
# ---------------------------------------------------------------------------

# 时间轴一行里的时间戳：小时 1~3 位，毫秒分隔符兼容 , . ． ，
TIMESTAMP_RE = re.compile(
    r"(?P<h>\d{1,3}):(?P<m>\d{1,2}):(?P<s>\d{1,2})[\,\.．，](?P<ms>\d{1,4})"
)
# 箭头：允许 -- >、--> 等
ARROW_RE = re.compile(r"--\s*>")
# 严格输出格式
STRICT_TIMESTAMP_RE = re.compile(r"^\d{2,}:\d{2}:\d{2},\d{3}$")
# 序号行（允许前后空格）
INDEX_RE = re.compile(r"^\s*\d+\s*$")
# 日文假名（含半角片假名、片假名语音扩展），用于“日文残留”检测
KANA_RE = re.compile(r"[\u3040-\u30ff\u31f0-\u31ff\uff65-\uff9f]")

# 输出时区缓冲：条与条之间使用两个换行
_BLANK = re.compile(r"\n[ \t\u3000]*\n")

# 读取时按此顺序尝试编码，避免显式指定
SUPPORTED_ENCODINGS: Tuple[str, ...] = (
    "utf-8",
    "cp932",      # Shift_JIS（日文外挂字幕常见）
    "gb18030",    # 简体中文
    "big5",       # 繁体中文
    "latin-1",    # 最后兜底，几乎不会解码失败
)

# 双语排版模式：中文在上 / 日文在上 / 同一行
BILINGUAL_MODES: Tuple[str, ...] = ("zh_top", "ja_top", "same_line")


# ---------------------------------------------------------------------------
# 异常
# ---------------------------------------------------------------------------

class SrtError(ValueError):
    """SRT 相关错误基类（错误信息一律使用中文，便于目标机直读）。"""


class SrtParseError(SrtError):
    """SRT 解析相关错误。"""


class SrtMergeError(SrtError):
    """双语合并相关错误。"""


# ---------------------------------------------------------------------------
# 数据结构
# ---------------------------------------------------------------------------

@dataclass
class Cue:
    """一条字幕。start_ms / end_ms 为毫秒整数，text 允许内含换行（多行字幕）。"""

    start_ms: int
    end_ms: int
    text: str = ""
    index: int = 0                # 输出时使用的连续序号（从 1 开始）
    source_index: Optional[int] = None  # 原始文件中的序号（可能缺失）

    def duration_ms(self) -> int:
        return max(0, self.end_ms - self.start_ms)

    def duration_sec(self) -> float:
        return self.duration_ms() / 1000.0

    def visible_chars(self) -> int:
        return visible_char_count(self.text)

    def cps(self) -> float:
        seconds = self.duration_ms() / 1000.0
        if seconds <= 0:
            return 0.0
        return self.visible_chars() / seconds

    def text_lines(self) -> List[str]:
        """非空文本行（去掉行首尾空白），用于双语合并与质检。"""
        return [line.strip() for line in self.text.split("\n") if line.strip()]

    def copy_with(self, text: str, start_ms: Optional[int] = None,
                  end_ms: Optional[int] = None) -> "Cue":
        return Cue(
            start_ms=self.start_ms if start_ms is None else start_ms,
            end_ms=self.end_ms if end_ms is None else end_ms,
            text=text,
            index=self.index,
            source_index=self.source_index,
        )


# ---------------------------------------------------------------------------
# 时间戳
# ---------------------------------------------------------------------------

def _fraction_to_ms(frac: str) -> int:
    """把毫秒位数不同的分数字符串统一成毫秒。

    1 位按 100ms、2 位按 10ms、3 位按 1ms、4 位以上截断到 3 位。
    例：``"2"`` -> 200，``"23"`` -> 230，``"234"`` -> 234，``"2345"`` -> 234。
    """
    if not frac:
        return 0
    frac = frac[:3]
    return int(frac.ljust(3, "0"))


def parse_timestamp(value: str) -> int:
    """把一个时间戳字符串解析成毫秒。失败抛出 :class:`SrtParseError`。"""
    if value is None:
        raise SrtParseError("时间戳为空，无法解析。")
    match = TIMESTAMP_RE.search(str(value))
    if match is None:
        raise SrtParseError("无法识别的时间戳格式：{0!r}（应为 00:00:01,234）".format(value))
    hours = int(match.group("h"))
    minutes = int(match.group("m"))
    seconds = int(match.group("s"))
    if minutes > 59 or seconds > 59:
        raise SrtParseError("时间戳分/秒超出范围：{0!r}".format(value))
    return (
        hours * 3600000
        + minutes * 60000
        + seconds * 1000
        + _fraction_to_ms(match.group("ms"))
    )


def format_timestamp(total_ms: int) -> str:
    """把毫秒数格式化为严格的 ``HH:MM:SS,mmm``。"""
    try:
        total_ms = int(total_ms)
    except (TypeError, ValueError):
        raise SrtParseError("时间戳必须是整数毫秒：{0!r}".format(total_ms))
    if total_ms < 0:
        raise SrtParseError("时间戳不能为负数：{0}".format(total_ms))
    hours, rem = divmod(total_ms, 3600000)
    minutes, rem = divmod(rem, 60000)
    seconds, millis = divmod(rem, 1000)
    return "{0:02d}:{1:02d}:{2:02d},{3:03d}".format(hours, minutes, seconds, millis)


def is_strict_timestamp(value: str) -> bool:
    return STRICT_TIMESTAMP_RE.match(value) is not None


# ---------------------------------------------------------------------------
# 文本工具
# ---------------------------------------------------------------------------

def visible_char_count(text: str) -> int:
    """统计可见字符数（不计空白与全角空格），用于 CPS 计算。"""
    if not text:
        return 0
    return sum(1 for ch in text if (not ch.isspace()) and ch != "\u3000")


def find_kana(text: str) -> List[str]:
    """返回文本中出现的日文假名字符列表（去重、保持出现顺序）。"""
    if not text:
        return []
    seen = []
    for ch in text:
        if KANA_RE.match(ch) and ch not in seen:
            seen.append(ch)
    return seen


def has_kana(text: str) -> bool:
    return bool(text) and KANA_RE.search(text) is not None


def decode_srt_bytes(data: bytes) -> Tuple[str, str]:
    """按约定顺序尝试解码，返回 ``(文本, 实际编码)``。

    先显式识别 UTF-8 BOM（返回 ``utf-8-sig``），再按 UTF-8 / Shift_JIS /
    简体中文 / 繁体中文 / latin-1 兜底的顺序尝试。
    """
    if data is None:
        raise SrtParseError("读取 SRT 失败：内容为空。")
    if data.startswith(b"\xef\xbb\xbf"):
        return data.decode("utf-8-sig"), "utf-8-sig"
    for encoding in SUPPORTED_ENCODINGS:
        try:
            return data.decode(encoding), encoding
        except (UnicodeDecodeError, LookupError):
            continue
    return data.decode("utf-8", errors="replace"), "utf-8(replace)"


# ---------------------------------------------------------------------------
# 解析
# ---------------------------------------------------------------------------

def parse_srt(text: str, warnings: Optional[List[str]] = None) -> List[Cue]:
    """解析 SRT 文本，返回 :class:`Cue` 列表。

    ``warnings`` 若传入列表，解析过程中的非致命问题会追加中文描述。
    """
    if isinstance(text, bytes):
        text, _ = decode_srt_bytes(text)
    if text is None:
        raise SrtParseError("解析 SRT 失败：文本为 None。")

    raw = str(text).lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    blocks = _BLANK.split(raw)
    cues: List[Cue] = []
    seq = 0

    for block_no, block in enumerate(blocks, 1):
        lines = [line.rstrip() for line in block.split("\n")]
        while lines and not lines[0].strip():
            lines.pop(0)
        while lines and not lines[-1].strip():
            lines.pop()
        if not lines:
            continue

        arrow_pos = None
        for pos, line in enumerate(lines):
            if ARROW_RE.search(line):
                arrow_pos = pos
                break
        if arrow_pos is None:
            if warnings is not None:
                warnings.append("第 {0} 个块缺少时间轴（-->) 行，已跳过。".format(block_no))
            continue

        arrow_line = lines[arrow_pos]
        left, right = ARROW_RE.split(arrow_line, maxsplit=1)
        start_match = TIMESTAMP_RE.search(left)
        end_match = TIMESTAMP_RE.search(right)
        if start_match is None or end_match is None:
            if warnings is not None:
                warnings.append(
                    "第 {0} 个块的起始/结束时间戳无法解析，已跳过：{1!r}".format(
                        block_no, arrow_line.strip()
                    )
                )
            continue

        try:
            start_ms = parse_timestamp(start_match.group(0))
            end_ms = parse_timestamp(end_match.group(0))
        except SrtParseError as exc:
            if warnings is not None:
                warnings.append("第 {0} 个块时间戳无效，已跳过：{1}".format(block_no, exc))
            continue

        source_index: Optional[int] = None
        if arrow_pos > 0:
            maybe_index = lines[arrow_pos - 1].strip()
            if INDEX_RE.match(maybe_index):
                source_index = int(maybe_index)
                stray = [ln for ln in lines[: arrow_pos - 1] if ln.strip()]
                if stray and warnings is not None:
                    warnings.append(
                        "第 {0} 个块序号前存在多余行，已忽略：{1!r}".format(block_no, stray[0])
                    )
            else:
                stray = [ln for ln in lines[:arrow_pos] if ln.strip()]
                if stray and warnings is not None:
                    warnings.append(
                        "第 {0} 个块不是标准的“序号+时间轴+文本”结构，已按文本行处理。".format(
                            block_no
                        )
                    )
        elif arrow_pos == 0 and warnings is not None:
            warnings.append("第 {0} 个块缺少序号行，已自动编号。".format(block_no))

        text_lines = lines[arrow_pos + 1:]
        # 行首尾空白去掉，但保留下空行信息（空文本交给质检报告）
        text = "\n".join(line.strip() for line in text_lines).strip("\n")
        if not text.strip() and warnings is not None:
            warnings.append("第 {0} 个块正文为空（已保留，供质检报错）。".format(block_no))

        seq += 1
        cues.append(
            Cue(
                start_ms=start_ms,
                end_ms=end_ms,
                text=text,
                index=seq,
                source_index=source_index,
            )
        )

    return cues


def read_srt_with_meta(path: str) -> Tuple[List[Cue], str, List[str]]:
    """读取 SRT 文件，返回 ``(条列表, 实际编码, 解析警告)``。"""
    path = str(path)
    if not os.path.exists(path):
        raise SrtParseError("找不到 SRT 文件：{0}".format(path))
    with open(path, "rb") as fh:
        data = fh.read()
    text, encoding = decode_srt_bytes(data)
    warnings: List[str] = []
    cues = parse_srt(text, warnings=warnings)
    return cues, encoding, warnings


def read_srt(path: str) -> List[Cue]:
    """读取 SRT 文件，忽略解析警告。"""
    cues, _, _ = read_srt_with_meta(path)
    return cues


# ---------------------------------------------------------------------------
# 序列化
# ---------------------------------------------------------------------------

def serialize_srt(cues: Sequence[Cue], newline: str = "\n") -> str:
    """把条列表序列化成严格 SRT 文本（序号连续、时间戳严格格式）。"""
    if newline not in ("\n", "\r\n"):
        raise SrtError("不支持的行尾格式：{0!r}（只允许 \\n 或 \\r\\n）".format(newline))
    parts: List[str] = []
    for pos, cue in enumerate(cues, 1):
        text = "" if cue.text is None else str(cue.text)
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        if newline != "\n":
            text = text.replace("\n", newline)
        parts.append(
            "{0}{1}{2} --> {3}{1}{4}".format(
                pos,
                newline,
                format_timestamp(cue.start_ms),
                format_timestamp(cue.end_ms),
                text,
            )
        )
    if not parts:
        return ""
    return (newline * 2).join(parts) + newline


def write_srt(path: str, cues: Sequence[Cue], encoding: str = "utf-8",
              newline: str = "\n") -> str:
    """写出 SRT 文件（先写临时文件再替换，避免中途中断留下半个文件）。

    默认 UTF-8 无 BOM（项目约定，兼容播放器更多）；需要 BOM 时把
    ``encoding`` 设为 ``utf-8-sig``（配置文件 ``srt.encoding`` 可改）。
    """
    if encoding is None or str(encoding).strip() == "":
        encoding = "utf-8"
    content = serialize_srt(cues, newline=newline)
    path = str(path)
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    try:
        content.encode(str(encoding))
    except (LookupError, UnicodeEncodeError) as exc:
        raise SrtError("无法按 {0} 编码写出 {1}：{2}".format(encoding, path, exc))
    # 先写系统临时目录，再复制到目标：跨盘（如 C: -> 网络/移动盘）也安全，
    # 避免在部分盘上 mkstemp/os.replace 卡死或失败。
    fd, tmp_path = tempfile.mkstemp(prefix=".srt-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(content.encode(str(encoding)))
        shutil.copyfile(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass
    return path


# ---------------------------------------------------------------------------
# 双语合并
# ---------------------------------------------------------------------------

def _normalize_mode(mode: str) -> str:
    mode = (mode or "").strip()
    aliases = {
        "zh-ja": "zh_top",
        "zh_ja": "zh_top",
        "zh-top": "zh_top",
        "ja-zh": "ja_top",
        "ja_zh": "ja_top",
        "ja-top": "ja_top",
        "inline": "same_line",
        "same-line": "same_line",
        "same_line": "same_line",
    }
    normalized = aliases.get(mode, mode)
    if normalized not in BILINGUAL_MODES:
        raise SrtMergeError(
            "不支持的双语排版模式：{0!r}。合法取值：{1}".format(
                mode, "、".join(BILINGUAL_MODES)
            )
        )
    return normalized


def merge_bilingual(ja_cues: Sequence[Cue], zh_cues: Sequence[Cue],
                    mode: str = "zh_top", separator: str = " | ",
                    allow_mismatch: bool = False) -> Tuple[List[Cue], List[str]]:
    """合并日文 SRT 与中文 SRT，返回 ``(合并后的条列表, 警告列表)``。

    时间轴一律以日文条为准；条数与时间戳需逐条一致，否则抛
    :class:`SrtMergeError`；``allow_mismatch=True`` 时改为按最小条数对齐、
    保留日文时间轴并记录警告（不推荐，除非明确知道两份字幕来源不同）。
    """
    mode = _normalize_mode(mode)
    separator = " | " if separator is None else str(separator)
    warnings: List[str] = []

    if len(ja_cues) != len(zh_cues):
        message = "双语合并失败：日文 {0} 条，中文 {1} 条，条数不一致。".format(
            len(ja_cues), len(zh_cues)
        )
        if not allow_mismatch:
            raise SrtMergeError(message)
        warnings.append(message + "已按较少的 {0} 条对齐。".format(
            min(len(ja_cues), len(zh_cues))
        ))

    count = min(len(ja_cues), len(zh_cues))
    merged: List[Cue] = []
    timestamp_mismatches: List[str] = []

    for pos in range(count):
        ja = ja_cues[pos]
        zh = zh_cues[pos]
        if (ja.start_ms, ja.end_ms) != (zh.start_ms, zh.end_ms):
            message = "第 {0} 条时间戳不一致：日文 {1} --> {2}，中文 {3} --> {4}。".format(
                pos + 1,
                format_timestamp(ja.start_ms),
                format_timestamp(ja.end_ms),
                format_timestamp(zh.start_ms),
                format_timestamp(zh.end_ms),
            )
            timestamp_mismatches.append(message)
            if not allow_mismatch:
                continue  # 先收集全部不一致条目，循环结束后统一报错
            warnings.append(message + "已以日文时间轴为准继续合并。")

        merged.append(
            Cue(
                start_ms=ja.start_ms,
                end_ms=ja.end_ms,
                text=_compose_text(mode, ja.text, zh.text, separator),
                index=len(merged) + 1,
                source_index=ja.source_index,
            )
        )

    if timestamp_mismatches and not allow_mismatch:
        raise SrtMergeError(
            "双语合并失败：以下条目时间戳不一致。\n" + "\n".join(timestamp_mismatches)
        )

    # 条数不一致且允许错位时，把多出的日文条目也保留（中文留空）
    if count < len(ja_cues):
        for pos in range(count, len(ja_cues)):
            ja = ja_cues[pos]
            merged.append(
                Cue(
                    start_ms=ja.start_ms,
                    end_ms=ja.end_ms,
                    text=_compose_text(mode, ja.text, "", separator),
                    index=len(merged) + 1,
                    source_index=ja.source_index,
                )
            )

    return merged, warnings


def _compose_text(mode: str, ja_text: str, zh_text: str, separator: str) -> str:
    """按双语排版模式组装一条字幕文本。"""
    if mode == "zh_top":
        return _join_two_lines(zh_text, ja_text)
    if mode == "ja_top":
        return _join_two_lines(ja_text, zh_text)
    zh_flat = _flatten(zh_text)
    ja_flat = _flatten(ja_text)
    if zh_flat and ja_flat:
        return zh_flat + separator + ja_flat
    return zh_flat or ja_flat


def _flatten(text: str) -> str:
    """把多行文本压平成单行（同一行双语排版用）。"""
    lines = [line.strip() for line in str(text or "").split("\n") if line.strip()]
    return " ".join(lines)


def _join_two_lines(top: str, bottom: str) -> str:
    top = "" if top is None else str(top).strip("\n")
    bottom = "" if bottom is None else str(bottom).strip("\n")
    if top.strip() and bottom.strip():
        return top + "\n" + bottom
    return top if top.strip() else bottom


def merge_srt_files(ja_path: str, zh_path: str, out_path: str,
                    mode: str = "zh_top", separator: str = " | ",
                    allow_mismatch: bool = False, encoding: str = "utf-8-sig",
                    newline: str = "\n") -> Tuple[int, List[str]]:
    """文件级双语合并，返回 ``(条数, 警告列表)``。"""
    ja_cues = read_srt(ja_path)
    zh_cues = read_srt(zh_path)
    if not ja_cues:
        raise SrtMergeError("日文字幕为空或无法解析：{0}".format(ja_path))
    if not zh_cues:
        raise SrtMergeError("中文字幕为空或无法解析：{0}".format(zh_path))
    merged, warnings = merge_bilingual(
        ja_cues, zh_cues, mode=mode, separator=separator, allow_mismatch=allow_mismatch
    )
    write_srt(out_path, merged, encoding=encoding, newline=newline)
    return len(merged), warnings


# ---------------------------------------------------------------------------
# 命令行（仅用于人工排查，不参与流水线）
# ---------------------------------------------------------------------------

def _main(argv: Optional[List[str]] = None) -> int:
    import argparse
    import sys

    parser = argparse.ArgumentParser(description="SRT 解析/序列化排查小工具")
    parser.add_argument("file", help="要查看的 SRT 文件路径")
    parser.add_argument("--json", action="store_true", help="以 JSON 输出条信息")
    args = parser.parse_args(argv)

    try:
        cues, encoding, warnings = read_srt_with_meta(args.file)
    except SrtError as exc:
        print("错误：{0}".format(exc), file=sys.stderr)
        return 1
    payload = {
        "file": args.file,
        "encoding": encoding,
        "count": len(cues),
        "warnings": warnings,
        "cues": [
            {
                "index": cue.index,
                "start": format_timestamp(cue.start_ms),
                "end": format_timestamp(cue.end_ms),
                "duration_ms": cue.duration_ms(),
                "cps": round(cue.cps(), 2),
                "text": cue.text,
            }
            for cue in cues
        ],
    }
    if args.json:
        import json
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print("文件：{0}".format(args.file))
        print("编码：{0} | 条数：{1}".format(encoding, len(cues)))
        for warning in warnings:
            print("警告：{0}".format(warning))
        for cue in cues:
            print("{0:>4}  {1} --> {2}  CPS={3}".format(
                cue.index, format_timestamp(cue.start_ms),
                format_timestamp(cue.end_ms), round(cue.cps(), 2)
            ))
            for line in cue.text.split("\n"):
                print("      | " + line)
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
