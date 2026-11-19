# -*- coding: utf-8 -*-
<#
02-translate.ps1 —— 日译中：启动 llama-server（Vulkan/SYCL）→ 调 Python 逐句翻译 → 关闭服务

功能要点：
- 自动启动 llama-server 并等待 /health 就绪（超时/进程早退会给出中文诊断）；
- 检测到已有健康的 llama-server 时自动复用；也可用 -ServerUrl 指定；
- -Mock：完全离线（不启动服务、不调接口），用 Python 内置伪译文验证链路；
- 断点续跑：同目录已存在 zh.srt 时跳过，-Force 强制重新翻译。

用法（在项目根下）：
    .\scripts\windows\02-translate.ps1 -InputDir .\output\xxx
    .\scripts\windows\02-translate.ps1 -InputDir .\output                # 递归处理所有 ja.srt
    .\scripts\windows\02-translate.ps1 -InputDir .\output\xxx -ServerUrl http://127.0.0.1:8080
    .\scripts\windows\02-translate.ps1 -InputDir .\output\xxx -Mock      # 离线链路验证

产物：同目录下 zh.srt、bilingual.srt、translate-report.json
退出码：
    0  全部成功（含跳过）
    1  有文件翻译失败/部分失败（产物可能仍已写出）
    2  无输入、配置错误或服务启动失败
#>

[CmdletBinding()]
param(
    [Alias('InputPath', 'InputFile')][string]$InputDir = '',
    [string]$Config = '',
    [string]$ServerUrl = '',
    [switch]$Force,
    [switch]$Mock,
    [string]$PythonExe = '',
    [switch]$NoServerStart,
    [switch]$SkipHealthCheck,
    [int]$StartupTimeoutSec = 0
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WindowsScriptRoot = $PSScriptRoot
$ScriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot '_common.ps1')

function ConvertTo-ApiBase {
    param([string]$Value)
    $trimmed = $Value.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return '' }
    if ($trimmed.EndsWith('/v1')) { return $trimmed }
    return ($trimmed + '/v1')
}

function Get-HealthUrlFromApiBase {
    param([string]$ApiBase)
    $root = $ApiBase.Trim().TrimEnd('/')
    if ($root.EndsWith('/v1')) { $root = $root.Substring(0, $root.Length - 3) }
    return ($root.TrimEnd('/') + '/health')
}

function Test-PortListening {
    param([int]$Port)
    if ($null -eq (Get-Command -Name Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return $null }
    try {
        $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
        return ($listeners.Count -gt 0)
    } catch {
        return $null
    }
}

Write-Section '02 中日翻译（llama-server + translate_srt.py）'

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
    Initialize-Log -Directory $logsDir -Prefix 'translate' | Out-Null
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
$pythonScript = Join-Path $ScriptsRoot 'python/translate_srt.py'
if (-not (Test-Path -LiteralPath $pythonScript)) {
    Write-Err ("找不到 Python 翻译脚本：{0}。请确认 scripts/python/ 目录完整。" -f $pythonScript)
    exit 2
}

try {
    $jaFiles = @(Get-JaSrtFiles -Path $targetInput -Recurse)
} catch {
    Write-Err $_.Exception.Message
    exit 2
}
if ($jaFiles.Count -eq 0) {
    Write-Err ("输入路径下没有找到 ja.srt：{0}" -f $targetInput)
    Write-Err '02-translate.ps1 的 -InputDir 应指向 output\<视频名>\（含 ja.srt），或指向 output\ 递归处理；也可以先运行 01-transcribe.ps1。'
    exit 2
}

Write-Info ("配置文件：{0}" -f $configPath)
Write-Info ("Python：{0}" -f $pythonPath)
Write-Info ("待翻译日文字幕：{0} 个" -f $jaFiles.Count)
Write-Info ("模式：{0}" -f ($(if ($Mock) { '离线模拟（不启动 llama-server）' } else { '真实翻译（OpenAI 兼容接口）' })))

$apiBase = ''
$healthUrl = ''
$llamaHost = [string](Get-Cfg -Config $cfg -Path 'llama.host' -Default '127.0.0.1')
$llamaPort = [int](Get-Cfg -Config $cfg -Path 'llama.port' -Default 8080)
$startupTimeout = $StartupTimeoutSec
if ($startupTimeout -le 0) {
    $startupTimeout = [int](Get-Cfg -Config $cfg -Path 'llama.startup_timeout_sec' -Default 180)
}
$serverProcess = $null
$startedByUs = $false
$fatalError = ''
$successCount = 0
$skippedCount = 0
$failedCount = 0
$partialCount = 0
$failures = @()

try {
    # ---------- 服务准备（Mock 模式跳过） ----------
    if (-not $Mock) {
        $serverUrlFromParam = -not [string]::IsNullOrWhiteSpace($ServerUrl)
        $serverUrlFromConfig = [string](Get-Cfg -Config $cfg -Path 'llama.server_url' -Default '')
        $externalServer = $serverUrlFromParam -or (-not [string]::IsNullOrWhiteSpace($serverUrlFromConfig))

        if ($serverUrlFromParam) {
            $apiBase = ConvertTo-ApiBase $ServerUrl
        } elseif (-not [string]::IsNullOrWhiteSpace($serverUrlFromConfig)) {
            $apiBase = ConvertTo-ApiBase $serverUrlFromConfig
        } else {
            $apiBase = ConvertTo-ApiBase ([string](Get-Cfg -Config $cfg -Path 'translate.api_base' -Default ('http://' + $llamaHost + ':' + $llamaPort + '/v1')))
        }
        $healthUrl = Get-HealthUrlFromApiBase $apiBase
        Write-Info ("接口地址：{0}（健康检查：{1}）" -f $apiBase, $healthUrl)

        if ($externalServer) {
            Write-Info '使用外部/已有 llama-server 地址，不启动新进程。'
            if (-not $SkipHealthCheck) {
                try {
                    Wait-HttpReady -Url $healthUrl -TimeoutSec 30 -ServerLabel 'llama-server'
                    Write-Ok ("[复用] 外部 llama-server 健康检查通过：{0}" -f $healthUrl)
                } catch {
                    throw ("外部 llama-server 不可用：{0}" -f $_.Exception.Message)
                }
            } else {
                Write-Warn '已按 -SkipHealthCheck 跳过服务健康检查。'
            }
        } elseif ($NoServerStart) {
            Write-Warn '已指定 -NoServerStart：不启动服务，直接调用接口（请确认服务已在运行）。'
        } else {
            $reuseExisting = $false
            if (-not $SkipHealthCheck) {
                if (Test-HttpOk -Url $healthUrl -TimeoutSec 5) {
                    $reuseExisting = $true
                    Write-Ok ("[复用] 检测到已在运行的 llama-server：{0}" -f $healthUrl)
                }
            }
            if ($reuseExisting) {
                # 复用现有服务，无需启动
            } else {
                $portListening = Test-PortListening -Port $llamaPort
                if ($portListening -eq $true) {
                    throw ("端口 {0} 已被占用，但健康检查未通过（{1}）。请先关闭占用该端口的进程，或改用 -ServerUrl 指定其他服务地址。" -f $llamaPort, $healthUrl)
                }

                $llamaConfigured = [string](Get-Cfg -Config $cfg -Path 'tools.llama_server' -Default 'tools/windows/llama/llama-server.exe')
                $llamaExe = Find-ToolExecutable -Configured $llamaConfigured -CommandName 'llama-server'
                if (-not $llamaExe.Found) {
                    throw ("未找到 llama-server（配置值：{0}）。请把 llama.cpp 的 Windows Vulkan/SYCL 预编译解压到 tools/windows/llama/（详见 tools/README.md）。" -f $llamaConfigured)
                }
                $translationModel = Get-RequiredPath -Configured ([string](Get-Cfg -Config $cfg -Path 'models.translation' -Default 'models/translation/sakura-7b-*.gguf')) `
                    -Label '日译中翻译模型' -FixHint '检查 models/translation/ 下的 GGUF 是否已随硬盘拷贝（models/README.md）；配置支持通配符。'

                $nGpuLayers = [int](Get-Cfg -Config $cfg -Path 'llama.n_gpu_layers' -Default 99)
                $ctxSize = [int](Get-Cfg -Config $cfg -Path 'llama.ctx_size' -Default 4096)
                $llamaThreads = [int](Get-Cfg -Config $cfg -Path 'llama.threads' -Default 8)
                $llamaExtra = Get-CfgArray -Config $cfg -Path 'llama.extra_args'

                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $serverOutLog = Join-Path $logsDir ("llama-server-stdout-" + $stamp + ".log")
                $serverErrLog = Join-Path $logsDir ("llama-server-stderr-" + $stamp + ".log")
                $startArguments = @(
                    '-m', $translationModel,
                    '--host', $llamaHost,
                    '--port', [string]$llamaPort,
                    '-ngl', [string]$nGpuLayers,
                    '-c', [string]$ctxSize,
                    '-t', [string]$llamaThreads
                )
                if ($llamaExtra.Count -gt 0) { $startArguments += $llamaExtra }
                $quotedArguments = ($startArguments | ForEach-Object { Format-StartArgument ([string]$_) }) -join ' '

                Write-Step ("启动 llama-server：{0}" -f $llamaExe.Path)
                Write-Info ("  模型：{0}" -f $translationModel)
                Write-Info ("  参数：-ngl {0} -c {1} -t {2} 端口 {3}" -f $nGpuLayers, $ctxSize, $llamaThreads, $llamaPort)
                $serverProcess = Start-Process -FilePath $llamaExe.Path -ArgumentList $quotedArguments `
                    -WorkingDirectory $ProjectRoot -PassThru -NoNewWindow `
                    -RedirectStandardOutput $serverOutLog -RedirectStandardError $serverErrLog
                $startedByUs = $true
                Write-Info ("  PID={0}；等待 /health 就绪（超时 {1} 秒，模型加载可能需要数分钟）……" -f $serverProcess.Id, $startupTimeout)
                Wait-HttpReady -Url $healthUrl -TimeoutSec $startupTimeout -Process $serverProcess `
                    -LogPath $serverErrLog -ServerLabel 'llama-server'
                Write-Ok ("llama-server 已就绪：{0}" -f $healthUrl)
                Write-Info ("  服务日志：{0} / {1}" -f $serverOutLog, $serverErrLog)
            }
        }
    } else {
        $apiBase = ConvertTo-ApiBase ([string](Get-Cfg -Config $cfg -Path 'translate.api_base' -Default 'http://127.0.0.1:8080/v1'))
        Write-Warn '离线模拟模式：不启动 llama-server、不访问网络。译文为固定伪中文，仅用于验证文件链路。'
    }

    # ---------- 逐个翻译 ----------
    foreach ($jaFile in $jaFiles) {
        $outDir = Split-Path -Parent $jaFile.FullName
        $zhFile = Join-Path $outDir 'zh.srt'
        if ((Test-Path -LiteralPath $zhFile) -and (-not $Force)) {
            Write-Ok ("[跳过] 已存在 {0}（需要重跑加 -Force）" -f $zhFile)
            $skippedCount++
            continue
        }

        try {
            Write-Step ("翻译：{0}" -f $jaFile.FullName)
            $pythonArguments = @(
                $pythonScript,
                '--input', $jaFile.FullName,
                '--output-dir', $outDir,
                '--config', $configPath,
                '--report', 'translate-report.json'
            )
            if ($Mock) {
                $pythonArguments += @('--mock')
            } else {
                $pythonArguments += @('--api-base', $apiBase)
            }
            if ($SkipHealthCheck) {
                $pythonArguments += @('--no-health-check')
            }
            $exitCode = Invoke-Native -Exe $pythonPath -Arguments $pythonArguments -LogPath $script:LogFile
            if ($exitCode -eq 0) {
                $successCount++
                Write-Ok ("[完成] {0}" -f $zhFile)
            } elseif ($exitCode -eq 2) {
                $partialCount++
                $failedCount++
                Write-Warn ("[部分失败] {0}：部分句翻译失败已回退原文（退出码 2，详见 translate-report.json）" -f $zhFile)
                $failures += [PSCustomObject]@{ File = $jaFile.FullName; Reason = '部分句翻译失败（已回退原文）' }
            } else {
                $failedCount++
                Write-Err ("[失败] {0}：Python 翻译脚本退出码 {1}" -f $jaFile.FullName, $exitCode)
                $failures += [PSCustomObject]@{ File = $jaFile.FullName; Reason = ("翻译脚本退出码 " + $exitCode) }
            }
        } catch {
            $failedCount++
            $reason = $_.Exception.Message
            Write-Err ("[失败] {0}：{1}" -f $jaFile.FullName, $reason)
            $failures += [PSCustomObject]@{ File = $jaFile.FullName; Reason = $reason }
        }
    }
} catch {
    $fatalError = $_.Exception.Message
} finally {
    if ($startedByUs -and ($null -ne $serverProcess)) {
        Stop-ServerProcess -Process $serverProcess -Label 'llama-server'
    }
}

if (-not [string]::IsNullOrWhiteSpace($fatalError)) {
    Write-Err ("翻译流程中止：{0}" -f $fatalError)
    Write-Info '排查建议：先运行 .\scripts\windows\00-check-env.ps1；确认 llama-server/模型/显存/端口；也可用 -ServerUrl 指定已运行服务。'
    if ($script:LogFile) { Write-Info ("日志：{0}" -f $script:LogFile) }
    exit 2
}

# ---------- 汇总 ----------
Write-Section '翻译汇总'
Write-Host ("成功 {0} 个 | 跳过 {1} 个 | 部分失败 {2} 个 | 失败 {3} 个" -f `
    $successCount, $skippedCount, $partialCount, $failedCount) -ForegroundColor Cyan
Write-LogLine ("翻译汇总：成功 {0} | 跳过 {1} | 部分失败 {2} | 失败 {3}" -f `
    $successCount, $skippedCount, $partialCount, $failedCount)
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host '失败清单：' -ForegroundColor Red
    foreach ($item in $failures) {
        Write-Host ("  - {0}：{1}" -f $item.File, $item.Reason) -ForegroundColor Red
    }
}
if ($script:LogFile) { Write-Info ("日志：{0}" -f $script:LogFile) }
if ($failedCount -gt 0) { exit 1 }
Write-Ok '翻译全部完成。产物：zh.srt / bilingual.srt / translate-report.json'
exit 0
