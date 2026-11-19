# config/ 配置文件说明

> 流水线全部可调参数集中在这里：**改配置，不改脚本**。
>
> - `pipeline.example.json`：模板（提交进仓库，UTF-8 无 BOM）。
> - `pipeline.json`：实际生效配置（默认 = 方案A）。**首次运行脚本时若不存在，会自动从模板复制并打印中文提示**，
>   然后请按目标机实际情况修改。
> - `pipeline.json`：**最终配置**（large-v3 + Hy-MT2），也是脚本默认读取的配置。


> - 旧 `planA` / `planB` / `planB-full` 配置与旧模型未随仓库发布（仅本地保留）；当前只有 `pipeline.json` 一份生效配置。
>   部署与验收口径见 `docs/05-选型与实测结论.md`。
> - 所有路径都相对**项目根**（不是相对 config 目录），不写盘符/绝对路径；整个目录搬到别的磁盘/机器也无需改配置。
> - 工具与模型路径支持通配符（如 `models/translation/*.gguf`），匹配多个时按文件名排序取第一个
>   并打印警告；想固定选择就改成精确文件名。
>
> **状态（2026-11-16 定版）：已在本机 Windows + Arc A770 实跑验证（00-check-env 0 FAIL、selftest 17/17、整片 166.7 分钟跑通）；最终模型为 large-v3 + Hy-MT2。**

## 字段说明

### 顶层

| 字段 | 默认 | 说明 |
|---|---|---|
| `schema_version` | `1` | 配置格式版本，目前固定 1 |
| `paths` | — | 各工作目录（相对项目根） |
| `input_extensions` | 常见音视频后缀数组 | 01/run-all 扫描 `input/` 时接受的扩展名（带点、小写比较） |
| `tools` | — | 外部可执行文件路径/命令名 |
| `models` | — | 模型文件路径（支持通配符） |
| `audio` | — | ffmpeg 抽音频参数 |
| `whisper` | — | whisper.cpp 听写参数 |
| `llama` | — | llama-server 启动参数 |
| `translate` | — | 翻译接口与提示词参数 |
| `bilingual` | — | 双语 SRT 排版 |
| `qc` | — | 质检阈值与严重级别 |
| `srt` | — | SRT 输出编码/行尾 |
| `log` | — | 日志保留策略（预留） |

### `paths`

| 字段 | 默认 | 说明 |
|---|---|---|
| `input_dir` | `input` | 待处理视频目录，用户自行放入 |
| `work_dir` | `work` | 中间音频等可删产物 |
| `output_dir` | `output` | 最终字幕产物根目录 |
| `logs_dir` | `logs` | 运行日志 |

### `tools`（放置约定见 `tools/README.md`）

| 字段 | 默认 | 说明 |
|---|---|---|
| `ffmpeg` | `tools/windows/ffmpeg/ffmpeg.exe` | 也可写 `ffmpeg` 走系统 PATH |
| `ffprobe` | `tools/windows/ffmpeg/ffprobe.exe` | 可选；当前流水线未强制使用 |
| `whisper_cli` | `tools/windows/whisper/whisper-cli.exe` | 社区构建若叫 `main.exe` 改这里 |
| `llama_server` | `tools/windows/llama/llama-server.exe` | Vulkan/SYCL 预编译包 |
| `python` | `.venv/Scripts/python.exe` | **两方案共用的项目 venv**（Python 3.12，无第三方依赖）；文件不存在时脚本自动回退 `python`/`python3`/`py`。重建方法见 `docs/05-选型与实测结论.md` §2 |

### `models`（模型由准备机预下载，见 `models/README.md`）

| 字段 | 默认 | 说明 |
|---|---|---|
| `whisper` | `models/whisper/ggml-large-v3.bin` | 日语听写主模型（large-v3，约 2.88GB） |
| `whisper_fallback` | （已删除） | 旧 turbo 对照模型已随 2026-11-16 瘦身移除；脚本不使用该字段 |
| `vad` | `models/whisper/ggml-silero-v5.1.2.bin` | Silero VAD 模型（`whisper.vad=true` 时必需） |
| `translation` | `models/translation/HY-MT2-7B-Q8_0.gguf` | 日译中 GGUF（最终为 Hy-MT2 7B Q8_0；支持通配符） |

### `languages`（语言对，决定听写语言与翻译方向）

| 字段 | 默认 | 说明 |
|---|---|---|
| `source` | `ja` | 源语言；传给 whisper `-l`（`auto` 可自动检测） |
| `target` | `zh` | 目标语言；决定翻译提示词与 QC（仅 target=zh 时检查假名残留） |

> 默认针对日语→简体中文调优；换语言对时同步修改翻译模型（`models.translation` + `translate.model`），必要时清空 `whisper.initial_prompt`。
### `audio`（ffmpeg 抽音轨）

| 字段 | 默认 | 说明 |
|---|---|---|
| `sample_rate` | `16000` | whisper.cpp 推荐 16kHz |
| `channels` | `1` | 单声道 |
| `codec` | `pcm_s16le` | WAV 16-bit PCM |
| `wav_name` | `audio16k.wav` | 中间音频文件名 |
| `extra_args` | `[]` | 追加给 ffmpeg 的参数数组（按需，如 `-map 0:a:0`） |

### `whisper`（whisper.cpp）

| 字段 | 默认 | 说明 |
|---|---|---|
| `language` | `ja` | 日语听写 |
| `threads` | `8` | CPU 线程数（`-t`） |
| `vad` | `true` | 是否启用 VAD（`-vad`，并附 `-vm <vad 模型>`） |
| `word_timestamps` | `false` | 是否额外输出词级时间戳（`-owts`）；不同构建支持差异大，按需开启 |
| `suppress_non_speech` | `true` | 抑制非语音（`-sns`） |
| `initial_prompt` | 日语口语提示 | 传给 whisper `--prompt` 的初始提示；通用内容建议清空 |
| `extra_args` | `["-dev","1", "-mc","0", "-vt","0.3", "--prompt","…"]` | 追加参数数组。**本机 Vulkan 枚举 0=AMD 780M 核显、1=Arc A770，必须用 `-dev 1` 指定 Arc**；换机器后用 `whisper-cli --help` 顶部设备列表核对索引 |
| `chunk_minutes` | `10` | **长音频必需**：本机 whisper-cli 的 VAD 在 ≥30 分钟音频上退化为 0 段，必须物理切片；0=关闭切片（短音频/调试用） |
| `clean` | `true` | 分片合并时清洗幻觉黑名单/纯语气/纯符号/空文本条目（`merge_srt_parts.py`） |
| `streaming` | `true` | 流式分片：逐片直接从源视频抽取→听写→立即删除，峰值本地占用≈1 片（约 20MB/10 分钟），适合 SMB 批处理 |
| `chunk_extract_timeout_sec` | `600` | 单片抽取超时（秒）；超时杀 ffmpeg 并把该视频判失败，批量队列继续（坏盘保护） |
| `full_extract_timeout_sec` | `1800` | 整轨抽取（非流式模式）超时（秒） |
| `timeout_sec` | `1800` | 单片 whisper 听写超时（秒）；超时判失败并继续下一个视频 |

### `llama`（llama-server）

| 字段 | 默认 | 说明 |
|---|---|---|
| `host` | `127.0.0.1` | 仅本机监听，安全 |
| `port` | `8080` | 端口被占用时 02 会复用健康服务或报错提示 |
| `n_gpu_layers` | `99` | `-ngl`，尽量全部层放 GPU |
| `ctx_size` | `4096` | `-c` 上下文长度 |
| `threads` | `8` | `-t` CPU 线程数 |
| `startup_timeout_sec` | `180` | 等待 `/health` 就绪上限；模型大/盘慢可加大 |
| `server_url` | `""` | 非空时 02 直接复用该服务（等效 `-ServerUrl`）；如 `http://127.0.0.1:8080` |
| `extra_args` | `["-dev","Vulkan1"]` | 追加参数数组。**本机用 `-dev Vulkan1` 指定 Arc A770**（设备 0 为 AMD 核显）；设备名以 `llama-server --list-devices` 为准 |

### `translate`（日译中接口与提示词）

| 字段 | 默认 | 说明 |
|---|---|---|
| `api_base` | `http://127.0.0.1:8080/v1` | OpenAI 兼容地址；脚本自动拼 `/chat/completions` |
| `model` | `Hy-MT2-7B-Q8_0` | 请求中的 `model` 字段；含 `hy-mt` 会自动套 hunyuan 提示词 |
| `concurrency` | `2` | 并发请求数；本地 llama-server 建议 1~4 |
| `context_size` | `4` | 每条翻译附带的“前文日文”条数（仅供理解，不参与输出） |
| `timeout_sec` | `180` | 单次请求超时（模型慢/14B 可加大） |
| `retries` | `3` | 失败重试次数（指数退避，最多单次等待 10 秒） |
| `temperature` | `0.3` | 采样温度；字幕翻译建议低温度 |
| `top_p` | `0.9` | 核采样 |
| `max_tokens` | `512` | 单条输出上限 |
| `fallback_on_error` | `true` | 某句最终失败时回退日文原文并记录到报告；false 则直接失败 |
| `api_key` | `""` | 本地 llama-server 不需要；接远程兼容服务时才填 |
| `health_url` | `""` | 留空则由 `api_base` 推导 `/health` |
| `system_prompt` | 中文提示词 | 系统提示；要求“只输出译文、不合并/不拆分” |
| `user_template` | 中文模板 | 支持占位符 `{context}`、`{text}`、`{index}`；替换用字符串替换，不用 format |

> 改提示词时保留 `{text}` 占位符，否则脚本会硬校验失败（当前实现不强制，但会影响翻译效果）。
> 若模型返回带“译文：”前缀/包裹引号，`translate_srt.py` 会自动清理。

### `bilingual`（双语排版）

| 字段 | 默认 | 说明 |
|---|---|---|
| `mode` | `zh_top` | `zh_top` 中文在上/日文在下；`ja_top` 反之；`same_line` 同一行 |
| `separator` | `" | "` | 仅 `same_line` 使用 |
| `allow_mismatch` | `false` | 日/中条数或时间戳不一致时是否仍按条号对齐合并（默认严格报错） |

### `qc`（质检阈值）

| 字段 | 默认 | 说明 |
|---|---|---|
| `max_cps` | `15.0` | 每秒最多显示字符数（中文按可见字符计，不含空白）；超出记 warning |
| `min_duration_ms` | `500` | 单条最短时长，低于记 warning |
| `max_duration_ms` | `9000` | 单条最长时长，超过记 warning |
| `overlap_tolerance_ms` | `0` | 允许的时间轴重叠毫秒数（0 = 完全不允许）；超出记 error |
| `max_gap_ms` | `15000` | 相邻条间隔超过此值记 warning（场景切换属正常，可调大） |
| `kana_severity` | `error` | 中文里检测到日文假名的级别（`error`/`warning`；翻译回退原文时会出现） |
| `duplicate_severity` | `warning` | 相邻两条文本完全相同的级别（听写幻觉信号） |
| `max_compare_items` | `20` | 与参考 ja.srt 对比时，最多列出多少条时间戳不一致明细 |
| `strict` | `false` | true 时质检 warning 也算不通过（等价于 03 的 `-Strict`） |

### `srt`（输出文件格式）

| 字段 | 默认 | 说明 |
|---|---|---|
| `encoding` | `utf-8` | 默认 **UTF-8 无 BOM**（项目约定，播放器兼容性更好）；个别旧播放器需要 BOM 时改 `utf-8-sig` |
| `newline` | `lf` | `lf` 或 `crlf`；Windows 记事本可改 `crlf` |

> 解析端始终容忍 BOM/CRLF，输出格式只影响生成的文件。

### `log`

| 字段 | 默认 | 说明 |
|---|---|---|
| `keep_days` | `30` | 日志保留天数（当前脚本不自动清理，留作后续扩展/手工清理参考） |

## 最终配置与历史对照

当前只有一份生效配置：pipeline.json（large-v3 + Hy-MT2）。历史方案对照见 docs/05-选型与实测结论.md；旧配置与旧模型未随仓库发布。

## 常见修改示例

- **换翻译模型**：把 `models.translation` 改成精确文件名，例如
  `HY-MT2-7B-Q8_0.gguf`（相对 `models/translation/`）。
- **显存紧张**：`llama.ctx_size` 调小（如 2048）、`llama.n_gpu_layers` 调小（如 20 让部分层走 CPU）。
- **中文在上/日文在下 → 同一行**：`bilingual.mode` 改 `same_line`，`bilingual.separator` 改 `" / "`。
- **CPS 太严格**：`qc.max_cps` 调到 18~20（要兼顾可读性）。
- **想让质检警告也失败**：`qc.strict` 改 `true`，或运行 `03-bilingual.ps1 -Strict`。
- **复用已运行的 llama-server**：把 `llama.server_url` 填上地址，或用 `02-translate.ps1 -ServerUrl ...`。
- **验证配置 JSON 合法**：`python -m json.tool config/pipeline.json > NUL`（命令报错即格式有误）。

## 注意

- 配置文件请保持 UTF-8 编码；`.md/.py/.json` 约定 UTF-8 无 BOM（`.ps1` 才是 UTF-8 with BOM）。
- 不要把 `config/pipeline.json` 里的个人路径/密钥提交到仓库；本仓库默认只提交 `pipeline.example.json`。
- 目标机首次运行脚本会自动生成 `pipeline.json`，这是预期行为（日志/控制台会打印中文提示）。
