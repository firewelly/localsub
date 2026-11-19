# 01 · Windows 部署手册

> 适用目标机：Windows 11 + Intel Arc A770 16GB + Ryzen 7 7840H + 32GB RAM，**无 NVIDIA CUDA**
> 文档版本：2026-11-16｜**本机已按本文完成部署并实机验证**（环境自检、Vulkan 设备选择、单句翻译）；整片听写/翻译耗时与显存峰值仍未实测

---

## 0. 前置条件

### 0.1 系统要求

| 项目 | 要求 | 说明 |
|------|------|------|
| 操作系统 | Windows 11 22H2+ | 确保系统更新到最新版本 |
| 显卡 | Intel Arc A770 16GB | **已安装最新驱动**（见 §0.2） |
| 内存 | 32GB | 听写 + 翻译串行运行时，系统内存建议 ≥16GB 可用 |
| 磁盘 | 20GB+ 可用空间 | 模型 ≈10GB + 工具 ≈1GB + work/output 临时空间 |
| Python | 3.9+（可选） | 仅 babelscribe 路线需要 |

### 0.2 显卡驱动安装

**必须步骤**：确保 Intel Arc A770 驱动为最新版本。

1. 访问 [Intel Arc 显卡驱动下载页](https://www.intel.com/content/www/us/en/download-center/home.html)
2. 选择「Intel® Arc™ A-Series Graphics」
3. 下载并安装最新版驱动
4. 重启后确认：任务管理器 → 性能 → GPU，能看到「Intel Arc A770」

[来源:Intel 官方] Vulkan 后端依赖新驱动，旧版本可能导致 Vulkan 初始化失败。

### 0.3 本项目目录

**本项目已整体位于本机本地磁盘的工作目录**（不再以移动硬盘为工作盘；移动硬盘仅作冷备份，其 NTFS 有掉文件历史）。

**约定**：所有命令都在项目根目录执行，**只使用相对路径**。整个目录可搬到任意盘符/机器，脚本无需修改。

```powershell
# 打开 PowerShell，进入项目根目录（示例）
cd <项目根>
# 后续命令均在项目根下执行
```

---

## 1. 工具安装（三选一路线）

> **推荐路线 A**：whisper.cpp Vulkan + llama.cpp Vulkan，纯 CLI、可批处理、离线可用。  
> **备选路线 B**：llama.cpp SYCL，需额外安装 Intel oneAPI runtime。  
> **轻量路线 C**：babelscribe，仅日语听写，自动下载 Vulkan 版 whisper.cpp。

---

### 路线 A：whisper.cpp Vulkan + llama.cpp Vulkan（推荐）

#### 1.1 下载 whisper.cpp Vulkan 包

1. 访问社区包发布页：[jerryshell/whisper.cpp-windows-vulkan-bin v1.0.0](https://github.com/jerryshell/whisper.cpp-windows-vulkan-bin/releases/tag/v1.0.0)
2. 下载 `whisper.cpp-windows-vulkan.zip`（17.5MB）
3. 解压到 `.\tools\windows\whisper\` 目录（**所有 exe 与 DLL 一起保留**）

[来源:已核实] Release v1.0.0（发布于 2025-08-21），资产大小 18,340,920 B。exe 名为 `whisper-cli.exe`；本机已实装并验证。

**验证**：

```powershell
Test-Path .\tools\windows\whisper\whisper-cli.exe
# 应返回 True
```

#### 1.2 下载 llama.cpp Vulkan 包

1. 访问官方发布页：[llama.cpp Release b12428](https://github.com/ggml-org/llama.cpp/releases/tag/b12428)
2. 下载 `llama-b12428-bin-win-vulkan-x64.zip`（36.5MB）
3. 解压到 `.\tools\windows\llama\` 目录（**exe 与全部 DLL 一起保留**，新版本是 exe 桩 + `-impl.dll` 结构）

[来源:已核实] Release b12428（2026-11-16 抓取），包含 `llama-server.exe` 和 `llama-cli.exe`。本机已实装并成功加载 Sakura 模型。

**验证**：

```powershell
Test-Path .\tools\windows\llama\llama-server.exe
# 应返回 True
```

#### 1.3 下载 ffmpeg

1. 访问 [BtbN FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds/releases)（或 [gyan.dev](https://www.gyan.dev/ffmpeg/builds/)）
2. 下载 `ffmpeg-master-latest-win64-gpl.zip`（约 193MB）
3. 解压后将 `bin\ffmpeg.exe`、`bin\ffprobe.exe` 复制到 `.\tools\windows\ffmpeg\`

[来源:已核实] 本机实装 BtbN 2026-11-15 构建（`ffmpeg version N-128915`），已实跑 `-version` 与抽音频。

**验证**：

```powershell
.\tools\windows\ffmpeg\ffmpeg.exe -version
# 应显示版本信息
```

#### 1.4 环境变量

**无需设置**。脚本使用相对路径，直接在项目根下执行即可。

#### 1.5 Vulkan 设备选择（重要，2026-11-16 实机发现）

本机 Vulkan 枚举顺序为：

```
0 = AMD Radeon 780M Graphics（核显，共享内存）
1 = Intel(R) Arc(TM) A770 Graphics（独显，16GB）
```

whisper-cli 与 llama-server 默认都用 device 0，**会落到 AMD 核显**。项目已在 `config/pipeline.json` 固定：

```json
"whisper": { "extra_args": ["-dev", "1"] },
"llama":   { "extra_args": ["-dev", "Vulkan1"] }
```

**核对命令**：

```powershell
& .\tools\windows\whisper\whisper-cli.exe --help 2>&1 | Select-Object -First 4
& .\tools\windows\llama\llama-server.exe --list-devices
```

换机器/更新驱动后若顺序变化，按上面输出改 `extra_args` 的索引/设备名。whisper 实跑日志应出现 `using Vulkan1 backend`。

---

### 路线 B：llama.cpp SYCL（备选）

> **风险提示**：SYCL 版需要 Intel oneAPI runtime，若缺失 DLL 会启动失败。建议优先尝试路线 A（Vulkan）。

#### 1.1 下载 llama.cpp SYCL 包

1. 访问 [llama.cpp Release b12428](https://github.com/ggml-org/llama.cpp/releases/tag/b12428)
2. 下载 `llama-b12428-bin-win-sycl-x64.zip`（约 164MB）
3. 解压到 `.\tools\windows\`

[来源:已核实] 资产名与大小已核实；但 SYCL runtime 是否随包自带【未核实】。

#### 1.2 安装 Intel oneAPI runtime

若 llama-server 启动时报 DLL 缺失错误，需安装：

1. 访问 [Intel oneAPI Base Toolkit](https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html)
2. 下载并安装 Base Toolkit（选择「Runtime only」即可）
3. 重启后重试

[来源:推断,需实机验证] SYCL 依赖 `sycl*.dll`、`ur_*.dll` 等，具体缺失哪些需看报错信息。

---

### 路线 C：babelscribe 轻量路径（仅听写）

> **适用场景**：只需日语听写，不需要翻译；希望用一条命令快速出 SRT。

#### 1.1 安装 Python 3.9+

从 [python.org](https://www.python.org/downloads/) 下载安装。

#### 1.2 安装 babelscribe

```powershell
py -3 -m pip install babelscribe
```

[来源:已核实] babelscribe v0.4.0，MIT 许可证，README 明确支持 Intel GPU（Vulkan 后端）。

#### 1.3 运行命令

```powershell
# 基本用法（首次运行会自动下载 Vulkan 版 whisper.cpp）
babelscribe .\input\xxx.mp4 -l ja -f srt
# 输出 xxx.srt（与视频同目录）
```

[来源:已核实] README 文档明确参数：`-l ja`、`-f srt`、`-m large-v3`（模型可选）。

**注意**：
- 首次运行会联网下载 Vulkan 版 `whisper-cli` 和模型，缓存到 `~/.babelscribe`
- **离线复用**：可用 `--bin .\tools\windows\whisper-cli.exe` 指定自有构建，用 `BABELSCRIBE_MODELS` 指向 `.\models\whisper`，但该组合是否完整支持【未核实】
- Windows 可能需要 VC++ 运行库【未核实】

---

## 2. 模型放置

### 2.1 检查模型文件

模型应已预下载到 `models/` 目录：

```powershell
# 检查模型文件（2026-11-16 实机已全部就位）
Test-Path .\models\whisper\ggml-large-v3.bin
Test-Path .\models\whisper\ggml-silero-v5.1.2.bin
Test-Path .\models\translation\Sakura-Galtransl-7B-v3.7.gguf
# 方案B：
Test-Path .\models\translation\HY-MT2-7B-Q8_0.gguf
```

[来源:已核实] 模型文件清单与大小见 `models/MANIFEST.md`。

### 2.2 运行 SHA256 校验（PowerShell）

```powershell
# 校验 Whisper large-v3
$hash = Get-FileHash .\models\whisper\ggml-large-v3.bin -Algorithm SHA256
$hash.Hash
# 与 models/CHECKSUMS.sha256 中的值比对
```

完整校验脚本见 `models/README.md`。

---

## 3. 首次自检

执行环境检查脚本，确认工具与模型就绪：

```powershell
.\scripts\windows\00-check-env.ps1
```

### 3.1 预期输出

```
[INFO] 检查环境...
[PASS] ffmpeg: .\tools\windows\ffmpeg\ffmpeg.exe
[PASS] whisper-cli: .\tools\windows\whisper\whisper-cli.exe
[PASS] llama-server: .\tools\windows\llama\llama-server.exe
[PASS] Whisper 模型: ggml-large-v3.bin
[PASS] VAD 模型: ggml-silero-v5.1.2.bin
[PASS] 翻译模型: Sakura-Galtransl-7B-v3.7.gguf
[INFO] 显卡: Intel(R) Arc(TM) A770 Graphics (16GB)

全部检查通过！
```

> 2026-11-16 本机实跑为 **14 PASS / 0 FAIL**（仅「输入目录为空」「端口状态」两条警告）。

### 3.2 失败怎么办

| 检查项 | 失败原因 | 修复方案 |
|--------|---------|---------|
| ffmpeg | 文件不存在 | 按 §1.1 下载并放到 `tools\windows\` |
| whisper-cli | 文件不存在 | 按 §1.1 下载社区 Vulkan 包 |
| llama-server | 文件不存在 | 按 §1.2 下载 llama.cpp Vulkan 包 |
| 模型文件 | 未下载或路径错误 | 检查 `models/MANIFEST.md` 并重新下载 |

---

## 4. 单文件试跑

### 4.1 准备测试视频

将一个短日语视频（建议 1–5 分钟）放入 `input/` 目录：

```powershell
# 示例：假设视频名为 test.mp4
Test-Path .\input\test.mp4
# 应返回 True
```

### 4.2 完整流程命令

**第一步：抽取音频**

```powershell
.\tools\windows\ffmpeg\ffmpeg.exe -hide_banner -i ".\input\test.mp4" -vn -loglevel error -ar 16000 -ac 1 -c:a pcm_s16le -y ".\work\test.wav"
```

[来源:已核实] 参数与 jerryshell README 示例一致，whisper.cpp 只接受 16-bit WAV。

**第二步：日语听写 → ja.srt**

```powershell
.\tools\windows\whisper\whisper-cli.exe `
  -m .\models\whisper\ggml-large-v3.bin `
  -f .\work\test.wav `
  -l ja `
  -dev 1 `
  --vad -vm .\models\whisper\ggml-silero-v5.1.2.bin `
  -sns `
  -osrt `
  -of .\output\test\ja
```

[来源:已核实] 本机实跑确认 `--vad`、`-vm`、`-sns`、`-osrt`、`-of`、`-dev` 均受支持；`-dev 1` 指定 Arc。

**第三步：启动 llama-server**

```powershell
# 新开一个 PowerShell 窗口
.\tools\windows\llama\llama-server.exe `
  -m .\models\translation\Sakura-Galtransl-7B-v3.7.gguf `
  -dev Vulkan1 `
  --host 127.0.0.1 --port 8080 `
  -ngl 99 `
  -c 4096
```

[来源:已核实] 本机实测：`-dev Vulkan1` 将模型加载到 Arc A770；模型加载约 18 秒，`/health` 可用。

等待看到类似输出：

```
llama server listening at http://127.0.0.1:8080
```

**第四步：翻译 → zh.srt**

```powershell
# 回到原 PowerShell 窗口
.\scripts\windows\02-translate.ps1 -InputDir .\output\test -ServerUrl http://127.0.0.1:8080
```

**第五步：合并双语 + 质检**

```powershell
.\scripts\windows\03-bilingual.ps1 -InputDir .\output\test
```

### 4.3 验证产出

检查输出目录：

```powershell
Get-ChildItem .\output\test
# 应看到：ja.srt, zh.srt, bilingual.srt, report.json
```

打开 `bilingual.srt`，确认：
- 日中双语对齐
- 时间轴准确
- 无乱码（UTF-8 编码）

---

## 5. 批量跑

将所有待处理视频放入 `input/` 目录，然后执行：

```powershell
.\scripts\windows\run-all.ps1 -InputDir .\input
```

脚本会自动完成：
1. 抽取音频
2. 日语听写
3. 日译中翻译
4. 合并双语 + 质检
5. 产出汇总日志

**参数调整**：编辑 `config/pipeline.json` 修改模型、并发数、CPS 阈值等。

---

## 6. 验收清单

### 6.1 确认 GPU 使用

**方法一：日志关键字**

```powershell
# 检查 whisper 日志
Select-String -Path .\logs\whisper-*.log -Pattern "Vulkan|ggml_vulkan|backend|device"
```

预期出现：
- `ggml_vulkan: Found N Vulkan devices`
- `ggml_vulkan: 0 = Intel(R) Arc(TM) A770 Graphics`
- `register_backend: registered backend Vulkan`

[来源:推断,需实机验证] 关键字取自 ggml Vulkan 后端通用日志惯例，实机以真实日志为准。

**方法二：任务管理器**

1. 打开任务管理器 → 性能 → GPU
2. 选择「Intel Arc A770」
3. 听写/翻译期间，观察「3D」或「Dedicated GPU memory」有明显占用

**方法三：GPU-Z**

使用 GPU-Z 工具观察显存占用与 GPU 负载。

### 6.2 预期耗时区间

| 视频时长 | 预期听写耗时 | 预期翻译耗时 | 说明 |
|---------|------------|------------|------|
| 5 分钟 | 待实测填空 | 待实测填空 | RTF（Real-Time Factor）需实机测量 |
| 30 分钟 | 待实测填空 | 待实测填空 |  |
| 1 小时 | 待实测填空 | 待实测填空 |  |

[来源:未实机验证] 准备机为 macOS，无法实测 Windows + Arc 性能。首跑后请回填实测数据。

### 6.3 显存占用

| 阶段 | 显存估算 | 说明 |
|------|---------|------|
| Whisper large-v3 | ≈3.1GB | 模型加载 + 计算缓冲 |
| Sakura 7B Q6K | ≈6.3GB | 模型加载 + KV cache |
| **并发警告** | 峰值 10–13GB | 建议串行运行（先听写后翻译），避免 OOM |

[来源:推断,需实机验证] 基于 GGUF 文件大小估算，实机显存峰值以任务管理器为准。

---

## 7. 卸载/清理

### 7.1 清理临时文件

```powershell
# 删除 work/ 下的临时 WAV 文件
Remove-Item .\work\*.wav -Force

# 删除日志（可选）
Remove-Item .\logs\*.log -Force
```

### 7.2 卸载工具

删除 `tools/windows/` 目录即可：

```powershell
Remove-Item .\tools\windows\* -Recurse -Force
```

### 7.3 卸载模型

删除 `models/` 目录即可（约 10GB）：

```powershell
Remove-Item .\models\* -Recurse -Force
```

---

## 附录：故障排查

如遇问题，请查阅 [04-排错手册.md](04-排错手册.md)。

---

**来源汇总**：
- whisper.cpp Vulkan 社区包：[jerryshell/whisper.cpp-windows-vulkan-bin v1.0.0](https://github.com/jerryshell/whisper.cpp-windows-vulkan-bin/releases/tag/v1.0.0) [已核实]
- llama.cpp Release b12428：[官方发布页](https://github.com/ggml-org/llama.cpp/releases/tag/b12428) [已核实]
- Sakura 翻译参数：[SakuraLLM README](https://github.com/SakuraLLM/SakuraLLM/blob/main/README.md) [已核实]
- babelscribe：[phonology024/babelscribe](https://github.com/phonology024/babelscribe) [已核实]
- ffmpeg 抽音频命令：jerryshell README 示例 [已核实]
- 其他参数：标注为 [推断,需实机验证]