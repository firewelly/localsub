# -*- coding: utf-8 -*-
<#
download-tools.ps1 —— 缺失工具/模型的下载指引（不自动下载，只输出可照做的步骤与来源）

设计说明：目标机（Windows 11 + Intel Arc A770，无 CUDA）可能网络受限，且二进制/模型体积大、
来源与许可证需要人工确认，因此本脚本不做静默下载，只负责：
1) 检查当前配置路径下哪些工具/模型已就位（-CheckOnly）；
2) 按组件输出官方/镜像下载地址、资产名、解压后的相对目录、版本注意事项与校验方法；
3) 说明代理与 GitCode/HF 镜像的可用渠道；推荐“准备机预下载 + 随移动硬盘搬迁”的离线路径。

用法（在项目根下）：
    .\scripts\windows\download-tools.ps1                    # 输出全部下载指引
    .\scripts\windows\download-tools.ps1 -Component llama   # 只看某一类
    .\scripts\windows\download-tools.ps1 -CheckOnly         # 只检查本地是否就位（缺项退出码 1）
    .\scripts\windows\download-tools.ps1 -Open              # 同时用浏览器打开官方下载页

退出码：
    0  指引输出完成 / -CheckOnly 时所需组件齐全
    1  -CheckOnly 模式下存在缺失组件
    2  配置不可用
#>

[CmdletBinding()]
param(
    [ValidateSet('all', 'ffmpeg', 'whisper', 'llama', 'python', 'models')]
    [string[]]$Component = @('all'),
    [switch]$CheckOnly,
    [switch]$Open,
    [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WindowsScriptRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot '_common.ps1')

function Test-ComponentSelected {
    param([string]$Name)
    return (($Component -contains 'all') -or ($Component -contains $Name))
}

function Write-Link {
    param([string]$Label, [string]$Url)
    Write-Host ("    下载页：{0}" -f $Url) -ForegroundColor DarkCyan
    if ($Open -and (Test-IsWindows)) {
        try {
            Start-Process $Url | Out-Null
        } catch {
            Write-Warn ("打开浏览器失败：{0}" -f $_.Exception.Message)
        }
    }
}

Write-Section '工具与模型下载指引（download-tools.ps1）'
Write-Info '本脚本不会自动下载（体积大、来源与许可证需人工确认）；请按下列步骤手动放置文件。'
Write-Info '推荐路径：先在准备机上下载好，随移动硬盘整体搬到目标机；目标机只需离线放置。'

# ---------- 配置 ----------
try {
    $configInfo = Get-PipelineConfig -ConfigPath $Config
} catch {
    Write-Err ("配置读取失败：{0}" -f $_.Exception.Message)
    exit 2
}
$cfg = $configInfo.Data
$configPath = $configInfo.Path
$toolsRoot = Resolve-FullPath -Relative 'tools/windows'
$modelsRoot = Resolve-FullPath -Relative 'models'

Write-Info ("配置文件：{0}" -f $configPath)
Write-Info ("工具目录：{0}" -f $toolsRoot)
Write-Info ("模型目录：{0}" -f $modelsRoot)

# ---------- -CheckOnly：只检查 ----------
if ($CheckOnly) {
    Write-Section '本地就位检查'
    $missing = 0
    $checks = @()

    $ffmpegConfigured = [string](Get-Cfg -Config $cfg -Path 'tools.ffmpeg' -Default 'tools/windows/ffmpeg/ffmpeg.exe')
    $checks += [PSCustomObject]@{
        Category = 'ffmpeg'
        Label = 'ffmpeg'
        Result = (Find-ToolExecutable -Configured $ffmpegConfigured -CommandName 'ffmpeg')
        Hint = '放到 tools/windows/ffmpeg/ffmpeg.exe'
    }
    $whisperConfigured = [string](Get-Cfg -Config $cfg -Path 'tools.whisper_cli' -Default 'tools/windows/whisper/whisper-cli.exe')
    $checks += [PSCustomObject]@{
        Category = 'whisper'
        Label = 'whisper-cli'
        Result = (Find-ToolExecutable -Configured $whisperConfigured -CommandName 'whisper-cli')
        Hint = '放到 tools/windows/whisper/whisper-cli.exe（含 DLL）'
    }
    $llamaConfigured = [string](Get-Cfg -Config $cfg -Path 'tools.llama_server' -Default 'tools/windows/llama/llama-server.exe')
    $checks += [PSCustomObject]@{
        Category = 'llama'
        Label = 'llama-server'
        Result = (Find-ToolExecutable -Configured $llamaConfigured -CommandName 'llama-server')
        Hint = '放到 tools/windows/llama/llama-server.exe（含 DLL）'
    }
    try {
        $pythonPath = Get-PythonCommand -Config $cfg
        $checks += [PSCustomObject]@{
            Category = 'python'
            Label = 'Python'
            Result = [PSCustomObject]@{ Found = $true; Path = $pythonPath }
            Hint = '安装 Python 3.11/3.12 并勾选 Add python.exe to PATH'
        }
    } catch {
        $checks += [PSCustomObject]@{
            Category = 'python'
            Label = 'Python'
            Result = [PSCustomObject]@{ Found = $false; Path = '' }
            Hint = '安装 Python 3.11/3.12 并勾选 Add python.exe to PATH'
        }
    }
    $whisperModel = Resolve-ConfiguredPath -Configured ([string](Get-Cfg -Config $cfg -Path 'models.whisper' -Default 'models/whisper/ggml-large-v3.bin'))
    $checks += [PSCustomObject]@{
        Category = 'models'
        Label = 'Whisper 听写模型'
        Result = $whisperModel
        Hint = '放在 models/whisper/ （详见 models/README.md）'
    }
    $translationModel = Resolve-ConfiguredPath -Configured ([string](Get-Cfg -Config $cfg -Path 'models.translation' -Default 'models/translation/sakura-7b-*.gguf'))
    $checks += [PSCustomObject]@{
        Category = 'models'
        Label = '日译中翻译模型'
        Result = $translationModel
        Hint = '放在 models/translation/ （详见 models/README.md）'
    }

    foreach ($item in $checks) {
        if (-not (Test-ComponentSelected $item.Category)) { continue }
        if ($item.Result.Found) {
            Write-Host ("[已就位] {0}：{1}" -f $item.Label, $item.Result.Path) -ForegroundColor Green
        } else {
            Write-Host ("[缺失] {0}：{1}" -f $item.Label, $item.Hint) -ForegroundColor Red
            $missing++
        }
    }
    if ($missing -gt 0) {
        Write-Err ("共有 {0} 项缺失。运行 .\scripts\windows\download-tools.ps1 查看下载指引。" -f $missing)
        exit 1
    }
    Write-Ok '所选组件均已就位。'
    exit 0
}

# ---------- 下载指引 ----------
if (Test-ComponentSelected 'ffmpeg') {
    Write-Section 'ffmpeg（抽 16kHz 单声道 WAV）'
    Write-Host '  放置位置：tools/windows/ffmpeg/ffmpeg.exe（建议同时放 ffprobe.exe）' -ForegroundColor Yellow
    Write-Link 'ffmpeg Windows 静态包（gyan.dev）' 'https://www.gyan.dev/ffmpeg/builds/'
    Write-Link 'ffmpeg Windows 静态包（BtbN，GitHub Releases）' 'https://github.com/BtbN/FFmpeg-Builds/releases'
    Write-Host '  步骤：下载 ffmpeg-release-essentials.zip（或 gpl-shared）→ 解压 → 把 bin/ffmpeg.exe 复制到上述目录。' -ForegroundColor Gray
    Write-Host '  说明：本项目只用 ffmpeg 抽音轨；可选硬字幕烧录也用它。来源与版本以官方页面为准（未实机验证）。' -ForegroundColor Gray
}

if (Test-ComponentSelected 'llama') {
    Write-Section 'llama-server（llama.cpp，Vulkan / SYCL 后端）'
    Write-Host '  放置位置：tools/windows/llama/（llama-server.exe 及其同目录 DLL 全部保留）' -ForegroundColor Yellow
    Write-Link 'llama.cpp 官方 Releases' 'https://github.com/ggml-org/llama.cpp/releases'
    Write-Host '  Vulkan 版资产名形如：llama-bXXXXX-bin-win-vulkan-x64.zip（已核实 b12405 存在，约 36MB）。' -ForegroundColor Gray
    Write-Host '  SYCL 版资产名形如：llama-bXXXXX-bin-win-sycl-x64.zip（Intel 路径备选；需 Intel oneAPI 运行库，未实机验证）。' -ForegroundColor Gray
    Write-Host '  步骤：下载 zip → 全部解压到 tools/windows/llama/ → 用 00-check-env.ps1 检查 llama-server 是否可执行。' -ForegroundColor Gray
    Write-Host '  运行时参数集中在 config/pipeline.json 的 llama 段（-ngl 99 / -c / -t / 端口）。' -ForegroundColor Gray
}

if (Test-ComponentSelected 'whisper') {
    Write-Section 'whisper-cli（whisper.cpp，日语听写）'
    Write-Host '  放置位置：tools/windows/whisper/（whisper-cli.exe 及其 DLL）' -ForegroundColor Yellow
    Write-Link 'whisper.cpp 官方 Releases' 'https://github.com/ggml-org/whisper.cpp/releases'
    Write-Link 'whisper.cpp 官方编译说明（自编译 Vulkan）' 'https://github.com/ggml-org/whisper.cpp/blob/master/docs/build.md'
    Write-Host '  重要（已核实）：官方 Windows 预编译只有 CPU 版，没有 Vulkan 预编译包。' -ForegroundColor Yellow
    Write-Host '  任选其一：' -ForegroundColor Gray
    Write-Host '    A. 先用 CPU 版跑通流程（慢，但稳定；后续再换 Vulkan）；' -ForegroundColor Gray
    Write-Host '    B. 使用社区 Vulkan 构建（如 jerryshell/whisper.cpp-windows-vulkan-bin，未核实其可用性与许可证，使用前请自行确认）；' -ForegroundColor Gray
    Write-Host '    C. 在 Windows 上用 CMake 自编译（cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release），产物放本目录。' -ForegroundColor Gray
    Write-Host '  注意：可执行文件名可能是 whisper-cli.exe 或 main.exe，若不是 whisper-cli.exe 请改 config/pipeline.json 的 tools.whisper_cli。' -ForegroundColor Gray
}

if (Test-ComponentSelected 'python') {
    Write-Section 'Python（运行 scripts/python 流水线逻辑）'
    Write-Link 'Python Windows 下载页' 'https://www.python.org/downloads/windows/'
    Write-Host '  建议版本：3.11 或 3.12（64 位）；安装时务必勾选 "Add python.exe to PATH"。' -ForegroundColor Gray
    Write-Host '  本项目 Python 脚本只依赖标准库（urllib/json），不需要 pip 安装任何第三方包。' -ForegroundColor Gray
    Write-Host '  无网络的机器请下载 python-3.12.x-amd64.exe 离线安装包后再拷贝。' -ForegroundColor Gray
}

if (Test-ComponentSelected 'models') {
    Write-Section '模型（Whisper / VAD / Sakura 或 GalTransl GGUF）'
    Write-Host '  放置位置：models/whisper/ 与 models/translation/（随硬盘搬迁，目标机无需再下载）' -ForegroundColor Yellow
    Write-Host '  本仓库已提供（或正在准备）models/MANIFEST.md、models/CHECKSUMS.sha256、models/README.md。' -ForegroundColor Gray
    Write-Link 'Whisper ggml 模型（ggerganov/whisper.cpp）' 'https://huggingface.co/ggerganov/whisper.cpp'
    Write-Link 'Sakura 7B GGUF（SakuraLLM）' 'https://huggingface.co/SakuraLLM/Sakura-7B-Qwen2.5-v1.0-GGUF'
    Write-Link 'HuggingFace 国内镜像（可选）' 'https://hf-mirror.com/'
    Write-Host '  需要的文件：' -ForegroundColor Gray
    Write-Host '    models/whisper/ggml-large-v3.bin（日语听写主模型，约 3.1GB）' -ForegroundColor Gray
    Write-Host '    models/whisper/ggml-silero-v5.1.2.bin（VAD 模型，约 0.9MB）' -ForegroundColor Gray
    Write-Host '    models/translation/*.gguf（Sakura/GalTransl 日译中模型，配置里可用通配符）' -ForegroundColor Gray
    Write-Host '  校验：PowerShell 里运行 Get-FileHash -Algorithm SHA256 .\models\whisper\ggml-large-v3.bin，与 models/CHECKSUMS.sha256 对照。' -ForegroundColor Gray
}

if (Test-ComponentSelected 'all' -or $Component.Count -gt 1) {
    Write-Section '网络与镜像说明（目标机 / 准备机）'
    Write-Host '  GitHub / HuggingFace 在国内直连可能失败，可用以下渠道（按需自行核实可用性）：' -ForegroundColor Gray
    Write-Host '    1) 本地代理：Clash / v2rayN 等，PowerShell 里先设置 $env:HTTP_PROXY / $env:HTTPS_PROXY 再下载；' -ForegroundColor Gray
    Write-Host '    2) HuggingFace 镜像：https://hf-mirror.com/（把 huggingface.co 替换为 hf-mirror.com）；' -ForegroundColor Gray
    Write-Host '    3) GitCode 镜像站：https://gitcode.com/gh_mirrors/（如 llama.cpp 的镜像仓库路径请以站点实际为准，未核实）；' -ForegroundColor Gray
    Write-Host '    4) 最稳妥：在准备机下载好，随移动硬盘整体搬到目标机（本项目默认离线交付方式）。' -ForegroundColor Gray
    Write-Host '  下载完成后请回到项目根运行 .\scripts\windows\00-check-env.ps1 做完整自检。' -ForegroundColor Cyan
}

Write-Section '完成'
Write-Ok '下载指引输出完毕。放置文件后请运行：.\scripts\windows\00-check-env.ps1'
if ($script:LogFile) { Write-Info ("日志：{0}" -f $script:LogFile) }
exit 0
