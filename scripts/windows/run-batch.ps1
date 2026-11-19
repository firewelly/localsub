# -*- coding: utf-8 -*-
<#
run-batch.ps1 —— 批量流水线（两阶段：先全部听写，再统一翻译/合并；可断点续跑）

设计目标（2026-11-16）：
- **避免翻译模型反复加载**：先把所有目标视频听写成 ja.srt，再启动一次 llama-server 批量翻译全部；
- **断点续跑**：每完成一个阶段就写 output/batch-state.json；重跑时按产物存在性 + 状态自动跳过；
- **长任务日志**：logs/batch-*.log 记录每个视频/阶段的时间戳与结果，另有 01/02/03 各自日志；
- **低 IO / SMB 友好**：听写使用 whisper.streaming 分片（逐片抽取→听写→删除），源可放 NAS/SMB。

用法（项目根下）：
    .\scripts\windows\run-batch.ps1 -InputDir <源盘>:\videos -Recurse            # 全库（可随时中断再跑）
    .\scripts\windows\run-batch.ps1 -InputDir <源盘>:\videos -Recurse -Limit 3   # 只处理队列前 3 部
    .\scripts\windows\run-batch.ps1 -InputList .\work\pilot.txt          # 指定文件清单（每行一个路径）
    .\scripts\windows\run-batch.ps1 -InputDir .\input -Force             # 全部重跑
    .\scripts\windows\run-batch.ps1 -InputDir .\output -SkipTranscribe   # 只补翻译+合并

阶段：
    1) 听写：01-transcribe.ps1（逐视频，缺失 ja.srt 才跑）
    2) 翻译：02-translate.ps1（一次启动 llama-server，递归处理 output 下所有 ja.srt）
    3) 合并质检：03-bilingual.ps1（递归处理 output 下所有 ja.srt）

退出码：0 全部成功；1 有失败项（可修复后重跑续传）；2 配置/输入错误。
#>

[CmdletBinding()]
param(
    [Alias('InputPath', 'InputFile')][string]$InputDir = '',
    [string]$InputList = '',
    [string]$Config = '',
    [string]$OutputRoot = '',
    [string]$WorkRoot = '',
    [string]$StateFile = '',
    [string]$StageDir = '',
    [switch]$KeepStaged,
    [int]$Limit = 0,
    [int]$TranscribeRetries = 1,
    [switch]$Recurse,
    [switch]$ExcludeCUC,
    [switch]$OutputBesideSource,
    [switch]$ListOnly,
    [switch]$Status,
    [switch]$Force,
    [switch]$SkipTranscribe,
    [switch]$SkipTranslate,
    [switch]$SkipMerge,
    [string]$PythonExe = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WindowsScriptRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot '_common.ps1')

function Invoke-ChildScript {
    param([string]$ScriptName, [string[]]$Arguments = @())
    $scriptPath = Join-Path $WindowsScriptRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw ("找不到子脚本：{0}" -f $scriptPath) }
    $psExe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($psExe)) { throw '无法获取当前 PowerShell 可执行文件路径。' }
    if (Test-IsWindows) {
        $callArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
    } else {
        $callArgs = @('-NoProfile', '-File', $scriptPath)
    }
    $callArgs += $Arguments
    # 逐行流式转发子脚本输出：用户可实时看到「第几片/第几个视频」的进度
    & $psExe @callArgs 2>&1 | ForEach-Object {
        $text = [string]$_
        if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
            Add-Content -LiteralPath $script:LogFile -Value $text -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        if ($text.Trim().Length -gt 0) { Write-Host $text -ForegroundColor DarkGray }
    }
    return $LASTEXITCODE
}

function Load-BatchState {
    param([string]$Path)
    if ((Test-Path -LiteralPath $Path) -and (-not $Force)) {
        try {
            $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $obj) { return $obj }
        } catch {
            Write-Warn ("状态文件无法解析，将重建：{0}" -f $_.Exception.Message)
        }
    }
    return [PSCustomObject]@{
        schema_version = 1
        created_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        updated_at = ''
        tasks = @{}
    }
}

function Save-BatchState {
    param($State, [string]$Path)
    $State.updated_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    Write-Utf8NoBom -Path $Path -Text (ConvertTo-Json -InputObject $State -Depth 8) | Out-Null
}

function Copy-MirrorToSource {
    <# 输出到源目录模式：把本地 output/<key>/ 的产物复制到视频同目录（PowerShell 处理 Unicode/网络盘更稳）。 #>
    param($Task)
    if (-not (Test-Path -LiteralPath $Task.MirrorDir)) { return }
    foreach ($name in @('ja.srt', 'zh.srt', 'bilingual.srt', 'report.json', 'transcribe-report.json', 'translate-report.json')) {
        $src = Join-Path $Task.MirrorDir $name
        $dst = Join-Path $Task.OutDir $name
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-TaskKey {
    param([string]$BaseName, [string]$FullName)
    return $BaseName
}

function Copy-ToStage {
    <# 从（可能不稳定的）源盘带超时/重试复制到本地暂存目录；失败抛异常。 #>
    param([string]$Source, [string]$StageRoot, [int]$Retries = 2, [int]$TimeoutSec = 900)
    $name = Split-Path -Leaf $Source
    $srcDir = Split-Path -Parent $Source
    $dest = Join-Path $StageRoot $name
    if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -eq (Get-Item -LiteralPath $Source).Length)) {
        return $dest
    }
    New-Item -ItemType Directory -Path $StageRoot -Force | Out-Null
    for ($attempt = 0; $attempt -le $Retries; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Seconds 5 }
        try {
            # Start-Process 的 ArgumentList 数组不会自动加引号，含空格/全角字符的路径必须手动加引号
            $argList = @(
                ('"' + $srcDir + '"'),
                ('"' + $StageRoot + '"'),
                ('"' + $name + '"'),
                '/R:1', '/W:2', '/NP', '/NJH', '/NJS'
            )
            $proc = Start-Process -FilePath 'robocopy' -ArgumentList $argList `
                -PassThru -WindowStyle Hidden
            if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
                throw ("复制超时（{0} 秒）：源盘可能已掉线" -f $TimeoutSec)
            }
            if ($proc.ExitCode -le 7 -and (Test-Path -LiteralPath $dest)) {
                if ((Get-Item -LiteralPath $dest).Length -eq (Get-Item -LiteralPath $Source).Length) { return $dest }
                throw '复制后大小不一致（源文件读取不完整）'
            }
            throw ("robocopy 退出码 {0}" -f $proc.ExitCode)
        } catch {
            if ($attempt -ge $Retries) { throw ("暂存复制失败：{0}" -f $_.Exception.Message) }
            Write-Warn ("暂存复制重试 {0}/{1}：{2}" -f ($attempt + 1), $Retries, $_.Exception.Message)
        }
    }
}

# ---------- 配置与路径 ----------
try {
    $configInfo = Get-PipelineConfig -ConfigPath $Config
} catch {
    Write-Err ("配置读取失败：{0}" -f $_.Exception.Message)
    exit 2
}
$cfg = $configInfo.Data
$configPath = $configInfo.Path
$OutputRootOverride = $OutputRoot
$WorkRootOverride = $WorkRoot

$outputRoot = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.output_dir' -Default 'output'))
if (-not [string]::IsNullOrWhiteSpace($OutputRootOverride)) { $outputRoot = Resolve-FullPath -Relative $OutputRootOverride }
$workRoot = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.work_dir' -Default 'work'))
if (-not [string]::IsNullOrWhiteSpace($WorkRootOverride)) { $workRoot = Resolve-FullPath -Relative $WorkRootOverride }
$logsDir = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.logs_dir' -Default 'logs'))
if (-not (Test-Path -LiteralPath $outputRoot)) { New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null }

try { Initialize-Log -Directory $logsDir -Prefix 'batch' | Out-Null } catch { Write-Warn ("无法创建日志：{0}" -f $_.Exception.Message) }
if ([string]::IsNullOrWhiteSpace($StateFile)) { $StateFile = Join-Path $outputRoot 'batch-state.json' }
else { $StateFile = Resolve-FullPath -Relative $StateFile }

Write-Section '批量流水线（run-batch.ps1）'
Write-Info ("项目根：{0}" -f $ProjectRoot)
Write-Info ("配置：{0}" -f $configPath)
Write-Info ("输出：{0}" -f $outputRoot)
Write-Info ("状态：{0}" -f $StateFile)
Write-Info ("模式：{0}" -f ($(if ($Force) { '强制重跑' } else { '断点续跑（已完成的跳过）' })))

# ---------- 只看状态 ----------
if ($Status) {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        Write-Warn ("尚无批量状态（未开始或状态文件已删除）：{0}" -f $StateFile)
        exit 0
    }
    try { $st = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        Write-Err ("状态文件无法解析：{0}" -f $_.Exception.Message); exit 2
    }
    Write-Section '批量状态（-Status）'
    $rows = @()
    $done = 0; $total = 0
    foreach ($prop in $st.tasks.PSObject.Properties) {
        $t = $prop.Value
        $total++
        $allDone = ($t.stages.transcribe -eq 'done') -and ($t.stages.translate -eq 'done') -and ($t.stages.merge -eq 'done')
        if ($allDone) { $done++ }
        $rows += [PSCustomObject]@{
            视频 = $prop.Name
            听写 = $(if ($t.stages.transcribe) { $t.stages.transcribe } else { '未开始' })
            翻译 = $(if ($t.stages.translate) { $t.stages.translate } else { '未开始' })
            合并 = $(if ($t.stages.merge) { $t.stages.merge } else { '未开始' })
            错误 = [string]$t.last_error
        }
    }
    $table = ($rows | Format-Table -AutoSize -Wrap | Out-String)
    Write-Host $table
    Write-Host ("完成 {0} / {1}（未完成 {2}）" -f $done, $total, ($total - $done)) -ForegroundColor Cyan
    Write-Info ("状态文件：{0}" -f $StateFile)
    exit 0
}

$extensions = Get-CfgArray -Config $cfg -Path 'input_extensions'
$media = @()
if (-not [string]::IsNullOrWhiteSpace($InputList)) {
    $listPath = Resolve-FullPath -Relative $InputList
    if (-not (Test-Path -LiteralPath $listPath)) { Write-Err ("清单文件不存在：{0}" -f $listPath); exit 2 }
    foreach ($line in (Get-Content -LiteralPath $listPath -Encoding UTF8)) {
        $text = $line.Trim()
        if ($text.Length -eq 0 -or $text.StartsWith('#')) { continue }
        $candidate = Resolve-FullPath -Relative $text
        if (Test-Path -LiteralPath $candidate) { $media += (Get-Item -LiteralPath $candidate) }
        else { Write-Warn ("清单中的文件不存在，跳过：{0}" -f $candidate) }
    }
} else {
    $target = $outputRoot
    if (-not [string]::IsNullOrWhiteSpace($InputDir)) { $target = Resolve-FullPath -Relative $InputDir }
    try {
        $media = @(Get-InputMediaFiles -Path $target -Extensions $extensions -Recurse:$Recurse)
    } catch {
        Write-Err $_.Exception.Message
        exit 2
    }
}
if ($media.Count -eq 0) {
    Write-Err '没有找到待处理的音视频文件。请用 -InputDir / -InputList 指定，或把文件放进 input/。'
    exit 2
}
if ($ExcludeCUC) {
    $before = $media.Count
    $media = @($media | Where-Object { $_.BaseName -notmatch '\-(C|UC)([ ._\-]|$)' })
    Write-Info ("已排除 -C/-UC 版本：{0} -> {1} 个" -f $before, $media.Count)
}
if ($ListOnly) {
    Write-Section '任务清单（-ListOnly，不执行）'
    $i = 0
    foreach ($f in $media) { $i++; Write-Host ("  {0,3}. {1}" -f $i, $f.FullName) }
    Write-Host ("共 {0} 个视频。" -f $media.Count) -ForegroundColor Cyan
    exit 0
}
if ($Limit -gt 0 -and $media.Count -gt $Limit) {
    Write-Info ("共 {0} 个文件，按 -Limit 只取前 {1} 个。" -f $media.Count, $Limit)
    $media = @($media | Select-Object -First $Limit)
}
Write-Ok ("任务队列：{0} 个视频。" -f $media.Count)

# ---------- 构建任务 ----------
$tasks = @()
$seenKeys = @{}
foreach ($file in $media) {
    $key = Get-TaskKey -BaseName $file.BaseName -FullName $file.FullName
    if ($seenKeys.ContainsKey($key)) {
        $hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($file.FullName))).Replace('-', '').Substring(0, 8).ToLowerInvariant()
        $key = $file.BaseName + '-' + $hash
        Write-Warn ("存在同名视频，输出目录改用：{0}" -f $key)
    }
    $seenKeys[$key] = $true
    $outDir = if ($OutputBesideSource) { Split-Path -Parent $file.FullName } else { Join-Path $outputRoot $key }
    $mirrorDir = Join-Path $outputRoot $key
    $tasks += [PSCustomObject]@{
        Key = $key
        Name = $file.Name
        Source = $file.FullName
        OutDir = $outDir
        JaSrt = (Join-Path $outDir 'ja.srt')
        ZhSrt = (Join-Path $outDir 'zh.srt')
        BiSrt = (Join-Path $outDir 'bilingual.srt')
        Report = (Join-Path $outDir 'report.json')
        MirrorDir = $mirrorDir
        MirrorJa = (Join-Path $mirrorDir 'ja.srt')
        MirrorZh = (Join-Path $mirrorDir 'zh.srt')
        MirrorBi = (Join-Path $mirrorDir 'bilingual.srt')
        MirrorReport = (Join-Path $mirrorDir 'report.json')
    }
}

$state = Load-BatchState -Path $StateFile
# PSCustomObject 的 tasks 是 NoteProperty（object），这里统一成 hashtable 便于读写
$stateTasks = @{}
if ($null -ne $state.tasks) {
    foreach ($prop in $state.tasks.PSObject.Properties) { $stateTasks[$prop.Name] = $prop.Value }
}
foreach ($task in $tasks) {
    if (-not $stateTasks.ContainsKey($task.Key)) {
        $stateTasks[$task.Key] = [PSCustomObject]@{
            source = $task.Source
            out_dir = $task.OutDir
            stages = [PSCustomObject]@{ transcribe = ''; translate = ''; merge = '' }
            seconds = [PSCustomObject]@{ transcribe = 0; translate = 0; merge = 0 }
            last_error = ''
        }
    }
}
$state.tasks = $stateTasks
Save-BatchState -State $state -Path $StateFile | Out-Null

function Set-TaskStage {
    param([string]$Key, [string]$Stage, [string]$Status, [double]$Seconds, [string]$Error)
    if (-not $stateTasks.ContainsKey($Key)) { return }
    $entry = $stateTasks[$Key]
    $entry.stages.$Stage = $Status
    if ($Seconds -gt 0) { $entry.seconds.$Stage = [Math]::Round($Seconds, 1) }
    if (-not [string]::IsNullOrWhiteSpace($Error)) { $entry.last_error = $Error }
    Save-BatchState -State $state -Path $StateFile | Out-Null
}

# ---------- 阶段 1：全部听写 ----------
$failures = @()
if (-not $SkipTranscribe) {
    Write-Section '阶段 1/3：批量听写（01-transcribe.ps1，逐视频）'
    $index = 0
    $doneCount = 0
    $elapsedSum = 0.0
    foreach ($task in $tasks) {
        $index++
        $entry = $stateTasks[$task.Key]
        # 输出到源目录模式：若源目录还没有 ja.srt，但本地 output/<key>/ 已有产物，先迁移过去，避免重复听写
        if ($OutputBesideSource -and (-not (Test-Path -LiteralPath $task.JaSrt))) {
            $legacyDir = Join-Path $outputRoot $task.Key
            $legacyJa = Join-Path $legacyDir 'ja.srt'
            if (Test-Path -LiteralPath $legacyJa) {
                foreach ($name in @('ja.srt', 'zh.srt', 'bilingual.srt', 'report.json', 'transcribe-report.json', 'translate-report.json')) {
                    $srcFile = Join-Path $legacyDir $name
                    $dstFile = Join-Path $task.OutDir $name
                    if ((Test-Path -LiteralPath $srcFile) -and (-not (Test-Path -LiteralPath $dstFile))) {
                        Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force -ErrorAction SilentlyContinue
                    }
                }
                Write-Ok ("[{0}/{1}] 迁移本地已有字幕到源目录：{2}" -f $index, $tasks.Count, $task.Key)
            }
        }
        if ((Test-Path -LiteralPath $task.JaSrt) -and (-not $Force)) {
            Write-Ok ("[{0}/{1}] 跳过（已有 ja.srt）：{2}" -f $index, $tasks.Count, $task.Key)
            if ($OutputBesideSource -and (-not (Test-Path -LiteralPath $task.MirrorJa))) {
                if (-not (Test-Path -LiteralPath $task.MirrorDir)) { New-Item -ItemType Directory -Path $task.MirrorDir -Force | Out-Null }
                Copy-Item -LiteralPath $task.JaSrt -Destination $task.MirrorJa -Force -ErrorAction SilentlyContinue
                $srcReport = Join-Path $task.OutDir 'transcribe-report.json'
                if (Test-Path -LiteralPath $srcReport) {
                    Copy-Item -LiteralPath $srcReport -Destination (Join-Path $task.MirrorDir 'transcribe-report.json') -Force -ErrorAction SilentlyContinue
                }
            }
            if ($entry.stages.transcribe -ne 'done') { Set-TaskStage -Key $task.Key -Stage 'transcribe' -Status 'done' -Seconds 0 -Error '' }
            continue
        }
        $start = Get-Date
        $ok = $false
        $lastError = ''
        $transcribeSource = $task.Source
        $stagedPath = ''
        if (-not [string]::IsNullOrWhiteSpace($StageDir)) {
            try {
                Write-Info ("  暂存复制到本地：{0}" -f $task.Name)
                $stagedPath = Copy-ToStage -Source $task.Source -StageRoot (Resolve-FullPath -Relative $StageDir)
                $transcribeSource = $stagedPath
            } catch {
                $lastError = $_.Exception.Message
                Set-TaskStage -Key $task.Key -Stage 'transcribe' -Status 'failed' -Seconds 0 -Error $lastError
                $failures += [PSCustomObject]@{ Key = $task.Key; Stage = 'stage'; Reason = $lastError }
                Write-Err ("[{0}/{1}] 暂存失败：{2}（{3}）" -f $index, $tasks.Count, $task.Key, $lastError)
                continue
            }
        }
        for ($attempt = 0; $attempt -le $TranscribeRetries; $attempt++) {
            if ($attempt -gt 0) {
                Write-Warn ("[{0}/{1}] 第 {2} 次重试：{3}" -f $index, $tasks.Count, $attempt, $task.Key)
                Start-Sleep -Seconds 5
            }
            Write-Step ("[{0}/{1}] 听写：{2}" -f $index, $tasks.Count, $task.Name)
            try {
                $args = @('-InputDir', $transcribeSource, '-Config', $configPath,
                          '-OutputRoot', $outputRoot, '-WorkRoot', $workRoot)
                if ($OutputBesideSource) { $args += '-OutputBesideSource' }
                if ($Force) { $args += '-Force' }
                $code = Invoke-ChildScript -ScriptName '01-transcribe.ps1' -Arguments $args
                $jaOk = (Test-Path -LiteralPath $task.JaSrt) -and ((Get-Item -LiteralPath $task.JaSrt).Length -gt 0)
                if ($code -eq 0 -and $jaOk) { $ok = $true; break }
                if (-not $jaOk -and (Test-Path -LiteralPath $task.JaSrt)) {
                    # 失败时可能留下空文件，清掉以便下一次重试真正重跑
                    Remove-Item -LiteralPath $task.JaSrt -Force -ErrorAction SilentlyContinue
                }
                $lastError = ("01 退出码 {0}，ja.srt 有效={1}" -f $code, $jaOk)
            } catch {
                $lastError = $_.Exception.Message
            }
        }
        $elapsed = ((Get-Date) - $start).TotalSeconds
        if ($ok) {
            Set-TaskStage -Key $task.Key -Stage 'transcribe' -Status 'done' -Seconds $elapsed -Error ''
            if ($OutputBesideSource) {
                if (-not (Test-Path -LiteralPath $task.MirrorDir)) { New-Item -ItemType Directory -Path $task.MirrorDir -Force | Out-Null }
                Copy-Item -LiteralPath $task.JaSrt -Destination $task.MirrorJa -Force -ErrorAction SilentlyContinue
                $srcReport = Join-Path $task.OutDir 'transcribe-report.json'
                if (Test-Path -LiteralPath $srcReport) {
                    Copy-Item -LiteralPath $srcReport -Destination (Join-Path $task.MirrorDir 'transcribe-report.json') -Force -ErrorAction SilentlyContinue
                }
            }
            if (($stagedPath -ne '') -and (-not $KeepStaged) -and (Test-Path -LiteralPath $stagedPath)) {
                Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
            }
            Write-Ok ("[{0}/{1}] 听写完成：{2}（{3}）" -f $index, $tasks.Count, $task.Key, (Format-Elapsed -Seconds $elapsed))
        } else {
            Set-TaskStage -Key $task.Key -Stage 'transcribe' -Status 'failed' -Seconds $elapsed -Error $lastError
            $failures += [PSCustomObject]@{ Key = $task.Key; Stage = 'transcribe'; Reason = $lastError }
            Write-Err ("[{0}/{1}] 听写失败：{2}（{3}）" -f $index, $tasks.Count, $task.Key, $lastError)
        }
        $doneCount++
        $elapsedSum += $elapsed
        $avg = $elapsedSum / $doneCount
        $remainSec = $avg * ($tasks.Count - $index)
        Write-Info ("  总进度 {0}/{1}，本视频 {2}，预计剩余 {3}" -f $index, $tasks.Count,
            (Format-Elapsed -Seconds $elapsed), (Format-Elapsed -Seconds $remainSec))
    }
} else {
    Write-Warn '已跳过听写阶段（-SkipTranscribe）。'
}

# ---------- 阶段 2：统一翻译（只启动一次 llama-server） ----------
# 输出到源目录时：Python 侧只在本地 output/<key>/ 读写，阶段结束后再用 PowerShell 复制到源目录
# （避免 Python 在移动盘/网络盘的长 Unicode 路径上写文件失败或卡死）
$scanRoot = $outputRoot
if (-not $SkipTranslate) {
    Write-Section '阶段 2/3：批量翻译（02-translate.ps1，单服务实例）'
    $pending = @($tasks | Where-Object {
        $ja = if ($OutputBesideSource) { $_.MirrorJa } else { $_.JaSrt }
        $zh = if ($OutputBesideSource) { $_.MirrorZh } else { $_.ZhSrt }
        (Test-Path -LiteralPath $ja) -and (($Force) -or (-not (Test-Path -LiteralPath $zh)))
    })
    if ($pending.Count -eq 0) {
        Write-Ok '没有待翻译的视频（均已有 zh.srt）。'
    } else {
        Write-Info ("待翻译 {0} 个目录，启动一次 llama-server 批量处理……" -f $pending.Count)
        $start = Get-Date
        $args = @('-InputDir', $scanRoot, '-Config', $configPath)
        if ($Force) { $args += '-Force' }
        if (-not [string]::IsNullOrWhiteSpace($PythonExe)) { $args += @('-PythonExe', $PythonExe) }
        $code = Invoke-ChildScript -ScriptName '02-translate.ps1' -Arguments $args
        $elapsed = ((Get-Date) - $start).TotalSeconds
        foreach ($task in $pending) {
            $zh = if ($OutputBesideSource) { $task.MirrorZh } else { $task.ZhSrt }
            if (Test-Path -LiteralPath $zh) {
                Set-TaskStage -Key $task.Key -Stage 'translate' -Status 'done' -Seconds 0 -Error ''
                if ($OutputBesideSource) { Copy-MirrorToSource -Task $task }
            } else {
                Set-TaskStage -Key $task.Key -Stage 'translate' -Status 'failed' -Seconds 0 -Error ("02 退出码 {0}，未生成 zh.srt" -f $code)
                $failures += [PSCustomObject]@{ Key = $task.Key; Stage = 'translate'; Reason = ("02 退出码 {0}" -f $code) }
            }
        }
        if ($code -eq 0) { Write-Ok ("翻译阶段完成（{0}）" -f (Format-Elapsed -Seconds $elapsed)) }
        else { Write-Warn ("翻译阶段结束，退出码 {0}，详见上方日志。" -f $code) }
    }
} else {
    Write-Warn '已跳过翻译阶段（-SkipTranslate）。'
}

# ---------- 阶段 3：合并双语 + 质检 ----------
if (-not $SkipMerge) {
    Write-Section '阶段 3/3：批量合并 + 质检（03-bilingual.ps1）'
    $pending = @($tasks | Where-Object {
        $ja = if ($OutputBesideSource) { $_.MirrorJa } else { $_.JaSrt }
        $zh = if ($OutputBesideSource) { $_.MirrorZh } else { $_.ZhSrt }
        $rep = if ($OutputBesideSource) { $_.MirrorReport } else { $_.Report }
        (Test-Path -LiteralPath $ja) -and (Test-Path -LiteralPath $zh) -and
        (($Force) -or (-not (Test-Path -LiteralPath $rep)))
    })
    if ($pending.Count -eq 0) {
        Write-Ok '没有待合并的视频（均已有 report.json）。'
    } else {
        Write-Info ("待合并 {0} 个目录……" -f $pending.Count)
        $start = Get-Date
        $args = @('-InputDir', $scanRoot, '-Config', $configPath)
        if ($Force) { $args += '-Force' }
        if (-not [string]::IsNullOrWhiteSpace($PythonExe)) { $args += @('-PythonExe', $PythonExe) }
        $code = Invoke-ChildScript -ScriptName '03-bilingual.ps1' -Arguments $args
        $elapsed = ((Get-Date) - $start).TotalSeconds
        foreach ($task in $pending) {
            $rep = if ($OutputBesideSource) { $task.MirrorReport } else { $task.Report }
            $bi = if ($OutputBesideSource) { $task.MirrorBi } else { $task.BiSrt }
            if ((Test-Path -LiteralPath $rep) -and (Test-Path -LiteralPath $bi)) {
                Set-TaskStage -Key $task.Key -Stage 'merge' -Status 'done' -Seconds 0 -Error ''
                if ($OutputBesideSource) { Copy-MirrorToSource -Task $task }
            } else {
                Set-TaskStage -Key $task.Key -Stage 'merge' -Status 'failed' -Seconds 0 -Error ("03 退出码 {0}" -f $code)
                $failures += [PSCustomObject]@{ Key = $task.Key; Stage = 'merge'; Reason = ("03 退出码 {0}" -f $code) }
            }
        }
        if ($code -eq 0) { Write-Ok ("合并质检阶段完成（{0}）" -f (Format-Elapsed -Seconds $elapsed)) }
        else { Write-Warn ("合并质检阶段结束，退出码 {0}（可能是质检 error），详见 report.json。" -f $code) }
    }
} else {
    Write-Warn '已跳过合并阶段（-SkipMerge）。'
}

# ---------- 汇总 ----------
Write-Section '批量汇总'
$done = 0; $failed = 0
foreach ($task in $tasks) {
    $entry = $stateTasks[$task.Key]
    $allDone = ($entry.stages.transcribe -eq 'done') -and ($entry.stages.translate -eq 'done') -and ($entry.stages.merge -eq 'done')
    if ($allDone) { $done++ } else { $failed++ }
    $taskState = if ($allDone) { '完成' } else { '未完成' }
    Write-Host ("  - {0}：{1}（听写={2} 翻译={3} 合并={4}）" -f $task.Key, $taskState, $entry.stages.transcribe, $entry.stages.translate, $entry.stages.merge) -ForegroundColor $(if ($allDone) { 'Green' } else { 'Yellow' })
}
Write-Host ("完成 {0} 个 | 未完成 {1} 个" -f $done, $failed) -ForegroundColor Cyan
Write-Info ("状态文件：{0}" -f $StateFile)
if ($script:LogFile) { Write-Info ("日志：{0}" -f $script:LogFile) }
if ($failed -gt 0) {
    Write-Err '存在未完成任务；修复后重跑同一命令即可从断点继续（已完成的会跳过）。'
    exit 1
}
Write-Ok '全部任务完成。'
exit 0
