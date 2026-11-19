# Third-Party Components / 第三方组件与许可

This repository contains **only original project code** (PowerShell scripts, Python modules,
configuration and documentation). **No third-party source code is vendored or copied into this
repository.** Runtime dependencies (binaries and model weights) are downloaded separately by the
user and are **not distributed** with this repository.

本仓库**仅包含本项目原创代码**，**没有内置或复制任何上游源码**；运行时依赖（二进制与模型）
由用户自行下载，**不随仓库分发**。

## 1. Runtime binaries / 运行时二进制

| Component | Version used | Role | License | Source | In repo? |
|---|---|---|---|---|---|
| whisper.cpp | community Vulkan build `jerryshell/whisper.cpp-windows-vulkan-bin` v1.0.0 | ASR engine | **MIT** | https://github.com/ggml-org/whisper.cpp · https://github.com/jerryshell/whisper.cpp-windows-vulkan-bin | No |
| llama.cpp (`llama-server`) | b12428 (Vulkan Windows build) | Translation server | **MIT** | https://github.com/ggml-org/llama.cpp/releases | No |
| ffmpeg | BtbN Windows static build (2026-11-15) | Audio extraction | **LGPL-2.1+ or GPL-2.0+** (depends on build flags) | https://github.com/BtbN/FFmpeg-Builds · https://ffmpeg.org/legal.html | No |
| Intel Arc graphics driver / Vulkan runtime | latest vendor driver | GPU runtime | Proprietary (Intel) | https://www.intel.com/content/www/us/en/download/785597/ | No |
| Python | 3.12.x | Runtime | PSF-2.0 | https://www.python.org/ | No |

> ffmpeg builds that include GPL components (e.g. x264) are GPL; LGPL builds are available.
> If you redistribute a specific ffmpeg binary, you must comply with that build's license.

## 2. Model weights / 模型权重

| Model | File used | Role | License (per model card) | Download | In repo? |
|---|---|---|---|---|---|
| Whisper large-v3 | `ggml-large-v3.bin` | Japanese/multilingual ASR | **Apache-2.0** (OpenAI model card); ggml conversion repo is MIT | https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin | No |
| Silero VAD v5.1.2 | `ggml-silero-v5.1.2.bin` | Voice activity detection | **MIT** (upstream repo and `ggml-org/whisper-vad`) | https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin · https://github.com/snakers4/silero-vad | No |
| Hy-MT2-7B Q8_0 | `HY-MT2-7B-Q8_0.gguf` | Japanese → Chinese MT | **Apache-2.0** (model card) | https://huggingface.co/tencent/Hy-MT2-7B-GGUF/resolve/main/HY-MT2-7B-Q8_0.gguf | No |

Model cards:
- https://huggingface.co/openai/whisper-large-v3
- https://huggingface.co/tencent/Hy-MT2-7B-GGUF
- https://huggingface.co/ggml-org/whisper-vad

> Model licenses are independent of this repository's MIT license. Apache-2.0 permits commercial
> use subject to its terms (attribution/NOTICE); always re-check the upstream model card before
> redistribution or commercial deployment.

## 3. Prompt / template attribution

The Japanese→Chinese instruction template used for Hy-MT2 (`HUNYUAN_INSTR` in
`scripts/python/translate_srt.py`) is adapted from the official Hy-MT2 model card / prompt examples
(Apache-2.0). The rest of the prompts and all filtering/QC rules are original project work.

## 4. What is NOT included / 未包含内容

- No whisper.cpp / llama.cpp / ffmpeg source code or binaries.
- No model weights.
- No video, audio, subtitle or user data.
- No code from [dlsandy/Transub](https://github.com/dlsandy/Transub); this project is not a fork.

## 5. If you redistribute binaries or models

1. Keep the upstream copyright/license notices (MIT for whisper.cpp/llama.cpp, Apache-2.0 for
   Whisper/Hy-MT2 weights, MIT for Silero).
2. For ffmpeg, check whether your build is LGPL or GPL and provide the corresponding source/offers
   as required.
3. Do not imply the upstream authors endorse this project.
