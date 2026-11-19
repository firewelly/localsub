#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把日文 SRT 与中文 SRT 合并为双语 SRT（中文在上 / 日文在上 / 同一行）。

时间轴一律以日文文件为准；默认要求两个文件条数与每条时间戳严格一致，
不一致时以退出码 2 失败并列出具体条目；``--allow-mismatch`` 可降级为
“按条号对齐 + 警告”（不推荐，除非明确知道两份字幕来源不同）。
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
from typing import List, Optional

import pipeline_config as cfgmod
import srt_io

__version__ = "1.0.0"


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="合并日文/中文 SRT 为双语 SRT（时间轴以日文为准）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--ja", required=True, help="日文 SRT 路径")
    parser.add_argument("--zh", required=True, help="中文 SRT 路径")
    parser.add_argument("--out", required=True, help="输出双语 SRT 路径")
    parser.add_argument("--mode", default=None,
                        help="双语排版：zh_top（中上日下）/ ja_top（日上中下）/ same_line（同一行）")
    parser.add_argument("--separator", default=None, help="same_line 模式的分隔符（默认读配置）")
    parser.add_argument("--config", "-c", default=None, help="配置文件路径")
    parser.add_argument("--allow-mismatch", action="store_true",
                        help="条数/时间戳不一致时仍按条号对齐合并（会写警告）")
    parser.add_argument("--report", default=None, help="可选：合并信息 JSON 输出路径")
    parser.add_argument("--quiet", action="store_true", help="只输出最终结果")
    return parser


def _write_json(path: str, data: dict) -> str:
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    return path


def main(argv: Optional[List[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    try:
        cfg, cfg_path = cfgmod.load_pipeline_config(args.config)
        mode, separator = cfgmod.bilingual_options(cfg)
        if args.mode:
            mode = args.mode
        if args.separator is not None:
            separator = args.separator
        encoding, newline = cfgmod.srt_writer_options(cfg)
        root = cfgmod.find_project_root()

        ja_cues = srt_io.read_srt(args.ja)
        zh_cues = srt_io.read_srt(args.zh)
        if not ja_cues:
            raise srt_io.SrtMergeError("日文字幕为空或无法解析：{0}".format(args.ja))
        if not zh_cues:
            raise srt_io.SrtMergeError("中文字幕为空或无法解析：{0}".format(args.zh))

        merged, warnings = srt_io.merge_bilingual(
            ja_cues, zh_cues, mode=mode, separator=separator,
            allow_mismatch=bool(args.allow_mismatch),
        )
        srt_io.write_srt(args.out, merged, encoding=encoding, newline=newline)
        if len(merged) != len(ja_cues):
            warnings.append(
                "合并条数 {0} 与日文条数 {1} 不一致（allow_mismatch 模式）。".format(
                    len(merged), len(ja_cues)))
    except srt_io.SrtMergeError as exc:
        print("[错误] {0}".format(exc), file=sys.stderr)
        return 2
    except cfgmod.ConfigError as exc:
        print("[错误] {0}".format(exc), file=sys.stderr)
        return 1
    except srt_io.SrtError as exc:
        print("[错误] SRT 处理失败：{0}".format(exc), file=sys.stderr)
        return 1
    except OSError as exc:
        print("[错误] 文件读写失败：{0}".format(exc), file=sys.stderr)
        return 1

    if not args.quiet:
        print("=" * 62)
        print("双语合并完成")
        print("日文：{0}（{1} 条）".format(args.ja, len(ja_cues)))
        print("中文：{0}（{1} 条）".format(args.zh, len(zh_cues)))
        print("输出：{0}（{1} 条）".format(args.out, len(merged)))
        print("排版：{0} | 编码：{1} | 行尾：{2}".format(
            mode, encoding, "CRLF" if newline == "\r\n" else "LF"))
        print("[校验] 双语文件条数与时间戳与日文逐条一致（{0} 条）。".format(len(merged)))
        for warning in warnings[:20]:
            print("[警告] {0}".format(warning))
        if len(warnings) > 20:
            print("[警告] 另有 {0} 条警告未显示。".format(len(warnings) - 20))

    if args.report:
        try:
            _write_json(args.report, {
                "schema_version": 1,
                "tool": "merge_srt.py",
                "version": __version__,
                "generated_at": datetime.datetime.now().astimezone().isoformat(
                    timespec="seconds"),
                "config": cfgmod.project_relative(cfg_path, root),
                "ja": cfgmod.project_relative(args.ja, root),
                "zh": cfgmod.project_relative(args.zh, root),
                "out": cfgmod.project_relative(args.out, root),
                "mode": mode,
                "separator": separator,
                "cues": len(merged),
                "warnings": warnings,
            })
        except OSError as exc:
            print("[错误] 写合并报告失败：{0}".format(exc), file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
