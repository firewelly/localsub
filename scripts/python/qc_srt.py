#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SRT 质检：CPS 超限、时长过短/过长、时间轴重叠、空字幕、日文假名残留、
条数丢失与时间戳不一致对比。输出机器可读 JSON 报告 + 人读中文摘要。

用法示例（在项目根下）：
    python3 scripts/python/qc_srt.py --input output/xxx/zh.srt \
        --reference output/xxx/ja.srt --report output/xxx/report.json

严重级别约定：
- ``error``：必须修复（空字幕、时间轴重叠/时长非法、条数或时间戳不一致、日文残留）；
- ``warning``：建议修复（CPS 超限、时长过短/过长、重复文本、过长停顿）。

退出码：
- 0：质检通过（可能有警告，除非加 --strict）；
- 1：存在 error 项，或 --strict 时存在 warning 项；
- 2：运行错误（文件缺失、解析失败、配置非法等）。
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Optional, Sequence

import pipeline_config as cfgmod
import srt_io

__version__ = "1.0.0"

SEVERITY_ERROR = "error"
SEVERITY_WARNING = "warning"


class QcRuntimeError(RuntimeError):
    """质检运行错误（中文信息）。"""


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="SRT 字幕质检：CPS/时长/重叠/空字幕/日文残留/条数对比",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--input", "-i", required=True, help="待质检的 SRT（通常是 zh.srt）")
    parser.add_argument("--reference", "-r", default=None,
                        help="参考 SRT（通常是 ja.srt），用于条数丢失与时间戳对比")
    parser.add_argument("--report", default=None,
                        help="质检 JSON 输出路径（默认 <input>.qc.json）")
    parser.add_argument("--config", "-c", default=None, help="配置文件路径")
    parser.add_argument("--target-lang", default=None,
                        help="目标语言（默认读配置 languages.target，缺省 zh）：zh 检查假名残留；bilingual 跳过")
    parser.add_argument("--max-cps", type=float, default=None, help="覆盖 qc.max_cps")
    parser.add_argument("--min-duration-ms", type=int, default=None, help="覆盖 qc.min_duration_ms")
    parser.add_argument("--max-duration-ms", type=int, default=None, help="覆盖 qc.max_duration_ms")
    parser.add_argument("--strict", action="store_true", help="存在 warning 也返回非零退出码")
    parser.add_argument("--quiet", action="store_true", help="不打印人读摘要（仍写 JSON）")
    return parser


# ---------------------------------------------------------------------------
# 质检逻辑
# ---------------------------------------------------------------------------

def _visible_line_cps(line: str, duration_ms: int) -> float:
    seconds = duration_ms / 1000.0
    if seconds <= 0:
        return 0.0
    return srt_io.visible_char_count(line) / seconds


def qc_check(input_path: str, reference_path: Optional[str], target_lang: str,
             thresholds: Dict[str, Any]) -> Dict[str, Any]:
    """执行全部检查，返回 report 字典（不负责写文件与打印）。"""
    issues: List[Dict[str, Any]] = []

    def add(code: str, severity: str, index: Optional[int], message: str,
            detail: Optional[str] = None) -> None:
        item: Dict[str, Any] = {
            "code": code,
            "severity": severity,
            "index": index,
            "message": message,
        }
        if detail:
            item["detail"] = detail
        issues.append(item)

    if not os.path.isfile(input_path):
        raise QcRuntimeError("找不到待质检的 SRT 文件：{0}".format(input_path))
    cues, encoding, parse_warnings = srt_io.read_srt_with_meta(input_path)

    max_cps = float(thresholds["max_cps"])
    min_duration_ms = int(thresholds["min_duration_ms"])
    max_duration_ms = int(thresholds["max_duration_ms"])
    overlap_tolerance_ms = int(thresholds["overlap_tolerance_ms"])
    max_gap_ms = int(thresholds["max_gap_ms"])
    kana_severity = str(thresholds["kana_severity"])
    duplicate_severity = str(thresholds["duplicate_severity"])

    for warning in parse_warnings:
        add("parse_warning", SEVERITY_WARNING, None, warning)

    if not cues:
        add("no_cues", SEVERITY_ERROR, None,
            "文件为空或解析不出任何字幕条，请检查 SRT 格式或编码。")

    previous = None
    for position, cue in enumerate(cues, 1):
        text = cue.text if cue.text is not None else ""
        lines = cue.text_lines()

        if not lines:
            add("empty_text", SEVERITY_ERROR, position, "第 {0} 条正文为空。".format(position))
        duration = cue.duration_ms()
        if cue.end_ms <= cue.start_ms:
            add("invalid_duration", SEVERITY_ERROR, position,
                "第 {0} 条结束时间不晚于开始时间（{1} --> {2}）。".format(
                    position,
                    srt_io.format_timestamp(cue.start_ms),
                    srt_io.format_timestamp(cue.end_ms)))
        elif duration < min_duration_ms:
            add("duration_too_short", SEVERITY_WARNING, position,
                "第 {0} 条时长 {1}ms 少于下限 {2}ms。".format(
                    position, duration, min_duration_ms))
        elif duration > max_duration_ms:
            add("duration_too_long", SEVERITY_WARNING, position,
                "第 {0} 条时长 {1}ms 超过上限 {2}ms。".format(
                    position, duration, max_duration_ms))

        if target_lang == "bilingual":
            line_cps = [
                (line_no + 1, _visible_line_cps(line, duration))
                for line_no, line in enumerate(lines)
            ]
            worst = max(line_cps, key=lambda item: item[1]) if line_cps else (0, 0.0)
        else:
            worst = (1, _visible_line_cps(text, duration))

        if duration > 0 and worst[1] > max_cps:
            add("cps_over", SEVERITY_WARNING, position,
                "第 {0} 条 CPS {1:.1f} 超过上限 {2:.1f}{3}。".format(
                    position, worst[1], max_cps,
                    "（第 {0} 行）".format(worst[0]) if target_lang == "bilingual" and len(lines) > 1 else ""))

        if target_lang == "zh" and srt_io.has_kana(text):
            kana = srt_io.find_kana(text)
            add("kana_residue", kana_severity, position,
                "第 {0} 条疑似残留日文假名：{1}".format(position, "、".join(kana)))

        if previous is not None:
            gap = cue.start_ms - previous.end_ms
            if cue.start_ms < previous.end_ms - overlap_tolerance_ms:
                add("overlap", SEVERITY_ERROR, position,
                    "第 {0} 条与第 {1} 条时间轴重叠 {2}ms。".format(
                        position, position - 1,
                        previous.end_ms - cue.start_ms))
            elif gap > max_gap_ms:
                add("large_gap", SEVERITY_WARNING, position,
                    "第 {0} 条与上一条间隔 {1}ms，超过 {2}ms。".format(
                        position, gap, max_gap_ms))

        if previous is not None and lines and previous.text_lines():
            current_flat = " ".join(lines)
            previous_flat = " ".join(previous.text_lines())
            if current_flat == previous_flat:
                add("duplicate_text", duplicate_severity, position,
                    "第 {0} 条与第 {1} 条文本完全相同，可能是听写幻觉。".format(
                        position, position - 1))

        previous = cue

    # ---------- 与参考文件对比 ----------
    reference_info: Dict[str, Any] = {"provided": False}
    if reference_path:
        if not os.path.isfile(reference_path):
            raise QcRuntimeError("找不到参考 SRT 文件：{0}".format(reference_path))
        ref_cues, ref_encoding, ref_warnings = srt_io.read_srt_with_meta(reference_path)
        reference_info = {
            "provided": True,
            "path": reference_path,
            "encoding": ref_encoding,
            "count": len(ref_cues),
            "parse_warnings": ref_warnings[:20],
        }
        if len(cues) != len(ref_cues):
            add("count_mismatch", SEVERITY_ERROR, None,
                "条数丢失/新增：待质检 {0} 条，参考 {1} 条（相差 {2} 条）。".format(
                    len(cues), len(ref_cues), len(cues) - len(ref_cues)))
        compare_limit = int(thresholds["max_compare_items"])
        mismatch_count = 0
        for position in range(min(len(cues), len(ref_cues))):
            left = cues[position]
            right = ref_cues[position]
            if (left.start_ms, left.end_ms) != (right.start_ms, right.end_ms):
                mismatch_count += 1
                if mismatch_count <= compare_limit:
                    add("timestamp_mismatch", SEVERITY_ERROR, position + 1,
                        "第 {0} 条时间戳与参考不一致：待质检 {1} --> {2}，参考 {3} --> {4}。".format(
                            position + 1,
                            srt_io.format_timestamp(left.start_ms),
                            srt_io.format_timestamp(left.end_ms),
                            srt_io.format_timestamp(right.start_ms),
                            srt_io.format_timestamp(right.end_ms)))
        if mismatch_count > compare_limit:
            add("timestamp_mismatch", SEVERITY_ERROR, None,
                "共 {0} 条时间戳与参考不一致，仅显示前 {1} 条。".format(
                    mismatch_count, compare_limit))
        else:
            reference_info["timestamp_mismatch_count"] = mismatch_count

    # ---------- 指标 ----------
    total_duration_ms = 0
    max_cps_value = 0.0
    max_cps_index = 0
    min_duration_value = None
    min_duration_index = 0
    max_duration_value = 0
    max_duration_index = 0
    cps_values: List[float] = []

    for position, cue in enumerate(cues, 1):
        duration = cue.duration_ms()
        total_duration_ms = max(total_duration_ms, cue.end_ms)
        if target_lang == "bilingual":
            lines = cue.text_lines()
            value = max([_visible_line_cps(line, duration) for line in lines] or [0.0])
        else:
            value = _visible_line_cps(cue.text or "", duration)
        cps_values.append(value)
        if value > max_cps_value:
            max_cps_value = value
            max_cps_index = position
        if min_duration_value is None or duration < min_duration_value:
            min_duration_value = duration
            min_duration_index = position
        if duration > max_duration_value:
            max_duration_value = duration
            max_duration_index = position

    errors = [item for item in issues if item["severity"] == SEVERITY_ERROR]
    warnings = [item for item in issues if item["severity"] == SEVERITY_WARNING]
    summary = {
        "cues": len(cues),
        "errors": len(errors),
        "warnings": len(warnings),
        "passed": len(errors) == 0,
        "strict_passed": len(errors) == 0 and len(warnings) == 0,
    }
    report: Dict[str, Any] = {
        "schema_version": 1,
        "tool": "qc_srt.py",
        "version": __version__,
        "generated_at": datetime.datetime.now().astimezone().isoformat(
            timespec="seconds"),
        "input": {
            "path": input_path,
            "encoding": encoding,
            "target_lang": target_lang,
        },
        "reference": reference_info,
        "thresholds": {
            "max_cps": max_cps,
            "min_duration_ms": min_duration_ms,
            "max_duration_ms": max_duration_ms,
            "overlap_tolerance_ms": overlap_tolerance_ms,
            "max_gap_ms": max_gap_ms,
            "kana_severity": kana_severity,
        },
        "summary": summary,
        "metrics": {
            "total_duration_ms": total_duration_ms,
            "cps_max": round(max_cps_value, 2),
            "cps_max_index": max_cps_index,
            "cps_mean": round(sum(cps_values) / len(cps_values), 2) if cps_values else 0.0,
            "duration_min_ms": min_duration_value if min_duration_value is not None else 0,
            "duration_min_index": min_duration_index,
            "duration_max_ms": max_duration_value,
            "duration_max_index": max_duration_index,
        },
        "issues": issues,
        "errors": errors,
        "warnings": warnings,
    }
    return report


# ---------------------------------------------------------------------------
# 摘要与入口
# ---------------------------------------------------------------------------

_CODE_LABELS = {
    "no_cues": "空文件",
    "empty_text": "空字幕",
    "invalid_duration": "时长非法",
    "duration_too_short": "时长过短",
    "duration_too_long": "时长过长",
    "cps_over": "CPS 超限",
    "kana_residue": "日文假名残留",
    "overlap": "时间轴重叠",
    "large_gap": "停顿过长",
    "duplicate_text": "重复文本",
    "count_mismatch": "条数不一致",
    "timestamp_mismatch": "时间戳不一致",
    "parse_warning": "解析警告",
}


def print_summary(report: Dict[str, Any], report_path: str) -> None:
    """打印中文人读摘要。"""
    summary = report["summary"]
    metrics = report["metrics"]
    reference = report["reference"]

    print("=" * 62)
    print("SRT 质检报告")
    print("文件：{0}（目标语言：{1}）".format(report["input"]["path"],
                                             report["input"]["target_lang"]))
    if reference.get("provided"):
        print("参考：{0}（{1} 条）".format(reference["path"], reference["count"]))
    print("条数：{0} | 错误 {1} 项 | 警告 {2} 项 | 结论：{3}".format(
        summary["cues"], summary["errors"], summary["warnings"],
        "通过" if summary["passed"] else "不通过"))
    print("指标：最长 CPS {0:.1f}（第 {1} 条）| 平均 CPS {2:.1f} | 最短时长 {3}ms（第 {4} 条）"
          "| 最长时长 {5}ms（第 {6} 条）".format(
              metrics["cps_max"], metrics["cps_max_index"], metrics["cps_mean"],
              metrics["duration_min_ms"], metrics["duration_min_index"],
              metrics["duration_max_ms"], metrics["duration_max_index"]))

    if report["errors"]:
        print("-" * 62)
        print("错误（必须修复）：")
        for item in report["errors"][:10]:
            print("  [错误] {0}（{1}）".format(item["message"], _CODE_LABELS.get(item["code"], item["code"])))
        if len(report["errors"]) > 10:
            print("  ……共 {0} 项，完整清单见 JSON 报告。".format(len(report["errors"])))

    if report["warnings"]:
        print("-" * 62)
        print("警告（建议修复）：")
        for item in report["warnings"][:10]:
            print("  [警告] {0}（{1}）".format(item["message"], _CODE_LABELS.get(item["code"], item["code"])))
        if len(report["warnings"]) > 10:
            print("  ……共 {0} 项，完整清单见 JSON 报告。".format(len(report["warnings"])))

    print("-" * 62)
    print("质检报告：{0}".format(report_path))
    print("=" * 62)


def _write_json(path: str, data: Dict[str, Any]) -> str:
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    tmp = str(path) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp, str(path))
    return str(path)


def main(argv: Optional[List[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    try:
        cfg, cfg_path = cfgmod.load_pipeline_config(args.config)
        thresholds = {
            "max_cps": args.max_cps if args.max_cps is not None
            else cfgmod.cfg_get_float(cfg, "qc.max_cps", 15.0),
            "min_duration_ms": args.min_duration_ms if args.min_duration_ms is not None
            else cfgmod.cfg_get_int(cfg, "qc.min_duration_ms", 500),
            "max_duration_ms": args.max_duration_ms if args.max_duration_ms is not None
            else cfgmod.cfg_get_int(cfg, "qc.max_duration_ms", 9000),
            "overlap_tolerance_ms": cfgmod.cfg_get_int(cfg, "qc.overlap_tolerance_ms", 0),
            "max_gap_ms": cfgmod.cfg_get_int(cfg, "qc.max_gap_ms", 15000),
            "kana_severity": str(cfgmod.cfg_get(cfg, "qc.kana_severity", "error")),
            "duplicate_severity": str(cfgmod.cfg_get(cfg, "qc.duplicate_severity", "warning")),
            "max_compare_items": cfgmod.cfg_get_int(cfg, "qc.max_compare_items", 20),
        }
        report = qc_check(args.input, args.reference,
                          args.target_lang or cfgmod.cfg_get(cfg, "languages.target", "zh"),
                          thresholds)
    except cfgmod.ConfigError as exc:
        print("[错误] {0}".format(exc), file=sys.stderr)
        return 2
    except (QcRuntimeError, srt_io.SrtError, OSError) as exc:
        print("[错误] {0}".format(exc), file=sys.stderr)
        return 2

    report_path = args.report or (str(args.input) + ".qc.json")
    try:
        _write_json(report_path, report)
    except OSError as exc:
        print("[错误] 写质检报告失败：{0}".format(exc), file=sys.stderr)
        return 2

    if not args.quiet:
        print_summary(report, report_path)

    errors = report["summary"]["errors"]
    warnings = report["summary"]["warnings"]
    if errors:
        print("[结果] 质检不通过：{0} 项错误。".format(errors))
        return 1
    if warnings and args.strict:
        print("[结果] --strict 模式下警告也视为不通过：{0} 项警告。".format(warnings))
        return 1
    print("[结果] 质检通过{0}。".format("（有 {0} 项警告）".format(warnings) if warnings else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
