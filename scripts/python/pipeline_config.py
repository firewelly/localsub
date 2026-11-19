#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流水线配置定位与加载模块（仅依赖标准库，兼容 Python 3.8+）。

项目根目录由本文件位置推导：``scripts/python/pipeline_config.py`` 向上两级
即为项目根（``scripts/`` -> 项目根）。同时向上查找 ``config/pipeline.example.json``
做二次确认，保证整个目录被拷到移动硬盘任意盘符后仍然可用（不依赖绝对路径）。

配置使用规则：
- 优先使用用户显式传入的 ``--config`` 路径（相对路径相对项目根解析）。
- 未传入时使用 ``config/pipeline.json``。
- ``config/pipeline.json`` 不存在时，若 ``config/pipeline.example.json`` 存在，
  自动复制一份并输出中文提示，然后按默认值继续运行。
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

__version__ = "1.0.0"

SCRIPT_DIR = Path(__file__).resolve().parent
# scripts/python -> scripts -> 项目根
_FALLBACK_PROJECT_ROOT = SCRIPT_DIR.parents[1]

CONFIG_DIR_NAME = "config"
CONFIG_NAME = "pipeline.json"
EXAMPLE_NAME = "pipeline.example.json"


class ConfigError(RuntimeError):
    """配置相关错误（中文信息，便于目标机直读）。"""


# ---------------------------------------------------------------------------
# 项目根定位
# ---------------------------------------------------------------------------

def find_project_root(start: Optional[Path] = None) -> Path:
    """从 ``start`` 起逐级向上查找含 ``config/pipeline.example.json`` 的目录。"""
    base = Path(start) if start is not None else SCRIPT_DIR
    for candidate in [base] + list(base.parents):
        if (candidate / CONFIG_DIR_NAME / EXAMPLE_NAME).is_file():
            return candidate
    return _FALLBACK_PROJECT_ROOT


PROJECT_ROOT: Path = find_project_root()


def ensure_config(config_path: Optional[str] = None,
                  root: Optional[Path] = None) -> Tuple[Path, bool]:
    """确保配置文件存在，返回 ``(配置路径, 是否为本次自动复制)``。"""
    root = Path(root) if root is not None else find_project_root()
    if config_path:
        candidate = Path(config_path)
        if not candidate.is_absolute():
            candidate = root / candidate
    else:
        candidate = root / CONFIG_DIR_NAME / CONFIG_NAME

    if candidate.is_file():
        return candidate, False

    example = root / CONFIG_DIR_NAME / EXAMPLE_NAME
    if not example.is_file():
        raise ConfigError(
            "缺少配置文件：{0}，且未找到模板 {1}。请先确认项目目录完整。".format(
                candidate, example
            )
        )
    candidate.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.copyfile(str(example), str(candidate))
    except OSError as exc:
        raise ConfigError(
            "自动复制配置文件失败：{0} -> {1}，原因：{2}".format(example, candidate, exc)
        )
    print(
        "[提示] 未找到 {0}，已从 {1} 自动复制默认配置，请按需修改。".format(
            candidate, example.name
        ),
        file=sys.stderr,
    )
    return candidate, True


def load_pipeline_config(config_path: Optional[str] = None,
                         root: Optional[Path] = None) -> Tuple[Dict[str, Any], Path]:
    """加载配置 JSON，返回 ``(配置字典, 实际使用的配置路径)``。"""
    path, _ = ensure_config(config_path=config_path, root=root)
    try:
        with open(str(path), "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as exc:
        raise ConfigError(
            "配置文件不是合法 JSON：{0}（第 {1} 行第 {2} 列）。".format(
                path, exc.lineno, exc.colno
            )
        )
    except OSError as exc:
        raise ConfigError("读取配置文件失败：{0}，原因：{1}".format(path, exc))
    if not isinstance(data, dict):
        raise ConfigError("配置文件顶层必须是 JSON 对象：{0}".format(path))
    return data, path


# ---------------------------------------------------------------------------
# 取值 / 路径工具
# ---------------------------------------------------------------------------

def cfg_get(config: Dict[str, Any], dotted_key: str, default: Any = None) -> Any:
    """按 ``a.b.c`` 形式读取嵌套配置，缺失时返回 ``default``。"""
    node: Any = config
    for part in str(dotted_key).split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return default if node is None else node


def cfg_get_float(config: Dict[str, Any], dotted_key: str, default: float) -> float:
    try:
        return float(cfg_get(config, dotted_key, default))
    except (TypeError, ValueError):
        return float(default)


def cfg_get_int(config: Dict[str, Any], dotted_key: str, default: int) -> int:
    try:
        return int(cfg_get(config, dotted_key, default))
    except (TypeError, ValueError):
        return int(default)


def cfg_get_bool(config: Dict[str, Any], dotted_key: str, default: bool) -> bool:
    value = cfg_get(config, dotted_key, default)
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "on", "是")
    return bool(value)


def resolve_path(relative: Optional[str], root: Optional[Path] = None) -> Path:
    """把配置里的相对路径解析成绝对路径（绝对路径原样返回，仅用于外部传入）。"""
    root = Path(root) if root is not None else find_project_root()
    if relative is None or str(relative).strip() == "":
        return root
    text = str(relative).strip()
    if text.startswith("~"):
        text = os.path.expanduser(text)
    candidate = Path(text)
    if candidate.is_absolute():
        return candidate
    return root / candidate


def resolve_glob(relative_pattern: Optional[str],
                 root: Optional[Path] = None) -> Tuple[Optional[Path], List[Path]]:
    """解析可能含通配符的配置路径，返回 ``(首选路径, 全部候选)``。

    用于“模型文件名带量化后缀、准备机下载的确切文件名未知”的场景：
    例如配置 ``models/translation/sakura-*.gguf``。
    """
    if relative_pattern is None or str(relative_pattern).strip() == "":
        return None, []
    pattern_path = resolve_path(relative_pattern, root=root)
    text = str(pattern_path)
    if any(ch in text for ch in "*?["):
        import glob
        candidates = [Path(p) for p in glob.glob(text)]
        candidates = [p for p in candidates if p.is_file()]
        candidates.sort(key=lambda p: p.name)
        return (candidates[0] if candidates else None), candidates
    return (pattern_path if pattern_path.is_file() else None), (
        [pattern_path] if pattern_path.is_file() else []
    )


def project_relative(path: Any, root: Optional[Path] = None) -> str:
    """把路径转成项目内相对路径（POSIX 分隔符）；项目外路径原样返回字符串。"""
    root = Path(root) if root is not None else find_project_root()
    try:
        candidate = Path(path)
        if candidate.is_absolute():
            return candidate.relative_to(root).as_posix()
        return candidate.as_posix()
    except (ValueError, TypeError):
        return str(path)


def srt_writer_options(config: Dict[str, Any]) -> Tuple[str, str]:
    """读取 SRT 写出选项，返回 ``(编码, 行尾)``。"""
    encoding = str(cfg_get(config, "srt.encoding", "utf-8-sig") or "utf-8-sig")
    newline_name = str(cfg_get(config, "srt.newline", "lf") or "lf").strip().lower()
    newline = "\r\n" if newline_name in ("crlf", "windows", "win") else "\n"
    return encoding, newline


def bilingual_options(config: Dict[str, Any]) -> Tuple[str, str]:
    """读取双语排版选项，返回 ``(模式, 分隔符)``。"""
    mode = str(cfg_get(config, "bilingual.mode", "zh_top") or "zh_top")
    separator = str(cfg_get(config, "bilingual.separator", " | ") or " | ")
    return mode, separator


# ---------------------------------------------------------------------------
# 直接用本模块排查配置（python pipeline_config.py）
# ---------------------------------------------------------------------------

def _main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="流水线配置排查小工具")
    parser.add_argument("--config", default=None, help="配置文件路径（默认 config/pipeline.json）")
    parser.add_argument("--print", dest="do_print", action="store_true", help="打印完整配置")
    args = parser.parse_args()

    print("脚本目录：{0}".format(SCRIPT_DIR))
    resolved_root = find_project_root()
    print("项目根目录：{0}".format(resolved_root))
    try:
        config, path = load_pipeline_config(args.config)
    except ConfigError as exc:
        print("错误：{0}".format(exc), file=sys.stderr)
        return 1
    print("配置文件：{0}".format(path))
    if args.do_print:
        print(json.dumps(config, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
