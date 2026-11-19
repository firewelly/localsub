# -*- coding: utf-8 -*-
<#
03-bilingual.ps1 —— 双语合并 + SRT 质检

对每个含 ja.srt 的目录：
1) 用 merge_srt.py 合并 ja.srt + zh.srt → bilingual.srt（时间轴以日文为准）；
2) 用 qc_srt.py 质检 zh.srt（CPS/时长/重叠/空字幕/日文残留/条数与时间戳对比），
   报告写到同目录 report.json。

用法（在项目根下）：
    .\scripts\windows\03-bilingual.ps1 -InputDir .\output\xxx
    .\scripts\windows\03-bilingual.ps1 -InputDir .\output            # 递归处理
    .\scripts\windows\03-bilingual.ps1 -InputDir .\output\xxx -Force # 重新合并
    .\scripts\windows\03-bilingual.ps1 -InputDir .\output\xxx -Strict # 警告也算不通过

产物：同目录下 bilingual.srt、report.json
退出码：
    0  全部通过（允许质检警告）
    1  有文件合并或质检失败/不通过
    2  无输入、配置错误
#>

[CmdletBinding()]
param(
    [Alias('InputPath', 'InputFile')][string]$InputDir = '',
    [string]$Config = '',
    [string]$PythonExe = '',
    [switch]$Force,
    [switch]$AllowMismatch,
    [switch]$Strict,
    [string]$Mode = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WindowsScriptRoot = $PSScriptRoot
$ScriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot '_common.ps1')

Write-Section '03 双语合并 + 质检'

# ---------- 配置 ----------
try {
    $configInfo = Get-PipelineConfig -ConfigPath $Config
} catch {
    Write-Err ("配置读取失败：{0}" -f $_.Exception.Message)
    exit 2
}
$cfg = $configInfo.Data
$configPath = $configInfo.Path

$outputRoot = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.output_dir' -Default 'output'))
$logsDir = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.logs_dir' -Default 'logs'))
try {
    Initialize-Log -Directory $logsDir -Prefix 'bilingual' | Out-Null
} catch {
    Write-Warn ("无法创建日志：{0}" -f $_.Exception.Message)
}

$targetInput = $outputRoot
if (-not [string]::IsNullOrWhiteSpace($InputDir)) {
    $targetInput = Resolve-FullPath -Relative $InputDir
}

try {
    $pythonPath = Get-PythonCommand -Config $cfg -Override $PythonExe
} catch {
    Write-Err $_.Exception.Message
    exit 2
}
$mergeScript = Join-Path $ScriptsRoot 'python/merge_srt.py'
$qcScript = Join-Path $ScriptsRoot 'python/qc_srt.py'
foreach ($requiredScript in @($mergeScript, $qcScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript)) {
        Write-Err ("找不到 Python 脚本：{0}。请确认 scripts/python/ 目录完整。" -f $requiredScript)
        exit 2
    }
}

$qsStrict = ([bool]$Strict) -or [bool](Get-Cfg -Config $cfg -Path 'qc.strict' -Default $false)
$qsAllowMismatch = ([bool]$AllowMismatch) -or [bool](Get-Cfg -Config $cfg -Path 'bilingual.allow_mismatch' -Default $false)
$bilingualMode = $Mode
if ([string]::IsNullOrWhiteSpace($bilingualMode)) {
    $bilingualMode = [string](Get-Cfg -Config $cfg -Path 'bilingual.mode' -Default 'zh_top')
}

try {
    $jaFiles = @(Get-JaSrtFiles -Path $targetInput -Recurse)
} catch {
    Write-Err $_.Exception.Message
    exit 2
}
if ($jaFiles.Count -eq 0) {
    Write-Err ("输入路径下没有找到 ja.srt：{0}" -f $targetInput)
    Write-Err '03-bilingual.ps1 的 -InputDir 应指向 output\<视频名>\（含 ja.srt/zh.srt），或指向 output\ 递归处理。'
    exit 2
}

Write-Info ("配置文件：{0}" -f $configPath)
Write-Info ("Python：{0}" -f $pythonPath)
Write-Info ("待处理日文字幕：{0} 个 | 双语排版：{1} | 质检严格模式：{2}" -f `
    $jaFiles.Count, $bilingualMode, $(if ($qsStrict) { '开' } else { '关' }))

$passedCount = 0
$failedCount = 0
$mergedCount = 0
$skippedMergeCount = 0
$failures = @()

foreach ($jaFile in $jaFiles) {
    $outDir = Split-Path -Parent $jaFile.FullName
    $zhFile = Join-Path $outDir 'zh.srt'
    $bilingualFile = Join-Path $outDir 'bilingual.srt'
    $reportFile = Join-Path $outDir 'report.json'
    $fileFailed = $false

    Write-Step ("处理：{0}" -f $outDir)

    # ---------- 合并 ----------
    if (-not (Test-Path -LiteralPath $zhFile)) {
        $reason = ("缺少中文文件 {0}：请先运行 02-translate.ps1 完成翻译。" -f $zhFile)
        Write-Err $reason
        $failures += [PSCustomObject]@{ File = $outDir; Reason = $reason }
        $failedCount++
        continue
    }

    if ((Test-Path -LiteralPath $bilingualFile) -and (-not $Force)) {
        Write-Ok ("[跳过合并] 已存在 {0}（需要重跑加 -Force）" -f $bilingualFile)
        $skippedMergeCount++
    } else {
        $mergeArguments = @(
            $mergeScript,
            '--ja', $jaFile.FullName,
            '--zh', $zhFile,
            '--out', $bilingualFile,
            '--config', $configPath,
            '--mode', $bilingualMode
        )
        if ($qsAllowMismatch) { $mergeArguments += @('--allow-mismatch') }
        $mergeExit = Invoke-Native -Exe $pythonPath -Arguments $mergeArguments -LogPath $script:LogFile
        if ($mergeExit -eq 0) {
            $mergedCount++
            if (Test-Path -LiteralPath $bilingualFile) {
                Write-Ok ("[完成] 双语文件：{0}" -f $bilingualFile)
            }
        } else {
            $fileFailed = $true
            $reason = ("双语合并失败（退出码 {0}）：日文/中文条数或时间戳不一致，详见日志。" -f $mergeExit)
            Write-Err $reason
            $failures += [PSCustomObject]@{ File = $outDir; Reason = $reason }
        }
    }

    # ---------- 质检 ----------
    $qcArguments = @(
        $qcScript,
        '--input', $zhFile,
        '--reference', $jaFile.FullName,
        '--report', $reportFile,
        '--config', $configPath,
        '--target-lang', 'zh'
    )
    if ($qsStrict) { $qcArguments += @('--strict') }
    $qcExit = Invoke-Native -Exe $pythonPath -Arguments $qcArguments -LogPath $script:LogFile

    if ($qcExit -eq 0) {
        $reportSummary = ''
        if (Test-Path -LiteralPath $reportFile) {
            try {
                $reportJson = Get-Content -LiteralPath $reportFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $reportSummary = ("条数 {0} | 错误 {1} | 警告 {2}" -f `
                    $reportJson.summary.cues, $reportJson.summary.errors, $reportJson.summary.warnings)
            } catch {
                $reportSummary = '（报告读取失败）'
            }
        }
        Write-Ok ("[质检通过] {0} {1}" -f $reportFile, $reportSummary)
    } else {
        $fileFailed = $true
        if ($qcExit -eq 1) {
            $reason = ("质检不通过（退出码 1）：请查看 {0}" -f $reportFile)
        } else {
            $reason = ("质检运行错误（退出码 {0}）：请检查日志与文件编码。" -f $qcExit)
        }
        Write-Err $reason
        $failures += [PSCustomObject]@{ File = $outDir; Reason = $reason }
    }

    if ($fileFailed) {
        $failedCount++
    } else {
        $passedCount++
    }
}

# ---------- 汇总 ----------
Write-Section '双语合并与质检汇总'
Write-Host ("通过 {0} 个 | 失败 {1} 个 | 新合并 {2} 个 | 跳过合并 {3} 个" -f `
    $passedCount, $failedCount, $mergedCount, $skippedMergeCount) -ForegroundColor Cyan
Write-LogLine ("双语汇总：通过 {0} | 失败 {1} | 新合并 {2} | 跳过合并 {3}" -f `
    $passedCount, $failedCount, $mergedCount, $skippedMergeCount)
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host '失败清单：' -ForegroundColor Red
    foreach ($item in $failures) {
        Write-Host ("  - {0}：{1}" -f $item.File, $item.Reason) -ForegroundColor Red
    }
}
if ($script:LogFile) { Write-Info ("日志：{0}" -f $script:LogFile) }
if ($failedCount -gt 0) {
    Write-Err '存在未通过的文件：请按 report.json 中 errors 修复（翻译质量/时间轴/条数）。'
    exit 1
}
Write-Ok '双语合并与质检全部完成。'
exit 0
