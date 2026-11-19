# -*- coding: utf-8 -*-
<#
run-all.ps1 —— 一键批量流水线：input/ 下所有视频 → output/<文件名>/{ja.srt, zh.srt, bilingual.srt, report.json}

流程：00 环境自检 → 01 日语听写 → 02 日译中 → 03 双语合并 + 质检 → 汇总 output/summary-*.json

用法（在项目根下）：
    .\scripts\windows\run-all.ps1
    .\scripts\windows\run-all.ps1 -InputDir .\input
    .\scripts\windows\run-all.ps1 -Force                      # 忽略断点全部重跑
    .\scripts\windows\run-all.ps1 -Mock -SkipTranscribe -InputDir .\output\xxx
                                                              # 离线验证翻译+合并+质检链路
    .\scripts\windows\run-all.ps1 -SkipEnvCheck               # 跳过 00 环境自检

说明：
- -Mock 不调用任何模型接口，译文为伪中文，仅用于验证脚本链路；听写阶段仍需真实工具，
  因此 Mock 模式要求目标目录已存在 ja.srt（或配合 -SkipTranscribe 直接处理已有 ja.srt）。
- 单个视频失败不会中断整批，最后汇总并返回非零退出码。

退出码：
    0  全部成功
    1  有视频处理失败（或环境自检不通过）
    2  无输入、配置错误
#>

[CmdletBinding()]
param(
    [Alias('InputPath', 'InputFile')][string]$InputDir = '',
    [string]$Config = '',
    [string]$OutputRoot = '',
    [string]$WorkRoot = '',
    [string]$PythonExe = '',
    [string]$ServerUrl = '',
    [switch]$Force,
    [switch]$Mock,
    [switch]$SkipTranscribe,
    [switch]$SkipEnvCheck,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WindowsScriptRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot '_common.ps1')

function Invoke-ChildScript {
    <# 用独立 PowerShell 进程调用子脚本，保证子脚本的 exit 码能被父脚本读取。 #>
    param(
        [string]$ScriptName,
        [string[]]$Arguments = @()
    )
    $scriptPath = Join-Path $WindowsScriptRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw ("找不到子脚本：{0}" -f $scriptPath)
    }
    $psExe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($psExe)) {
        throw '无法获取当前 PowerShell 可执行文件路径，无法调用子脚本。'
    }
    if (Test-IsWindows) {
        $callArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
    } else {
        $callArgs = @('-NoProfile', '-File', $scriptPath)
    }
    $callArgs += $Arguments
    $lines = & $psExe @callArgs 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $lines) {
        $text = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
            Add-Content -LiteralPath $script:LogFile -Value $text -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        if ($text.Trim().Length -gt 0) {
            Write-Host $text -ForegroundColor DarkGray
        }
    }
    return $code
}

Write-Section '一键批量流水线（run-all.ps1）'

# ---------- 配置与路径 ----------
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

$inputTarget = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.input_dir' -Default 'input'))
if (-not [string]::IsNullOrWhiteSpace($InputDir)) {
    $inputTarget = Resolve-FullPath -Relative $InputDir
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
    Initialize-Log -Directory $logsDir -Prefix 'run-all' | Out-Null
} catch {
    Write-Warn ("无法创建日志：{0}" -f $_.Exception.Message)
}
if (-not (Test-Path -LiteralPath $outputRoot)) {
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
}

Write-Info ("项目根：{0}" -f $ProjectRoot)
Write-Info ("配置：{0}" -f $configPath)
Write-Info ("输入：{0}" -f $inputTarget)
Write-Info ("输出：{0}" -f $outputRoot)
Write-Info ("模式：{0} | 听写阶段：{1}" -f `
    $(if ($Mock) { '离线模拟（翻译不调接口）' } else { '真实运行' }),
    $(if ($SkipTranscribe) { '跳过（使用已有 ja.srt）' } else { '执行' }))

$runStart = Get-Date
$results = @()
$failedCount = 0
$successCount = 0

try {
    # ---------- 环境自检 ----------
    if ($Mock) {
        Write-Warn '模拟模式：跳过 00 环境自检（不检查 GPU/模型，仅验证脚本链路）。'
    } elseif ($SkipEnvCheck) {
        Write-Warn '已按 -SkipEnvCheck 跳过环境自检，请自行确保环境可用。'
    } else {
        Write-Step '步骤 1/1：环境自检（00-check-env.ps1）'
        $envArgs = @('-Config', $configPath)
        $envExit = Invoke-ChildScript -ScriptName '00-check-env.ps1' -Arguments $envArgs
        if ($envExit -ne 0) {
            Write-Err '环境自检未通过，已中止批量流程。请先按 00-check-env.ps1 的修复提示处理后重试。'
            throw '环境自检未通过（退出码非零）。'
        }
        Write-Ok '环境自检通过。'
    }

    # ---------- 收集任务 ----------
    $tasks = @()
    if ($SkipTranscribe) {
        try {
            $jaFiles = @(Get-JaSrtFiles -Path $inputTarget -Recurse)
        } catch {
            Write-Err $_.Exception.Message
            exit 2
        }
        if ($jaFiles.Count -eq 0) {
            Write-Err ("-SkipTranscribe 模式下，输入路径中没有 ja.srt：{0}" -f $inputTarget)
            exit 2
        }
        foreach ($jaFile in $jaFiles) {
            $tasks += [PSCustomObject]@{
                Name = (Split-Path -Leaf (Split-Path -Parent $jaFile.FullName))
                Source = $jaFile.FullName
                OutDir = (Split-Path -Parent $jaFile.FullName)
                JaSrt = $jaFile.FullName
            }
        }
        Write-Ok ("跳过听写：直接处理已有日文字幕 {0} 个。" -f $tasks.Count)
    } else {
        try {
            $mediaFiles = @(Get-InputMediaFiles -Path $inputTarget `
                -Extensions (Get-CfgArray -Config $cfg -Path 'input_extensions') -Recurse)
        } catch {
            Write-Err $_.Exception.Message
            exit 2
        }
        if ($mediaFiles.Count -eq 0) {
            Write-Err ("输入目录中没有找到支持的音视频文件：{0}" -f $inputTarget)
            Write-Err '把视频放入 input/ 后重试，或用 -InputDir 指定单个文件/目录。'
            exit 2
        }
        foreach ($mediaFile in $mediaFiles) {
            $baseName = $mediaFile.BaseName
            $outDir = Join-Path $outputRoot $baseName
            $tasks += [PSCustomObject]@{
                Name = $baseName
                Source = $mediaFile.FullName
                OutDir = $outDir
                JaSrt = (Join-Path $outDir 'ja.srt')
            }
        }
        Write-Ok ("共 {0} 个视频待处理。" -f $tasks.Count)
    }

    # ---------- 逐个视频执行 ----------
    foreach ($task in $tasks) {
        $taskStart = Get-Date
        $status = '成功'
        $reasons = @()
        $transcribeExit = 0
        $translateExit = 0
        $bilingualExit = 0
        $zhSrt = Join-Path $task.OutDir 'zh.srt'
        $bilingualSrt = Join-Path $task.OutDir 'bilingual.srt'
        $reportJson = Join-Path $task.OutDir 'report.json'

        Write-Section ("处理：{0}" -f $task.Name)

        # 1) 听写
        if ($SkipTranscribe) {
            Write-Info '[听写] 已按 -SkipTranscribe 跳过。'
        } elseif ($Mock) {
            if (-not (Test-Path -LiteralPath $task.JaSrt)) {
                $reasons += ("模拟模式要求已存在 ja.srt：{0}（请先用真实工具听写，或加 -SkipTranscribe）" -f $task.JaSrt)
            } else {
                Write-Info ("[听写] 模拟模式，复用已有 {0}" -f $task.JaSrt)
            }
        } else {
            $transcribeArgs = @('-InputDir', $task.Source, '-Config', $configPath,
                '-OutputRoot', $outputRoot, '-WorkRoot', $workRoot)
            if ($Force) { $transcribeArgs += @('-Force') }
            $transcribeExit = Invoke-ChildScript -ScriptName '01-transcribe.ps1' -Arguments $transcribeArgs
            if ($transcribeExit -ne 0) {
                $reasons += ("日语听写失败（01 退出码 {0}）" -f $transcribeExit)
            }
        }

        if ($transcribeExit -ne 0) {
            $status = '失败'
        }

        # 2) 翻译
        if ($status -ne '失败') {
            if (-not (Test-Path -LiteralPath $task.JaSrt)) {
                $reasons += ("缺少日文字幕：{0}" -f $task.JaSrt)
                $status = '失败'
            } elseif ((Test-Path -LiteralPath $zhSrt) -and (-not $Force)) {
                Write-Ok ("[翻译] 已存在 {0}，跳过（需要重跑加 -Force）" -f $zhSrt)
            } else {
                $translateArgs = @('-InputDir', $task.JaSrt, '-Config', $configPath)
                if ($Mock) { $translateArgs += @('-Mock') }
                if ($Force) { $translateArgs += @('-Force') }
                if (-not [string]::IsNullOrWhiteSpace($PythonExe)) { $translateArgs += @('-PythonExe', $PythonExe) }
                if (-not [string]::IsNullOrWhiteSpace($ServerUrl)) { $translateArgs += @('-ServerUrl', $ServerUrl) }
                $translateExit = Invoke-ChildScript -ScriptName '02-translate.ps1' -Arguments $translateArgs
                if ($translateExit -ne 0) {
                    $reasons += ("日译中失败（02 退出码 {0}）" -f $translateExit)
                    $status = '失败'
                }
            }
        }

        # 3) 双语合并 + 质检
        if ($status -ne '失败') {
            $bilingualArgs = @('-InputDir', $task.JaSrt, '-Config', $configPath)
            if ($Force) { $bilingualArgs += @('-Force') }
            if ($Strict) { $bilingualArgs += @('-Strict') }
            if (-not [string]::IsNullOrWhiteSpace($PythonExe)) { $bilingualArgs += @('-PythonExe', $PythonExe) }
            $bilingualExit = Invoke-ChildScript -ScriptName '03-bilingual.ps1' -Arguments $bilingualArgs
            if ($bilingualExit -ne 0) {
                $reasons += ("双语合并/质检未通过（03 退出码 {0}）" -f $bilingualExit)
                $status = '失败'
            }
        }

        # 4) 产物完整性检查
        $artifacts = @()
        foreach ($required in @(@{ Name = 'ja.srt'; Path = $task.JaSrt },
                                @{ Name = 'zh.srt'; Path = $zhSrt },
                                @{ Name = 'bilingual.srt'; Path = $bilingualSrt },
                                @{ Name = 'report.json'; Path = $reportJson })) {
            $exists = Test-Path -LiteralPath $required.Path
            $artifacts += [PSCustomObject]@{ Name = $required.Name; Path = $required.Path; Exists = $exists }
            if (-not $exists) {
                $reasons += ("缺少产物 {0}：{1}" -f $required.Name, $required.Path)
            }
        }
        if ($reasons.Count -gt 0) { $status = '失败' }

        $qcSummary = $null
        if (Test-Path -LiteralPath $reportJson) {
            try {
                $qcSummary = Get-Content -LiteralPath $reportJson -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                $reasons += ("report.json 无法解析：{0}" -f $reportJson)
                $status = '失败'
            }
        }

        $elapsed = ((Get-Date) - $taskStart).TotalSeconds
        if ($status -eq '成功') {
            $successCount++
            Write-Ok ("[成功] {0}（用时 {1}）" -f $task.Name, (Format-Elapsed -Seconds $elapsed))
        } else {
            $failedCount++
            Write-Err ("[失败] {0}（用时 {1}）" -f $task.Name, (Format-Elapsed -Seconds $elapsed))
            foreach ($reason in $reasons) { Write-Err ("  原因：{0}" -f $reason) }
        }

        $results += [PSCustomObject]@{
            name = $task.Name
            source = $task.Source
            output_dir = $task.OutDir
            status = $status
            reasons = @($reasons)
            artifacts = @($artifacts)
            elapsed_sec = [Math]::Round($elapsed, 1)
            translate_exit = $translateExit
            qc = $(if ($null -ne $qcSummary) {
                    [PSCustomObject]@{
                        cues = $qcSummary.summary.cues
                        errors = $qcSummary.summary.errors
                        warnings = $qcSummary.summary.warnings
                        passed = $qcSummary.summary.passed
                    }
                } else { $null })
        }
    }
} catch {
    Write-Err ("批量流程中止：{0}" -f $_.Exception.Message)
    if ($script:LogFile) { Write-Info ("日志：{0}" -f $script:LogFile) }
    exit 1
}

# ---------- 汇总输出 ----------
$totalElapsed = ((Get-Date) - $runStart).TotalSeconds
Write-Section '批量运行汇总'
Write-Host ("成功 {0} 个 | 失败 {1} 个 | 总用时 {2}" -f `
    $successCount, $failedCount, (Format-Elapsed -Seconds $totalElapsed)) -ForegroundColor Cyan
Write-LogLine ("批量汇总：成功 {0} | 失败 {1} | 总用时 {2}" -f `
    $successCount, $failedCount, (Format-Elapsed -Seconds $totalElapsed))

$summaryObject = [PSCustomObject]@{
    schema_version = 1
    tool = 'run-all.ps1'
    generated_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    project_root = $ProjectRoot
    config = $configPath
    mode = $(if ($Mock) { 'mock' } else { 'real' })
    skip_transcribe = [bool]$SkipTranscribe
    input = $inputTarget
    output_root = $outputRoot
    counts = [PSCustomObject]@{
        total = $tasks.Count
        success = $successCount
        failed = $failedCount
    }
    elapsed_sec = [Math]::Round($totalElapsed, 1)
    results = @($results)
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$summaryPath = Join-Path $outputRoot ("summary-" + $stamp + ".json")
try {
    Write-Utf8NoBom -Path $summaryPath -Text (ConvertTo-Json -InputObject $summaryObject -Depth 8) | Out-Null
    Write-Ok ("汇总已写入：{0}" -f $summaryPath)
} catch {
    Write-Warn ("写汇总文件失败：{0}" -f $_.Exception.Message)
}

if ($script:LogFile) { Write-Info ("日志：{0}" -f $script:LogFile) }
if ($failedCount -gt 0) {
    Write-Err ("批量流程结束：有 {0} 个视频失败，请查看上面的原因与 output/ 下的 report.json。" -f $failedCount)
    exit 1
}
Write-Ok '批量流程全部成功。产物在 output/<视频名>/ 下（ja.srt / zh.srt / bilingual.srt / report.json）。'
exit 0
