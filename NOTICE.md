# NOTICE

## Naming history

This project was developed under the working name **transub**. It has since been repackaged as a
general-purpose local subtitle pipeline (**LocalSub**). The old name only reflected the early
working directory and is not an assertion of affiliation.

## Relationship to dlsandy/Transub

- [dlsandy/Transub](https://github.com/dlsandy/Transub) was **evaluated and not adopted**:
  it is a Windows-only Electron GUI, has no CLI/automation entry point, and documents GPU
  acceleration only for NVIDIA (CUDA) and AMD (ROCm) — not Intel Arc.
- **No source code, assets, or configuration from that project are included here.**
- This repository is **not a fork** of dlsandy/Transub.

## Third-party components

| Component | License | Usage |
|---|---|---|
| whisper.cpp | MIT | ASR engine (community Windows Vulkan build) |
| llama.cpp | MIT | Translation server (Vulkan build) |
| ffmpeg | LGPL/GPL (build dependent) | Audio extraction |
| ggml-large-v3 / Silero VAD | MIT / Apache-2.0 | Download from their official repositories |
| Hy-MT2-7B GGUF | see Tencent repository | Download from `tencent/Hy-MT2-7B-GGUF` |

Model files are not part of this repository. See `models/MANIFEST.md` for sources and checksums.
