# -*- coding: utf-8 -*-
<#
01-transcribe.ps1 —— 日语听写：ffmpeg 抽 16kHz 单声道 WAV → whisper.cpp（Vulkan）输出 ja.srt

用法（在项目根下）：
    .\scripts\windows\01-transcribe.ps1                       # 批量处理 input/ 下所有音视频
    .\scripts\windows\01-transcribe.ps1 -InputDir .\input
    .\scripts\windows\01-transcribe.ps1 -InputDir .\input\001.mp4
    .\scripts\windows\01-transcribe.ps1 -Force                # 忽略已有 ja.srt 强制重跑

产物：output\<文件名>\ja.srt；中间音频 work\<文件名>\audio16k.wav；日志 logs\transcribe-*.log

退出码：
    0  全部成功（含跳过）
    1  有文件处理失败（其余继续处理）
    2  输入为空或参数/配置错误
#>

[CmdletBinding()]
param(
    [Alias('InputPath', 'InputFile')][string]$InputDir = '',
    [string]$Config = '',
    [string]$OutputRoot = '',
    [string]$WorkRoot = '',
    [switch]$Force,
    [switch]$Recurse,
    [switch]$OutputBesideSource,
    [switch]$KeepAudio
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WindowsScriptRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot '_common.ps1')

Write-Section '01 日语听写（ffmpeg + whisper.cpp）'

# ---------- 配置 ----------
try {
    $configInfo = Get-PipelineConfig -ConfigPath $Config
} catch {
    Write-Err ("配置读取失败：{0}" -f $_.Exception.Message)
    exit 2
}
$cfg = $configInfo.Data
$configPath = $configInfo.Path
# PowerShell 变量名大小写不敏感：先快照参数，避免下面的同名小写变量覆盖参数值
$OutputRootOverride = $OutputRoot
$WorkRootOverride = $WorkRoot

$inputRoot = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.input_dir' -Default 'input'))
if (-not [string]::IsNullOrWhiteSpace($InputDir)) {
    $inputRoot = Resolve-FullPath -Relative $InputDir
}
$outputRoot = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.output_dir' -Default 'output'))
if (-not [string]::IsNullOrWhiteSpace($OutputRootOverride)) {
    $outputRoot = Resolve-FullPath -Relative $OutputRootOverride
}
$workRoot = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.work_dir' -Default 'work'))
if (-not [string]::IsNullOrWhiteSpace($WorkRootOverride)) {
    $workRoot = Resolve-FullPath -Relative $WorkRootOverride
}
$logsDir = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.logs_dir' -Default 'logs'))

try {
    Initialize-Log -Directory $logsDir -Prefix 'transcribe' | Out-Null
} catch {
    Write-Warn ("无法创建日志：{0}" -f $_.Exception.Message)
}

Write-Info ("配置文件：{0}" -f $configPath)
Write-Info ("输入：{0}" -f $inputRoot)
Write-Info ("输出：{0}" -f $outputRoot)
Write-Info ("中间文件：{0}" -f $workRoot)

# ---------- 工具与模型 ----------
try {
    $ffmpegConfigured = [string](Get-Cfg -Config $cfg -Path 'tools.ffmpeg' -Default 'tools/windows/ffmpeg/ffmpeg.exe')
    $ffmpeg = Find-ToolExecutable -Configured $ffmpegConfigured -CommandName 'ffmpeg'
    if (-not $ffmpeg.Found) {
        throw ("未找到 ffmpeg（配置值：{0}）。请把 ffmpeg.exe 放入 tools/windows/ffmpeg/，详见 tools/README.md。" -f $ffmpegConfigured)
    }
    $whisperConfigured = [string](Get-Cfg -Config $cfg -Path 'tools.whisper_cli' -Default 'tools/windows/whisper/whisper-cli.exe')
    $whisper = Find-ToolExecutable -Configured $whisperConfigured -CommandName 'whisper-cli'
    if (-not $whisper.Found) {
        throw ("未找到 whisper-cli（配置值：{0}）。官方预编译只有 CPU 版，Vulkan 版需社区构建/自编译，放 tools/windows/whisper/，详见 tools/README.md。" -f $whisperConfigured)
    }
    $whisperModelPath = Get-RequiredPath -Configured ([string](Get-Cfg -Config $cfg -Path 'models.whisper' -Default 'models/whisper/ggml-large-v3.bin')) `
        -Label 'Whisper 听写模型' -FixHint '检查 models/whisper/ 是否已随硬盘拷贝（models/README.md）。'
    $vadEnabled = Get-Cfg -Config $cfg -Path 'whisper.vad' -Default $true
    $vadModelPath = ''
    if ($vadEnabled) {
        $vadModelPath = Get-RequiredPath -Configured ([string](Get-Cfg -Config $cfg -Path 'models.vad' -Default 'models/whisper/ggml-silero-v5.1.2.bin')) `
            -Label 'Silero VAD 模型' -FixHint '或把 config/pipeline.json 的 whisper.vad 改为 false。'
    }
} catch {
    Write-Err $_.Exception.Message
    exit 2
}

$ffmpegPath = $ffmpeg.Path
$whisperPath = $whisper.Path
$sampleRate = [int](Get-Cfg -Config $cfg -Path 'audio.sample_rate' -Default 16000)
$channels = [int](Get-Cfg -Config $cfg -Path 'audio.channels' -Default 1)
$codec = [string](Get-Cfg -Config $cfg -Path 'audio.codec' -Default 'pcm_s16le')
$wavName = [string](Get-Cfg -Config $cfg -Path 'audio.wav_name' -Default 'audio16k.wav')
$audioExtra = Get-CfgArray -Config $cfg -Path 'audio.extra_args'
$whisperLanguage = [string](Get-Cfg -Config $cfg -Path 'languages.source' -Default (Get-Cfg -Config $cfg -Path 'whisper.language' -Default 'ja'))
$whisperPrompt = [string](Get-Cfg -Config $cfg -Path 'whisper.initial_prompt' -Default '')
$whisperThreads = [int](Get-Cfg -Config $cfg -Path 'whisper.threads' -Default 8)
$whisperWordTs = Get-Cfg -Config $cfg -Path 'whisper.word_timestamps' -Default $false
$whisperSuppress = Get-Cfg -Config $cfg -Path 'whisper.suppress_non_speech' -Default $true
$whisperExtra = Get-CfgArray -Config $cfg -Path 'whisper.extra_args'
$whisperChunkMinutes = [int](Get-Cfg -Config $cfg -Path 'whisper.chunk_minutes' -Default 0)
$whisperClean = Get-Cfg -Config $cfg -Path 'whisper.clean' -Default $true
$whisperStreaming = [bool](Get-Cfg -Config $cfg -Path 'whisper.streaming' -Default $false)
# 超时保护：坏盘/坏文件读取挂死时，超时杀进程并让该视频失败，批量队列继续
$chunkExtractTimeout = [int](Get-Cfg -Config $cfg -Path 'whisper.chunk_extract_timeout_sec' -Default 600)
$fullExtractTimeout = [int](Get-Cfg -Config $cfg -Path 'whisper.full_extract_timeout_sec' -Default 1800)
$whisperTimeout = [int](Get-Cfg -Config $cfg -Path 'whisper.timeout_sec' -Default 1800)
$streamChunks = ($whisperChunkMinutes -gt 0) -and $whisperStreaming
$mergePartsScript = Join-Path $ProjectRoot 'scripts/python/merge_srt_parts.py'
$pythonPath = ''
if ($whisperChunkMinutes -gt 0) {
    try {
        $pythonPath = Get-PythonCommand -Config $cfg
        if (-not (Test-Path -LiteralPath $mergePartsScript)) {
            throw ("缺少分片合并脚本：{0}" -f $mergePartsScript)
        }
    } catch {
        Write-Err ("分片听写依赖 Python/合并脚本不可用：{0}" -f $_.Exception.Message)
        exit 2
    }
}
$extensions = Get-CfgArray -Config $cfg -Path 'input_extensions'

# ---------- 枚举输入 ----------
try {
    $files = @(Get-InputMediaFiles -Path $inputRoot -Extensions $extensions -Recurse:$Recurse)
} catch {
    Write-Err $_.Exception.Message
    exit 2
}
if ($files.Count -eq 0) {
    Write-Err ("输入目录中没有找到支持的音视频文件：{0}" -f $inputRoot)
    Write-Err '请把视频放进 input/，或用 -InputDir 指定单个文件/目录；支持的扩展名见 config/pipeline.json 的 input_extensions。'
    exit 2
}
Write-Ok ("共 {0} 个输入文件待处理。" -f $files.Count)

# ---------- 逐个处理 ----------
$successCount = 0
$skippedCount = 0
$failedCount = 0
$failures = @()
$batchStart = Get-Date

foreach ($file in $files) {
    $baseName = $file.BaseName
    $outDir = if ($OutputBesideSource) { Split-Path -Parent $file.FullName } else { Join-Path $outputRoot $baseName }
    $jaSrt = Join-Path $outDir 'ja.srt'
    $workDir = Join-Path $workRoot $baseName
    $wavPath = Join-Path $workDir $wavName
    $fileStart = Get-Date

    if ((Test-Path -LiteralPath $jaSrt) -and (-not $Force)) {
        Write-Ok ("[跳过] 已存在 {0}（需要重跑加 -Force）" -f $jaSrt)
        $skippedCount++
        continue
    }

    try {
        Write-Step ("处理：{0}" -f $file.Name)
        if (-not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $workDir)) {
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        }

        # ---- 抽音频（流式分片模式跳过整轨抽取，改为逐片直接抽取）----
        if ($streamChunks) {
            Write-Info '  流式分片模式：跳过整轨 WAV，按片直接抽取并即时删除（低 IO）'
        } else {
        $needExtract = $true
        if ((Test-Path -LiteralPath $wavPath) -and (-not $Force)) {
            $wavInfo = Get-Item -LiteralPath $wavPath
            if ($wavInfo.Length -gt 0 -and $wavInfo.LastWriteTime -ge $file.LastWriteTime) {
                $needExtract = $false
            }
        }
        if ($needExtract) {
            Write-Info ("  抽取音频：{0} Hz / {1} 声道 / {2}" -f $sampleRate, $channels, $codec)
            $ffmpegArguments = @(
                '-nostdin', '-hide_banner', '-loglevel', 'warning', '-y',
                '-i', $file.FullName,
                '-vn', '-ac', [string]$channels, '-ar', [string]$sampleRate, '-c:a', $codec
            )
            if ($audioExtra.Count -gt 0) { $ffmpegArguments += $audioExtra }
            $ffmpegArguments += @($wavPath)
            $exitCode = Invoke-Native -Exe $ffmpegPath -Arguments $ffmpegArguments -LogPath $script:LogFile -TimeoutSec $fullExtractTimeout
            if ($exitCode -ne 0) {
                throw ("ffmpeg 抽取音频失败（退出码 {0}）。常见原因：源文件没有音轨、文件损坏、磁盘空间不足。详见日志。" -f $exitCode)
            }
            if (-not (Test-Path -LiteralPath $wavPath)) {
                throw ("ffmpeg 未生成音频文件：{0}" -f $wavPath)
            }
            if ((Get-Item -LiteralPath $wavPath).Length -le 0) {
                throw ("音频文件为空：{0}" -f $wavPath)
            }
        } else {
            Write-Info ("  [复用] 已存在较新的音频文件：{0}" -f $wavPath)
        }
        }

        # ---- whisper.cpp 听写（whisper.chunk_minutes > 0 时走「物理切片 + VAD + 合并清洗」）----
        $whisperFlags = @()
        if ($vadEnabled) {
            # 注意：本机社区 Vulkan 版 whisper-cli 只接受长参数 --vad（-vad 会报 unknown argument）
            $whisperFlags += @('--vad')
            if (-not [string]::IsNullOrWhiteSpace($vadModelPath)) {
                $whisperFlags += @('-vm', $vadModelPath)
            }
        }
        if ($whisperSuppress) {
            $whisperFlags += @('-sns')
        }
        if ((-not [string]::IsNullOrWhiteSpace($whisperPrompt)) -and (-not ($whisperExtra -contains '--prompt'))) {
            $whisperFlags += @('--prompt', $whisperPrompt)
        }
        if ($whisperWordTs) {
            $whisperFlags += @('-owts')
        }
        if ($whisperExtra.Count -gt 0) { $whisperFlags += $whisperExtra }

        if ($whisperChunkMinutes -gt 0) {
            # 长音频（≥30 分钟）下该 whisper-cli 的 VAD 会退化为 0 段，必须物理切片后逐片 VAD。
            $chunkSeconds = $whisperChunkMinutes * 60
            $partsDir = if ($OutputBesideSource) { $workDir } else { $outDir }
            $chunkDir = Join-Path $workDir 'chunks'
            if (Test-Path -LiteralPath $chunkDir) { Remove-Item -LiteralPath $chunkDir -Recurse -Force }
            New-Item -ItemType Directory -Path $chunkDir -Force | Out-Null
            Get-ChildItem -LiteralPath $partsDir -Filter 'ja.part*.srt' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $jaSrt) { Remove-Item -LiteralPath $jaSrt -Force }

            if ($streamChunks) {
                # 流式：逐片直接从源视频抽取 → 听写 → 立即删除，峰值本地占用 ≈ 1 片（约 20MB/10分钟）
                $ffprobeConfigured = [string](Get-Cfg -Config $cfg -Path 'tools.ffprobe' -Default 'tools/windows/ffmpeg/ffprobe.exe')
                $ffprobe = Find-ToolExecutable -Configured $ffprobeConfigured -CommandName 'ffprobe'
                if (-not $ffprobe.Found) {
                    throw ("未找到 ffprobe（配置值：{0}）；流式分片模式需要它读取片长。" -f $ffprobeConfigured)
                }
                $durationText = [string]((& $ffprobe.Path -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $file.FullName) -join '')
                $durationSec = 0.0
                if (-not [double]::TryParse($durationText.Trim(), [ref]$durationSec)) {
                    throw ("无法读取视频时长：{0}（ffprobe 输出：{1}）" -f $file.FullName, $durationText)
                }
                if ($durationSec -le 0) { throw ("视频时长为 0：{0}" -f $file.FullName) }
                $chunkCount = [int][Math]::Ceiling($durationSec / $chunkSeconds)
                Write-Info ("  流式分片：{0} 片 × {1} 分钟，逐片抽取/听写/删除（源时长 {2:N0} 秒）" -f $chunkCount, $whisperChunkMinutes, $durationSec)
                $videoChunkStart = Get-Date

                for ($chunkIndex = 0; $chunkIndex -lt $chunkCount; $chunkIndex++) {
                    $startSec = $chunkIndex * $chunkSeconds
                    $chunkStart = Get-Date
                    $chunkPath = Join-Path $chunkDir ('chunk_{0:D3}.wav' -f $chunkIndex)
                    $extractArgs = @(
                        '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
                        '-ss', [string]$startSec,
                        '-t', [string]$chunkSeconds,
                        '-i', $file.FullName,
                        '-vn', '-ac', [string]$channels, '-ar', [string]$sampleRate, '-c:a', $codec
                    )
                    if ($audioExtra.Count -gt 0) { $extractArgs += $audioExtra }
                    $extractArgs += @($chunkPath)
                    $chunkPrepareExit = Invoke-Native -Exe $ffmpegPath -Arguments $extractArgs -LogPath $script:LogFile -TimeoutSec $chunkExtractTimeout
                    if (($chunkPrepareExit -ne 0) -or (-not (Test-Path -LiteralPath $chunkPath)) -or
                        ((Get-Item -LiteralPath $chunkPath).Length -le 0)) {
                        throw ("第 {0} 片抽取失败（退出码 {1}）。请检查源文件与磁盘空间。" -f $chunkIndex, $chunkPrepareExit)
                    }
                    $partPrefix = Join-Path $partsDir ('ja.part{0:D3}' -f $chunkIndex)
                    $chunkArguments = @(
                        '-m', $whisperModelPath,
                        '-f', $chunkPath,
                        '-l', $whisperLanguage,
                        '-osrt',
                        '-of', $partPrefix,
                        '-t', [string]$whisperThreads
                    ) + $whisperFlags
                    $chunkExit = Invoke-Native -Exe $whisperPath -Arguments $chunkArguments -LogPath $script:LogFile -TimeoutSec $whisperTimeout
                    if (($chunkExit -ne 0) -and (-not (Test-Path -LiteralPath ($partPrefix + '.srt')))) {
                        throw ("第 {0} 片听写失败（whisper-cli 退出码 {1}，无产物）。请检查日志。" -f $chunkIndex, $chunkExit)
                    }
                    if ($chunkExit -ne 0) {
                        Write-Warn ("第 {0} 片 whisper-cli 退出码 {1}，但已生成分片字幕，继续。" -f $chunkIndex, $chunkExit)
                    }
                    Remove-Item -LiteralPath $chunkPath -Force -ErrorAction SilentlyContinue
                    Write-Info ("  [片 {0}/{1}] 完成，本片用时 {2}，累计 {3}" -f `
                        ($chunkIndex + 1), $chunkCount,
                        (Format-Elapsed -Seconds ((Get-Date) - $chunkStart).TotalSeconds),
                        (Format-Elapsed -Seconds ((Get-Date) - $fileStart).TotalSeconds))
                }
            } else {
                $splitArgs = @(
                    '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
                    '-i', $wavPath,
                    '-f', 'segment',
                    '-segment_time', [string]$chunkSeconds,
                    '-reset_timestamps', '1',
                    '-c', 'copy',
                    (Join-Path $chunkDir 'chunk_%03d.wav')
                )
                $exitCode = Invoke-Native -Exe $ffmpegPath -Arguments $splitArgs -LogPath $script:LogFile -TimeoutSec $chunkExtractTimeout
                if ($exitCode -ne 0) {
                    throw ("ffmpeg 切片失败（退出码 {0}）。请检查磁盘空间与源音频。" -f $exitCode)
                }
                $chunkFiles = @(Get-ChildItem -LiteralPath $chunkDir -Filter 'chunk_*.wav' -File | Sort-Object Name)
                if ($chunkFiles.Count -eq 0) {
                    throw ("ffmpeg 未生成任何分片音频：{0}" -f $chunkDir)
                }
                Write-Info ("  分片数：{0}，逐片听写（语言 {1}，线程 {2}）……" -f $chunkFiles.Count, $whisperLanguage, $whisperThreads)

                $chunkIndex = 0
                foreach ($chunkFile in $chunkFiles) {
                    $chunkStart = Get-Date
                    $partPrefix = Join-Path $partsDir ('ja.part{0:D3}' -f $chunkIndex)
                    $chunkArguments = @(
                        '-m', $whisperModelPath,
                        '-f', $chunkFile.FullName,
                        '-l', $whisperLanguage,
                        '-osrt',
                        '-of', $partPrefix,
                        '-t', [string]$whisperThreads
                    ) + $whisperFlags
                    $chunkExit = Invoke-Native -Exe $whisperPath -Arguments $chunkArguments -LogPath $script:LogFile -TimeoutSec $whisperTimeout
                    if (($chunkExit -ne 0) -and (-not (Test-Path -LiteralPath ($partPrefix + '.srt')))) {
                        throw ("第 {0} 片听写失败（whisper-cli 退出码 {1}，无产物）。请检查日志。" -f $chunkIndex, $chunkExit)
                    }
                    if ($chunkExit -ne 0) {
                        Write-Warn ("第 {0} 片 whisper-cli 退出码 {1}，但已生成分片字幕，继续。" -f $chunkIndex, $chunkExit)
                    }
                    Write-Info ("  [片 {0}/{1}] 完成，本片用时 {2}，累计 {3}" -f `
                        ($chunkIndex + 1), $chunkFiles.Count,
                        (Format-Elapsed -Seconds ((Get-Date) - $chunkStart).TotalSeconds),
                        (Format-Elapsed -Seconds ((Get-Date) - $fileStart).TotalSeconds))
                    $chunkIndex++
                }
            }

            # 输出到源目录时：先在本地 work/ 合并，再用 PowerShell 复制到源目录
            # （whisper/部分 Python 临时文件写入对远程/移动盘的长 Unicode 路径不可靠）
            $mergeOut = $jaSrt
            $mergeReport = Join-Path $outDir 'transcribe-report.json'
            if ($OutputBesideSource) {
                $mergeOut = Join-Path $workDir 'ja.final.srt'
                $mergeReport = Join-Path $workDir 'transcribe-report.json'
            }
            $mergeArguments = @(
                $mergePartsScript,
                '--parts-dir', $partsDir,
                '--prefix', 'ja.part',
                '--chunk-seconds', [string]$chunkSeconds,
                '--out', $mergeOut,
                '--report', $mergeReport
            )
            if (-not $whisperClean) { $mergeArguments += '--no-clean' }
            $exitCode = Invoke-Native -Exe $pythonPath -Arguments $mergeArguments -LogPath $script:LogFile
            if ($exitCode -eq 2) {
                # 清洗后无有效字幕：不要留下空 ja.srt，否则重跑会被误判为“已完成”
                if (Test-Path -LiteralPath $mergeOut) { Remove-Item -LiteralPath $mergeOut -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $jaSrt) { Remove-Item -LiteralPath $jaSrt -Force -ErrorAction SilentlyContinue }
                throw ("分片合并后没有有效字幕（整片可能无人声，或过滤过严）。详见 {0}" -f $mergeReport)
            }
            if ($exitCode -ne 0) {
                throw ("分片合并失败（Python 退出码 {0}）。" -f $exitCode)
            }
            if ($OutputBesideSource) {
                Copy-Item -LiteralPath $mergeOut -Destination $jaSrt -Force
                if (Test-Path -LiteralPath $mergeReport) {
                    Copy-Item -LiteralPath $mergeReport -Destination (Join-Path $outDir 'transcribe-report.json') -Force
                }
            }

            Get-ChildItem -LiteralPath $partsDir -Filter 'ja.part*.srt' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $chunkDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            $outputPrefix = Join-Path $outDir 'ja'
            $whisperArguments = @(
                '-m', $whisperModelPath,
                '-f', $wavPath,
                '-l', $whisperLanguage,
                '-osrt',
                '-of', $outputPrefix,
                '-t', [string]$whisperThreads
            ) + $whisperFlags

            Write-Info ("  听写（whisper.cpp，语言 {0}，线程 {1}）……" -f $whisperLanguage, $whisperThreads)
            $exitCode = Invoke-Native -Exe $whisperPath -Arguments $whisperArguments -LogPath $script:LogFile -TimeoutSec $whisperTimeout
            if ($exitCode -ne 0) {
                if (-not (Test-Path -LiteralPath $jaSrt)) {
                    throw ("whisper-cli 退出码 {0}，且未生成 {1}。请检查日志中的模型加载/Vulkan 设备信息。" -f $exitCode, $jaSrt)
                }
                Write-Warn ("whisper-cli 返回退出码 {0}，但已生成 {1}，继续（请检查日志确认是否为警告）。" -f $exitCode, $jaSrt)
            }
        }
        if (-not (Test-Path -LiteralPath $jaSrt)) {
            throw ("未生成预期的日文字幕 {0}。请检查 whisper-cli 是否支持 -osrt/-of 参数（详见日志）。" -f $jaSrt)
        }
        if ((Get-Item -LiteralPath $jaSrt).Length -le 0) {
            throw ("日文字幕文件为空：{0}" -f $jaSrt)
        }

        # ---- 清理中间音频（默认清理，-KeepAudio 保留） ----
        if (-not $KeepAudio) {
            Remove-Item -LiteralPath $wavPath -Force -ErrorAction SilentlyContinue
        }

        $elapsed = ((Get-Date) - $fileStart).TotalSeconds
        $cueCount = 0
        try {
            $cueCount = ([regex]::Matches((Get-Content -LiteralPath $jaSrt -Raw -Encoding UTF8), '(?m)^\d+\s*$')).Count
        } catch { }
        Write-Ok ("[完成] {0} -> {1}（{2} 条，文件大小 {3} 字节，用时 {4}）" -f `
            $file.Name, $jaSrt, $cueCount, (Get-Item -LiteralPath $jaSrt).Length, (Format-Elapsed -Seconds $elapsed))
        $successCount++
    } catch {
        $reason = $_.Exception.Message
        Write-Err ("[失败] {0}：{1}" -f $file.Name, $reason)
        Write-LogLine ("失败 {0}：{1}" -f $file.Name, $reason)
        $failedCount++
        $failures += [PSCustomObject]@{ File = $file.Name; Reason = $reason }
    }
}

# ---------- 汇总 ----------
$batchElapsed = ((Get-Date) - $batchStart).TotalSeconds
Write-Section '听写汇总'
Write-Host ("成功 {0} 个 | 跳过 {1} 个 | 失败 {2} 个 | 总用时 {3}" -f `
    $successCount, $skippedCount, $failedCount, (Format-Elapsed -Seconds $batchElapsed)) -ForegroundColor Cyan
Write-LogLine ("成功 {0} | 跳过 {1} | 失败 {2} | 总用时 {3}" -f `
    $successCount, $skippedCount, $failedCount, (Format-Elapsed -Seconds $batchElapsed))
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host '失败清单：' -ForegroundColor Red
    foreach ($item in $failures) {
        Write-Host ("  - {0}：{1}" -f $item.File, $item.Reason) -ForegroundColor Red
    }
    Write-Info ("日志：{0}" -f $script:LogFile)
    exit 1
}
Write-Ok '听写全部完成。产物目录：output\<文件名>\ja.srt'
if ($script:LogFile) { Write-Info ("日志：{0}" -f $script:LogFile) }
exit 0
