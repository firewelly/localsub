# 模型清单（2026-11-16 定版）

> 最终 pipeline 只依赖以下 **3 个模型文件**，位于本机 `models/` 下，运行时无需联网。
> **模型权重不随本仓库分发**；请按下方链接自行下载，并遵守各自的许可证。
> 实验模型（turbo / turbo-q8 / Sakura）已删除；旧配置与旧模型未随仓库发布。

## 1. 保留模型与下载地址

| 文件（相对 `models/`） | 大小 | sha256 | 用途 | 许可证 | 下载 |
|---|---|---|---|---|---|
| `whisper/ggml-large-v3.bin` | 2.88 GB | `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2` | 听写主模型（large-v3 fp16） | Apache-2.0（OpenAI 权重；ggml 转换仓库标注 MIT） | https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin |
| `whisper/ggml-silero-v5.1.2.bin` | 0.9 MB | `29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf` | Silero VAD（`--vad`，长音频分片必需） | MIT | https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin |
| `translation/HY-MT2-7B-Q8_0.gguf` | 7.43 GB | `58b3ad55dd6f6fa08c695cddc34fb5f8f708a844f78ae10508071914b0ed67c0` | 日译中主模型（Hy-MT2-7B Q8_0） | Apache-2.0 | https://huggingface.co/tencent/Hy-MT2-7B-GGUF/resolve/main/HY-MT2-7B-Q8_0.gguf |

参考页：

- Whisper large-v3 模型卡：https://huggingface.co/openai/whisper-large-v3
- Silero VAD 上游：https://github.com/snakers4/silero-vad
- Hy-MT2-7B-GGUF 模型卡：https://huggingface.co/tencent/Hy-MT2-7B-GGUF
- 第三方组件与许可汇总：[THIRD_PARTY.md](../THIRD_PARTY.md)

## 2. 下载（PowerShell，可选）

```powershell
# 在项目根下执行；如网络需要代理，请先设置 HTTPS_PROXY / ALL_PROXY
New-Item -ItemType Directory -Force models\whisper, models\translation | Out-Null
curl.exe -L -o models\whisper\ggml-large-v3.bin        https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin
curl.exe -L -o models\whisper\ggml-silero-v5.1.2.bin   https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
curl.exe -L -o models\translation\HY-MT2-7B-Q8_0.gguf  https://huggingface.co/tencent/Hy-MT2-7B-GGUF/resolve/main/HY-MT2-7B-Q8_0.gguf
```

## 3. 校验方法

```powershell
# 在项目根下执行
Get-FileHash models\whisper\ggml-large-v3.bin -Algorithm SHA256
Get-FileHash models\whisper\ggml-silero-v5.1.2.bin -Algorithm SHA256
Get-FileHash models\translation\HY-MT2-7B-Q8_0.gguf -Algorithm SHA256
# 或对照 models/CHECKSUMS.sha256 逐行比较
```

`scripts/python/selftest.py` / `00-check-env.ps1` 会检查文件是否存在；本清单用于离线核对完整性。

## 4. 注意

- **模型不随仓库分发**；本仓库的 MIT 许可不覆盖模型权重。
- 移动硬盘/外置盘不可靠：复制后必须重新校验 sha256。
- 不要从本清单之外的旧路径引用模型；脚本统一通过 `config/pipeline.json` 的 `models.*` 读取。
- 许可证以各上游模型卡为准；商用/再分发前请复核。
