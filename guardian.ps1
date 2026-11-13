param([switch]$LibraryOnly, [switch]$Once)
$ErrorActionPreference = 'Stop'

function New-MonitorState {
    return @{ Failures = 0; LastOpen = [double]::NegativeInfinity }
}
function Step-Monitor($State, [bool]$Online, [bool]$PortalReachable, [double]$Now, [bool]$PageActive = $false) {
    if ($Online) {
        $State.Failures = 0
        $State.LastOpen = [double]::NegativeInfinity
        return 'online'
    }
    $State.Failures++
    if (!$PageActive -and $State.Failures -ge 3 -and $PortalReachable -and ($Now - $State.LastOpen) -ge 300) {
        $State.LastOpen = $Now
        return 'open'
    }
    return 'wait'
}
function Test-ExpectedResponse([int]$Code, [string]$Body, [string]$Expected) {
    return ($Code -eq 200 -and $Body.Trim() -ceq $Expected)
}
function Invoke-DirectGet([string]$Url) {
    # No system/PAC/environment HTTP proxy; TUN and routing rules remain outside our control.
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Proxy = $null
    $request.AllowAutoRedirect = $false
    $request.Timeout = 8000
    $request.ReadWriteTimeout = 8000
    $request.UserAgent = 'DGUT-Local-Monitor/1.0'
    $request.Headers['Cache-Control'] = 'no-cache, no-store'
    $response = $null
    $reader = $null
    try {
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        # The expected probes are tiny; do not consume an arbitrarily large portal body.
        $buffer = New-Object char[] 4096
        $count = $reader.Read($buffer, 0, $buffer.Length)
        return @{ Code = [int]$response.StatusCode; Body = (-join $buffer[0..([Math]::Max(0,$count-1))]); Reachable = $true }
    } catch {
        return @{ Code = 0; Body = ''; Reachable = $false }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
    }
}
function Get-NetworkSample {
    $first = Invoke-DirectGet 'http://www.msftconnecttest.com/connecttest.txt'
    $online = Test-ExpectedResponse $first.Code $first.Body 'Microsoft Connect Test'
    if (!$online) {
        $second = Invoke-DirectGet 'http://www.msftncsi.com/ncsi.txt'
        $online = Test-ExpectedResponse $second.Code $second.Body 'Microsoft NCSI'
    }
    $portal = $false
    if (!$online) {
        $p = Invoke-DirectGet 'http://login.dgut.edu.cn/'
        $portal = $p.Reachable -and ($p.Code -ge 200 -and $p.Code -lt 400)
    }
    return @{ Online = [bool]$online; PortalReachable = [bool]$portal }
}
function Write-MonitorLog([string]$Message) {
    $log = Join-Path $PSScriptRoot 'guardian.log'
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1048576) {
        Move-Item -LiteralPath $log -Destination "$log.previous" -Force
    }
    Add-Content -LiteralPath $log -Value ("{0:o} {1}" -f (Get-Date), $Message) -Encoding UTF8
}
function Test-PageLease {
    try {
        $lease = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'portal-lease.json') -Raw | ConvertFrom-Json
        return ([double]$lease.Until -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    } catch { return $false }
}
function Start-LocalOcr {
    $python = Join-Path $PSScriptRoot '.venv\Scripts\pythonw.exe'
    if (!(Test-Path $python)) { throw 'Local OCR environment missing' }
    $request = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:18761/health')
    $request.Proxy = $null
    $request.Timeout = 1000
    $request.Headers['X-DGUT-Client'] = 'local-v2'
    try {
        $response = $request.GetResponse()
        $response.Dispose()
    } catch {
        Start-Process -FilePath $python -ArgumentList ('"' + (Join-Path $PSScriptRoot 'ocr_service.py') + '"') -WindowStyle Hidden
        Write-MonitorLog 'Started local OCR helper.'
    }
}
if ($LibraryOnly) { return }
if ($Once) { Get-NetworkSample | ConvertTo-Json; return }
. (Join-Path $PSScriptRoot 'proxy-bypass.ps1') -LibraryOnly

$mutex = New-Object System.Threading.Mutex($false, 'Local\DGUTReconnectGuardianV1')
$owned = $false
try {
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (!$owned) { return }
    $stop = Join-Path $PSScriptRoot 'guardian.stop'
    if (Test-Path $stop) { Remove-Item -LiteralPath $stop }
    $lastProxyAttempt=[double]::NegativeInfinity
    $state = New-MonitorState
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    Write-MonitorLog "Started PID=$PID; direct probes; interval=15s; browser cooldown=300s"
    while (!(Test-Path $stop)) {
        try {
            # Independent opt-in repair; failures must not prevent the original monitoring flow.
            try {
                $proxyEnabled=Get-ProxyGuardEnabled
                $proxy=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                $present=((Get-ProxyOverrideUpdate ([string]$proxy.ProxyOverride) $false) -eq [string]$proxy.ProxyOverride)
                if ((Get-ProxyGuardAction $proxyEnabled ($proxy.ProxyEnable -eq 1) $present $clock.Elapsed.TotalSeconds $lastProxyAttempt) -eq 'repair') {
                    $lastProxyAttempt=$clock.Elapsed.TotalSeconds
                    if ((Invoke-ProxyBypass 'Ensure') -eq 'repaired') { Write-MonitorLog 'PROXY_BYPASS_REPAIRED domain=login.dgut.edu.cn' }
                }
            } catch { Write-MonitorLog ('PROXY_BYPASS_ERROR ' + $_.Exception.GetType().Name) }
            Start-LocalOcr
            $sample = Get-NetworkSample
            if (Test-Path $stop) { break }
            $pageActive = Test-PageLease
            $action = Step-Monitor $state $sample.Online $sample.PortalReachable $clock.Elapsed.TotalSeconds $pageActive
            if ($action -eq 'open') {
                # Interactive browser is intentional; background helper itself remains hidden.
                Start-Process 'http://login.dgut.edu.cn/'
                Write-MonitorLog 'Opened portal in default browser (requires installed v2 userscript).'
            }
            [ordered]@{ Updated = (Get-Date).ToString('o'); PID = $PID; Online = $sample.Online;
                PortalReachable = $sample.PortalReachable; PageActive = $pageActive; Failures = $state.Failures; Action = $action } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'guardian-status.json') -Encoding UTF8
        } catch {
            # Avoid logging URLs, HTML, cookies, or exception messages that may include secrets.
            Write-MonitorLog ('Iteration failed: ' + $_.Exception.GetType().Name)
        }
        for ($i=0; $i -lt 15 -and !(Test-Path $stop); $i++) { Start-Sleep -Seconds 1 }
    }
    Write-MonitorLog 'Stopped by stop file.'
} finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
