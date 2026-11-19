# tools/ 工具与二进制放置约定

> 目标机 **Windows 11 + Intel Arc A770 16GB，无 NVIDIA CUDA**。本目录用于放置第三方命令行工具
> （ffmpeg / whisper.cpp / llama.cpp）。**本仓库不包含这些二进制**，需要用户自行下载后按下面约定放入。
>
> 工具路径全部写在 `config/pipeline.json` 的 `tools` 段（相对项目根），缺失时脚本会给出中文错误与修复提示，
> 不会静默继续。可用 `.\scripts\windows\download-tools.ps1` 查看下载地址与步骤。
>
> **状态（2026-11-16）：三个工具已实装到本机 `tools/windows/` 并通过 `00-check-env.ps1` 与实跑验证；
> 注意 Vulkan 设备 0 是 AMD 核显、1 是 Arc A770，配置里已用 `-dev 1` / `-dev Vulkan1` 指定 Arc。**

## 目录约定

```
tools/
└─ windows/
   ├─ ffmpeg/
   │  ├─ ffmpeg.exe          # 必需
   │  └─ ffprobe.exe         # 可选（本项目当前未强制使用）
   ├─ whisper/
   │  ├─ whisper-cli.exe     # 必需（若社区构建文件名是 main.exe，可在配置里改路径）
   │  └─ *.dll               # 该构建自带的 DLL 全部保留
   └─ llama/
      ├─ llama-server.exe    # 必需
      └─ *.dll               # 该构建自带的 DLL 全部保留（Vulkan/SYCL 运行时）
```

## 需要的二进制清单

| 工具 | 配置键（默认值） | 版本/来源建议 | 用途 |
|---|---|---|---|
| ffmpeg | `tools.ffmpeg` = `tools/windows/ffmpeg/ffmpeg.exe` | gyan.dev 或 BtbN 的 Windows 静态包（x64） | 抽 16kHz 单声道 WAV；（可选）硬字幕烧录 |
| whisper-cli | `tools.whisper_cli` = `tools/windows/whisper/whisper-cli.exe` | whisper.cpp Windows 构建；**官方预编译只有 CPU 版，Vulkan 需社区构建或自编译** | 日语听写 → `ja.srt` |
| llama-server | `tools.llama_server` = `tools/windows/llama/llama-server.exe` | llama.cpp 官方 Windows 预编译，**Vulkan 版**（本机实装 b12428，`llama-b12428-bin-win-vulkan-x64.zip`，36.5MB）或 SYCL/OpenVINO 版 | 加载 Sakura/Hy-MT2 GGUF，提供 OpenAI 兼容 `/v1/chat/completions` |
| Python | `tools.python` = `python`（也可填相对路径或 `py`） | Python **3.11 / 3.12** 64 位（本项目兼容 3.8+，但目标机建议 3.11/3.12）；安装时勾选 **Add python.exe to PATH** | 运行 `scripts/python` 下的流水线逻辑 |

模型不在本目录：Whisper/VAD/翻译 GGUF 放 `models/`（见 `models/README.md`，随硬盘提前下载）。

## 下载渠道（摘自官方页面，未在目标机实机验证）

- **ffmpeg**：<https://www.gyan.dev/ffmpeg/builds/> 或 <https://github.com/BtbN/FFmpeg-Builds/releases>
  → 解压后把 `bin/ffmpeg.exe`（和可选的 `ffprobe.exe`）放到 `tools/windows/ffmpeg/`。
- **llama.cpp**：<https://github.com/ggml-org/llama.cpp/releases>
  → 选择 `llama-bXXXXX-bin-win-vulkan-x64.zip`（Arc 走 Vulkan；SYCL 版需 Intel oneAPI 运行库，属备选）
  → **整个 zip 解压到 `tools/windows/llama/`**（`llama-server.exe` 依赖同目录 DLL）。
- **whisper.cpp**：<https://github.com/ggml-org/whisper.cpp/releases> + 编译说明
  <https://github.com/ggml-org/whisper.cpp/blob/master/docs/build.md>
  - 官方 Windows 预编译**只有 CPU 版**（无 CUDA 也可用，慢）；
  - Vulkan 路径：社区 Vulkan 构建（需自行核实可用性/许可证）或按官方文档自编译
    （例如 `cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release`）。
- **Python**：<https://www.python.org/downloads/windows/>（离线机器请先下载安装包再拷贝）
- **模型**：HuggingFace（国内可试 <https://hf-mirror.com/>），或直接用准备机预下载好的 `models/`。

> 代理/镜像说明见 `.\scripts\windows\download-tools.ps1` 的输出：本地代理 `HTTP_PROXY/HTTPS_PROXY`、
> hf-mirror、GitHub 加速前缀（如 `https://gh-proxy.com/`）、或“下载好后放入本地目录”的离线方式。

## 放置后的自检

```powershell
# 在项目根下执行
.\scripts\windows\00-check-env.ps1
.\scripts\windows\download-tools.ps1 -CheckOnly
```

自检会实际执行 `ffmpeg -version`、`whisper-cli --help`、`llama-server --version` 等做冒烟检查，
并核对模型文件是否存在、显卡是否为 Intel Arc、llama 端口是否空闲、输出目录是否可写。

## 工具目录缺失时脚本如何报错

- `00-check-env.ps1`：对应项显示红色 `[FAIL]`，同时给出修复提示（应下载哪个包、放到哪个相对目录），
  最终**退出码 1**，并提示运行 `download-tools.ps1`。
- `01-transcribe.ps1`：启动前解析 ffmpeg / whisper-cli / 模型，缺失时打印中文错误并**退出码 2**，
  不会进入批处理。
- `02-translate.ps1`：启动 llama-server 前解析 llama-server 与翻译模型，缺失时打印中文错误并**退出码 2**；
  也可以 `-ServerUrl` 复用外部已启动的服务（此时不需要 `tools/windows/llama`）。
- `03-bilingual.ps1` / `run-all.ps1`：只依赖 Python 与已生成的 `ja.srt`，工具缺失不影响这两步；
  `run-all.ps1` 会先跑 00 自检，自检不通过则中止（可用 `-SkipEnvCheck` 跳过，不推荐）。
- 路径支持通配符：如配置 `models/translation/*.gguf`，匹配多个时按文件名排序取第一个并打印警告；
  想固定选择请把配置改成精确文件名。

## 许可证与安全提示

- 各二进制（ffmpeg/whisper.cpp/llama.cpp）与模型（Whisper/Sakura/GalTransl）请在使用前自行核对其许可证
  与再分发条件；本仓库只提供放置约定与调用脚本，不内置也不重新分发这些文件。
- 不要把带可执行权限的工具提交进 Git；`tools/windows/**` 应保持在 `.gitignore` 中。
