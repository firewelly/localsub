# 模型清单（2026-11-16 瘦身定版）

> 最终 pipeline 只依赖以下 **3 个模型文件**，全部位于本机磁盘 `models/` 下，无需联网。
> 其余实验模型（turbo/turbo-q8/Sakura）已于 2026-11-16 永久删除；来源、sha256 与恢复步骤见
> 本地归档说明（未随仓库发布）。

## 1. 保留模型

| 文件（相对 `models/`） | 大小 | sha256 | 来源 | 用途 | 许可证 |
|---|---|---|---|---|---|
| `whisper/ggml-large-v3.bin` | 2.88 GB | `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2` | [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) | **日语听写主模型**（全尺寸，实测断句/标点明显优于 turbo） | MIT |
| `whisper/ggml-silero-v5.1.2.bin` | 0.9 MB | `29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf` | [ggml-org/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) | Silero VAD（`--vad`，长音频分片必需） | Apache-2.0 |
| `translation/HY-MT2-7B-Q8_0.gguf` | 7.43 GB | `58b3ad55dd6f6fa08c695cddc34fb5f8f708a844f78ae10508071914b0ed67c0` | [tencent/Hy-MT2-7B-GGUF](https://huggingface.co/tencent/Hy-MT2-7B-GGUF)（腾讯官方） | **日译中主模型**（7B Q8_0，hunyuan 提示词） | 见仓库 |

## 2. 校验方法

```powershell
# 在项目根下执行
Get-FileHash models\whisper\ggml-large-v3.bin -Algorithm SHA256
Get-FileHash models\whisper\ggml-silero-v5.1.2.bin -Algorithm SHA256
Get-FileHash models\translation\HY-MT2-7B-Q8_0.gguf -Algorithm SHA256
# 或对照 models/CHECKSUMS.sha256 逐行比较
```

`scripts/python/selftest.py` / `00-check-env.ps1` 会检查文件是否存在；本清单用于离线核对完整性。

## 3. 注意

- **移动硬盘/外置盘不可信**：2026-11-15/16 多次出现模型变 0 字节、复制中断、读取 `partial file`。
  模型只以本机磁盘副本为准；备份到移动盘后必须重新校验 sha256。
- 不要从本清单之外的旧路径引用模型；脚本统一通过 `config/pipeline.json` 的 `models.*` 读取。
- 许可证：Whisper MIT、Silero Apache-2.0、Hy-MT2 见腾讯仓库条款（默认仅个人非商业使用）。
