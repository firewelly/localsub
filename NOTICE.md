# NOTICE

## Naming history

This project was developed under the working name **transub** and is now packaged as **LocalSub**.
The old name only reflected the early working directory and does not imply affiliation.

## Relationship to dlsandy/Transub

- [dlsandy/Transub](https://github.com/dlsandy/Transub) was **evaluated and not adopted**:
  Windows-only Electron GUI, no CLI/automation entry point, GPU acceleration documented only for
  NVIDIA (CUDA) and AMD (ROCm) — not Intel Arc.
- **No source code, assets, or configuration from that project are included here.**
- This repository is **not a fork** of dlsandy/Transub.

## No vendored upstream source

This repository contains only original project code. No whisper.cpp, llama.cpp, ffmpeg, Silero or
model source code is vendored. Binaries and model weights are downloaded separately by the user and
are not distributed with this repository.

## Third-party components and licenses

| Component | Role | License | Source |
|---|---|---|---|
| whisper.cpp | ASR engine (community Windows Vulkan build) | MIT | https://github.com/ggml-org/whisper.cpp |
| llama.cpp | Translation server (Vulkan build) | MIT | https://github.com/ggml-org/llama.cpp |
| ffmpeg | Audio extraction | LGPL-2.1+ / GPL-2.0+ (build-dependent) | https://ffmpeg.org/legal.html |
| Whisper large-v3 weights | ASR | Apache-2.0 (OpenAI model card) | https://huggingface.co/openai/whisper-large-v3 |
| Silero VAD v5.1.2 | VAD | MIT | https://github.com/snakers4/silero-vad |
| Hy-MT2-7B Q8_0 | JA→ZH MT | Apache-2.0 | https://huggingface.co/tencent/Hy-MT2-7B-GGUF |

Exact files, download URLs and redistribution notes: [THIRD_PARTY.md](THIRD_PARTY.md).
Model files are not part of this repository. See `models/MANIFEST.md` for checksums.
