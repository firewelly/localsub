# models/ 目录说明（2026-11-16 瘦身定版）

本目录存放最终 pipeline 所需的 **3 个模型**，全部位于本机本地磁盘（移动硬盘仅作冷备份，不作工作盘）。

## 目录结构

```
models/
├── whisper/
│   ├── ggml-large-v3.bin             # 听写主模型（2.88GB，fp16 large-v3）
│   └── ggml-silero-v5.1.2.bin        # Silero VAD（0.9MB）
├── translation/
│   └── HY-MT2-7B-Q8_0.gguf           # 翻译主模型（7.43GB，腾讯官方 Hy-MT2-7B Q8_0）
├── MANIFEST.md                       # 来源、许可、sha256
└── CHECKSUMS.sha256                  # 逐文件 sha256 清单
```

> 2026-11-16 瘦身：`ggml-large-v3-turbo.bin`、`ggml-large-v3-turbo-q8_0.bin`、
> `Sakura-Galtransl-7B-v3.7.gguf` 已永久删除（共 8.15GB）。来源、sha256 与恢复步骤见
> 本地归档说明（未随仓库发布）。

## 校验（换机器/换盘后必跑）

```powershell
# 在项目根下执行：逐个比对 CHECKSUMS.sha256
Get-Content .\models\CHECKSUMS.sha256 |
  Where-Object { $_ -match '^\s*[0-9a-f]{64}\s' } |
  ForEach-Object {
    $h, $rel = $_ -split '\s+', 2
    $file = Join-Path '.\models' $rel.Trim()
    if (-not (Test-Path $file)) { Write-Host "MISSING $rel" -ForegroundColor Red; return }
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
    if ($actual -eq $h) { Write-Host "PASS $rel" -ForegroundColor Green }
    else { Write-Host "FAIL $rel`n  expect $h`n  actual $actual" -ForegroundColor Red }
  }
```

2026-11-16 本机 3 个模型全部 PASS。

## 当前离线就绪状态

| 功能 | 状态 | 备注 |
|---|---|---|
| 日语听写 | ✅ 可用 | large-v3 + Silero VAD 已就位并校验；实测整片 166.7 分钟 701 条 |
| 日译中翻译 | ✅ 可用 | Hy-MT2-7B-Q8_0 已校验并整片实跑：701 条零失败、0 假名残留 |

## 缺失/损坏模型补下载

1. **本机直接下**（2026-11-16 实测可用）：
   - HuggingFace 直连 SSL 失败时用镜像 `https://hf-mirror.com/<repo>/resolve/main/<file>`；
   - 大文件用 `curl.exe -L -C - -o <file>.part <url>` 支持断点续传；
   - 下完先对 `CHECKSUMS.sha256` 校验，通过后再改名为正式文件名。
2. **不要再从移动硬盘复制**：该盘 2026-11-15/16 多次出现文件变 0 字节 / 读取 `partial file`，已弃用为工作盘。

## 注意

- **路径必须保持相对**：配置统一写 `models/...`，移动项目目录不需要改路径。
- **显存实测**：large-v3 听写峰值 1.07–3.2GB；Hy-MT2 翻译峰值 6.2–8.6GB；合计 <10GB（A770 16GB 安全）。
- **许可证**：Whisper MIT、Silero Apache-2.0、Hy-MT2 见腾讯官方仓库；默认仅个人非商业使用。
