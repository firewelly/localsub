# 字幕流水线公共函数库（Windows PowerShell 5.1 / PowerShell 7 兼容）
#
# 本文件不直接执行，只被 scripts/windows 下的入口脚本 dot-source 引入：
#     $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
#     . (Join-Path $PSScriptRoot '_common.ps1')
#
# 约定：
# - 所有路径一律基于调用脚本已定义的 $ProjectRoot 用 Join-Path 拼接，禁止硬编码盘符/绝对路径；
# - 所有面向用户的提示使用中文；错误以 throw 抛出，由入口脚本捕获后返回非零退出码；
# - 日志文件由 Initialize-Log 创建，Write-Info/Ok/Warn/Err 会同时写日志。

$script:LogFile = ''

# ---------------------------------------------------------------------------
# 控制台输出与日志
# ---------------------------------------------------------------------------

function Write-LogLine {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($script:LogFile)) { return }
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # 日志写入失败不影响主流程
    }
}

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Gray
    Write-LogLine ("信息 " + $Message)
}

function Write-Ok {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
    Write-LogLine ("成功 " + $Message)
}

function Write-Warn {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
    Write-LogLine ("警告 " + $Message)
}

function Write-Err {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
    Write-LogLine ("错误 " + $Message)
}

function Write-Step {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
    Write-LogLine ("步骤 " + $Message)
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 62) -ForegroundColor DarkCyan
    Write-Host (" " + $Title) -ForegroundColor Cyan
    Write-Host ("=" * 62) -ForegroundColor DarkCyan
    Write-LogLine ("===== " + $Title + " =====")
}

function Initialize-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [string]$Prefix = 'run'
    )
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $Directory ("{0}-{1}.log" -f $Prefix, $stamp)
    $header = "===== 日志开始 {0} | PowerShell {1} | 项目根 {2} =====" -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PSVersionTable.PSVersion.ToString(), $ProjectRoot
    [System.IO.File]::WriteAllText(
        $script:LogFile,
        $header + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($true))
    )
    return $script:LogFile
}

# ---------------------------------------------------------------------------
# 配置读取
# ---------------------------------------------------------------------------

function Get-PipelineConfig {
    <# 读取 config/pipeline.json；缺失时从 pipeline.example.json 自动复制（中文提示）。 #>
    param([string]$ConfigPath = '')

    $configDir = Join-Path $ProjectRoot 'config'
    $examplePath = Join-Path $configDir 'pipeline.example.json'
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $configDir 'pipeline.json'
    } elseif (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
        $ConfigPath = Join-Path $ProjectRoot $ConfigPath
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if (-not (Test-Path -LiteralPath $examplePath)) {
            throw "缺少配置文件：$ConfigPath，且未找到模板 $examplePath。请确认项目目录完整后重试。"
        }
        $parent = Split-Path -Parent $ConfigPath
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $examplePath -Destination $ConfigPath -Force
        Write-Warn "未找到配置文件 $ConfigPath，已从 config/pipeline.example.json 自动复制，请按需修改。"
    }

    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $data = $raw | ConvertFrom-Json
    } catch {
        throw "配置文件不是合法 JSON：$ConfigPath。请检查括号/逗号，或用 Python 校验（python -m json.tool config/pipeline.json）。原始错误：$($_.Exception.Message)"
    }
    if ($null -eq $data) {
        throw "配置文件内容为空或无法解析：$ConfigPath。"
    }
    return [PSCustomObject]@{ Path = $ConfigPath; Data = $data }
}

function Get-Cfg {
    <# 按 a.b.c 形式读取嵌套配置值；缺失返回默认值。 #>
    param($Config, [string]$Path, $Default = $null)
    $node = $Config
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $node) { return $Default }
        $property = $node.PSObject.Properties[$part]
        if ($null -eq $property) { return $Default }
        $node = $property.Value
    }
    if ($null -eq $node) { return $Default }
    return $node
}

function Get-CfgArray {
    param($Config, [string]$Path)
    $value = Get-Cfg -Config $Config -Path $Path -Default @()
    if ($null -eq $value) { return @() }
    return @($value)
}

# ---------------------------------------------------------------------------
# 路径与工具解析
# ---------------------------------------------------------------------------

function Resolve-FullPath {
    param([string]$Relative, [string]$Root = '')
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $ProjectRoot }
    if ([string]::IsNullOrWhiteSpace($Relative)) { return $Root }
    if ([System.IO.Path]::IsPathRooted($Relative)) { return $Relative }
    return (Join-Path $Root $Relative)
}

function Resolve-ConfiguredPath {
    <# 解析配置路径；支持通配符（如 models/translation/sakura-*.gguf）。 #>
    param([string]$Configured, [string]$Root = '')

    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $ProjectRoot }
    $result = [PSCustomObject]@{
        Found = $false
        Path = ''
        Candidates = @()
        IsGlob = $false
        Configured = $Configured
    }
    if ([string]::IsNullOrWhiteSpace($Configured)) { return $result }

    $full = Resolve-FullPath -Relative $Configured -Root $Root
    if ($full.IndexOfAny([char[]]@('*', '?')) -ge 0) {
        $result.IsGlob = $true
        $items = @(Get-ChildItem -Path $full -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($items.Count -gt 0) {
            $result.Found = $true
            $result.Path = $items[0].FullName
            $result.Candidates = @($items | ForEach-Object { $_.FullName })
        }
        return $result
    }
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $result.Found = $true
        $result.Path = (Resolve-Path -LiteralPath $full).ProviderPath
        $result.Candidates = @($result.Path)
    }
    return $result
}

function Find-ToolExecutable {
    <# 先在配置路径里找，再从系统 PATH 找；返回 Found/Path/Source。 #>
    param([string]$Configured, [string]$CommandName = '', [string]$Root = '')
    $resolved = Resolve-ConfiguredPath -Configured $Configured -Root $Root
    if ($resolved.Found) {
        return [PSCustomObject]@{
            Found = $true
            Path = $resolved.Path
            Source = '配置文件'
            Configured = $Configured
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($CommandName)) {
        $commands = @(Get-Command -Name $CommandName -CommandType Application -ErrorAction SilentlyContinue)
        $command = $null
        if ($commands.Count -gt 0) { $command = $commands[0] }
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            return [PSCustomObject]@{
                Found = $true
                Path = [string]$command.Source
                Source = '系统 PATH'
                Configured = $Configured
            }
        }
    }
    return [PSCustomObject]@{
        Found = $false
        Path = ''
        Source = '未找到'
        Configured = $Configured
    }
}

function Get-PythonCommand {
    <# 取得可用的 Python 解释器路径：优先 -PythonExe，其次配置 tools.python，再试 python/python3/py。 #>
    param($Config, [string]$Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $result = Find-ToolExecutable -Configured $Override -CommandName $Override
        if ($result.Found) { return $result.Path }
        if (Test-Path -LiteralPath $Override) {
            return (Resolve-Path -LiteralPath $Override).ProviderPath
        }
        throw "指定的 Python 可执行文件不存在：$Override。请检查 -PythonExe 参数。"
    }

    $candidates = @()
    $configured = [string](Get-Cfg -Config $Config -Path 'tools.python' -Default 'python')
    $candidates += $configured
    $candidates += @('python', 'python3', 'py')
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $result = Find-ToolExecutable -Configured $candidate -CommandName $candidate
        if ($result.Found) { return $result.Path }
    }
    throw "未找到 Python。请安装 Python 3.11/3.12（安装时勾选 Add python.exe to PATH），或在 config/pipeline.json 的 tools.python 里填写可执行文件相对路径。"
}

function Get-RequiredPath {
    <# 解析配置中的必需文件路径，找不到时抛中文错误（附修复提示）。 #>
    param(
        [string]$Configured,
        [string]$Label,
        [string]$FixHint = '',
        [switch]$AllowGlob
    )
    $resolved = Resolve-ConfiguredPath -Configured $Configured
    if (-not $resolved.Found) {
        $extra = ''
        if (-not [string]::IsNullOrWhiteSpace($FixHint)) { $extra = " 修复提示：$FixHint" }
        throw "$Label 不存在或未配置（配置值：$Configured）。请确认文件已随硬盘拷贝到位。$extra"
    }
    if ($resolved.IsGlob -and $resolved.Candidates.Count -gt 1) {
        Write-Warn ("$Label 匹配到 {0} 个候选，已按文件名排序取第一个：{1}" -f `
            $resolved.Candidates.Count, $resolved.Path)
        Write-Warn "如需固定选择，请把 config/pipeline.json 中该项改成精确文件名。"
    }
    return $resolved.Path
}

function Test-IsWindows {
    return ($env:OS -eq 'Windows_NT')
}

function Test-PathIsRelative {
    param([string]$Path)
    return (-not [System.IO.Path]::IsPathRooted($Path))
}

# ---------------------------------------------------------------------------
# 进程与命令行执行
# ---------------------------------------------------------------------------

function Invoke-Native {
    <# 运行外部命令：合并 stdout/stderr，逐行写日志并回显；返回进程退出码。
       TimeoutSec > 0 时启用超时：超时会杀掉进程并返回 124（用于防止坏盘/坏文件把批量队列卡死）。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$LogPath = '',
        [switch]$NoEcho,
        [int]$TimeoutSec = 0
    )
    if ($TimeoutSec -gt 0) {
        $quoted = ($Arguments | ForEach-Object { Format-StartArgument ([string]$_) }) -join ' '
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $Exe
            $psi.Arguments = $quoted
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
            $proc = [System.Diagnostics.Process]::Start($psi)
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
                try { $proc.Kill() } catch { }
                $msg = ("[超时] 外部命令超过 {0} 秒未完成，已强制结束：{1}" -f $TimeoutSec, [System.IO.Path]::GetFileName($Exe))
                if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
                    Add-Content -LiteralPath $LogPath -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
                }
                if (-not $NoEcho) { Write-Warn $msg }
                return 124
            }
            $text = [string]$outTask.Result + [string]$errTask.Result
            foreach ($line in ($text -split "`r?`n")) {
                $lineText = [string]$line
                if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
                    Add-Content -LiteralPath $LogPath -Value $lineText -Encoding UTF8 -ErrorAction SilentlyContinue
                }
                if (-not $NoEcho -and $lineText.Trim().Length -gt 0) {
                    Write-Host $lineText -ForegroundColor DarkGray
                }
            }
            return $proc.ExitCode
        } catch {
            $msg = ("[错误] 外部命令启动/执行失败：{0}：{1}" -f [System.IO.Path]::GetFileName($Exe), $_.Exception.Message)
            if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
                Add-Content -LiteralPath $LogPath -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
            }
            if (-not $NoEcho) { Write-Warn $msg }
            return 125
        }
    }
    $lines = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $lines) {
        $text = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Add-Content -LiteralPath $LogPath -Value $text -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        if (-not $NoEcho -and $text.Trim().Length -gt 0) {
            Write-Host $text -ForegroundColor DarkGray
        }
    }
    return $code
}

function Format-StartArgument {
    <# 给 Start-Process 用的单参数补引号（路径含空格时必需）。 #>
    param([string]$Value)
    if ($Value -match '\s') { return ('"' + $Value + '"') }
    return $Value
}

function Get-TailText {
    param([string]$Path, [int]$Lines = 15)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        return ((Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop) -join [Environment]::NewLine)
    } catch {
        return ''
    }
}

function Test-HttpOk {
    param([string]$Url, [int]$TimeoutSec = 3)
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($null -ne $response -and [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300) {
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Test-ProcessExited {
    param($Process)
    if ($null -eq $Process) { return $true }
    try {
        return $Process.HasExited
    } catch {
        return $true
    }
}

function Stop-ServerProcess {
    param($Process, [string]$Label = 'llama-server')
    if ($null -eq $Process) { return }
    try {
        if (-not (Test-ProcessExited -Process $Process)) {
            Stop-Process -Id $Process.Id -Force -ErrorAction Stop
            $Process.WaitForExit(5000) | Out-Null
            Write-Ok "[已关闭] $Label（PID $($Process.Id)）"
        }
    } catch {
        Write-Warn "关闭 $Label 进程失败（PID $($Process.Id)）：$($_.Exception.Message)"
    }
}

function Wait-HttpReady {
    <# 轮询健康接口直到就绪；进程提前退出/超时都会抛出中文错误（含日志尾部）。 #>
    param(
        [string]$Url,
        [int]$TimeoutSec = 180,
        $Process = $null,
        [string]$LogPath = '',
        [string]$ServerLabel = 'llama-server'
    )
    $start = Get-Date
    $lastReport = 0.0
    while ($true) {
        $elapsed = ((Get-Date) - $start).TotalSeconds
        if ($null -ne $Process) {
            if (Test-ProcessExited -Process $Process) {
                $exitCode = '未知'
                try { $exitCode = $Process.ExitCode } catch { }
                $tail = Get-TailText -Path $LogPath -Lines 15
                throw ("$ServerLabel 进程启动后提前退出（退出码 $exitCode）。常见原因：模型文件缺失/损坏、显存不足、Vulkan DLL 不完整。`n日志尾部：`n$tail")
            }
        }
        if (Test-HttpOk -Url $Url -TimeoutSec 3) { return $true }
        if ($elapsed -ge $TimeoutSec) {
            $tail = Get-TailText -Path $LogPath -Lines 15
            throw ("等待 $ServerLabel 就绪超时（已等 $([int]$elapsed) 秒，上限 $TimeoutSec 秒）：$Url。`n排查：1) 查看日志确认模型是否在加载；2) 显存是否不足；3) 端口是否被占用。`n日志尾部：`n$tail")
        }
        if (($elapsed - $lastReport) -ge 10) {
            $lastReport = $elapsed
            Write-Info ("  等待服务就绪……已等待 {0} 秒（上限 {1} 秒）" -f [int]$elapsed, $TimeoutSec)
        }
        Start-Sleep -Seconds 2
    }
}

# ---------------------------------------------------------------------------
# 文件与输入枚举
# ---------------------------------------------------------------------------

function Write-Utf8NoBom {
    <# 写 UTF-8 无 BOM 文本（JSON 报告用；项目约定 .json 无 BOM）。 #>
    param([string]$Path, [string]$Text)
    $full = Resolve-FullPath -Relative $Path
    $parent = Split-Path -Parent $full
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($full, $Text, (New-Object System.Text.UTF8Encoding($false)))
    return $full
}

function ConvertTo-JsonReport {
    param($Object)
    return ($Object | ConvertTo-Json -Depth 8)
}

function Format-Elapsed {
    param([double]$Seconds)
    $total = [int][Math]::Round($Seconds)
    if ($total -lt 60) { return ("{0} 秒" -f $total) }
    $minutes = [int]($total / 60)
    $sec = $total % 60
    if ($minutes -lt 60) { return ("{0} 分 {1} 秒" -f $minutes, $sec) }
    $hours = [int]($minutes / 60)
    $minutes = $minutes % 60
    return ("{0} 小时 {1} 分" -f $hours, $minutes)
}

function Get-InputMediaFiles {
    <# 枚举输入路径下的音视频文件；传入单文件时直接返回该文件。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Extensions = @(),
        [switch]$Recurse
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "输入路径不存在：$Path。请确认路径（相对路径以项目根为基准）以及硬盘是否插好。"
    }
    $item = Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer) {
        return @($item)
    }
    $normalized = @($Extensions | ForEach-Object { $_.ToLowerInvariant() })
    if ($normalized.Count -eq 0) {
        $normalized = @('.mp4', '.mkv', '.mov', '.wav', '.mp3', '.m4a', '.flac', '.avi', '.wmv', '.webm', '.ts')
    }
    $files = @(
        Get-ChildItem -LiteralPath $Path -File -Recurse:$Recurse -ErrorAction Stop |
            Where-Object { $normalized -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object FullName
    )
    return $files
}

function Get-JaSrtFiles {
    <# 枚举日文字幕：支持 `ja.srt` 或 `*.ja.srt`；传入目录时默认只找当前层。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Recurse
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "输入路径不存在：$Path。请确认路径（相对路径以项目根为基准）。"
    }
    $item = Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer) {
        if ($item.Name -like '*.srt') { return @($item) }
        throw "指定的文件不是 SRT：$Path。02/03 脚本需要 ja.srt（或用 -InputDir 指向视频所在输出目录）。"
    }
    $files = @(
        Get-ChildItem -LiteralPath $Path -File -Recurse:$Recurse -Filter '*.srt' -ErrorAction Stop |
            Where-Object { $_.Name -eq 'ja.srt' -or $_.Name -like '*.ja.srt' } |
            Sort-Object FullName
    )
    return $files
}

function Get-OutputBaseName {
    <# 由输入项推导产物目录名：视频取文件名去扩展名；ja.srt 取其所在目录名。 #>
    param([Parameter(Mandatory = $true)]$Item)
    if ($Item.Name -eq 'ja.srt') {
        return (Split-Path -Leaf (Split-Path -Parent $Item.FullName))
    }
    if ($Item.Name -like '*.ja.srt') {
        return $Item.Name.Substring(0, $Item.Name.Length - '.ja.srt'.Length)
    }
    return $Item.BaseName
}
