# AGENTS.md — 项目协作与执行约定

> 本文件是本仓库的「Agent 上岗手册」。任何 AI Agent（含 DSH 智能体团队成员、Codex、Claude Code、Cursor 等）在本目录工作前必须先读完本文件。
> 人（项目所有者）也按本文件理解项目结构。**最后更新：2026-11-16**

---

## 1. 项目是什么

**通用的本地字幕流水线**：把视频转成时间轴准确、可用的双语 SRT，全程离线、不依赖云端 API。默认针对**日语 → 简体中文**调优；主支持 **Windows 11 + Intel Arc A770 16GB（USB4 外置显卡）**，Vulkan 后端、无 NVIDIA CUDA。

| 项 | 内容 |
|---|---|
| 最终执行机 | Windows 11 + **Intel Arc A770 16GB（USB4/雷电外置）** + Ryzen 7 7840H + 32GB RAM，**无 NVIDIA CUDA** |
| 当前工作机 | **本机 Windows 11 + Arc A770**（2026-11-16 起直接在本机工作、跑推理；原 macOS 准备机仅作历史记录） |
| 介质 | **本机本地磁盘的工作目录**（2026-11-16 起工作副本、模型、工具全部在本机磁盘）；2TB 移动硬盘（NTFS）仅作冷备份，**不作工作盘**（该盘有 NTFS 掉文件历史，2026-11-15/16 两次丢模型） |
| 产物 | `output/<视频名>/` 下 `ja.srt`（日语听写）、`zh.srt`（中文）、`bilingual.srt`（中日双语）、`report.json`（质检） |

**交付形态** = 可搬迁的项目目录 + 一键脚本 + 预下载模型 + 文档，插到目标机就能跑。

---

## 2. 铁律（违反即返工）

1. **绝对路径禁令**。目标机盘符未知（可能是 `D:` `E:` `F:`），所有脚本、配置、文档中的路径必须是**相对项目根**的。
   - PowerShell：用 `$PSScriptRoot` 推导项目根，`Join-Path` 拼接。
   - Python：用 `os.path.dirname(os.path.abspath(__file__))` 定位。
   - 文档/命令示例：写成 `cd <项目根>` 或「在项目根下执行 `.\scripts\windows\xxx.ps1`」。
   - 禁止把本机绝对路径写进脚本/配置/文档（示例统一用 `<相对路径>` 或 `<盘符>:/...`）。
2. **无 CUDA 前提**。任何方案不得假设 `cuda`、`nvidia-smi`、`cuDNN`、`torch.cuda` 可用。GPU 路径只有：**Vulkan**（whisper.cpp / llama.cpp）、**SYCL/oneAPI**（llama.cpp）、或 Intel 官方 **OpenVINO**。
3. **不臆造命令**。文档里的每条命令要么标注来源 URL，要么标注「推断，需实机验证」。禁止写「应该可以」。
4. **未验证必须声明**。截至 2026-11-16 已在本机（Windows 11 + Arc A770）实机验证：`selftest.py` 17/17、`00-check-env.ps1` 最终配置 0 FAIL、whisper-cli 走 Vulkan1（Arc）、llama-server 加载并翻译、**最终组合（large-v3 + Hy-MT2）与两个历史对照组均在同素材①（166.7 分钟）整片跑通**（数据见 §8/§10，素材已去番号）。**尚未验证**：更多素材的翻译复验、NAS/SMB 上 CPU 推理耗时；文档中未实测项仍须标注「未实机验证」。
5. **写作用域**。多人/多 Agent 并行时，先领任务再动手；同一文件同一时间只能有一个 owner。默认分工见 §7。
6. **中文优先**。文档、注释、提交信息、日志文案一律中文（代码标识符用英文）。
7. **文件编码**：所有 `.ps1` 存 **UTF-8 with BOM**（否则 Windows PowerShell 5.1 中文乱码）；`.md` / `.py` / `.json` 存 **UTF-8 无 BOM**；SRT 输出 **UTF-8**（是否加 BOM 由 config 决定，默认不加，兼容播放器更多）。

---

## 3. 技术路线（已核实结论，2026-11-15）

### 3.1 主链路（自动化、可批处理）

```
视频 → ffmpeg 抽 16kHz 单声道 WAV
     → whisper.cpp（Vulkan 后端）日语听写 → ja.srt
     → llama-server（llama.cpp Vulkan/SYCL，OpenAI 兼容 /v1/chat/completions）
        跑 Hy-MT2-7B GGUF → 逐句翻译 → zh.srt
     → 合并 → bilingual.srt + report.json（质检）
```

理由：整条链路都是**命令行 + 本地端口**，可被脚本编排、可断点重跑、可批量；两个引擎都支持 Intel GPU 的非 CUDA 后端。

### 3.2 工具核实表（重要，勿再重复踩坑）

| 工具 | 结论 | 证据 |
|---|---|---|
| **Transub**（v3.3.1，2026-11-09） | ⚠️ **不能作为自动化主路径**。官方 README 明确「仅 Windows」、GPU 加速只写 NVIDIA(CUDA)/AMD(ROCm)，是 Electron GUI，**没有 `transub run` 这类 CLI**。原方案里的"Intel XPU 听写 + CLI"说法**不成立**。<br>可用价值：作为**人工复核/精修的 GUI 备选**（编辑器、质检、烧录），但 Arc 上大概率回落 CPU。 | github.com/dlsandy/Transub README「下载安装」「GPU」段 |
| **VoiceTransl**（v1.31，2026-10-17） | ⚠️ **GUI 工具，不做脚本编排**。README 声明支持 AMD/NVIDIA/Intel GPU 加速、翻译引擎可调显存占用；听写路线基于 CrispASR 的 Qwen3-ASR + 强制对齐；GPLv3。适合当**人工兜底/对照实验**。 | github.com/shinnpuru/VoiceTransl README |
| **babelscribe**（v0.4.0，MIT） | ✅ **可用作轻量听写前端**：`pip install babelscribe`；命令行 `babelscribe video.mp4 -f srt -l ja`；首次运行自动下载 **Vulkan 版 whisper.cpp**，官方支持 Intel Arc；还能当 MCP server。适合「只要日语听写」的简化路径。 | phonology024.github.io/babelscribe |
| **whisper.cpp 官方 Windows 预编译** | ⚠️ 官方 Release 只有 CPU / CUDA / OpenCL-Adreno，**没有 Vulkan 的 Windows 预编译包**。本机采用社区构建 `jerryshell/whisper.cpp-windows-vulkan-bin` v1.0.0（2025-08，zip 17.5MB），**已实装并验证 Vulkan1=Arc**。 | api.github.com ggml-org/whisper.cpp releases；本机实跑 2026-11-16 |
| **llama.cpp 官方 Windows 预编译** | ✅ 有 `llama-bXXXXX-bin-win-vulkan-x64.zip`（约 36MB）、`-sycl-x64`（约 164MB）、`-openvino-*-x64`（约 100MB），均含 `llama-server.exe`。本机实装 **b12428**（2026-11-16 抓取）。 | api.github.com ggml-org/llama.cpp releases；本机实跑 2026-11-16 |
| **ffmpeg** | Windows 静态包（gyan.dev / BtbN）。只用于抽音轨与（可选）硬字幕烧录。 | 官方下载页 |

> 工具版本会更新：**上线前重新核对 Release 资产名**，不要把本表当永久真值。文档里已核实项都带日期。

### 3.3 模型

| 用途 | 模型 | 位置（相对路径） |
|---|---|---|
| 日语听写主模型 | Whisper **large-v3**（ggml fp16，2.88GB） | `models/whisper/ggml-large-v3.bin` |
| VAD | Silero VAD（ggml，0.9MB） | `models/whisper/ggml-silero-v5.1.2.bin` |
| 日译中主模型 | **Hy-MT2-7B-Q8_0**（腾讯官方，7.43GB） | `models/translation/HY-MT2-7B-Q8_0.gguf` |

> 2026-11-16 瘦身定版：turbo / turbo-q8 / Sakura 已永久删除（共 8.15GB），旧配置未随仓库发布。
> 来源与 sha256 见 `models/MANIFEST.md`。**不要再把已删模型写回配置。**

模型清单、来源 URL、sha256、许可证见 `models/MANIFEST.md`；目标机离线校验见 `models/README.md`。

---

## 4. 目录结构（约定，任何人不得随意新增顶层目录）

```
<项目根>/
├─ AGENTS.md              ← 本文件：Agent 上岗手册
├─ README.md              ← 人看的总入口
├─ .gitignore
├─ docs/
│  ├─ 00-项目方案.md       ← 目标/范围/里程碑/验收标准
│  ├─ 01-部署手册-Windows.md
│  ├─ 02-工作流与参数.md    ← 听写/翻译参数、双语排版、CPS 阈值
│  ├─ 03-模型与工具清单.md
│  ├─ 04-排错手册.md
│  └─ research/            ← 工具核实记录（含证据链接、未核实项）
├─ config/
│  ├─ pipeline.example.json ← 参数模板（脚本缺 pipeline.json 时自动复制）
│  └─ README.md
├─ scripts/
│  ├─ windows/             ← .ps1（目标机执行入口）
│  ├─ python/              ← 跨平台、可单测的核心逻辑
│  └─ mac/                 ← 准备机辅助脚本（下模型、校验等）
├─ tools/
│  ├─ windows/             ← 放 ffmpeg.exe / whisper-cli.exe / llama-server.exe 及其 DLL
│  └─ README.md            ← 二进制清单与放置约定
├─ models/                 ← 预下载模型（随硬盘搬迁）
├─ input/                  ← 待处理视频（用户自己放）
├─ work/                   ← 中间产物（音频 wav、临时文件，可删）
├─ output/                 ← 最终字幕产物
└─ logs/                   ← 运行日志
```

---

## 5. 命令速查（目标机 Windows）

```powershell
# 在项目根下执行
.\scripts\windows\00-check-env.ps1          # 环境自检：ffmpeg/whisper/llama-server/模型/显卡
.\scripts\windows\01-transcribe.ps1 -InputDir .\input        # 只做日语听写
.\scripts\windows\02-translate.ps1 -InputDir .\output\xxx    # 只做中日翻译
.\scripts\windows\03-bilingual.ps1 -InputDir .\output\xxx    # 合并双语 + 质检
.\scripts\windows\run-all.ps1 -InputDir .\input              # 一键全流程（单视频/单批）
.\scripts\windows\run-batch.ps1 -InputDir <源盘>:\videos -Recurse -ExcludeCUC
                                                            # 批量：先全部听写再统一翻译；断点续跑
.\scripts\windows\run-batch.ps1 -Status                     # 查看批量进度（另开终端）
.\scripts\windows\run-batch.ps1 -InputDir <源盘>:\videos -Recurse -ExcludeCUC -OutputBesideSource
                                                            # 输出写在视频同目录
```

参数全部集中在 `config/pipeline.json`，不要硬编码进脚本。

---

## 6. 开发与验证约定

- **本机可验证的**：Python 代码（`selftest.py` 必须全绿）、SRT 解析/合并/质检逻辑、配置文件合法性、PowerShell 脚本、Vulkan 后端设备选择、模型加载与整片听写/翻译（三组合均已实测）、显存峰值（GPU 计数器）。
- **尚未验证的**：更多素材的 Hy-MT2 vs Sakura 复验、NAS/SMB 上 CPU 推理速度。**必须在文档里标注「未实机验证」**，并给出验证步骤。
- **改动必跑**：`python3 scripts/python/selftest.py`；涉及 SRT 逻辑的改动还需用一份真实字幕做回归。
- **测试要求**：测试必须覆盖错误路径（空 SRT、时间戳非法、条数丢失、翻译接口超时/失败回退），不能只验证「有输出」。
- 提交前检查隐私：不把 `.env`、API Key、个人路径、视频文件本身提交；`input/`、`work/`、`output/`、`logs/`、`models/*.bin`、`tools/windows/**` 已在 `.gitignore` 中排除。

---

## 7. 并行协作分工（DSH 智能体团队）

| 角色 | 写作用域 | 职责 |
|---|---|---|
| Lead | 根目录 `README.md`、`AGENTS.md`、`docs/00-*`、`.gitignore` | 方案、任务拆分、最终审查与验收 |
| scout-arc | `docs/research/01-*` | 只读调研，核实工具链事实 |
| scout-models | `models/` | 核实仓库、下载、校验清单 |
| builder-pipe | `scripts/`、`config/`、`tools/` | 脚本与 Python 管道实现 |
| doc-writer | `docs/01-*`、`docs/02-*`、`docs/03-*`、`docs/04-*` | 部署/参数/排错文档 |

规则：**先建任务再派人**；依赖用 `blocked_by`；同一文件同一时刻只有一个 owner；完成即 `complete`；**Lead 必须亲自跑测试并 review 最终产物**，不能只看汇报。

---

## 8. 当前状态（2026-11-16，本机实机）

**已完成并实机验证**：
- 项目在本机本地磁盘（非移动盘）；外置盘多次掉线/读取报 `partial file`，只作冷备份，不作工作盘。
- **模型瘦身定版（2026-11-16）**：仅保留 `whisper/ggml-large-v3.bin`、`whisper/ggml-silero-v5.1.2.bin`、`translation/HY-MT2-7B-Q8_0.gguf`（均校验通过）；turbo×2 与 Sakura 已永久删除（共 8.15GB），旧配置/元数据未随仓库发布，来源与 sha256 见 `models/MANIFEST.md`。
- 工具就位：ffmpeg（BtbN 2026-11-15）、whisper-cli（jerryshell Vulkan v1.0.0）、llama-server（b12428 Vulkan）。
- **共用 Python 环境**：`.venv`（Python 3.12.10，零第三方依赖），`tools.python` 指向它；`selftest.py` **17/17（285 断言）**。
- **配置定版**：`config/pipeline.json` = large-v3 + Hy-MT2；`pipeline.example.json` 同步；旧 planA/planB/planB-full 已归档（不提交）。`00-check-env.ps1` **0 FAIL**。
- **整片实测（素材已去番号）**：
  - 素材①（对白密集，166.7 分钟）：**最终组合 701 条 / 约 29 分钟，0 error / 236 警告，翻译零失败、0 假名残留**；对照组 large-v3+Sakura 701 条 / 28m07s、1 error；turbo-q8+Hy-MT2 466 条 / 10m32s、0 error（151 条超长 cue）。
  - 素材②（对白极稀，81.8 分钟）：关 VAD 得 164 条、其中 140 条幻觉；VAD+10 分钟分片+清洗后仅 2 条真实对白。
  - 同 10 分钟片段模型对照：turbo-q8 75 条/100s、turbo-fp16 56 条/74s、large-v3 125 条/244s（文本明显更准）。
  - 显存峰值 <10GB（听写 1.07–3.2GB、翻译 6.2–8.6GB）。
- **关键硬件发现**：Vulkan 枚举 0=AMD Radeon 780M（核显）、1=Intel Arc A770；配置已固定 `-dev 1` / `-dev Vulkan1`（日志 `using Vulkan1 backend`）。
- **关键缺陷（实跑发现并修复）**：`-vad`→`--vad`；`01` 成功消息 `-f` 占位符缺参；`translate_srt.py` 误读 `translation.*`；该 whisper-cli 的 VAD 长音频退化 → 10 分钟分片 + 流式抽取；新增 `merge_srt_parts.py` 合并/清洗。
- **批量流程（run-batch.ps1）**：阶段1 全部听写 → 阶段2 单次 llama-server 统一翻译 → 阶段3 统一合并/质检；`output/batch-state.json` + 产物双重断点续跑；实时显示 `[i/N]`、`[片 k/N]`、预计剩余；`-Status`/`-ListOnly`/`-Limit`/`-Force`；`-StageDir` 可选暂存；**抽取/听写超时保护**（默认 600s/1800s）→ 超时杀进程、该视频判失败并继续队列，重跑可续。

**待办**：
- [ ] 更多素材复验 Hy-MT2 翻译质量（当前仅素材① 一部）。
- [ ] `translate_srt.py` 的 concurrency/timeout/retries/temperature 尚未接配置（当前用默认值）。
- [ ] NAS/SMB 批处理实测（本地 scratch + 流式分片已支持，CPU 推理速度待测）。
- [ ] 外置盘稳定性复测（换 USB 线/口），或改用 NAS（SMB）源。
---

## 9. 遇到不确定时

1. 先查 `docs/research/` 是否已有结论，避免重复调研。
2. 需要外部信息时走代理抓官方 Release / README / Issue，**引用链接与日期**。
3. 方案有重大变更（换引擎、换模型、改目录结构）→ 先改本文件与 `docs/00-项目方案.md`，再改代码。
4. 无法验证的事情，宁可写成「待实机验证」，也不要假装完成。

## 10. 技术路线与方案选择（2026-11-16 实测，素材已去番号）

### 10.1 最终链路

```
视频 → ffmpeg 抽 16kHz 单声道
     → whisper.cpp (Vulkan) + Silero VAD：10 分钟分片、逐片听写、合并清洗 → ja.srt
     → llama-server (Vulkan) + Hy-MT2-7B：逐句翻译（hunyuan 提示词）→ zh.srt
     → 合并 → bilingual.srt + report.json（QC）
```

### 10.2 为什么是 large-v3 + Hy-MT2（素材①：对白密集，166.7 分钟）

| 组合 | 听写 | 翻译 | 全流程 | 质检 |
|---|---|---|---|---|
| large-v3 + Sakura | 701 条 / 25m19s | 零失败，1 条整句不译 | 28m07s | 1 error / 229 警告 |
| turbo-q8 + Hy-MT2 | 466 条 / 7m32s | 零失败 | 10m32s | 0 error / 191 警告（151 超长 cue） |
| **large-v3 + Hy-MT2（定版）** | **701 条 / 25m19s** | **零失败、0 残留** | ~29m | **0 error / 236 警告** |

- turbo 组合虽快约 3 倍，但大量 30 秒级超长 cue、断句与标点差，不适合作为字幕交付。
- Sakura 偶发整句不译（残留假名，QC 直接判 error）；Hy-MT2 同份 701 条零残留。
- 显存峰值：听写 1.07–3.2GB、翻译 6.2–8.6GB，合计 <10GB（A770 16GB 安全）。

### 10.3 听写模型对照（同 10 分钟片段）

| 模型 | 条数 | 耗时 | 观察 |
|---|---|---|---|
| turbo-q8_0 | 75 | 100s | 长句粘连、无标点 |
| turbo-fp16 | 56 | 74s | 略好，仍粘连 |
| **large-v3** | **125** | 244s | 有标点、断句正确，明显更准 |

结论：**参数量 > 量化精度**；turbo 两档都不足以替代 large-v3。

### 10.4 为什么必须 VAD + 10 分钟分片（素材②：对白极稀，81.8 分钟）

- 该 whisper-cli（jerryshell Vulkan v1.0.0）的 VAD 在 **≥~35 分钟**音频上退化为 0 段（30 分钟片正常 342 段、82 分钟整片 0 段）。
- 关 VAD 整片跑：164 条里 140 条幻觉（`ご視聴ありがとうございました` 等）。
- 10 分钟分片 + VAD + 清洗：正常识别，清洗后仅 2 条真实对白 → 素材本身几乎无对白。
- 因此「整片一次载入」不可行（除非接受空字幕或大量幻觉）；分片是正确性必需，不是性能选择。
- 分片开销：每片模型加载约 2 秒，17 片约 34 秒（占 166 分钟片总耗时 ~2%）。

### 10.5 批量与 IO 设计

- **两阶段**：全部听写完成后再统一翻译，翻译模型只加载一次；状态文件 + 产物双重判定断点续跑。
- **流式分片**：抽一片 → 听写 → 立即删除，峰值本地占用≈1 片（10 分钟≈20MB），适合 SMB/NAS。
- **源盘隔离**：`-StageDir` 带超时与重试复制到本地，单个视频失败不阻塞整个队列。

### 10.6 结论

- 交付默认：**large-v3 + Hy-MT2**（`config/pipeline.json`），166.7 分钟片约 29 分钟（≈5.8× 实时），质检 0 error。
- 旧组合（turbo/Sakura）已删除，旧组合未随仓库发布；不建议作为交付默认。

---

## 11. 命名与引用

- 本项目早期工作名为 **transub**，现按通用字幕流水线重新包装（文档标题 LocalSub）。
- **未复用 [dlsandy/Transub](https://github.com/dlsandy/Transub) 的任何代码**；该项目因仅 Windows GUI、无 CLI、不支持 Intel Arc 被排除，早期命名仅受其启发。
- 本仓库**不是其 fork**；第三方组件与许可见 NOTICE.md。
