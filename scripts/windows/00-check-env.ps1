# -*- coding: utf-8 -*-
<#
00-check-env.ps1 —— 目标机环境自检（ffmpeg / whisper-cli / llama-server / 模型 / Python / 显卡 / 端口）

用法（在项目根下）：
    .\scripts\windows\00-check-env.ps1
    .\scripts\windows\00-check-env.ps1 -Config config/pipeline.json
    .\scripts\windows\00-check-env.ps1 -SkipGpu

退出码：
    0  关键项全部通过（允许警告项）
    1  存在 FAIL 项（或配置文件不可用）

说明：本脚本只在 Windows 目标机上做真实检查。准备机（macOS）上运行时，工具/显卡等项
会如实报 FAIL/WARN，这是预期行为（准备机不放 tools/windows 也不放模型）。
#>

[CmdletBinding()]
param(
    [string]$Config = '',
    [string]$PythonExe = '',
    [switch]$SkipGpu,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WindowsScriptRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot '_common.ps1')

$script:Results = @()

function Add-Result {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = '',
        [string]$FixHint = ''
    )
    $script:Results += [PSCustomObject]@{
        Name = $Name
        Status = $Status
        Detail = $Detail
        FixHint = $FixHint
    }
}

function Invoke-QuickCheck {
    <# 快速执行一个命令行工具并截取首行输出；超时则杀进程。 #>
    param(
        [string]$ExePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutMs = 15000
    )
    $token = [Guid]::NewGuid().ToString('N')
    $stdout = Join-Path ([System.IO.Path]::GetTempPath()) ("localsub-check-" + $token + ".out")
    $stderr = Join-Path ([System.IO.Path]::GetTempPath()) ("localsub-check-" + $token + ".err")
    try {
        $process = Start-Process -FilePath $ExePath -ArgumentList $Arguments -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $finished = $process.WaitForExit($TimeoutMs)
        if (-not $finished) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
            return [PSCustomObject]@{ Ok = $false; ExitCode = -1; Output = '执行超时' }
        }
        $text = ''
        if (Test-Path -LiteralPath $stdout) {
            $text = [string](Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue)
        }
        if (Test-Path -LiteralPath $stderr) {
            $errText = [string](Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
            if (-not [string]::IsNullOrWhiteSpace($errText)) { $text = $text + "`n" + $errText }
        }
        $firstLine = ($text.Trim() -split "`n" | Select-Object -First 1)
        return [PSCustomObject]@{ Ok = ($process.ExitCode -eq 0); ExitCode = $process.ExitCode; Output = $firstLine }
    } catch {
        return [PSCustomObject]@{ Ok = $false; ExitCode = -1; Output = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $stdout -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue
    }
}

Write-Section '字幕流水线环境自检（00-check-env.ps1）'
Write-Info ("项目根：{0}" -f $ProjectRoot)
Write-Info ("PowerShell：{0}（{1}）" -f $PSVersionTable.PSVersion.ToString(), $PSVersionTable.PSEdition)

# ---------- 配置文件 ----------
$configInfo = $null
try {
    $configInfo = Get-PipelineConfig -ConfigPath $Config
    Add-Result '配置文件' 'PASS' $configInfo.Path
} catch {
    Write-Err ("配置文件不可用：{0}" -f $_.Exception.Message)
    Add-Result '配置文件' 'FAIL' $_.Exception.Message '先修复 config/pipeline.json（可从 config/pipeline.example.json 复制），再重新运行本脚本。'
}
if ($null -eq $configInfo) {
    Write-Err '环境自检中止：配置文件不可用，无法继续检查。'
    exit 1
}
$cfg = $configInfo.Data
$configPath = $configInfo.Path

# ---------- 日志 ----------
$logsDir = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.logs_dir' -Default 'logs'))
try {
    Initialize-Log -Directory $logsDir -Prefix 'check-env' | Out-Null
} catch {
    Write-Warn ("无法创建日志目录 {0}：{1}" -f $logsDir, $_.Exception.Message)
}

# ---------- PowerShell 版本 ----------
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Add-Result 'PowerShell 版本' 'FAIL' $PSVersionTable.PSVersion.ToString() `
        '请使用 Windows PowerShell 5.1 或 PowerShell 7+（Windows 11 自带 5.1）。'
} else {
    Add-Result 'PowerShell 版本' 'PASS' $PSVersionTable.PSVersion.ToString()
}

# ---------- 操作系统 ----------
if (Test-IsWindows) {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        Add-Result '操作系统' 'PASS' ("{0}（{1}）" -f $os.Caption, $os.Version)
    } catch {
        Add-Result '操作系统' 'WARN' ("无法读取系统信息：{0}" -f $_.Exception.Message)
    }
} else {
    Add-Result '操作系统' 'WARN' '当前不是 Windows，本脚本应在目标机 Windows 11 上运行（准备机运行属预期结果）。'
}

# ---------- 工具目录 ----------
$toolsDir = Resolve-FullPath -Relative 'tools/windows'
if (Test-Path -LiteralPath $toolsDir) {
    Add-Result '工具目录' 'PASS' $toolsDir
} else {
    Add-Result '工具目录' 'FAIL' ("不存在：{0}" -f $toolsDir) `
        '把 ffmpeg / whisper-cli / llama-server 及其 DLL 放入 tools/windows/ 下，详见 tools/README.md；或运行 .\scripts\windows\download-tools.ps1 查看下载指引。'
}

# ---------- ffmpeg ----------
$ffmpegConfigured = [string](Get-Cfg -Config $cfg -Path 'tools.ffmpeg' -Default 'tools/windows/ffmpeg/ffmpeg.exe')
$ffmpeg = Find-ToolExecutable -Configured $ffmpegConfigured -CommandName 'ffmpeg'
if ($ffmpeg.Found) {
    $check = Invoke-QuickCheck -ExePath $ffmpeg.Path -Arguments @('-version')
    if ($check.Ok) {
        Add-Result 'ffmpeg' 'PASS' ("{0} | {1}" -f $ffmpeg.Path, $check.Output)
    } else {
        Add-Result 'ffmpeg' 'WARN' ("已找到 {0}，但 -version 执行异常：{1}" -f $ffmpeg.Path, $check.Output) `
            '可能是压缩包没解完整（缺 DLL）。建议重新解压 gyan.dev / BtbN 的完整静态包。'
    }
} else {
    Add-Result 'ffmpeg' 'FAIL' ("未找到 ffmpeg（配置值：{0}，系统 PATH 也没有）" -f $ffmpegConfigured) `
        '下载 Windows 版 ffmpeg，把 ffmpeg.exe 放到 tools/windows/ffmpeg/。'
}

# ---------- whisper-cli ----------
$whisperConfigured = [string](Get-Cfg -Config $cfg -Path 'tools.whisper_cli' -Default 'tools/windows/whisper/whisper-cli.exe')
$whisper = Find-ToolExecutable -Configured $whisperConfigured -CommandName 'whisper-cli'
if ($whisper.Found) {
    $check = Invoke-QuickCheck -ExePath $whisper.Path -Arguments @('--help') -TimeoutMs 20000
    if ($check.Ok) {
        Add-Result 'whisper-cli' 'PASS' $whisper.Path
    } else {
        Add-Result 'whisper-cli' 'WARN' ("已找到 {0}，但 --help 返回码 {1}：{2}" -f $whisper.Path, $check.ExitCode, $check.Output) `
            '可能是词汇参数版本差异或缺少 Vulkan/DLL 依赖；请以实际听写日志为准，必要时换一份社区 Vulkan 构建。'
    }
} else {
    Add-Result 'whisper-cli' 'FAIL' ("未找到 whisper-cli（配置值：{0}）" -f $whisperConfigured) `
        '官方 whisper.cpp Windows 预编译只有 CPU 版；Vulkan 版需社区构建或自行编译，放到 tools/windows/whisper/。'
}

# ---------- llama-server ----------
$llamaConfigured = [string](Get-Cfg -Config $cfg -Path 'tools.llama_server' -Default 'tools/windows/llama/llama-server.exe')
$llama = Find-ToolExecutable -Configured $llamaConfigured -CommandName 'llama-server'
if ($llama.Found) {
    $check = Invoke-QuickCheck -ExePath $llama.Path -Arguments @('--version') -TimeoutMs 20000
    if ($check.Ok) {
        Add-Result 'llama-server' 'PASS' ("{0} | {1}" -f $llama.Path, $check.Output)
    } else {
        $helpCheck = Invoke-QuickCheck -ExePath $llama.Path -Arguments @('--help') -TimeoutMs 20000
        Add-Result 'llama-server' 'WARN' ("已找到 {0}，但 --version 返回码 {1}（--help 返回码 {2}）" -f $llama.Path, $check.ExitCode, $helpCheck.ExitCode) `
            '部分构建不支持 --version；若 --help 正常一般可用。请确认下载的是 Vulkan/SYCL 版并解压齐全 DLL。'
    }
} else {
    Add-Result 'llama-server' 'FAIL' ("未找到 llama-server（配置值：{0}）" -f $llamaConfigured) `
        '下载 llama.cpp 的 Windows Vulkan 预编译包（如 llama-b12405-bin-win-vulkan-x64.zip），解压全部文件到 tools/windows/llama/。'
}

# ---------- Python ----------
try {
    $pythonPath = Get-PythonCommand -Config $cfg -Override $PythonExe
    $check = Invoke-QuickCheck -ExePath $pythonPath -Arguments @('--version')
    $versionText = $check.Output
    $match = [regex]::Match($versionText, 'Python\s+(\d+)\.(\d+)')
    if ($match.Success) {
        $major = [int]$match.Groups[1].Value
        $minor = [int]$match.Groups[2].Value
        if ($major -ge 3 -and $minor -ge 8) {
            Add-Result 'Python' 'PASS' ("{0} | {1}" -f $pythonPath, $versionText)
        } else {
            Add-Result 'Python' 'FAIL' ("版本过低：{0}" -f $versionText) `
                '本项目要求 Python 3.8+（目标机建议 3.11 或 3.12，安装时勾选 Add python.exe to PATH）。'
        }
    } else {
        Add-Result 'Python' 'WARN' ("{0} 可执行，但无法解析版本：{1}" -f $pythonPath, $versionText)
    }
} catch {
    Add-Result 'Python' 'FAIL' $_.Exception.Message '安装 Python 3.11/3.12，或在 config/pipeline.json 的 tools.python 填写相对路径。'
}

# ---------- 模型 ----------
$whisperModelConfigured = [string](Get-Cfg -Config $cfg -Path 'models.whisper' -Default 'models/whisper/ggml-large-v3.bin')
try {
    $whisperModel = Get-RequiredPath -Configured $whisperModelConfigured -Label 'Whisper 听写模型' `
        -FixHint '模型由准备机预下载到 models/whisper/，详见 models/README.md。'
    $sizeGb = [Math]::Round((Get-Item -LiteralPath $whisperModel).Length / 1GB, 2)
    Add-Result 'Whisper 模型' 'PASS' ("{0}（{1} GB）" -f $whisperModel, $sizeGb)
} catch {
    Add-Result 'Whisper 模型' 'FAIL' $_.Exception.Message '检查 models/ 是否已随硬盘拷贝；文件名是否与配置一致。'
}

$vadEnabled = Get-Cfg -Config $cfg -Path 'whisper.vad' -Default $true
if ($vadEnabled) {
    $vadConfigured = [string](Get-Cfg -Config $cfg -Path 'models.vad' -Default 'models/whisper/ggml-silero-v5.1.2.bin')
    try {
        $vadModel = Get-RequiredPath -Configured $vadConfigured -Label 'Silero VAD 模型' `
            -FixHint '若不需要 VAD，可把 config/pipeline.json 的 whisper.vad 改为 false。'
        Add-Result 'VAD 模型' 'PASS' $vadModel
    } catch {
        Add-Result 'VAD 模型' 'FAIL' $_.Exception.Message '把 ggml-silero-v5.1.2.bin 放到 models/whisper/，或关闭 whisper.vad。'
    }
} else {
    Add-Result 'VAD 模型' 'PASS' '配置中已关闭 VAD，无需 VAD 模型。'
}

$translationConfigured = [string](Get-Cfg -Config $cfg -Path 'models.translation' -Default 'models/translation/sakura-7b-*.gguf')
try {
    $translationModel = Get-RequiredPath -Configured $translationConfigured -Label '日译中翻译模型' -AllowGlob `
        -FixHint '模型由准备机预下载到 models/translation/，详见 models/README.md；可用通配符配置。'
    $sizeGb = [Math]::Round((Get-Item -LiteralPath $translationModel).Length / 1GB, 2)
    Add-Result '翻译模型' 'PASS' ("{0}（{1} GB）" -f $translationModel, $sizeGb)
} catch {
    Add-Result '翻译模型' 'FAIL' $_.Exception.Message '检查 models/translation/ 下是否有 Sakura/GalTransl GGUF 文件。'
}

# ---------- 磁盘空间 ----------
try {
    $drive = Get-PSDrive -PSProvider FileSystem |
        Where-Object { $ProjectRoot.StartsWith($_.Root, [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object { $_.Root.Length } -Descending |
        Select-Object -First 1
    if ($null -ne $drive) {
        $freeGb = [Math]::Round($drive.Free / 1GB, 1)
        if ($freeGb -ge 10) {
            Add-Result '磁盘空间' 'PASS' ("{0} 剩余 {1} GB" -f $drive.Root, $freeGb)
        } else {
            Add-Result '磁盘空间' 'WARN' ("{0} 仅剩 {1} GB" -f $drive.Root, $freeGb) `
                '输出字幕与中间 wav 需要空间；建议至少保留 10 GB，可清理 work/ 与旧日志。'
        }
    } else {
        Add-Result '磁盘空间' 'WARN' '无法定位项目所在分区。'
    }
} catch {
    Add-Result '磁盘空间' 'WARN' ("读取磁盘空间失败：{0}" -f $_.Exception.Message)
}

# ---------- 显卡（Intel Arc / Vulkan） ----------
if ($SkipGpu) {
    Add-Result '显卡/显存' 'WARN' '已通过 -SkipGpu 跳过检测。'
} elseif (-not (Test-IsWindows)) {
    Add-Result '显卡/显存' 'WARN' '当前不是 Windows，无法探测显卡（准备机预期结果）。请在目标机上重新运行。'
} else {
    try {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            ForEach-Object { $_.Name })
        if ($gpus.Count -eq 0) {
            Add-Result '显卡/显存' 'WARN' '未检测到显示适配器。'
        } else {
            $names = ($gpus -join '；')
            if ($names -match 'Arc') {
                Add-Result '显卡/显存' 'PASS' ("检测到 Intel Arc：{0}" -f $names)
            } elseif ($names -match 'Intel') {
                Add-Result '显卡/显存' 'WARN' ("检测到 Intel 显卡但名称未含 Arc：{0}，请确认是 Arc A770 且驱动为最新版。" -f $names)
            } else {
                Add-Result '显卡/显存' 'WARN' ("显示适配器：{0}。本方案 GPU 加速依赖 Intel Vulkan/SYCL，不使用 CUDA。" -f $names)
            }
        }
    } catch {
        Add-Result '显卡/显存' 'WARN' ("读取显卡信息失败：{0}" -f $_.Exception.Message)
    }
}

# ---------- llama-server 端口 ----------
$port = [int](Get-Cfg -Config $cfg -Path 'llama.port' -Default 8080)
$hasNetCmd = $null -ne (Get-Command -Name Get-NetTCPConnection -ErrorAction SilentlyContinue)
if (-not $hasNetCmd) {
    Add-Result 'llama 端口' 'WARN' ("无法检查端口 {0}（仅 Windows 支持）；02-translate.ps1 启动前会自行检查。" -f $port)
} else {
    try {
        $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
        if ($null -eq $listeners) { $listeners = @() }
        if ($listeners.Count -gt 0) {
            Add-Result 'llama 端口' 'WARN' ("端口 {0} 已被占用" -f $port) `
                '若已有 llama-server 在运行，02-translate.ps1 会自动复用；否则先关闭占用进程或改 config/pipeline.json 的 llama.port。'
        } else {
            Add-Result 'llama 端口' 'PASS' ("端口 {0} 空闲" -f $port)
        }
    } catch {
        Add-Result 'llama 端口' 'WARN' ("端口 {0} 状态未知：{1}" -f $port, $_.Exception.Message)
    }
}

# ---------- 读写权限与目录 ----------
try {
    foreach ($relative in @([string](Get-Cfg -Config $cfg -Path 'paths.output_dir' -Default 'output'),
                            [string](Get-Cfg -Config $cfg -Path 'paths.work_dir' -Default 'work'),
                            [string](Get-Cfg -Config $cfg -Path 'paths.logs_dir' -Default 'logs'))) {
        $dir = Resolve-FullPath -Relative $relative
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    $probe = Join-Path $logsDir ('.write-probe-' + [Guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($probe, 'probe')
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    Add-Result '读写权限' 'PASS' 'output/ work/ logs/ 可创建可写入。'
} catch {
    Add-Result '读写权限' 'FAIL' $_.Exception.Message '确认项目目录不是只读；移动硬盘 NTFS 是否已正确挂载。'
}

# ---------- 输入目录 ----------
$inputDir = Resolve-FullPath -Relative ([string](Get-Cfg -Config $cfg -Path 'paths.input_dir' -Default 'input'))
if (Test-Path -LiteralPath $inputDir) {
    $mediaFiles = @(Get-InputMediaFiles -Path $inputDir -Extensions (Get-CfgArray -Config $cfg -Path 'input_extensions'))
    if ($mediaFiles.Count -gt 0) {
        Add-Result '输入目录' 'PASS' ("{0}（找到 {1} 个音视频文件）" -f $inputDir, $mediaFiles.Count)
    } else {
        Add-Result '输入目录' 'WARN' ("{0} 目前没有音视频文件" -f $inputDir) '把待处理视频放入 input/ 后再运行 01/run-all。'
    }
} else {
    Add-Result '输入目录' 'WARN' ("输入目录不存在：{0}" -f $inputDir) '创建 input/，或把待处理视频放进去。'
}

# ---------- 输出报告 ----------
Write-Section '自检结果'
foreach ($item in $script:Results) {
    $color = 'Green'
    if ($item.Status -eq 'WARN') { $color = 'Yellow' }
    if ($item.Status -eq 'FAIL') { $color = 'Red' }
    if (-not $Quiet) {
        Write-Host ("[{0}] {1}：{2}" -f $item.Status, $item.Name, $item.Detail) -ForegroundColor $color
        Write-LogLine ("[{0}] {1}：{2}" -f $item.Status, $item.Name, $item.Detail)
    }
}

$passed = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$warned = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
Write-Host ''
Write-Host ("汇总：通过 {0} 项 | 警告 {1} 项 | 失败 {2} 项" -f $passed, $warned, $failed) -ForegroundColor Cyan
Write-LogLine ("汇总：通过 {0} 项 | 警告 {1} 项 | 失败 {2} 项" -f $passed, $warned, $failed)

if ($failed -gt 0) {
    Write-Host ''
    Write-Host '需要修复的问题：' -ForegroundColor Red
    foreach ($item in @($script:Results | Where-Object { $_.Status -eq 'FAIL' })) {
        Write-Host ("  - {0}：{1}" -f $item.Name, $item.FixHint) -ForegroundColor Red
        Write-LogLine ("修复提示 {0}：{1}" -f $item.Name, $item.FixHint)
    }
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '可运行 .\scripts\windows\download-tools.ps1 查看工具与模型的下载指引。' -ForegroundColor Yellow
    }
    exit 1
}

if ($warned -gt 0) {
    Write-Warn '存在警告项（不阻塞主流程，但建议逐项确认）。'
}
Write-Ok '环境自检通过：可以继续运行 01-transcribe.ps1 / run-all.ps1。'
if ($script:LogFile) { Write-Info ("日志：{0}" -f $script:LogFile) }
exit 0
