# 02 · 工作流与参数

> 适用目标机：Windows 11 + Intel Arc A770 16GB，无 NVIDIA CUDA
> 文档版本：2026-11-15｜未实机验证（准备机为 macOS）

---

## 0. 全流程概览

```
视频文件 → ffmpeg 抽 16kHz 单声道 WAV
         → whisper.cpp Vulkan 日语听写 → ja.srt
         → llama-server + Sakura GGUF 日译中 → zh.srt
         → 合并双语 + 质检 → bilingual.srt + report.json
```

**产物位置**：`output/<视频名>/`

| 文件 | 内容 | 说明 |
|------|------|------|
| `ja.srt` | 日语原文 | 听写输出 |
| `zh.srt` | 中文译文 | 翻译输出 |
| `bilingual.srt` | 中日双语 | 合并输出 |
| `report.json` | 质检报告 | 字幕质量指标 |
| `translate-report.json` | 翻译报告 | 翻译统计（可选） |

---

## 1. 环节一：音频抽取

**工具**：ffmpeg
**输入**：视频文件（任意格式）
**输出**：`work/<basename>/<basename>.wav`

### 1.1 命令

```powershell
.\tools\windows\ffmpeg.exe -i .\input\video.mp4 `
    -vn -ac 1 -ar 16000 -c:a pcm_s16le `
    .\work\video\video.wav
```

### 1.2 参数说明

| 参数 | 含义 | 来源 |
|------|------|------|
| `-i` | 输入文件 | [ffmpeg 官方文档] |
| `-vn` | 忽略视频流 | [ffmpeg 官方文档] |
| `-ac 1` | 单声道 | [whisper.cpp 推荐] |
| `-ar 16000` | 16kHz 采样率 | [whisper.cpp 推荐] |
| `-c:a pcm_s16le` | 16-bit PCM WAV | [whisper.cpp 推荐] |

[来源:已核实] 参数来自 whisper.cpp 官方示例。

---

## 2. 环节二：日语听写

**工具**：whisper.cpp Vulkan（whisper-cli.exe）
**输入**：WAV 音频
**输出**：`output/<basename>/ja.srt`

### 2.1 命令

```powershell
.\tools\windows\whisper-cli.exe `
    -m .\models\whisper\ggml-large-v3.bin `
    -f .\work\video\video.wav `
    -l ja `
    --vad `
    -vm .\models\whisper\ggml-silero-v5.1.2.bin `
    -osrt `
    -of .\output\video\ja `
    -sns
```

### 2.2 参数说明

| 参数 | 含义 | 推荐值 | 来源 |
|------|------|--------|------|
| `-m` | 模型路径 | `ggml-large-v3.bin` | [已核实] |
| `-f` | 音频文件 | WAV 16kHz 单声道 | [已核实] |
| `-l` | 语言 | `ja`（日语） | [已核实] |
| `--vad` | 启用 VAD | 默认启用 | [whisper.cpp 文档] |
| `-vm` | VAD 模型 | `ggml-silero-v5.1.2.bin` | [已核实] |
| `-osrt` | 输出格式 | SRT | [whisper.cpp 文档] |
| `-of` | 输出前缀 | 无扩展名 | [whisper.cpp 文档] |
| `-sns` | 抑制非语音 | 推荐（减少幻觉） | [whisper.cpp 文档] |
| `-owts` | 词级时间戳 | 可选（调试用） | [whisper.cpp 文档] |

### 2.3 听写参数建议

| 参数 | 说明 |
|------|------|
| `--vad` | **必须启用**，显著减少静音段的幻觉 |
| `-sns` | **必须启用**，抑制非语音 token，减少重复句 |
| `-l ja` | 明确指定语言，避免自动检测出错 |

[来源:已核实] 参数来自 whisper.cpp 官方文档与社区实践。

### 2.4 GPU 加速验证

**预期日志关键字**：
```
ggml_vulkan: Found N Vulkan devices
ggml_vulkan: 0 = Intel(R) Arc(TM) A770 Graphics
```

**检查方法**：
```powershell
# 查看 whisper-cli 输出日志
Select-String -Path .\logs\whisper-*.log -Pattern "Vulkan"
```

如果看到 `CPU backend` 而非 `Vulkan`，说明未启用 GPU，见《04-排错手册》症状 #1。

---

## 3. 环节三：日译中翻译

**工具**：llama.cpp Vulkan/SYCL（llama-server.exe）+ Sakura GGUF
**输入**：`ja.srt`
**输出**：`zh.srt`

### 3.1 启动 llama-server

```powershell
# 方式一：脚本自动启动（推荐）
.\scripts\windows\02-translate.ps1 -InputDir .\output\video

# 方式二：手动启动 server
Start-Process -FilePath .\tools\windows\llama-server.exe `
    -ArgumentList @(
        '-m', '.\models\translation\Sakura-Galtransl-7B-v3.7.gguf',
        '--port', '8080',
        '--host', '127.0.0.1',
        '-ngl', '99',
        '-c', '4096'
    ) -NoNewWindow
```

### 3.2 llama-server 参数

| 参数 | 含义 | 推荐值 | 来源 |
|------|------|--------|------|
| `-m` | 模型路径 | Sakura 7B Q4_K_M | [已核实] |
| `--port` | 监听端口 | 8080 | [llama.cpp 文档] |
| `--host` | 监听地址 | 127.0.0.1 | [llama.cpp 文档] |
| `-ngl` | GPU 层数 | 99（全量卸载） | [llama.cpp 文档] |
| `-c` | 上下文长度 | 4096 | [Sakura 推荐] |

### 3.3 翻译采样参数

**Sakura 官方推荐**（来自 SakuraLLM README）：

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| `temperature` | 0.1 | 低温度，减少随机性 |
| `top_p` | 0.3 | 低 top_p，保证质量 |
| `repetition_penalty` | 1.0 | 无重复惩罚 |
| `max_tokens` | 512 | 单句最大长度 |

### 3.4 健康检查

```powershell
# 等待 server 启动（最多 60 秒）
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        Invoke-RestMethod -Uri http://127.0.0.1:8080/health -TimeoutSec 1 | Out-Null
        $ready = $true
        break
    } catch {
        Start-Sleep -Seconds 1
    }
}
if (-not $ready) { throw "llama-server 启动超时" }
```

[来源:已核实] 采样参数来自 SakuraLLM 官方 README。

---

## 4. 环节四：双语合并

**工具**：Python 脚本 `merge_srt.py`
**输入**：`ja.srt`、`zh.srt`
**输出**：`bilingual.srt`

### 4.1 排版模式

配置文件 `config/pipeline.json` 中的 `bilingual_layout` 字段：

| 值 | 排版方式 | 示例 |
|----|---------|------|
| `zh_top` | 中文在上，日文在下 | `1\n中文译文\n日文原文` |
| `ja_top` | 日文在上，中文在下 | `1\n日文原文\n中文译文` |
| `alternate` | 双行交替 | `1\n中文\n日文`（单条 SRT） |

**推荐**：`zh_top`（适合中文观众）

### 4.2 质量检查

| 检查项 | 阈值 | 说明 |
|--------|------|------|
| CPS（字/秒） | ≤25 | 阅读速度上限 |
| 最小时长 | ≥1s | 短字幕难以阅读 |
| 最大时长 | ≤7s | 长字幕需要拆分 |
| 条数一致性 | zh==ja | 严格模式检查 |
| 时间戳一致性 | 逐条对比 | 严格模式检查 |

---

## 5. 一键全流程

```powershell
# 基础用法
.\scripts\windows\run-all.ps1 -InputDir .\input

# 仅翻译（跳过听写）
.\scripts\windows\run-all.ps1 -InputDir .\input -SkipTranscribe

# Mock 模式（测试流程，不调用真实翻译）
.\scripts\windows\run-all.ps1 -InputDir .\input -Mock
```

### 5.1 参数说明

| 参数 | 说明 |
|------|------|
| `-InputDir` | 输入视频目录 |
| `-Mock` | 使用伪翻译（测试流程） |
| `-SkipTranscribe` | 跳过听写（已有 ja.srt） |

---

## 6. 配置文件

所有参数集中在 `config/pipeline.json`：

```json
{
  "version": "1.0",
  "audio": {
    "sample_rate": 16000,
    "channels": 1,
    "codec": "pcm_s16le"
  },
  "transcribe": {
    "model": "models/whisper/ggml-large-v3.bin",
    "language": "ja",
    "vad_model": "models/whisper/ggml-silero-v5.1.2.bin",
    "vad": true,
    "suppress_non_speech": true
  },
  "translate": {
    "model": "models/translation/Sakura-Galtransl-7B-v3.7.gguf",
    "base_url": "http://127.0.0.1:8080/v1",
    "temperature": 0.1,
    "top_p": 0.3,
    "repetition_penalty": 1.0,
    "max_tokens": 512,
    "context_lines": 3,
    "concurrency": 1,
    "timeout_seconds": 30,
    "max_retries": 3
  },
  "bilingual": {
    "layout": "zh_top",
    "strict_mode": false
  },
  "qc": {
    "max_cps": 25,
    "min_duration": 1.0,
    "max_duration": 7.0,
    "check_missing": true
  }
}
```

[来源:已核实] 参数来自 Python 脚本默认值与工具文档。

---

## 7. 性能参考

> ⚠️ 以下数据为推测，**需实机验证后填空**

| 环节 | 预估速度（RTF） | 1 小时视频耗时 |
|------|----------------|---------------|
| 音频抽取 | 100x | ~1 分钟 |
| 日语听写 | 1-5x（GPU） | 12-60 分钟 |
| 日译中翻译 | 0.5-2x（GPU） | 30-120 分钟 |
| 合并质检 | 50x | ~1 分钟 |

**RTF**：Real-Time Factor，1.0 = 与视频时长相同

---

## 8. 注意事项

1. **显存管理**：听写（large-v3，~3GB）与翻译（Sakura 7B，~5GB）串行运行，避免显存不足
2. **断点续传**：脚本支持 `-Force` 参数重跑，默认跳过已存在文件
3. **日志查看**：所有日志写入 `logs/` 目录，按时间戳命名
4. **错误恢复**：翻译失败会回退到原文，记录在 `translate-report.json`

---

## 参考资料

- [whisper.cpp 官方文档](https://github.com/ggml-org/whisper.cpp)
- [llama.cpp 官方文档](https://github.com/ggml-org/llama.cpp)
- [SakuraLLM 官方 README](https://github.com/SakuraLLM/Sakura-13B-LNovel-GGUF)
- [ffmpeg 官方文档](https://ffmpeg.org/documentation.html)