param([switch]$LibraryOnly, [switch]$Once)
$ErrorActionPreference = 'Stop'

function New-MonitorState {
    return @{ Failures = 0; LastOpen = [double]::NegativeInfinity }
}
function New-NetworkHistory {
    return @{Version=1;FirstFailureAt=$null;ConfirmedAt=$null;FailureCount=0;LastSampleAt=$null;LastOnlineAt=$null;GapObserved=$false}
}
function ConvertTo-NetworkHistory($Saved) {
    if (!$Saved -or $Saved.Version -ne 1) { return $null }
    $state = New-NetworkHistory
    try {
        foreach ($key in @($state.Keys)) {
            if (!$Saved.PSObject.Properties[$key]) { return $null }
            $state[$key] = $Saved.$key
        }
        foreach ($key in @('FirstFailureAt','ConfirmedAt','LastSampleAt','LastOnlineAt')) {
            if ($state[$key]) { $null = [DateTimeOffset]::Parse($state[$key]) }
        }
        if ($state.FailureCount -lt 0 -or ($state.FirstFailureAt -and $state.FailureCount -lt 1)) { return $null }
        return $state
    } catch { return $null }
}
function Update-NetworkHistory($State, [bool]$Online, [DateTimeOffset]$At) {
    $events = @()
    if ($State.LastSampleAt) {
        $gap = ($At - [DateTimeOffset]::Parse($State.LastSampleAt)).TotalSeconds
        if ($gap -gt 90 -or $gap -lt 0) {
            $State.GapObserved = $true
            $events += [ordered]@{Event='NETWORK_MONITORING_GAP';At=$At.ToString('o');PreviousSampleAt=$State.LastSampleAt;GapSeconds=[math]::Round($gap,1)}
        }
    }
    $State.LastSampleAt = $At.ToString('o')
    if ($Online) {
        if ($State.FirstFailureAt) {
            $duration = ($At - [DateTimeOffset]::Parse($State.FirstFailureAt)).TotalSeconds
            if ($duration -lt 0) { $duration=$null; $State.GapObserved=$true }
            $event = if($State.ConfirmedAt){'NETWORK_RECOVERED'}else{'NETWORK_TRANSIENT_RECOVERED'}
            $events += [ordered]@{Event=$event;At=$At.ToString('o');StartedAt=$State.FirstFailureAt;ConfirmedAt=$State.ConfirmedAt;
                RecoveredAt=$At.ToString('o');DurationSeconds=$(if($null -ne $duration){[math]::Round($duration,1)}else{$null});
                Duration=$(if($null -ne $duration){[TimeSpan]::FromSeconds($duration).ToString('c')}else{$null});ContainsMonitoringGap=[bool]$State.GapObserved}
        }
        $State.FirstFailureAt=$null; $State.ConfirmedAt=$null; $State.FailureCount=0; $State.GapObserved=$false
        $State.LastOnlineAt=$At.ToString('o')
    } else {
        if (!$State.FirstFailureAt) {
            $State.FirstFailureAt=$At.ToString('o')
            $events += [ordered]@{Event='NETWORK_SUSPECT';At=$At.ToString('o');StartedAt=$State.FirstFailureAt;LastKnownOnlineAt=$State.LastOnlineAt}
        }
        $State.FailureCount++
        if ($State.FailureCount -ge 3 -and !$State.ConfirmedAt) {
            $State.ConfirmedAt=$At.ToString('o')
            $events += [ordered]@{Event='NETWORK_DOWN';At=$At.ToString('o');StartedAt=$State.FirstFailureAt;ConfirmedAt=$State.ConfirmedAt;ContainsMonitoringGap=[bool]$State.GapObserved}
        }
    }
    return $events
}
function Save-NetworkHistory($State) {
    $path=Join-Path $PSScriptRoot 'network-history-state.json'
    $State | ConvertTo-Json | Set-Content -LiteralPath "$path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}
function Write-NetworkEvent($Event) {
    $line=$Event | ConvertTo-Json -Compress
    $path=Join-Path $PSScriptRoot 'network-events.jsonl'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1048576) {
        Move-Item -LiteralPath $path -Destination "$path.previous" -Force
    }
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    Write-MonitorLog $line
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
    $state = New-MonitorState
    $history = New-NetworkHistory
    $historyPath=Join-Path $PSScriptRoot 'network-history-state.json'
    if (Test-Path -LiteralPath $historyPath) {
        try {
            $restored = ConvertTo-NetworkHistory (Get-Content -LiteralPath $historyPath -Raw | ConvertFrom-Json)
            if (!$restored) { throw 'Invalid network history' }
            $history=$restored
            if ($history.FirstFailureAt) {
                $history.GapObserved=$true
                Write-NetworkEvent ([ordered]@{Event='NETWORK_MONITORING_RESUMED';At=[DateTimeOffset]::Now.ToString('o');StartedAt=$history.FirstFailureAt;ContainsMonitoringGap=$true})
            }
        } catch { Write-MonitorLog 'NETWORK_HISTORY_RESET reason=invalid_saved_state' }
    }
    $lastProxyAttempt=[double]::NegativeInfinity
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    Write-MonitorLog "Started PID=$PID; direct probes; interval=15s; browser cooldown=300s"
    while (!(Test-Path $stop)) {
        try {
            try { Start-LocalOcr } catch { Write-MonitorLog ('OCR_HELPER_ERROR ' + $_.Exception.GetType().Name) }
            try {
                $proxyEnabled=Get-ProxyGuardEnabled
                $proxy=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                $present=((Get-ProxyOverrideUpdate ([string]$proxy.ProxyOverride) $false) -eq [string]$proxy.ProxyOverride)
                if ((Get-ProxyGuardAction $proxyEnabled ($proxy.ProxyEnable -eq 1) $present $clock.Elapsed.TotalSeconds $lastProxyAttempt) -eq 'repair') {
                    $lastProxyAttempt=$clock.Elapsed.TotalSeconds
                    if ((Invoke-ProxyBypass 'Ensure') -eq 'repaired') { Write-MonitorLog 'PROXY_BYPASS_REPAIRED domain=login.dgut.edu.cn' }
                }
            } catch { Write-MonitorLog ('PROXY_BYPASS_ERROR ' + $_.Exception.GetType().Name) }
            $sample = Get-NetworkSample
            if (Test-Path $stop) { break }
            $sampleAt=[DateTimeOffset]::Now
            foreach ($event in @(Update-NetworkHistory $history $sample.Online $sampleAt)) { Write-NetworkEvent $event }
            Save-NetworkHistory $history
            $pageActive = Test-PageLease
            $action = Step-Monitor $state $sample.Online $sample.PortalReachable $clock.Elapsed.TotalSeconds $pageActive
            if ($action -eq 'open') {
                # Interactive browser is intentional; background helper itself remains hidden.
                Start-Process 'http://login.dgut.edu.cn/'
                Write-MonitorLog 'Opened portal in default browser (requires installed v2 userscript).'
            }
            [ordered]@{ Updated = (Get-Date).ToString('o'); PID = $PID; Online = $sample.Online;
                PortalReachable = $sample.PortalReachable; PageActive = $pageActive; Failures = $state.Failures; Action = $action;
                OutageStartedAt=$history.FirstFailureAt;OutageConfirmedAt=$history.ConfirmedAt;ProxyGuardEnabled=(Get-ProxyGuardEnabled) } |
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
