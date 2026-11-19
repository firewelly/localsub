# 03 · 模型与工具清单

> 适用目标机：Windows 11 + Intel Arc A770 16GB，无 NVIDIA CUDA
> 文档版本：2026-11-16（**本机实机就位并逐文件校验**）

---

## 0. 总览（2026-11-16 瘦身定版）

> 最终 pipeline 只保留 3 个模型文件；turbo / turbo-q8 / Sakura 已永久删除（来源与 sha256 见 `models/MANIFEST.md`；旧模型未随仓库发布）。
> 本文 §1.2 及以后仍保留 turbo/Sakura 的历史参数记录，仅作对照参考，相关文件已不存在。

| 类别 | 文件 | 大小 | 状态 |
|---|---|---|---|
| 听写模型 | `ggml-large-v3.bin` | 2.88 GB | ✅ 校验通过（最终听写） |
| VAD 模型 | `ggml-silero-v5.1.2.bin` | 0.9 MB | ✅ 校验通过 |
| 翻译模型 | `HY-MT2-7B-Q8_0.gguf` | 7.43 GB | ✅ 校验通过（最终翻译） |
| 工具 | ffmpeg / whisper-cli / llama-server | ≈0.5 GB | ✅ 已实装 |
---

## 1. 听写模型（whisper.cpp ggml）

### 1.1 Whisper large-v3（方案A 主力）

| 属性 | 值 |
|------|---|
| 文件 | `models/whisper/ggml-large-v3.bin` |
| 大小 | 3,095,033,483 B（2.88GB） |
| sha256 | `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2` |
| 来源 | HuggingFace `ggerganov/whisper.cpp` |
| 许可证 | MIT |
| 用途 | 日语听写主模型（质量优先） |

### 1.2 large-v3-turbo（加速对照）

| 属性 | 值 |
|------|---|
| 文件 | `models/whisper/ggml-large-v3-turbo.bin` |
| 大小 | 1.62 GB |
| sha256 | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` |
| 用途 | 速度对照（质量略降） |

### 1.3 large-v3-turbo-q8_0（方案B 主力）

| 属性 | 值 |
|------|---|
| 文件 | `models/whisper/ggml-large-v3-turbo-q8_0.bin` |
| 大小 | 834 MB |
| sha256 | `317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1` |
| 用途 | 方案B 转录（q8 近无损，速度优先） |

### 1.4 Silero VAD

| 属性 | 值 |
|------|---|
| 文件 | `models/whisper/ggml-silero-v5.1.2.bin` |
| 大小 | 885,098 B（0.9MB） |
| sha256 | `29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf` |
| 来源 | HuggingFace `ggerganov/whisper.cpp` |
| 许可证 | MIT（GitHub `snakers4/silero-vad` 为 Apache-2.0） |
| 用途 | 语音活动检测（`--vad -vm`，减少幻觉/静音段） |

[来源:已核实] 全部文件已在本机 `00-check-env.ps1` 中识别；sha256 与 `models/CHECKSUMS.sha256` 一致（2026-11-16 逐文件复验）。

---

## 2. 翻译模型（llama.cpp GGUF）

### 2.1 Sakura-Galtransl-7B-v3.7（方案A）

| 属性 | 值 |
|------|---|
| 文件 | `models/translation/Sakura-Galtransl-7B-v3.7.gguf` |
| 大小 | 6,254,196,608 B（6.25GB，Q6_K） |
| sha256 | `e1ae01b1735cfdcd00a3c7e2e5e06ff3a2756cc0d7592f4b4f5945638a8629f2` |
| 来源 | HuggingFace `SakuraLLM/Sakura-GalTransl-7B-v3.7` |
| 用途 | 日译中专训（自然、幻觉少） |

### 2.2 Hy-MT2-7B-Q8_0（方案B）

| 属性 | 值 |
|------|---|
| 文件 | `models/translation/HY-MT2-7B-Q8_0.gguf` |
| 大小 | 7,981,928,896 B（7.98GB） |
| sha256 | `58b3ad55dd6f6fa08c695cddc34fb5f8f708a844f78ae10508071914b0ed67c0` |
| 来源 | HuggingFace `tencent/Hy-MT2-7B-GGUF`（腾讯官方） |
| 用途 | 日译中专用 MT（macOS 实测无拒答；目标机待 A/B） |

> 方案A/B 切换 = 改 `config/pipeline.json` 的 `models.translation` 指向对应文件；两模型共享同一 llama-server 启动方式。
> 许可证以各自仓库为准（Sakura/Hy-MT2 默认仅个人非商用），详见 `models/MANIFEST.md`。

---

## 3. 工具（2026-11-16 实装）

### 3.1 ffmpeg

| 属性 | 值 |
|------|---|
| 文件 | `tools/windows/ffmpeg/ffmpeg.exe`、`ffprobe.exe` |
| 版本 | BtbN `ffmpeg-master-latest-win64-gpl`（`N-128915-g3d16b774d7-20261115`） |
| 大小 | 324 MB（两个 exe） |
| 来源 | <https://github.com/BtbN/FFmpeg-Builds/releases> |
| 用途 | 抽 16kHz 单声道 WAV；（可选）烧录字幕 |

### 3.2 whisper.cpp Vulkan

| 属性 | 值 |
|------|---|
| 文件 | `tools/windows/whisper/whisper-cli.exe`（含同目录 DLL） |
| 版本 | 社区构建 `jerryshell/whisper.cpp-windows-vulkan-bin` v1.0.0（2025-08-21） |
| 大小 | 17.5 MB |
| 来源 | <https://github.com/jerryshell/whisper.cpp-windows-vulkan-bin/releases/tag/v1.0.0> |
| 用途 | 日语听写（Vulkan 后端） |

**实机验证**：`--help` 顶部枚举到 2 个 Vulkan 设备；`-dev 1` 时日志为 `using Vulkan1 backend`（Intel Arc A770）。

> 官方 whisper.cpp Release（v1.9.5）仍无 Windows Vulkan 预编译；社区包比官方旧，若遇问题可自编译（`-DGGML_VULKAN=ON`）。

### 3.3 llama.cpp Vulkan

| 属性 | 值 |
|------|---|
| 文件 | `tools/windows/llama/llama-server.exe`（exe 桩 + `-impl.dll`，同目录 DLL 全部保留） |
| 版本 | 官方 **b12428**（2026-11-16 抓取） |
| 大小 | 36.5 MB（zip） |
| 来源 | <https://github.com/ggml-org/llama.cpp/releases/tag/b12428> |
| 用途 | 加载 Sakura/Hy-MT2 GGUF，提供 OpenAI 兼容 `/v1/chat/completions` |

**实机验证**：`--list-devices` 显示 `Vulkan1: Intel(R) Arc(TM) A770 Graphics (16242 MiB)`；`-dev Vulkan1` 加载 Sakura 后 `/health` 就绪、单句翻译成功（"おはようございます…" → "早安，今天天气真好呢。"）。

### 3.4 Vulkan 设备选择（重要）

本机枚举顺序：**0 = AMD Radeon 780M（核显），1 = Intel Arc A770**。两个引擎默认都用 device 0。

- whisper：`config/pipeline.json` → `whisper.extra_args = ["-dev","1"]`
- llama：`config/pipeline.json` → `llama.extra_args = ["-dev","Vulkan1"]`

换机器/更新驱动后先核对：

```powershell
& .\tools\windows\whisper\whisper-cli.exe --help 2>&1 | Select-Object -First 4
& .\tools\windows\llama\llama-server.exe --list-devices
```

---

## 4. 目录结构（实际）

```
tools/windows/
├─ ffmpeg/  ffmpeg.exe, ffprobe.exe
├─ whisper/ whisper-cli.exe + DLL
└─ llama/   llama-server.exe + DLL

models/
├─ whisper/     ggml-large-v3.bin / ggml-large-v3-turbo.bin /
│               ggml-large-v3-turbo-q8_0.bin / ggml-silero-v5.1.2.bin
└─ translation/ Sakura-Galtransl-7B-v3.7.gguf / HY-MT2-7B-Q8_0.gguf
```

---

## 5. 离线就绪检查

| 项目 | 路径 | 状态 |
|------|------|------|
| ffmpeg | `tools/windows/ffmpeg/ffmpeg.exe` | ✅ |
| whisper.cpp | `tools/windows/whisper/whisper-cli.exe` | ✅ |
| llama.cpp | `tools/windows/llama/llama-server.exe` | ✅ |
| Whisper 模型 | `models/whisper/ggml-large-v3.bin` | ✅ |
| VAD 模型 | `models/whisper/ggml-silero-v5.1.2.bin` | ✅ |
| 翻译模型（A） | `models/translation/Sakura-Galtransl-7B-v3.7.gguf` | ✅ |
| 翻译模型（B） | `models/translation/HY-MT2-7B-Q8_0.gguf` | ✅ |

**结论：听写 + 翻译全链路可离线运行**（真实视频整片质量/耗时待首跑回填）。

---

## 6. 校验命令

```powershell
# 在项目根下逐个校验（Windows PowerShell / pwsh 均可）
Get-Content .\models\CHECKSUMS.sha256 |
  Where-Object { $_ -match '^\s*[0-9a-f]{64}\s' } |
  ForEach-Object {
    $h, $rel = $_ -split '\s+', 2
    $file = Join-Path '.\models' $rel.Trim()
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
    if ($actual -eq $h) { Write-Host "PASS $rel" -ForegroundColor Green }
    else { Write-Host "FAIL $rel" -ForegroundColor Red }
  }
```

---

## 7. 许可证摘要

| 组件 | 许可证 | 说明 |
|------|--------|------|
| Whisper ggml 模型 | MIT | OpenAI Whisper + ggml 转换 |
| Silero VAD | Apache-2.0 | silero-vad |
| Sakura-Galtransl | 见仓库 | 默认仅个人非商用 |
| Hy-MT2 | 见仓库 | 腾讯官方发布，使用前核对条款 |
| ffmpeg | LGPL/GPL | 取决于 BtbN gpl 构建 |
| whisper.cpp / llama.cpp | MIT | — |

---

## 参考资料

- Whisper ggml：<https://huggingface.co/ggerganov/whisper.cpp>
- Sakura-GalTransl：<https://huggingface.co/SakuraLLM/Sakura-GalTransl-7B-v3.7>
- Hy-MT2：<https://huggingface.co/tencent/Hy-MT2-7B-GGUF>
- whisper.cpp Vulkan 社区构建：<https://github.com/jerryshell/whisper.cpp-windows-vulkan-bin>
- llama.cpp Releases：<https://github.com/ggml-org/llama.cpp/releases>
- ffmpeg：<https://github.com/BtbN/FFmpeg-Builds/releases>
