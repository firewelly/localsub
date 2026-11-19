# 双方案说明（方案A / 方案B）与 macOS 实测结论入口

> 2026-11-15 由准备机（transub_mac 项目）移植时新增。本文件与 `00-方案B-项目方案.md`、
> `../research/02-macos-实测结论移植.md` 均为**增量新增**，未改动方案A 的任何原文件；
> 根目录 `AGENTS.md` 已恢复为原版逐字内容。

## 两套方案并行

| | 方案A（本项目原方案） | 方案B（macOS 实测移植版） |
|---|---|---|
| 文档 | `docs/00-项目方案.md` ～ `04-排错手册.md` | `docs/planB/00-方案B-项目方案.md` |
| 转录 | whisper large-v3（ggml fp16，2.9GB，质量优先） | whisper **large-v3-turbo（ggml q8_0，~0.9GB，速度优先）** |
| 翻译 | Sakura-GalTransl 7B GGUF | **Hy-MT2-7B Q8_0**（腾讯官方 GGUF） |
| 翻译脚本 | 方案A 的 python 模块 | `scripts/python/translate_srt.py`（已通过 selftest 16/16） |
| 共享 | `models/`、`.venv`、`tools/windows/`、`input/work/output/logs/`、`config/` | 同左 |

- 切换方案 = 切换 `--model` 指向的模型文件；两套模型文件在 `models/` 内互补共存。
- Sakura（A）与 Hy-MT2（B）**未做头对头**；目标机用同一段素材 A/B 后再定主力。
- 大内存机器的可选提升：Hy-MT2 fp16 / 30B-A3B MoE；whisper large-v3-full（方案A 已含）。

## macOS 实测核心结论（详见 research/02）

1. **转录**：通用 large-v3-turbo 全面优于日语专精 kotoba-whisper-v2.1（整片 A/B：覆盖 93 vs 54 分钟、垃圾段 3% vs 73%、对话场景漏句更少）；kotoba 的"！"碎片风暴是模型层固有行为；int8 量化 whisper 会损坏真对白，禁止用于生产。
2. **翻译**：Hy-MT2 各档位中**参数量 > 量化精度**（1.8B-4bit ≈ 1.8B-8bit；7B-4bit 优于 1.8B）；专用 MT 模型无拒答训练，适配限制级素材。
3. **提示词**：转录 initial_prompt 三版（对白/限制级/中文）+ Hy-MT2 官方指令行 + 忠实性条款，见 planB/00 §4。
4. **后处理**：幻觉黑名单 + 纯语气词过滤（已内置 translate_srt.py，`--drop-hallucination --drop-filler`）。
5. **方法教训**：跨 SRT 对比必须按时间戳对齐；翻译服务请求 model 字段与启动字符串的关系需实机确认；长任务保留原始日志；转录与翻译分阶段跑不同时驻留。

## 对原项目的改动清单（透明化）

| 文件 | 操作 |
|---|---|
| `AGENTS.md` | 曾被增改，**现已恢复原版逐字内容**；本文件替代其说明职能 |
| `docs/research/02-macos-实测结论移植.md` | 新增 |
| `docs/planB/00-方案B-项目方案.md`、本文件 | 新增 |
| `scripts/python/translate_srt.py` | 新增（该文件此前不存在，是 selftest 契约预留的模块位；实现后 selftest 16/16 全绿） |
| `models/whisper/ggml-large-v3-turbo-q8_0.bin`、`models/translation/HY-MT2-7B-Q8_0.gguf` | 新增下载 |
| 其余所有文件 | **未改动** |
