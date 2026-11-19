# LocalSub — Offline Subtitle Pipeline (general-purpose, tuned for Japanese → Chinese)

> Turn any Japanese-spoken video into accurate, time-aligned bilingual subtitles — fully offline,
> no cloud API. The pipeline is **general-purpose**: ASR is multilingual, translation and QC are
> configurable. The shipped defaults are **tuned and validated for Japanese → Simplified Chinese**
> subtitle production.
>
> Primary target: **Intel Arc A770 16 GB (external USB4/Thunderbolt eGPU)** on Windows 11,
> using the **Vulkan** backend (no NVIDIA CUDA required).

---

## 1. What it does

```
video ──► ffmpeg (16 kHz mono)
      ──► whisper.cpp (Vulkan) + Silero VAD : chunked ASR + cleaning ──► ja.srt
      ──► llama.cpp server (Vulkan) + Hy-MT2-7B : line-by-line translation ──► zh.srt
      ──► merge + QC ──► bilingual.srt + report.json
```

- **General**: any Whisper-supported source language; any OpenAI-compatible local translation
  model; translation target configurable.
- **Offline**: models and binaries are pre-downloaded; no API keys, no network at runtime.
- **Batch-first**: transcribe everything first, then load the translation model **once** and
  translate all files; fully resumable with per-video state and logs.
- **Time-axis fidelity**: cues are never re-timed or merged; every output line maps 1:1 to a cue.

## 2. Requirements

| Item | Recommended |
|---|---|
| OS | Windows 11 (22H2+) |
| GPU | **Intel Arc A770 16 GB**, external **USB4/Thunderbolt** enclosure OK |
| Driver | Latest Intel Arc driver (Vulkan ≥ 1.3) |
| CPU / RAM | 8 cores / 32 GB (Ryzen 7 7840H validated) |
| Disk | ≥ 20 GB free for models + workspace |
| Backend | Vulkan (validated). SYCL/OpenVINO builds of llama.cpp are optional experiments |

Other Vulkan-capable GPUs and pure-CPU execution work too, but throughput is lower.
USB4 eGPU bandwidth is sufficient: the workload is compute-bound, not PCIe-bound.

## 3. Quick start

```powershell
# from the project root
python -m venv .venv
.\.venv\Scripts\python.exe scripts\python\selftest.py   # 17/17 expected

.\scripts\windows\00-check-env.ps1                       # expect 0 FAIL

# single video / folder
.\scripts\windows\run-all.ps1 -InputDir .\input

# results: output\<video-name>\{ja,zh,bilingual}.srt + report.json
```

Batch mode (recommended for libraries):

```powershell
.\scripts\windows\run-batch.ps1 -InputDir <source-dir> -Recurse -ExcludeCUC
# write subtitles next to the source video instead of output/
.\scripts\windows\run-batch.ps1 -InputDir <source-dir> -Recurse -ExcludeCUC -OutputBesideSource
```

- Stage 1 transcribes every video → `ja.srt`; stage 2 starts one llama-server and translates all
  pending files; stage 3 merges and runs QC.
- Live progress: `[12/159] transcribe: ...`, `[chunk 4/13] done`, ETA; logs in `logs/batch-*.log`.
- `Ctrl+C` anytime; rerun the same command to resume.
- `-Status` shows per-video stage status; `-ListOnly` prints the queue; `-Limit N` runs the first N;
  `-Force` redoes everything.
- `-OutputBesideSource` writes `ja/zh/bilingual.srt + report.json` next to each video. Chunking and
  translation still happen on local disk, then PowerShell copies the files back (safer for
  removable/NAS volumes).

## 4. Configuration

All parameters live in `config/pipeline.json` (auto-copied from `pipeline.example.json`).

```json
"languages": { "source": "ja", "target": "zh" }
```

- `languages.source` drives Whisper's `-l`; `languages.target` drives translation prompts and QC.
- **Japanese → Chinese tuning (defaults):**
  - `whisper.initial_prompt` — Japanese adult-dialogue hint (improves ASR on colloquial/moaning
    audio); clear it for clean or non-adult content.
  - `translate.model` / `translate.api_base` — Hy-MT2-7B Q8_0 served by llama-server.
  - `prompt_style=auto` selects the Hunyuan instruction template **only** for ja→zh; other pairs
    get a neutral English prompt.
- **Other language pairs:** change `languages.*`, point `models.translation` to a suitable GGUF,
  set `translate.model`, and (optionally) clear `whisper.initial_prompt`. QC's kana-residue check
  only runs when `target=zh`.
- **Long audio:** `whisper.chunk_minutes=10` + `whisper.streaming=true` are required for this
  whisper.cpp build (its VAD degrades to zero segments on very long inputs). Extraction/ASR have
  timeouts (`chunk_extract_timeout_sec`, `timeout_sec`) so a bad file fails fast instead of
  stalling the queue.

## 5. Validation (results, no source identifiers)

All measurements on an Arc A770 (Vulkan). Long video: 166.7 min, dialogue-dense.

| Configuration | ASR | Translation | End-to-end | QC |
|---|---|---|---|---|
| large-v3 + Sakura 7B | 701 cues / 25m19s | 1 untranslated line | 28m07s | 1 error |
| turbo-q8 + Hy-MT2 | 466 cues / 7m32s | 0 failures | 10m32s | 0 error, 151 over-long cues |
| **large-v3 + Hy-MT2 (default)** | **701 cues** | **0 failures, 0 kana residue** | **~29 min** | **0 error** |

- Same 10-minute clip: turbo-q8 75 cues, turbo-fp16 56 cues, **large-v3 125 cues** (best
  punctuation/segmentation).
- Sparse-dialogue video (81.8 min): with VAD off, 164 cues of which 140 were hallucinations;
  with VAD + 10-min chunks + cleaning, only 2 real dialogue cues remained.
- Peak VRAM < 10 GB (ASR 1.1–3.2 GB, translation 6.2–8.6 GB).

**Conclusions:** use `large-v3` for ASR and `Hy-MT2` for JA→ZH; turbo variants are only useful as
fast drafts. VAD + chunking is mandatory, not an optimization. Full notes: `docs/05-*.md`.

## 6. Project layout

```
input/  output/  work/  logs/      # gitignored user data
models/whisper/                    # ggml-large-v3.bin, ggml-silero-v5.1.2.bin
models/translation/               # HY-MT2-7B-Q8_0.gguf
tools/windows/{ffmpeg,whisper,llama}/
scripts/windows/                  # 00-03, run-all, run-batch
scripts/python/                   # SRT I/O, translation, merge, QC, selftest
config/                           # pipeline.json + example
docs/                             # design, deployment, workflow, models, troubleshooting
```

## 7. Limitations

- whisper.cpp Windows Vulkan build is a community build; official Windows builds have no Vulkan.
- Translation quality is “accurate and readable”, not publishing-grade.
- Long tasks depend on disk stability; use `-StageDir` if the source volume is flaky.
- Model licences: Whisper MIT, Silero Apache-2.0, Hy-MT2 per Tencent repo; check before commercial use.

## 8. Naming and attribution

- Former working directory/name: **transub**. The project is now packaged as a general pipeline.
- **No code was copied from [dlsandy/Transub](https://github.com/dlsandy/Transub).** That project
  was evaluated and rejected for automation (Windows-only Electron GUI, no CLI, no Intel Arc
  support). The early working name was inspired by it for context only; this repository is **not a
  fork** of it. See [NOTICE.md](NOTICE.md).
- External projects used: whisper.cpp, llama.cpp, ffmpeg, Hugging Face models (see `models/MANIFEST.md`).

## 9. License

MIT for this repository's code. Model licences are separate; see `models/MANIFEST.md`.

---

# LocalSub — 本地字幕流水线（通用，针对日中场景调优）

> 把日语对白视频转成时间轴准确、可用的中日双语字幕，全程离线、不依赖云端 API。
> 流水线本身**通用**：听写支持多语言，翻译提示词与质检规则可配置；
> 默认配置针对**日语 → 简体中文**字幕生产做了实测调优。
>
> 主支持环境：Windows 11 + **Intel Arc A770 16GB（USB4/雷电外置显卡）**，Vulkan 后端，无需 CUDA。

## 功能

- **通用**：Whisper 支持的语言均可听写；翻译走任意 OpenAI 兼容本地服务，目标语言可配。
- **离线**：模型与工具预下载，运行时不出网。
- **批量优先**：先全部听写，再只加载一次翻译模型统一翻译；每个视频有状态与日志，可随时中断续跑。
- **时间轴保真**：不重排、不合并、不漂移，每条输出与原始 cue 一一对应。

## 环境

| 项 | 推荐 |
|---|---|
| 系统 | Windows 11 22H2+ |
| 显卡 | **Intel Arc A770 16GB**（外置 USB4 显卡盒可用） |
| 驱动 | 最新 Intel Arc 驱动（Vulkan ≥ 1.3） |
| CPU / 内存 | 8 核 / 32GB（Ryzen 7 7840H 已验证） |
| 磁盘 | 至少 20GB 可用 |
| 后端 | Vulkan（已验证）；llama.cpp 的 SYCL/OpenVINO 版属可选实验 |

其他 Vulkan 显卡或纯 CPU 也能跑，只是更慢；USB4 外置不会成为瓶颈（推理是算力瓶颈，不是带宽瓶颈）。

## 快速开始

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe scripts\python\selftest.py   # 期望 17/17
.\scripts\windows\00-check-env.ps1                       # 期望 0 FAIL

# 单视频/目录
.\scripts\windows\run-all.ps1 -InputDir .\input

# 批量：先全部听写，再统一翻译；输出到视频同目录
.\scripts\windows\run-batch.ps1 -InputDir <源目录> -Recurse -ExcludeCUC -OutputBesideSource
```

- 阶段 1 逐视频听写；阶段 2 只启动一次 llama-server 翻译全部；阶段 3 合并+质检。
- 实时进度 `[i/N]`、`[片 k/N]`、预计剩余；`Ctrl+C` 后重跑同命令续传。
- `-Status` 看状态、`-ListOnly` 看队列、`-Limit N` 只跑前 N 部、`-Force` 重跑。
- `-OutputBesideSource` 把字幕写在视频同目录；分片/翻译在本地完成后由 PowerShell 回写。

## 配置与日中调优

```json
"languages": { "source": "ja", "target": "zh" }
```

- 默认针对 **日语→中文** 调优：`whisper.initial_prompt` 为日语口语/成人向对白提示；
  `translate.model` 为 Hy-MT2-7B Q8_0；`prompt_style=auto` 仅在 ja→zh 时使用 Hunyuan 指令模板。
- 换语言对：改 `languages.*`、换翻译 GGUF 与 `translate.model`，必要时清空 `initial_prompt`；
  质检的假名残留检查只在 `target=zh` 时启用。
- 长音频必须分片：`whisper.chunk_minutes=10` + `whisper.streaming=true`；
  抽取/听写带超时，坏文件会失败并继续队列。

## 实测结论（不含素材番号）

166.7 分钟对白密集素材：large-v3+Sakura 701 条/28m07s/1 error；
turbo-q8+Hy-MT2 466 条/10m32s/0 error 但 151 条超长 cue；
**large-v3+Hy-MT2 默认组合 701 条/~29 分钟/0 error、翻译零失败、无假名残留**。
同 10 分钟片段：turbo-q8 75 条、turbo-fp16 56 条、large-v3 125 条（断句最好）。
对白极稀素材：关 VAD 164 条中 140 条幻觉；VAD+分片+清洗后仅 2 条真实对白。
显存峰值 <10GB。结论：**听写用 large-v3、翻译用 Hy-MT2；VAD+分片是必需项**。

## 命名与引用

- 早期工作名：**transub**；现按通用流水线重新包装。
- **未复用 [dlsandy/Transub](https://github.com/dlsandy/Transub) 的任何代码**；该项目因仅 Windows
  GUI、无 CLI、不支持 Intel Arc 而被排除，仅早期命名受其启发。本仓库**不是它的 fork**，详见
  [NOTICE.md](NOTICE.md)。
- 使用的外部项目：whisper.cpp、llama.cpp、ffmpeg、Hugging Face 模型（见 `models/MANIFEST.md`）。

## 许可

本仓库代码 MIT；模型许可另见 `models/MANIFEST.md`。
