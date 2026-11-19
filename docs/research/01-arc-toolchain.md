# 01 · Intel Arc A770（无 NVIDIA CUDA）日语听写 + 日译中工具链核实报告

> 核实人：scout-arc（DSH 团队调研成员）｜核实日期：**2026-11-15**｜适用目标机：Windows 11 + Intel Arc A770 16GB + Ryzen 7 7840H + 32GB RAM，**无 NVIDIA CUDA**
> 当前准备机是 macOS，**本文件中的 Windows 命令、Vulkan/SYCL 后端行为、显存与速度数据均未在目标机实机验证**。
>
> 证据等级约定：
> - **【已核实】**：本轮通过 `curl -x socks5h://127.0.0.1:1080` 抓取官方 README / `api.github.com` / HF API 元数据，附链接、版本号与抓取日期（2026-11-15）。其中标注"Lead 已核实"的条目由 Lead 同年同日抓取，本文件不重复抓取。
> - **【未核实】**：本轮没抓到直接证据（或只在第三方文档中出现），**不得当结论使用**，需实机验证或补充抓取。
> - 所有命令块末尾标注来源：`[来源:官方文档]` / `[推断,需实机验证]`。
>
> 抓取记录：本轮外部请求共 8 次（1 次多查询 web 搜索 + 7 次 GitHub 代理请求），清单见 §6。GitHub 直连超时，全部走 SOCKS5。

---

## 一、结论速览

### 1.1 推荐主路径（自动化、可批处理）

```
视频 → ffmpeg 抽 16kHz 单声道 PCM WAV
     → whisper.cpp（Windows 社区 Vulkan 构建 whisper-cli.exe）日语听写 → ja.srt
     → llama-server（llama.cpp Vulkan 构建，OpenAI 兼容 /v1/chat/completions）
        跑 Sakura 7B/8B GGUF 日译中 → zh.srt
     → 合并 bilingual.srt + report.json
```

理由：全链路都是**命令行 + 本地 HTTP 端口**，可编排、可断点重跑、可批量；两个引擎都有 Intel 可用的非 CUDA 后端（Vulkan），且都有 Windows x64 预编译资产（llama.cpp 为官方、whisper.cpp 为社区）。

### 1.2 三条旧断言裁定（逐条给证据，不得沿用原文）

| # | 旧断言 | 裁定 | 证据 |
|---|---|---|---|
| 1 | Transub v3.3.0+ 支持 Intel Arc XPU 听写 + 本地 LLM 翻译，并有 `transub run` CLI | **❌ 不成立** | GitHub **dlsandy/Transub v3.3.1（2026-11-09）**，仅 Windows、Electron GUI，README 的 GPU 段落只写 NVIDIA(CUDA)/AMD(ROCm)，无 Intel XPU 路径，也无任何 CLI 文档，主形态是"拖视频进 GUI"。证据：[README](https://github.com/dlsandy/Transub/blob/main/README.md)、[CHANGELOG](https://github.com/dlsandy/Transub/blob/main/CHANGELOG.md)、[Releases](https://github.com/dlsandy/Transub/releases)。【已核实（Lead 抓取 api.github.com + README，2026-11-15）】 |
| 2 | VoiceTransl 支持 Intel GPU 加速 | **⚠️ 只能算"部分成立、不可脚本化"** | GitHub **shinnpuru/VoiceTransl v1.31（2026-10-17）**，GPL-3.0，README 声明支持 AMD/NVIDIA/**Intel** 加速；听写基于 CrispASR 的 Qwen3-ASR + 强制对齐；翻译支持 Sakura / GalTransl / Ollama / Llamacpp；形态是 **GUI**。【已核实（Lead 抓取 README，2026-11-15）】；**但其"Intel 加速"到底落到哪个后端（whisper.cpp-Vulkan / OpenVINO / CTranslate2）、显存占用如何调、有无 CLI/HTTP 入口 —— 【未核实】，本轮未抓到代码或设置项证据，不得写进主路径。** |
| 3 | babelscribe 用 Vulkan 在 Arc 上跑 whisper.cpp | **✅ 基本成立，但 Intel Arc 未经官方实测** | GitHub **phonology024/babelscribe v0.4.0**，**MIT**。README（2026-11-15 抓取）首行即写 "offline speech-to-text and subtitles on any GPU (AMD, NVIDIA, Intel, Apple)"；硬件表明确 `AMD / NVIDIA / Intel GPU on Windows → Vulkan → windows-x64-vulkan`；底层就是 whisper.cpp；有 CLI：`babelscribe video.mp4 -f srt -l ja`；输出 SRT/VTT/TXT/JSON/ASS；也可当 MCP server。证据：[README](https://github.com/phonology024/babelscribe)。【已核实（README 抓取，2026-11-15）】；风险：作者自述**只在 AMD Radeon RX 9070 XT（Windows/Vulkan）端到端实测过**，Intel Arc 属"声明支持、未实测"。【已核实（README Limitations 段）】 |

### 1.3 备选与淘汰

| 类别 | 结论（1–2 行） |
|---|---|
| ✅ 主路径 | whisper.cpp(Vulkan, 社区包) + llama-server(Vulkan, 官方包) + Sakura GGUF；纯 CLI，可批量、可离线（模型预下载）。 |
| ✅ 轻量备选（听写） | **babelscribe**：`pip install` 即成，自动下 Vulkan 版 `whisper-cli`，CLI 可批处理；适合"只想快速出日语 SRT"的简化路径或交叉验证。风险是 Intel Arc 未实测、首跑需联网取二进制。 |
| ✅ 官方后端备选 | llama.cpp 已提供 `win-openvino` 预编译（b12405，OpenVINO 2026.4.1 x64）——Intel 自家推理栈，可作 Vulkan 失败时的后端备胎。【已核实（Lead 抓取 api.github.com，2026-11-15）】 |
| ⚠️ 未核实备选 | OpenVINO GenAI / optimum-intel 直接跑 Whisper（Arc GPU/NPU）、ArcSub、Buzz、Subtitle Edit+whisper.cpp、kotoba-whisper 日语专优模型：本轮均**未抓到官方证据**，列 §4 待办。 |
| ❌ 淘汰（主路径） | **Transub**：GUI、无 CLI、GPU 仅 CUDA/ROCm，无 Intel 证据 → 最多当人工复核 GUI。 |
| ❌ 淘汰（自动化） | **VoiceTransl**：GUI + GPL-3.0，Intel 后端未核实 → 仅作对照实验/人工兜底。 |
| ❌ 淘汰（GPU 退路） | **faster-whisper / WhisperX 的 GPU 加速**：其 GPU 后端是 CTranslate2，只吃 NVIDIA CUDA → Arc 上只能跑 **CPU 退路**（可用但慢），只能当最后兜底。【已核实（第三方对比表，babelscribe README，2026-11-15；非 faster-whisper 官方文档）】 |

---

## 二、逐工具核实表

| 工具 | 版本 / 日期 | Intel GPU（Arc）支持证据 | Windows | 可脚本化 | 许可证 | 核实状态 + 链接 |
|---|---|---|---|---|---|---|
| **whisper.cpp**（官方 ggml-org） | v1.9.5（2026-10-06） | **官方 Windows 预编译无 Vulkan**：仅 `win-cpu-arm64`、`win-cuda-*`、`win-opencl-adreno-arm64`、`whisper-bin-x64.zip`(CPU)。Vulkan 需自编译（README 给 `-DGGML_VULKAN=1`；Docker 的 `main-vulkan` 仅 linux/amd64） | ✅（MSVC/MinGW 自编译） | ✅ `whisper-cli` | MIT | 【已核实：Release 资产 Lead 抓 api.github.com 2026-11-15；[README](https://github.com/ggml-org/whisper.cpp) Vulkan/VAD/16-bit WAV 段本轮抓取 2026-11-15】 |
| **whisper.cpp-windows-vulkan-bin**（社区 jerryshell） | v1.0.0（发布 2025-08-21，资产 2026-05-31 更新） | 直接提供 Windows Vulkan 构建；上游是 whisper.cpp | ✅ 解压即用 | ✅ `whisper-cli.exe` | ⚠️ **仓库未声明许可证**（api.github.com `license: null`），上游 whisper.cpp 为 MIT | 【已核实：[repo](https://github.com/jerryshell/whisper.cpp-windows-vulkan-bin)、[release v1.0.0](https://github.com/jerryshell/whisper.cpp-windows-vulkan-bin/releases/tag/v1.0.0)、README 与 release API 本轮抓取 2026-11-15】 |
| **llama.cpp**（官方 ggml-org，Vulkan 版） | b12405（2026-11-13） | `llama-b12405-bin-win-vulkan-x64.zip`（36MB），Vulkan 后端覆盖 Intel Arc | ✅ | ✅ `llama-server.exe` / `llama-cli.exe` | MIT | 【已核实：Lead 抓 api.github.com 2026-11-15；[Release b12405](https://github.com/ggml-org/llama.cpp/releases/tag/b12405)】 |
| **llama.cpp**（官方，SYCL 版） | b12405（2026-11-13） | `llama-b12405-bin-win-sycl-x64.zip`（164MB），Intel oneAPI/SYCL 后端 | ✅ | ✅ | MIT | 【已核实：资产名与大小 Lead 抓取 2026-11-15】；**SYCL runtime（oneAPI）是否随包自带 —— 【未核实】** |
| **llama.cpp**（官方，OpenVINO 版） | b12405（2026-11-13） | `llama-b12405-bin-win-openvino-2026.4.1-x64.zip`（100MB） | ✅ | ✅ | MIT | 【已核实：Lead 抓取 2026-11-15】；实际可用性【未核实】 |
| **Sakura GGUF 模型**（HF） | 见 §3.4 文件清单 | 与后端无关（GGUF 通用） | ✅ | ✅ | ⚠️ CC-BY-NC-SA-4.0（非商用，模型卡 tags 实测） | 【已核实：本地 HF API 元数据 `models/_meta/_info.json` 等，抓取 2026-11-15】 |
| **babelscribe** | v0.4.0 | README 声明 Intel Arc（Vulkan），硬件表 `windows-x64-vulkan` | ✅ | ✅ CLI + Python + MCP | **MIT** | 【已核实：[README](https://github.com/phonology024/babelscribe) 本轮抓取 2026-11-15；版本号 Lead 核实】 |
| **Transub** | v3.3.1（2026-11-09） | README GPU 段仅 NVIDIA(CUDA)/AMD(ROCm)；**无 Intel 证据** | ✅ 仅 Windows | ❌ 无 CLI（Electron GUI） | 未核实（不含本主路径） | 【已核实：[README](https://github.com/dlsandy/Transub/blob/main/README.md) Lead 抓取 2026-11-15】 |
| **VoiceTransl** | v1.31（2026-10-17） | README 声明 AMD/NVIDIA/Intel 加速；**具体 Intel 后端【未核实】** | ✅ | ❌ GUI 为主（CLI/HTTP 入口【未核实】） | **GPL-3.0** | 【部分已核实：[repo](https://github.com/shinnpuru/VoiceTransl) Lead 抓取 2026-11-15】 |
| **faster-whisper / WhisperX** | — | GPU 后端 = CTranslate2，**CUDA only**；Arc 只能 CPU | ✅ | ✅ Python | MIT | 【已核实（第三方对比表，babelscribe README 2026-11-15）；faster-whisper 官方文档本轮未抓】 |
| **Buzz** | — | 有 whisper.cpp 后端选项（社区 issue 提到 "Windows 1.3.0 Whisper.cpp (Vulkan)"） | ✅ | ⚠️ GUI 为主 | MIT | **【未核实】**：仅搜索摘要，未抓仓库/Release，不得当结论 |
| **Subtitle Edit + whisper.cpp** | 4.x | GUI 可挂 whisper.cpp 构建；jerryshell README 明确"复制文件到 `%appdata%\Subtitle Edit\Whisper\Cpp`" | ✅ | ❌（GUI 精修） | Subtitle Edit 为 GPL-ish（未核实） | 【部分已核实：jerryshell README 集成段，2026-11-15】 |
| **ArcSub** | — | — | — | — | — | **【未核实】**：本轮未定位到稳定官方仓库，不作为方案 |
| **OpenVINO GenAI / optimum-intel Whisper** | OpenVINO 2026.x | Intel 官方，理论支持 Arc GPU/NPU | ✅ | ✅ Python | Apache-2.0 | **【未核实】**：本轮未抓 Intel 官方文档；命令见 §3.6 只给"待核实的形状"，不写死参数 |
| **ffmpeg**（gyan.dev / BtbN 静态包） | — | 与 GPU 无关（纯 CPU 解码/封装） | ✅ | ✅ | GPL/LGPL 视构建而定（未核实具体包） | **【未核实】**：本轮未抓下载页；抽 WAV 的**命令参数本身**已在 jerryshell README 示例里核实 |
| **kotoba-whisper**（日语专优） | — | 与后端无关（HF Whisper 架构微调） | ✅ | 需转换后才能进 whisper.cpp/faster-whisper | 未核实 | **【未核实】**：能否转 ggml / 转 CTranslate2、与 large-v3 的 CER 对比均未核实 |

---

## 三、可直接复制的 Windows 命令块

> 全部命令**在项目根目录执行**（`cd <项目根>`），只用相对路径；不出现盘符与绝对路径。
> PowerShell 5.1 下若中文乱码，请把脚本存成 UTF-8 with BOM（见 AGENTS.md §2 铁律 7）。

### 3.0 放置二进制（一次性）

```powershell
# 项目根下执行
New-Item -ItemType Directory -Force .\tools\windows, .\work, .\output | Out-Null
# 1) 下载 jerryshell 的 whisper.cpp-windows-vulkan.zip（资产名已核实）
#    https://github.com/jerryshell/whisper.cpp-windows-vulkan-bin/releases/tag/v1.0.0
#    -> whisper.cpp-windows-vulkan.zip （18,340,920 B ≈ 17.5 MiB）
# 2) 解压到 .\tools\windows\，确认存在 .\tools\windows\whisper-cli.exe 及配套 DLL
# 3) 下载 llama.cpp 的 llama-b12405-bin-win-vulkan-x64.zip（已核实资产名）
#    https://github.com/ggml-org/llama.cpp/releases/tag/b12405
#    解压到 .\tools\windows\，确认 llama-server.exe / llama-cli.exe
```

[来源:官方/资产名已核实] jerryshell Releases + Lead 的 llama.cpp Release 抓取；**zip 内 DLL 清单未核实**，解压后务必对照 `whisper-cli.exe` 能否单独启动。

### 3.1 抽 16kHz 单声道 PCM WAV（whisper-cli 只吃 16-bit WAV）

```powershell
ffmpeg -hide_banner -i ".\input\xxx.mp4" -vn -loglevel error -ar 16000 -ac 1 -c:a pcm_s16le -y ".\work\xxx.wav"
```

[来源:官方文档] 与 jerryshell README 示例逐参数一致（`-vn -ar 16000 -ac 1 -c:a pcm_s16le`）；whisper.cpp README 明确 "currently runs only with 16-bit WAV files"（2026-11-15 抓取）。

### 3.2 日语听写 → `ja.srt`（whisper.cpp Vulkan，社区包）

```powershell
.\tools\windows\whisper-cli.exe `
  -m .\models\whisper\ggml-large-v3.bin `
  -f .\work\xxx.wav `
  -l ja `
  --vad -vm .\models\whisper\ggml-silero-v5.1.2.bin `
  -sns `
  -osrt `
  -of .\output\xxx\ja
```

- `--vad -vm <模型>`：**已核实**，whisper.cpp README VAD 段原文给出（`--vad` + `--vad-model`；短选项 `-vm` 见 jerryshell 示例），VAD 模型来自 HF `ggml-org/whisper-vad`；本项目已预下载 `ggml-silero-v5.1.2.bin`（记录：sha256 `29940d98…a2cf`，与 jerryshell 示例同版本系列）。
- `-sns`（suppress non-speech tokens）、`-osrt`（输出 SRT）：**已核实**，jerryshell README 示例逐字出现。
- `-l ja`（语言）、`-of <前缀>`（输出文件前缀）：**未核实/推断**——本次抓取的 whisper.cpp 与 jerryshell README 未逐行列出这两个开关。实机首跑先执行 `.\tools\windows\whisper-cli.exe -h` 核对；若 `-of` 不存在，则去掉它，产物在 wav 同目录（`xxx.wav.srt`），脚本里改名/搬移即可。
- `-m`：**已核实**，README 示例通用。
- 注意 **VAD 模型要与构建配套**：jerry 包（2025-08 构建）示例用 `ggml-silero-v5.1.2.bin`；whisper.cpp 1.9.5 README 示例已换成 `silero-v6.2.0`。混用可能加载失败，实机以能加载为准（本机已备 v5.1.2，风险较低）。

### 3.3 如何确认"真的跑在 GPU"（首次务必做）

```powershell
# 把 stderr+stdout 一起落日志，然后查关键字
.\tools\windows\whisper-cli.exe -m .\models\whisper\ggml-large-v3.bin -f .\work\xxx.wav -l ja --vad -vm .\models\whisper\ggml-silero-v5.1.2.bin -osrt 2>&1 |
  Tee-Object -FilePath .\logs\whisper-xxx.log
Select-String -Path .\logs\whisper-xxx.log -Pattern "Vulkan|ggml_vulkan|backend|device"
```

预期日志关键字（**判断依据**）：出现 `ggml_vulkan: Found N Vulkan devices`、`ggml_vulkan: 0 = Intel(R) Arc(TM) A770 Graphics`、`register_backend: registered backend Vulkan` 之类行，即表示后端已注册到 Vulkan；若只出现 CPU 相关行或报 Vulkan 初始化失败，则退回 CPU。
[**未核实**：上述关键字取自 ggml Vulkan 后端的通用日志惯例，本轮未抓到官方日志原文。首次运行请把真实日志片段回填本文件 §4 第 3 条。]
旁证：任务管理器 → 性能 → GPU（Intel Arc），转写期间 3D/Dedicated GPU memory 应有明显占用；也可用 GPU-Z 看显存与 GPU 负载。

### 3.4 启动 llama-server（日译中，OpenAI 兼容）

```powershell
.\tools\windows\llama-server.exe `
  -m .\models\translation\sakura-7b-qwen2.5-v1.0-q6k.gguf `
  --host 127.0.0.1 --port 8080 `
  -ngl 99 `
  -c 4096
```

- `-m`、`--host/--port`、`-ngl 99`（全部层 offload 到 GPU）、`-c 4096`（上下文）：**llama.cpp 标准参数，但本轮未抓 llama.cpp README/--help，标【推断,需实机验证】**。实机先跑 `.\tools\windows\llama-server.exe --help` 核对；若显存吃紧，把 `-c` 降到 2048 或 `-ngl` 降到 20–30（Sakura 单句翻译用不到长上下文）。
- 模型文件（HF 实测存在，本地 HF API 元数据 2026-11-15）：
  - `sakura-7b-qwen2.5-v1.0-iq4xs.gguf`（4,250,298,208 B ≈ 4.25 GB）/ `…-q6k.gguf`（6,254,198,624 B ≈ 6.25 GB）
  - `sakura-8b-qwen3-v1.1-iq4xs.gguf`（4,593,296,064 B ≈ 4.59 GB）/ `…-q6k.gguf`（6,725,898,944 B ≈ 6.73 GB）
  - 其他已确认仓库：`SakuraLLM/Sakura-14B-Qwen2.5-v1.0-GGUF`、`SakuraLLM/Sakura-GalTransl-7B-v3.7`、`SakuraLLM/Sakura-GalTransl-14B-v3.8`。
- **16GB 显存建议**：whisper 与 llama-server **不要同时常驻**（large-v3 GGUF ≈3.1GB + q6k 翻译模型 ≈6.3GB + KV/计算缓冲，峰值估算 10–13GB，属推断），流水线按"先听写、后翻译"串行；Sakura 7B 用 q6k（≈6.3GB）较稳，14B 仅作可选实验。【推断,需实机验证】

### 3.5 OpenAI 兼容调用（Sakura 的官方 prompt 与解码参数）

```powershell
$ja = "こんにちは、今日はいい天気ですね。"
$sys = "你是一个轻小说翻译模型，可以流畅通顺地以日本轻小说的风格将日文翻译成简体中文，并联系上下文正确使用人称代词，不擅自添加原文中没有的代词。"
$user = "将下面的日文文本翻译成中文：" + $ja
$body = @{
  model = "sakura"
  temperature = 0.1
  top_p = 0.3
  max_tokens = 512
  messages = @(
    @{ role = "system"; content = $sys },
    @{ role = "user";   content = $user }
  )
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Uri "http://127.0.0.1:8080/v1/chat/completions" `
  -Method Post -ContentType "application/json; charset=utf-8" -Body $body |
  Select-Object -ExpandProperty choices |
  Select-Object -ExpandProperty message |
  Select-Object -ExpandProperty content
```

- **system / user 文案与 `将下面的日文文本翻译成中文：` 前缀**：**已核实**，SakuraLLM 仓库 README「推理 / prompt 格式」段原文（v1.0pre1 与 v0.9 模板相同）[链接](https://github.com/SakuraLLM/SakuraLLM/blob/main/README.md)，2026-11-15 抓取。
- **解码参数**：**已核实**，同一 README 的「推理与解码参数」表：`temperature=0.1`、`top p=0.3`、`do sample=True`、`beams number=1`、`repetition penalty=1`、`max new token=512`、`min new token=1`；出现退化（重复）时加 `frequency_penalty` **0.1~0.2**（README 明示）。
- `repetition penalty=1` 等于"不惩罚"，所以 OpenAI 请求里不必传该字段（OpenAI 协议本身也没有 `repetition_penalty`）；若需要，按 llama-server 扩展字段 `repeat_penalty` 传，**该字段名【未核实】**。
- 请求体字段（`model/temperature/top_p/max_tokens/messages`）是 OpenAI Chat Completions 协议标准；llama-server 对 `model` 值不校验（填任意字符串即可）【推断,需实机验证】。
- 注意：README 的解码参数针对 **Qwen2.5 的 v1.0（7B/14B）**；`Sakura-8B-Qwen3-v1.1-SFT` 与 GalTransl 系列的推荐参数**【未核实】**，接入 8B 版前先看其 HF 模型卡。

### 3.6 备选：babelscribe（一条命令出日语 SRT）

```powershell
py -3 -m pip install babelscribe          # README 写 Python 3.9+
babelscribe .\input\xxx.mp4 -l ja -f srt  # 输出 xxx.srt（与视频同目录）
```

- **已核实**（README 2026-11-15）：`pip install babelscribe`、Python 3.9+、`-l ja`、`-f srt`、默认 `-f srt` 输出同名 `.srt`，`-f srt,vtt,txt,json` 或 `ass` 可选；`babelscribe devices` 列出 GPU，`--device N` 指定；`-m large-v3` 指定模型；`--bin <路径>` 用自有 whisper.cpp 构建。
- 首次运行会**联网下载** `windows-x64-vulkan` 版 `whisper-cli` 与模型，缓存位置：程序在 `~/.babelscribe`（可用 `BABELSCRIBE_HOME` 改），模型在 `~/.babelscribe/models`（可用 `BABELSCRIBE_MODELS` 改）；ffmpeg 由包内置。【已核实（README Privacy/Models 段）】
- **离线复用**：目标机无网时，可先在项目内把已有 `ggml-large-v3.bin` 通过 `BABELSCRIBE_MODELS` 指向 `.\models\whisper`，并用 `--bin .\tools\windows\whisper-cli.exe` 复用 jerry 构建；**该组合是否被 babelscribe 完整支持（模型文件名是否必须匹配其 `babelscribe models` 列表）【未核实】**。
- Windows 运行库（Visual C++ / VC++ redistributable）是否必需：README **未提**，【未核实】。

### 3.7 备选（未核实，先不要投入）：OpenVINO 路径

- llama.cpp 已有官方 `llama-b12405-bin-win-openvino-2026.4.1-x64.zip`（已核实资产名），可直接试 Sakura GGUF 的 OpenVINO 后端；实际吞吐/兼容性【未核实】。
- OpenVINO GenAI / optimum-intel 直接跑 Whisper（Arc GPU、NPU）：Intel 官方路线，但**本轮未抓文档**，命令参数无法逐字给出。接入前必须打开官方 README 抄参数：[openvino.genai](https://github.com/openvinotoolkit/openvino.genai)、[optimum-intel](https://github.com/huggingface/optimum-intel)。**禁止在此方案上凭记忆写命令。**

### 3.8 可选：硬字幕烧录

```powershell
ffmpeg -hide_banner -i ".\input\xxx.mp4" -vf "subtitles=./output/xxx/bilingual.srt" -c:v libx264 -crf 18 -preset medium -c:a aac -b:a 192k -y ".\output\xxx\burn.mp4"
```

[推断,需实机验证]：`subtitles=` 滤镜需 ffmpeg 构建带 libass（gyan.dev full / BtbN gpl 构建通常带，**未核实**）；Windows 上滤镜里的路径建议用正斜杠，反斜杠需转义，首次务必先烧 30 秒样片试。

### 3.9 批处理骨架（PowerShell，推断，需实机验证）

```powershell
# scripts/windows 下的脚本用 $PSScriptRoot 推导项目根（禁止硬编码盘符）
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # scripts/windows -> 项目根
Get-ChildItem (Join-Path $Root "input") -File | Where-Object { $_.Extension -in ".mp4",".mkv",".mov" } | ForEach-Object {
    $name = $_.BaseName
    $wav  = Join-Path $Root "work\$name.wav"
    $outDir = Join-Path $Root "output\$name"
    New-Item -ItemType Directory -Force $outDir | Out-Null
    & ffmpeg -hide_banner -i $_.FullName -vn -loglevel error -ar 16000 -ac 1 -c:a pcm_s16le -y $wav
    & (Join-Path $Root "tools\windows\whisper-cli.exe") -m (Join-Path $Root "models\whisper\ggml-large-v3.bin") -f $wav -l ja --vad -vm (Join-Path $Root "models\whisper\ggml-silero-v5.1.2.bin") -sns -osrt -of (Join-Path $outDir "ja")
}
```

[推断,需实机验证]（参数见 §3.2 的核实状态）；`$PSScriptRoot` 相对根目录写法为 AGENTS.md 约定。

---

## 四、未核实与风险清单

**A. 三条旧断言相关**
1. Transub 的"Intel XPU 听写 + `transub run` CLI"**无任何证据**，已裁定不成立；但其 GUI 里有"GPU 加速"下拉，**有没有隐藏的 Intel 选项【未核实】**（要验证需在 Arc 机装 GUI 看设置项）。不投入。
2. VoiceTransl 的 Intel 加速后端、显存调节方式、是否可脚本化（CLI/HTTP）**全部未核实**；且 GPL-3.0 若做二次分发/嵌入有传染性风险。不投入主路径。
3. babelscribe 的 Intel Arc 支持是**声明级**，作者只在 AMD RX 9070 XT 实测；Windows 上 Intel Arc 端到端【未核实】。

**B. 主路径二进制**
4. jerryshell 社区包 **v1.0.0（2025-08-21 发布）** 与 whisper.cpp 上游 v1.9.5（2026-10）**版本不一致**：其 CLI 参数、VAD 模型版本(v5.1.2)、Vulkan 后端实现都可能是旧的。首跑必须 `whisper-cli.exe -h` 对参数，并用 §3.3 日志确认 Vulkan 后端。**该仓库无许可证声明**（GitHub API `license: null`），仅上游 whisper.cpp 为 MIT；分发到他人机器前注意合规。
5. 官方 whisper.cpp **无 Windows Vulkan 预编译**，自编译需 Visual Studio 2022 + Vulkan SDK + cmake（README 只给 `cmake -B build -DGGML_VULKAN=1`，Windows 具体依赖【未核实】）。备选：改用 babelscribe 自带 Vulkan 构建，或试 llama.cpp 的 win-openvino 版本。
6. **SYCL 版风险（未核实）**：`llama-b12405-bin-win-sycl-x64.zip` 若未自带 Intel oneAPI runtime（常见 `sycl*.dll`/`ur_*.dll` 缺失），启动会直接失败；修复方式一般是装 Intel oneAPI Base Toolkit 或改用 Vulkan 版。**先选 Vulkan 版，SYCL 只作性能对照。**

**C. 运行时/硬件风险（全部需实机验证）**
7. **Arc A770 Vulkan 已知问题**：本轮未检索 issue（【未核实】）。实机首验必查项：① 驱动版本（Intel Arc driver 最新版，旧驱动 Vulkan 后端可能崩溃）；② `ggml_vulkan: Found …` 是否识别到 A770；③ 长音频（>1h）是否会显存飙高/崩溃（whisper.cpp 按 30s 窗口+整段 PCM 载入，长音频风险在内存而非显存，但 Vulkan 分配失败会 abort）；④ 大模型（large-v3）显存峰值是否触发共享内存回退（回退后速度骤降）。测量方法：任务管理器 GPU 专用显存 + `whisper-cli` 计时（`--print-progress` 是否存在【未核实】）。
8. **16GB 显存并发**：whisper 与 llama-server 同时常驻有 OOM/回退风险（估算见 §3.4，【推断】）；流水线默认串行。
9. **whisper.cpp 只接受 16-bit WAV**（已核实），ffmpeg 抽音频必须 `-ar 16000 -ac 1 -c:a pcm_s16le`；不做这步会直接报错。
10. VAD 模型版本与构建配套问题（见 §3.2 末尾）。
11. `-l ja` / `-of` 参数名未逐字核实（见 §3.2）；以 `--help` 为准。

**D. 其他未核实项（本轮无证据，不得当结论）**
12. ffmpeg Windows 静态包来源（gyan.dev `https://www.gyan.dev/ffmpeg/builds/`、BtbN `https://github.com/BtbN/FFmpeg-Builds/releases`）：未抓取，版本号、是否含 libass 未核实；抽 WAV 命令本身已核实。
13. kotoba-whisper（日语专优）：能否转 ggml 进 whisper.cpp、能否用 faster-whisper/CT2 直接跑、与 large-v3 的 CER 差多少，**全未核实**；结论先不纳入主路径（主路径用 large-v3）。
14. ArcSub、Buzz（whisper.cpp-Vulkan 选项）、Subtitle Edit 的许可证与"是否能批处理"未核实；只作 GUI 精修备选。
15. OpenVINO GenAI / optimum-intel Whisper（Arc GPU/NPU）未核实；llama.cpp win-openvino 包可用性未核实。
16. babelscribe 离线复用 `--bin` + `BABELSCRIBE_MODELS` 是否完整可行、Windows 是否需 VC++ 运行库，均未核实。

**E. 目标机首验清单（验收，按序做，结果回填本文件）**
1. `vulkaninfo`（Vulkan SDK 自带）或 GPU-Z 确认 A770 驱动与 Vulkan 版本可用。
2. `.\tools\windows\whisper-cli.exe -h` → 记录参数表；确认 `-l`、`-of`、`--vad`、`-vm`、`-sns`、`-osrt`。
3. 用 30 秒日语样片跑 §3.2，贴日志：确认 Vulkan 设备行；记录耗时（RTF）、显存峰值。
4. `.\tools\windows\llama-server.exe --help` → 确认 `-ngl`、`-c`、`--host`、`--port`；启动后用 §3.5 curl 跑通一句，记录 TTFT/速度/显存。
5. 跑 1 个 5–10 分钟完整视频，产出 `ja.srt`/`zh.srt` 并人工抽查 5 句。
6. 记录：A770 驱动版本、whisper.cpp 社区包版本、llama.cpp release 号、实测 RTF 与显存峰值 → 写入 `docs/04-排错手册.md` 与 `docs/02-工作流与参数.md`。

---

## 五、参考资料（附抓取日期 2026-11-15）

| 用途 | 链接 | 抓取/核实状态 |
|---|---|---|
| whisper.cpp 官方仓库（Vulkan 编译、VAD 参数、16-bit WAV 限制） | https://github.com/ggml-org/whisper.cpp | 【已核实】README 本轮抓取 |
| whisper.cpp v1.9.5 Release（Windows 资产无 Vulkan） | https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.5 | 【已核实】Lead 抓 api.github.com |
| Windows Vulkan 社区包 jerryshell | https://github.com/jerryshell/whisper.cpp-windows-vulkan-bin | 【已核实】README + repo API + release API |
| jerryshell release v1.0.0（资产 `whisper.cpp-windows-vulkan.zip`） | https://github.com/jerryshell/whisper.cpp-windows-vulkan-bin/releases/tag/v1.0.0 | 【已核实】2025-08-21 发布，资产 18,340,920 B |
| Silero VAD ggml 模型 | https://huggingface.co/ggml-org/whisper-vad | 【已核实】whisper.cpp README 指到此处 |
| llama.cpp 仓库 / Release b12405 | https://github.com/ggml-org/llama.cpp ； https://github.com/ggml-org/llama.cpp/releases/tag/b12405 | 【已核实资产名】Lead 抓取 |
| SakuraLLM README（prompt 模板 + 解码参数表） | https://github.com/SakuraLLM/SakuraLLM/blob/main/README.md | 【已核实】本轮抓取 |
| Sakura GGUF 模型卡 | https://huggingface.co/SakuraLLM/Sakura-7B-Qwen2.5-v1.0-GGUF ； https://huggingface.co/SakuraLLM/Sakura-8B-Qwen3-v1.1-SFT-GGUF | 【已核实存在与文件大小】本地 HF API 元数据（2026-11-15） |
| babelscribe（MIT，Vulkan whisper.cpp，CLI） | https://github.com/phonology024/babelscribe | 【已核实】README 本轮抓取 |
| Transub（排除） | https://github.com/dlsandy/Transub | 【已核实】Lead 抓取 README/CHANGELOG/Releases |
| VoiceTransl（排除/GUI） | https://github.com/shinnpuru/VoiceTransl | 【部分已核实】Lead 抓取 README |
| ffmpeg Windows 静态包 | https://www.gyan.dev/ffmpeg/builds/ ； https://github.com/BtbN/FFmpeg-Builds/releases | **【未核实】**（未抓取） |
| faster-whisper（CPU 退路） | https://github.com/SYSTRAN/faster-whisper | 【未核实】官方文档未抓；CUDA-only 结论来自第三方对比表 |
| OpenVINO GenAI / optimum-intel（备选） | https://github.com/openvinotoolkit/openvino.genai ； https://github.com/huggingface/optimum-intel | **【未核实】**（未抓取） |
| kotoba-whisper（日语专优，备选） | https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0 | **【未核实】**（未抓取） |
| Subtitle Edit + whisper.cpp 集成路径 | https://www.nikse.dk/subtitleedit （jerryshell README 给出 `%appdata%\Subtitle Edit\Whisper\Cpp` 放置法） | 【部分已核实】 |

## 六、本轮抓取记录（8 次外部请求，均为 2026-11-15）

1. `web_search` 一次（4 个查询合并：Transub / VoiceTransl / babelscribe / whisper.cpp Vulkan）—— 仅用于定位仓库，结论均已用 GitHub 一手数据复核。
2–5. `raw.githubusercontent.com`：jerryshell README（首次 404，改用 master）、SakuraLLM README（HTTP 200，19,411 B）、babelscribe README（HTTP 200，20,062 B）、ggml-org/whisper.cpp README（HTTP 200，41,037 B）。
6. `api.github.com/repos/jerryshell/whisper.cpp-windows-vulkan-bin`（仓库元数据：license=null、default_branch=master）。
7. `raw.githubusercontent.com/.../whisper.cpp-windows-vulkan-bin/master/README.md`（1421 B）。
8. `api.github.com/repos/jerryshell/whisper.cpp-windows-vulkan-bin/releases/latest`（v1.0.0 资产名/大小/时间）。

所有请求经 `curl -x socks5h://127.0.0.1:1080`；GitHub 直连超时（未尝试直连）。
