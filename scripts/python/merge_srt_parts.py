#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""合并分片 SRT 并清洗幻觉/纯语气条目。

背景（2026-11-16 本机实测）：
- whisper-cli（jerryshell Vulkan v1.0.0）在**整段 ≥30 分钟音频**上 VAD 会退化为 0 段
  （`Final speech segments after filtering: 0`），但 10 分钟分片正常；
- VAD 开启后仍偶发幻觉句（如「ご視聴ありがとうございました」）与纯语气 cue。

因此听写改为：ffmpeg 物理切片 → 每片 whisper+VAD → 本脚本按「片序号 × 片长」平移时间戳
合并为 ja.srt，并丢弃幻觉黑名单 / 纯语气 / 空文本条目。

用法（项目根下）：
    python scripts/python/merge_srt_parts.py --parts-dir output/xxx \
        --prefix ja.part --chunk-seconds 600 --out output/xxx/ja.srt \
        --report output/xxx/transcribe-report.json [--no-clean]

退出码：0 成功；1 参数/文件错误或无任何分片；2 合并成功但清洗后 0 条（产物仍写出）。
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from typing import Dict, List, Optional, Tuple

import srt_io

# 与 translate_srt.py 共用同一套过滤规则（单一事实来源），避免两处黑名单不一致。
try:
    from translate_srt import HALLUCINATION_RE, is_filler, is_hallucination
except Exception:  # pragma: no cover - 仅在 translate_srt 缺失时兜底
    HALLUCINATION_RE = re.compile(r"ご視聴|ご清聴|チャンネル登録|ありがとうございました")
    is_hallucination = lambda t: bool(HALLUCINATION_RE.search(t))  # noqa: E731
    is_filler = lambda t: False  # noqa: E731

PART_RE = re.compile(r"^(?P<prefix>.+?)(?P<index>\d+)\.srt$")


def find_parts(parts_dir: str, prefix: str) -> List[Tuple[int, str]]:
    """返回 [(片序号, 文件路径)]，按序号升序；忽略不匹配前缀的文件。"""
    pattern = os.path.join(parts_dir, prefix + "*.srt")
    parts: List[Tuple[int, str]] = []
    for path in glob.glob(pattern):
        match = PART_RE.match(os.path.basename(path))
        if not match:
            continue
        parts.append((int(match.group("index")), path))
    parts.sort(key=lambda item: item[0])
    return parts


def is_symbol_only(text: str) -> bool:
    """纯符号（无假名/汉字/字母数字）的 cue，通常为 BGM 或噪声幻觉。"""
    stripped = (text or "").strip()
    if not stripped:
        return False
    return not re.search(r"[\u3040-\u30ff\u3400-\u9fff0-9A-Za-z]", stripped)


def clean_cues(cues: List[srt_io.Cue], do_clean: bool) -> Tuple[List[srt_io.Cue], Dict[str, int]]:
    dropped = {"hallucination": 0, "filler": 0, "empty": 0, "symbol_only": 0}
    if not do_clean:
        return list(cues), dropped
    kept: List[srt_io.Cue] = []
    for cue in cues:
        text = (cue.text or "").strip()
        if not text:
            dropped["empty"] += 1
            continue
        if is_hallucination(text):
            dropped["hallucination"] += 1
            continue
        if is_filler(text):
            dropped["filler"] += 1
            continue
        if is_symbol_only(text):
            dropped["symbol_only"] += 1
            continue
        kept.append(cue)
    return kept, dropped


def merge_parts(parts: List[Tuple[int, str]], chunk_seconds: int,
                do_clean: bool) -> Tuple[List[srt_io.Cue], Dict[str, object]]:
    merged: List[srt_io.Cue] = []
    dropped_total = {"hallucination": 0, "filler": 0, "empty": 0, "symbol_only": 0}
    raw_total = 0
    per_part: List[Dict[str, object]] = []
    for index, path in parts:
        offset_ms = index * chunk_seconds * 1000
        cues = srt_io.read_srt(path)
        raw_total += len(cues)
        shifted = [srt_io.Cue(c.start_ms + offset_ms, c.end_ms + offset_ms, c.text) for c in cues]
        kept, dropped = clean_cues(shifted, do_clean)
        for key in dropped_total:
            dropped_total[key] += dropped[key]
        merged.extend(kept)
        per_part.append({
            "part": os.path.basename(path),
            "index": index,
            "offset_ms": offset_ms,
            "raw_cues": len(cues),
            "kept_cues": len(kept),
            "dropped": dropped,
        })
    merged.sort(key=lambda c: (c.start_ms, c.end_ms))
    return merged, {
        "parts": len(parts),
        "chunk_seconds": chunk_seconds,
        "raw_cues": raw_total,
        "kept_cues": len(merged),
        "dropped": dropped_total,
        "per_part": per_part,
    }


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="合并分片 SRT 并按偏移平移时间戳（可选清洗幻觉/语气词）")
    parser.add_argument("--parts-dir", required=True, help="分片 SRT 所在目录")
    parser.add_argument("--prefix", default="ja.part", help="分片文件名前缀（默认 ja.part）")
    parser.add_argument("--chunk-seconds", type=int, default=600,
                        help="每片音频秒数（时间戳平移量，默认 600）")
    parser.add_argument("--out", required=True, help="合并后的 SRT 输出路径")
    parser.add_argument("--report", default=None, help="可选：合并统计 JSON 输出路径")
    parser.add_argument("--no-clean", action="store_true", help="只合并不清洗")
    parser.add_argument("--encoding", default="utf-8", help="输出编码（默认 utf-8 无 BOM）")
    parser.add_argument("--newline", default="lf", choices=["lf", "crlf"], help="输出行尾")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    if args.chunk_seconds <= 0:
        print("[错误] --chunk-seconds 必须为正整数。", file=sys.stderr)
        return 1
    if not os.path.isdir(args.parts_dir):
        print("[错误] 分片目录不存在：{0}".format(args.parts_dir), file=sys.stderr)
        return 1
    parts = find_parts(args.parts_dir, args.prefix)
    if not parts:
        print("[错误] 分片目录中没有匹配 {0}*.srt 的文件：{1}".format(
            args.prefix, args.parts_dir), file=sys.stderr)
        return 1

    merged, stats = merge_parts(parts, args.chunk_seconds, not args.no_clean)
    newline = "\r\n" if args.newline == "crlf" else "\n"
    srt_io.write_srt(args.out, merged, encoding=args.encoding, newline=newline)
    stats["output"] = os.path.abspath(args.out)
    stats["clean"] = not args.no_clean
    print("[分片] {0} 片，原始 {1} 条，保留 {2} 条（清洗丢弃 {3}）".format(
        stats["parts"], stats["raw_cues"], stats["kept_cues"],
        json.dumps(stats["dropped"], ensure_ascii=False)))
    if args.report:
        parent = os.path.dirname(os.path.abspath(args.report))
        if parent and not os.path.isdir(parent):
            os.makedirs(parent, exist_ok=True)
        with open(args.report, "w", encoding="utf-8") as fh:
            json.dump(stats, fh, ensure_ascii=False, indent=2)
        print("[报告] {0}".format(os.path.abspath(args.report)))
    if not merged:
        print("[警告] 清洗后没有剩余字幕条目（可能整片无人声）。", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
