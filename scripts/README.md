# scripts/ 脚本说明

> 字幕流水线脚本目录。目标机：Windows 11 + Intel Arc A770 16GB（无 NVIDIA CUDA）。
> 所有脚本与配置都使用**相对项目根**的路径，移动硬盘换盘符（D:/E:/F:）无需改代码。
>
> **状态：Python 部分已在本机（macOS）实跑通过；PowerShell 部分只做了语法解析与 macOS PowerShell 7
> 上的 mock 链路冒烟，未在 Windows 实机运行。详见文末「验证状态与未验证项」。**

## 目录结构

```
scripts/
├─ windows/                 目标机执行入口（Windows PowerShell 5.1 / PowerShell 7）
│  ├─ _common.ps1           公共函数库（被其他脚本 dot-source 引入，不直接运行）
│  ├─ 00-check-env.ps1      环境自检
│  ├─ 01-transcribe.ps1     日语听写（ffmpeg + whisper.cpp）
│  ├─ 02-translate.ps1      日译中（llama-server + Python 翻译脚本）
│  ├─ 03-bilingual.ps1      双语合并 + 质检
│  ├─ run-all.ps1           一键批量流水线
│  └─ download-tools.ps1    缺失工具/模型的下载指引
└─ python/                  跨平台核心逻辑（只依赖标准库，可单独运行/单测）
   ├─ srt_io.py             SRT 解析 / 序列化 / 双语合并
   ├─ pipeline_config.py    项目根定位 + 配置加载（缺失自动复制）
   ├─ translate_srt.py      逐句翻译（OpenAI 兼容接口；--mock/--dry-run）
   ├─ merge_srt.py          日文+中文 → 双语 SRT（独立 CLI）
   ├─ qc_srt.py             SRT 质检（CPS/时长/重叠/空字幕/日文残留/条数对比）
   ├─ selftest.py           Python 部分自检（不依赖模型/网络）
   └─ samples/demo.ja.srt   演示用日文样例字幕
```

## 首次使用（目标机 Windows）

```powershell
# 1) 在项目根打开 PowerShell（无需管理员权限），如遇执行策略拦截：
#    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   # 只需执行一次
cd <项目根>

# 2) 环境自检（首次会从 config/pipeline.example.json 自动复制出 config/pipeline.json）
.\scripts\windows\00-check-env.ps1

# 3) 工具/模型缺失时看下载指引
.\scripts\windows\download-tools.ps1

# 4) 把视频放进 input/，然后一键批处理
.\scripts\windows\run-all.ps1
```

单步执行：

```powershell
.\scripts\windows\01-transcribe.ps1 -InputDir .\input        # 只做日语听写
.\scripts\windows\02-translate.ps1 -InputDir .\output\001    # 只做翻译
.\scripts\windows\03-bilingual.ps1 -InputDir .\output\001    # 只做合并+质检
```

## 产物与日志

每个视频（以 `001.mp4` 为例）在 `output\001\` 下产出：

| 文件 | 说明 | 由谁生成 |
|---|---|---|
| `ja.srt` | 日语听写字幕（时间轴源头） | 01-transcribe.ps1 |
| `zh.srt` | 简体中文译文（条数/时间轴与 ja.srt 逐条一致） | 02-translate.ps1 |
| `bilingual.srt` | 中日双语（默认中文在上/日文在下） | 02 或 03 |
| `report.json` | 质检报告（错误/警告/指标，机器可读） | 03-bilingual.ps1 |
| `translate-report.json` | 翻译报告（成功/失败/回退明细，附加） | 02-translate.ps1 |

`run-all.ps1` 汇总报告写到 `output\summary-<时间戳>.json`；日志统一写 `logs\`。
中间音频 `work\<视频名>\audio16k.wav` 默认在上传成功后删除（`-KeepAudio` 可保留，用于排查）。

## PowerShell 脚本详解

### 公共约定

- 所有脚本从 `$PSScriptRoot` 推导项目根：`scripts/windows` 往上两级。
- 配置文件默认 `config\pipeline.json`；不存在时自动从 `config\pipeline.example.json` 复制并提示。
  所有可调参数（工具/模型路径、音频参数、whisper 参数、llama 参数、翻译/质检阈值、双语排版）都在配置里，
  不要改脚本硬编码。
- 工具/模型路径支持通配符（例如 `models/translation/Sakura-Galtransl-7B-v3.7.gguf` 会按文件名排序取第一个）。
- 失败一律返回非零退出码并输出**中文**错误与修复提示。

### `00-check-env.ps1` — 环境自检

| 参数 | 说明 |
|---|---|
| `-Config <path>` | 配置文件路径（默认 `config\pipeline.json`） |
| `-PythonExe <path>` | 指定 Python 可执行文件（默认读配置 `tools.python`，再依次尝试 PATH 里的 `python`/`python3`/`py`） |
| `-SkipGpu` | 跳过显卡检测（例如远程/虚拟机环境） |
| `-Quiet` | 只输出汇总，不逐项输出 |

检查项：PowerShell 版本、操作系统、`tools/windows` 目录、ffmpeg、whisper-cli、llama-server、
Python 版本（≥3.8）、Whisper 模型、Silero VAD 模型、翻译模型、磁盘剩余空间、显卡（Arc）、
llama 端口占用、output/work/logs 读写权限、input 目录。
输出 `[PASS]/[WARN]/[FAIL]` 彩色报告与修复提示。**退出码：0 关键项全通过（可有警告）；1 有 FAIL。**

### `01-transcribe.ps1` — 日语听写

| 参数 | 说明 |
|---|---|
| `-InputDir <path>` | 单个音视频文件或目录（别名 `-InputPath`/`-InputFile`）；默认 `input/` |
| `-Config <path>` | 配置文件路径 |
| `-OutputRoot <path>` | 覆盖 `output/` 根目录（默认读配置） |
| `-WorkRoot <path>` | 覆盖 `work/` 根目录 |
| `-Force` | 忽略已有 `ja.srt` / 已有音频，强制重跑 |
| `-Recurse` | 目录输入时递归子目录 |
| `-KeepAudio` | 成功后保留 `work` 下的 16k wav |

流程：ffmpeg 抽 16kHz/单声道 WAV → whisper.cpp（`-l ja -osrt`，可选 VAD/词级时间戳/`extra_args`）
→ `output\<视频名>\ja.srt`。已存在 `ja.srt` 时默认跳过（断点续跑）。
**退出码：0 全部成功/跳过；1 有文件失败（其余继续）；2 输入为空、配置或工具/模型缺失。**

### `02-translate.ps1` — 日译中

| 参数 | 说明 |
|---|---|
| `-InputDir <path>` | `ja.srt` 文件、含 `ja.srt` 的目录（如 `output\001`）或 `output\`（递归）；默认 `output\` |
| `-Config <path>` | 配置文件路径 |
| `-ServerUrl <url>` | 复用已在运行的 llama-server，如 `http://127.0.0.1:8080` |
| `-Force` | 已有 `zh.srt` 时也重新翻译 |
| `-Mock` | **离线模拟**：不启动服务、不联网，用内置伪中文跑完整文件链路（自测/演示用，不代表翻译质量） |
| `-PythonExe <path>` | 指定 Python（默认自动查找） |
| `-NoServerStart` | 只调用接口，不启动 llama-server（配合 `-ServerUrl` 或手工启动的服务） |
| `-SkipHealthCheck` | 跳过服务健康检查（外部服务确定可用时可加速） |
| `-StartupTimeoutSec <n>` | 覆盖服务启动就绪超时（默认读配置 `llama.startup_timeout_sec`，默认 180 秒） |

流程：解析目标 → 若未指定外部服务，则启动 `llama-server.exe`（参数来自配置 `llama` 段）→
轮询 `/health` 直到就绪（进程早退/超时会打印日志尾部与中文诊断）→ 调
`python\translate_srt.py` 逐句翻译 → 结束时关闭自己启动的 server。
自动检测已有健康服务并复用；端口被占用且健康检查不过时给出明确错误。
**退出码：0 全部成功/跳过；1 有翻译失败或部分失败（已回退原文，产物仍写出）；2 无输入、配置/服务启动失败。**

### `03-bilingual.ps1` — 双语合并 + 质检

| 参数 | 说明 |
|---|---|
| `-InputDir <path>` | `ja.srt` 文件、含 ja.srt/zh.srt 的目录或 `output\`；默认 `output\` |
| `-Config <path>` | 配置文件路径 |
| `-PythonExe <path>` | 指定 Python |
| `-Force` | 已有 `bilingual.srt` 时也重新合并（质检始终执行） |
| `-AllowMismatch` | 条数/时间戳不一致时仍按条号对齐合并（默认报错） |
| `-Strict` | 质检警告也视为不通过（默认只有 error 导致失败） |
| `-Mode <mode>` | 覆盖双语排版：`zh_top` / `ja_top` / `same_line` |

流程：`merge_srt.py` 合并（时间轴以日文为准，校验条数/时间戳逐条一致）→ `qc_srt.py` 质检
（CPS、时长上下限、时间轴重叠、空字幕、日文假名残留、条数丢失、时间戳对比）→ `report.json`。
**退出码：0 全部通过（允许警告）；1 有合并/质检不通过；2 无输入、配置错误。**

### `run-all.ps1` — 一键批量流水线

| 参数 | 说明 |
|---|---|
| `-InputDir <path>` | 输入视频文件/目录；默认 `input/` |
| `-Config <path>` | 配置文件路径 |
| `-OutputRoot` / `-WorkRoot <path>` | 覆盖输出/中间目录 |
| `-PythonExe <path>` | 指定 Python |
| `-ServerUrl <url>` | 复用外部 llama-server |
| `-Force` | 所有阶段忽略断点强制重跑 |
| `-Mock` | 翻译阶段离线模拟；听写阶段仍需真实工具，因此要求已有 `ja.srt`（或配 `-SkipTranscribe`） |
| `-SkipTranscribe` | 跳过听写，直接把 `-InputDir` 里的 `ja.srt`（含 `*.ja.srt`、子目录）走后续流程 |
| `-SkipEnvCheck` | 跳过 00 环境自检 |
| `-Strict` | 质检警告也算失败 |

流程：00 环境自检（失败即中止）→ 逐个视频：01 听写 → 02 翻译 → 03 合并+质检 →
校验四件产物 → 汇总写 `output\summary-<时间戳>.json`。单个视频失败不中断整批。
**退出码：0 全部成功；1 有失败（或环境自检不通过）；2 无输入/配置错误。**

### `download-tools.ps1` — 工具/模型下载指引

| 参数 | 说明 |
|---|---|
| `-Component <name[]>` | `all`/`ffmpeg`/`whisper`/`llama`/`python`/`models`，可多个 |
| `-CheckOnly` | 只检查本地是否就位，不输出下载指引 |
| `-Open` | 同时用默认浏览器打开官方下载页（Windows） |
| `-Config <path>` | 配置文件路径 |

**不做静默下载**（体积大、来源/许可证需人工确认），只输出官方与镜像地址、资产名、放置目录、
校验方法、代理与镜像说明。**退出码：0 指引输出完成（`-CheckOnly` 时组件齐全）；1 `-CheckOnly` 有缺失；2 配置不可用。**

### `_common.ps1` — 公共函数库

被上述脚本 `dot-source` 引入，不直接运行。提供：`Get-PipelineConfig`（含缺失自动复制）、`Get-Cfg`、
`Resolve-FullPath`、`Resolve-ConfiguredPath`（通配符解析）、`Find-ToolExecutable`（配置路径→PATH 回退）、
`Get-PythonCommand`、`Invoke-Native`（合并 stdout/stderr 写日志）、`Wait-HttpReady`、`Stop-ServerProcess`、
`Get-InputMediaFiles`、`Get-JaSrtFiles`、`Write-Utf8NoBom` 等。

## Python 脚本详解（跨平台，也可在 macOS/Linux 上单独运行）

> 目标机无需 pip 安装任何第三方包（只用标准库）。Python 版本需要 3.8+。

### `srt_io.py` — SRT 读写与合并基础模块

- 解析容错：UTF-8 BOM、CRLF、`.234` 点号毫秒、1~4 位毫秒、缺序号、箭头两侧多余空格、
  脏行跳过并记录警告；自动尝试 UTF-8/Shift_JIS/GB18030/Big5 编码。
- 序列化严格：时间戳统一 `HH:MM:SS,mmm`，序号连续，块间空行。
- 双语合并三种模式：`zh_top`（中上日下）、`ja_top`（日上中下）、`same_line`（同一行加分隔符）。
- 排查模式：`python3 scripts/python/srt_io.py <文件> [--json]`。

### `pipeline_config.py` — 配置定位与加载

从自身位置推导项目根，加载 `config/pipeline.json`；缺失时自动复制 `config/pipeline.example.json`
并输出中文提示。`python3 scripts/python/pipeline_config.py [--config 路径] [--print]` 可排查配置。

### `translate_srt.py` — 逐句翻译（核心）

```text
python3 scripts/python/translate_srt.py --input ja.srt [选项]
  --output-dir/-o      输出目录（默认与输入同目录）
  --zh-name            中文文件名（默认 zh.srt）
  --bilingual-name     双语文件名（默认 bilingual.srt）
  --report             翻译报告文件名（默认 report.json）
  --config/-c          配置文件路径
  --mock               离线自测：确定性伪译文，不联网
  --dry-run            只解析并预览请求，不调用接口、不写产物
  --api-base           覆盖 translate.api_base（如 http://127.0.0.1:8080/v1）
  --model              覆盖模型名（llama-server 一般忽略）
  --concurrency        并发数（默认读配置）
  --context-size       前文参考条数（默认读配置）
  --timeout            单次请求超时秒数
  --retries            失败重试次数
  --no-fallback        失败不回退原文，直接以非零退出码结束
  --no-health-check    跳过 llama-server /health 检查
  --quiet / --verbose
```

行为：并发调用 OpenAI 兼容 `/v1/chat/completions`；失败按指数退避重试；最终失败按
`translate.fallback_on_error` 回退日文原文并在报告 `failures` 记录。
**脚本内置断言**：输出中文/双语条数与时间戳必须与输入逐条一致，否则退出码 3 且不写“半对”文件。
**退出码：0 全部成功；1 运行错误（配置/输入/接口不可用）；2 部分句失败已回退（产物仍写出）；3 输出校验失败。**

### `merge_srt.py` — 独立双语合并 CLI

```text
python3 scripts/python/merge_srt.py --ja ja.srt --zh zh.srt --out bilingual.srt
  [--mode zh_top|ja_top|same_line] [--separator " | "] [--allow-mismatch] [--report 路径] [--quiet]
```

默认要求条数与时间戳逐条一致，不一致时退出码 2 并列出具体条目。

### `qc_srt.py` — 质检 CLI

```text
python3 scripts/python/qc_srt.py --input zh.srt --reference ja.srt --report report.json
  [--target-lang zh|ja|bilingual] [--max-cps N] [--min-duration-ms N] [--max-duration-ms N]
  [--strict] [--quiet]
```

检查项：CPS 超限（warning）、时长过短/过长（warning）、时间轴重叠/非法时长（error）、
空字幕（error）、日文假名残留（默认 error，可配置为 warning）、条数丢失与时间戳不一致（error）。
输出 JSON + 中文摘要。**退出码：0 通过（可有警告）；1 有 error（或 `--strict` 下有 warning）；2 运行错误。**

### `selftest.py` — Python 部分自检（不依赖模型/网络）

```powershell
python3 scripts/python/selftest.py            # 全量测试
python3 scripts/python/selftest.py --verbose  # 额外打印每项断言
```

覆盖：时间戳解析/格式化 round-trip、容错解析、严格序列化、编码读写（BOM/Shift_JIS/CRLF）、
双语三种排版与不一致报错、配置合法性与自动复制、`translate_srt.py --mock` 端到端（含产物条数/时间戳
逐条一致、可重复性、`--dry-run` 不写文件）、翻译失败路径（接口不可用→非零；回退→退出码 2 + 报告记录）、
质检正常/异常/`--strict`、各 CLI `--help`。**退出码：0 全绿；1 有失败。**

### `samples/demo.ja.srt` — 演示样例

8 条日文字幕，用于快速验证链路（产物建议写到 `/tmp` 或 `work/` 等临时目录，避免污染 `output/`）：

```powershell
python3 scripts/python/selftest.py
python3 scripts/python/translate_srt.py --input scripts/python/samples/demo.ja.srt --output-dir work/demo-mock --mock
```

## 验证状态与未验证项

### 已在本机（macOS）验证

- ✅ `python3 scripts/python/selftest.py`：16/16 项测试、260 项断言全部通过。
- ✅ `translate_srt.py --mock` 端到端：样例 8 条 → `zh.srt`/`bilingual.srt`/`report.json`，
  条数与时间戳与输入逐条一致（脚本内断言），双语排版正确、结果可重复。
- ✅ 配置缺失自动复制：中文提示 + 生成 `config/pipeline.json`。
- ✅ 7 个 `.ps1` 全部通过 PowerShell 解析器语法检查（本机 `pwsh` 7.5.4）。
- ✅ macOS PowerShell 7 上的 mock 链路冒烟：`00-check-env` 正常出报告并按缺工具返回 1；
  `02-translate -Mock` → `03-bilingual` → `run-all -Mock -SkipTranscribe` 全链路跑通，
  产物四件套齐全、汇总 JSON 正确；错误路径（缺工具/无输入/外部服务不可达）返回非零 + 中文提示。

### 未验证（必须在目标机 Windows 实机确认）

- ⚠️ Windows PowerShell 5.1 与 PowerShell 7 上的**实机执行**（本机只验证了解析与部分 mock 链路）。
- ⚠️ Windows 专有调用：`Get-CimInstance Win32_VideoController`（显卡）、`Get-NetTCPConnection`（端口）、
  `Start-Process -RedirectStandardOutput/Error`（llama-server 后台启动）等。
- ⚠️ ffmpeg / whisper-cli / llama-server 的真实命令行参数与行为（`-vad`/`-vm`/`-sns`/`-owts`、
  `--version`/`--help`、`-ngl` 等）——需以各二进制实际帮助为准；若有差异，优先改
  `config/pipeline.json` 的 `whisper.extra_args` / `llama.extra_args`。
- ⚠️ Vulkan/SYCL 后端是否真正使用 Intel Arc、显存占用、听写/翻译质量与速度。
- ⚠️ 中文/日文路径、含空格目录（脚本按相对路径与参数数组传递，但未在 Windows 实机覆盖）。

### 已知限制

- `02-translate.ps1` 启动的 llama-server 默认只监听配置里的 `llama.host`（默认 `127.0.0.1`），
  不对外网开放；如需远程复用，请自行改配置并注意安全。
- `--mock` 译文带 `【模拟】` 前缀，仅用于链路验证，**不可当成真实字幕交付**。
- 真实翻译质量取决于所选 GGUF（Sakura/GalTransl）与参数，脚本只保证流程与格式正确。
- 断点策略：`ja.srt`/`zh.srt`/`bilingual.srt` 已存在则跳过，需要重跑加 `-Force`。
