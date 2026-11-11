param(
    [ValidateSet('Install','Check','Start','Stop','EnableAutostart','DisableAutostart')]
    [string]$Action = 'Check',
    [string]$PythonPath,
    [switch]$Json,
    [switch]$LibraryOnly
)
$ErrorActionPreference = 'Stop'

function ConvertFrom-JsonSafe($Text) {
    try { return ($Text | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}
function Test-PythonInfo($Info) {
    return ($null -ne $Info -and $Info.version.Count -ge 2 -and
        $Info.version[0] -eq 3 -and $Info.version[1] -ge 10 -and $Info.bits -eq 64)
}
function Test-StoreAlias([string]$Path) {
    return ($Path -match '\\Microsoft\\WindowsApps\\')
}
function Test-ProjectEnvironment($Info, [string]$Root) {
    if (!$Info -or !$Info.prefix -or !$Info.base_prefix) { return $false }
    return ([IO.Path]::GetFullPath($Info.prefix).TrimEnd('\') -eq [IO.Path]::GetFullPath((Join-Path $Root '.venv')).TrimEnd('\') -and $Info.prefix -ne $Info.base_prefix)
}
function Test-OcrHealth($Health) {
    return ($null -ne $Health -and $Health.ready -eq $true -and
        $Health.offline_ocr -eq $true -and $Health.version -eq 2)
}
function Test-FreshStatus($Status) {
    try {
        $age = ([DateTimeOffset]::Now - [DateTimeOffset]::Parse($Status.Updated)).TotalSeconds
        return ($age -ge 0 -and $age -le 60)
    } catch { return $false }
}
function Get-LaunchSpec([string]$Root) {
    return @{
        FilePath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Root 'guardian.ps1') + '"'
    }
}
function Invoke-Probe([string]$Exe, [string]$Arguments, [int]$TimeoutSeconds = 8) {
    if (!(Test-Path -LiteralPath $Exe -PathType Leaf) -or (Test-StoreAlias $Exe)) { return $null }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $Exe
    $process.StartInfo.Arguments = $Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            # Only the probe child created by this invocation is terminated.
            $process.Kill()
            return $null
        }
        if ($process.ExitCode -ne 0) { return $null }
        return $stdout.Result.Trim()
    } catch { return $null } finally { $process.Dispose() }
}
function Get-PythonInfo([string]$Exe) {
    $output = Invoke-Probe $Exe '-I -c "import sys,struct,json;print(json.dumps(dict(version=list(sys.version_info[:3]),bits=struct.calcsize(''P'')*8,executable=sys.executable,prefix=sys.prefix,base_prefix=sys.base_prefix)))"'
    return ConvertFrom-JsonSafe $output
}
function Find-Python([string]$Root, [string]$Explicit) {
    if ($Explicit) {
        $info = Get-PythonInfo $Explicit
        if (!(Test-PythonInfo $info)) { throw '指定的 Python 不可用：需要可运行的 64 位 Python 3.10+，不能是商店占位入口。' }
        return $info
    }
    $candidates = @((Join-Path $Root '.venv\Scripts\python.exe'))
    foreach ($name in @('python','python3')) {
        $candidates += @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    }
    $launcher = Get-Command py -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($launcher) {
        # List installed interpreters only; never request installation via the launcher.
        $listing = Invoke-Probe $launcher.Source '-0p'
        foreach ($line in ($listing -split "`n")) {
            if ($line -match '([A-Za-z]:\\.+?python(?:3(?:\.\d+)?)?\.exe)\s*$') { $candidates += $Matches[1] }
        }
    }
    foreach ($registry in @('HKCU:\Software\Python\PythonCore','HKLM:\Software\Python\PythonCore')) {
        foreach ($version in @(Get-ChildItem -LiteralPath $registry -ErrorAction SilentlyContinue)) {
            $install = Get-Item -LiteralPath ($version.PSPath + '\InstallPath') -ErrorAction SilentlyContinue
            if ($install) {
                $exe = $install.GetValue('ExecutablePath')
                if (!$exe -and $install.GetValue('')) { $exe = Join-Path $install.GetValue('') 'python.exe' }
                if ($exe) { $candidates += $exe }
            }
        }
    }
    foreach ($candidate in @($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        $info = Get-PythonInfo $candidate
        if (Test-PythonInfo $info) { return $info }
    }
    return $null
}
function Test-LocalRuntime([string]$Root, [switch]$LoadModel) {
    $python = Join-Path $Root '.venv\Scripts\python.exe'
    $info = Get-PythonInfo $python
    if (!(Test-PythonInfo $info) -or !(Test-ProjectEnvironment $info $Root)) { return $false }
    if (!(Test-Path -LiteralPath (Join-Path $Root '.venv\Scripts\pythonw.exe'))) { return $false }
    $code = 'import ddddocr; from importlib.metadata import version; assert version(''ddddocr'') == ''1.6.1''; '
    if ($LoadModel) { $code += 'ddddocr.DdddOcr(show_ad=False); ' }
    $code += 'print(''READY'')'
    return ((Invoke-Probe $python ('-I -c "' + $code + '"') 45) -eq 'READY')
}
function Get-LocalHealth {
    $response = $null; $reader = $null
    try {
        $request = [Net.HttpWebRequest]::Create('http://127.0.0.1:18761/health')
        $request.Proxy = $null; $request.Timeout = 1500; $request.ReadWriteTimeout = 1500
        $request.Headers['X-DGUT-Client'] = 'local-v2'
        $response = $request.GetResponse()
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        return ConvertFrom-JsonSafe ($reader.ReadToEnd())
    } catch { return $null } finally {
        if ($reader) { $reader.Dispose() }; if ($response) { $response.Dispose() }
    }
}
function Get-SetupStatus([string]$Root) {
    $runtime = Test-LocalRuntime $Root
    $state = $null
    $stateFile = Join-Path $Root 'guardian-status.json'
    if (Test-Path -LiteralPath $stateFile) { $state = ConvertFrom-JsonSafe (Get-Content -LiteralPath $stateFile -Raw) }
    $running = $false
    if ($state -and $state.PID) {
        $proc = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$state.PID) -ErrorAction SilentlyContinue
        $running = ($null -ne $proc -and $proc.CommandLine -and $proc.CommandLine.IndexOf((Join-Path $Root 'guardian.ps1'), [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    $leaseActive = $false
    try {
        $lease = Get-Content -LiteralPath (Join-Path $Root 'portal-lease.json') -Raw | ConvertFrom-Json
        $leaseActive = [double]$lease.Until -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    } catch { }
    $health = Get-LocalHealth
    $ports = @(Get-NetTCPConnection -LocalPort 18761 -State Listen -ErrorAction SilentlyContinue)
    $serviceHere = $false
    foreach ($port in $ports) {
        $owner = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$port.OwningProcess) -ErrorAction SilentlyContinue
        if ($owner -and $owner.CommandLine -and $owner.CommandLine.IndexOf((Join-Path $Root 'ocr_service.py'), [StringComparison]::OrdinalIgnoreCase) -ge 0) { $serviceHere = $true }
    }
    $auto = ConvertFrom-JsonSafe ((& (Join-Path $Root 'autostart.ps1') -Action Status) -join "`n")
    $proxy = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $browser = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -ErrorAction SilentlyContinue
    $fresh = Test-FreshStatus $state
    return [pscustomobject]@{
        RuntimeReady = $runtime; GuardianRunning = [bool]$running; StatusFresh = $fresh
        Online = $(if ($fresh) { $state.Online } else { $null })
        OcrHealthy = (Test-OcrHealth $health); OcrBelongsToThisFolder = $serviceHere
        PortOccupied = ($ports.Count -gt 0); PageHeartbeat = $leaseActive
        AutostartRegistered = ($auto -and $auto.Registered -and $auto.Managed)
        AutostartConflict = ($auto -and $auto.Registered -and !$auto.Managed)
        DefaultBrowser = $browser.ProgId
        SystemProxyEnabled = ($proxy.ProxyEnable -eq 1); PacConfigured = [bool]$proxy.AutoConfigURL
        PortalBypass = (@($proxy.ProxyOverride -split ';') -contains 'login.dgut.edu.cn')
    }
}
function Show-Status($Status) {
    Write-Host "`n=== DGUT 运行检查 ==="
    $labels = [ordered]@{
        '本地Python和OCR依赖' = $Status.RuntimeReady
        '本目录后台正在运行' = $Status.GuardianRunning
        '后台状态仍在更新' = $Status.StatusFresh
        '当前直连联网' = $Status.Online
        '本机OCR服务健康' = $Status.OcrHealthy
        'OCR属于此项目目录' = $Status.OcrBelongsToThisFolder
        '网页已连接本机服务' = $Status.PageHeartbeat
        '登录自启动已注册' = $Status.AutostartRegistered
    }
    foreach ($label in $labels.Keys) {
        $value = if ($null -eq $labels[$label]) { '未确认' } elseif ($labels[$label]) { '是' } else { '否' }
        Write-Host ("{0}：{1}" -f $label, $value)
    }
    Write-Host ('默认浏览器标识：' + $Status.DefaultBrowser)
    if (!$Status.RuntimeReady) { Write-Host '[需处理] 本地运行环境不完整，请双击“一键安装.cmd”。' }
    if (!$Status.GuardianRunning -or !$Status.StatusFresh) { Write-Host '[需处理] 本目录监控未运行或状态过期；点击“启动监控.cmd”，再检查 guardian.log。' }
    if ($Status.PortOccupied -and (!$Status.OcrHealthy -or !$Status.OcrBelongsToThisFolder)) {
        Write-Host '[需处理] OCR端口可能属于其他程序/另一份项目。不会结束其进程，请先确认占用者。'
    }
    if (!$Status.OcrHealthy) { Write-Host '[需处理] 本地OCR未就绪，检查 ocr.log。' }
    if (!$Status.PageHeartbeat) { Write-Host '[待确认] 尚无有效网页心跳：可能未打开认证页、未安装脚本、权限未允许，或标签页被休眠。' }
    if ($Status.SystemProxyEnabled -and !$Status.PortalBypass) { Write-Host '[建议] 系统代理已开但缺少认证域名例外；请按 README 按需配置，程序不会擅自修改。' }
    if ($Status.PacConfigured) { Write-Host '[提示] 检测到PAC配置，实际路由需结合代理客户端核实。' }
    if ($Status.AutostartConflict) { Write-Host '[需确认] 已有自启动条目指向另一份配置，不会覆盖；先确定哪一个目录才是实际运行目录。' }
    elseif (!$Status.AutostartRegistered) { Write-Host '[可选] 尚未注册本目录自启动；如需启用，双击“开启登录自启动.cmd”。' }
    Write-Host '网页心跳不代表已解除暂停，也不代表验证码登录成功。请核实网页面板和实际联网结果。'
}
function Install-Runtime([string]$Root, [string]$Explicit) {
    if (Test-LocalRuntime $Root -LoadModel) {
        Write-Host '[完成] 本项目已有可用环境，离线模型加载通过，跳过重复安装。'
        return
    }
    $venv = Join-Path $Root '.venv'
    $localPython = Join-Path $venv 'Scripts\python.exe'
    if (Test-Path -LiteralPath $venv) {
        $info = Get-PythonInfo $localPython
        if (!(Test-PythonInfo $info) -or !(Test-ProjectEnvironment $info $Root)) {
            throw '已有 .venv 不可用，已保留未覆盖。请停止监控后备份/重命名它，再安装；详见 AI_SETUP.md。'
        }
        if ((Get-SetupStatus $Root).GuardianRunning) { throw '运行中的环境缺少依赖；请先停止监控，再修复安装。' }
    } else {
        $python = Find-Python $Root $Explicit
        if (!$python) {
            throw '没有找到64位 Python 3.10+。请从 https://www.python.org/downloads/windows/ 安装后重试；如已安装，使用 -PythonPath 指定 python.exe。不会自动安装系统软件。'
        }
        Write-Host ('使用 Python: ' + $python.executable)
        & $python.executable -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw '创建虚拟环境失败。请检查目录权限和 Python venv 组件；已有文件保留。' }
    }
    if (!(Test-ProjectEnvironment (Get-PythonInfo $localPython) $Root)) { throw '解释器未绑定本项目 .venv，拒绝安装依赖以免影响其他环境。' }
    Write-Host '正在安装项目依赖（首次需要网络）。不会修改系统 Python 或代理设置。'
    & $localPython -m pip install --disable-pip-version-check -r (Join-Path $Root 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw '依赖安装失败。请先完成校园网登录并检查网络/代理，再运行安装；环境已保留，可重试。' }
    if (!(Test-LocalRuntime $Root -LoadModel)) { throw '依赖安装后模型加载检查仍失败。请将错误交给 AI，勿假定已安装成功。' }
    Write-Host '[完成] 本地OCR运行环境就绪，模型加载验证通过。'
}

if ($LibraryOnly) { return }
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '当前仅支持 Windows；不要在 macOS/Linux 强行执行。' }
    $root = $PSScriptRoot
    foreach ($file in @('guardian.ps1','ocr_service.py','autostart.ps1','requirements.txt','dgut-reconnect.user.js')) {
        if (!(Test-Path -LiteralPath (Join-Path $root $file))) { throw "项目文件缺失：$file。请先完整解压ZIP。" }
    }
    switch ($Action) {
        'Install' {
            Install-Runtime $root $PythonPath
            Write-Host "`n下一步（需要你操作浏览器）："
            Write-Host '1. 在默认浏览器安装 Tampermonkey。'
            Write-Host '2. 用记事本打开 dgut-reconnect.user.js，全文复制到油猴的新脚本，保存并启用。'
            Write-Host '3. 允许访问127.0.0.1；首次账号登录由你完成。'
            Write-Host '4. 双击“启动监控.cmd”，再双击“检查运行状态.cmd”。自启动按需另行开启。'
            Write-Host '这里只完成本地环境安装，尚不能证明浏览器已配置或无人值守登录成功。'
        }
        'Check' {
            $status = Get-SetupStatus $root
            if ($Json) { $status | ConvertTo-Json } else { Show-Status $status }
        }
        'Start' {
            $status = Get-SetupStatus $root
            if (!$status.RuntimeReady) { throw '运行环境未就绪，请先双击“一键安装.cmd”。' }
            if ($status.PortOccupied -and (!$status.OcrHealthy -or !$status.OcrBelongsToThisFolder)) { throw '端口18761已被其他服务/项目占用，未启动。请先检查占用者，不要随意杀进程。' }
            $spec = Get-LaunchSpec $root
            Start-Process -FilePath $spec.FilePath -ArgumentList $spec.Arguments -WindowStyle Hidden
            Start-Sleep -Seconds 3
            $status = Get-SetupStatus $root
            Show-Status $status
            if (!$status.GuardianRunning -or !$status.StatusFresh) { throw '已请求启动，但尚未验证监控就绪。请稍后检查状态及日志；不要连续重复启动。' }
        }
        'Stop' {
            $null = New-Item -ItemType File -Path (Join-Path $root 'guardian.stop') -Force
            Write-Host '已请求停止本次后台和OCR；正在执行的检查结束后退出。不会取消登录自启动，请另行暂停网页脚本。'
        }
        'EnableAutostart' { & (Join-Path $root 'autostart.ps1') -Action Enable }
        'DisableAutostart' { & (Join-Path $root 'autostart.ps1') -Action Disable }
    }
} catch {
    if ($Json) { @{error=$_.Exception.Message} | ConvertTo-Json }
    else { Write-Host ('[未完成] ' + $_.Exception.Message) -ForegroundColor Red; Write-Host '请查看 README.md / AI_SETUP.md；不要把此提示当成成功。' }
    exit 1
}
