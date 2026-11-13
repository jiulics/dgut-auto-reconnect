$ErrorActionPreference='Stop'
. "$PSScriptRoot/guardian.ps1" -LibraryOnly
function Assert($a,$b,$name) { if($a -ne $b){ throw "FAIL $name : $a != $b" }; "PASS $name" }
$base=[DateTimeOffset]::Parse('2026-11-13T10:00:00+08:00')
$s=New-NetworkHistory
Assert @(Update-NetworkHistory $s $true $base).Count 0 'healthy sample is quiet'
$e=@(Update-NetworkHistory $s $false $base.AddSeconds(15))
Assert $e[0].Event 'NETWORK_SUSPECT' 'first failure logged'
Assert @(Update-NetworkHistory $s $false $base.AddSeconds(30)).Count 0 'second failure is quiet'
$e=@(Update-NetworkHistory $s $false $base.AddSeconds(45))
Assert $e[0].Event 'NETWORK_DOWN' 'third failure confirmed'
Assert $e[0].StartedAt $base.AddSeconds(15).ToString('o') 'start is first failed sample'
Assert @(Update-NetworkHistory $s $false $base.AddSeconds(60)).Count 0 'no repeated down logs'
$e=@(Update-NetworkHistory $s $true $base.AddSeconds(75))
Assert $e[0].Event 'NETWORK_RECOVERED' 'recovery event'
Assert $e[0].DurationSeconds 60 'observed duration measured'
Assert $e[0].ContainsMonitoringGap $false 'continuous observation'
Assert $s.FirstFailureAt $null 'recovery resets outage'
Assert @(Update-NetworkHistory $s $true $base.AddSeconds(90)).Count 0 'no repeated recovery logs'
$s=New-NetworkHistory
$null=Update-NetworkHistory $s $false $base
$e=@(Update-NetworkHistory $s $true $base.AddSeconds(15))
Assert $e[0].Event 'NETWORK_TRANSIENT_RECOVERED' 'one failure is not confirmed outage'
$s=New-NetworkHistory
$null=Update-NetworkHistory $s $false $base
$null=Update-NetworkHistory $s $false $base.AddSeconds(15)
$null=Update-NetworkHistory $s $false $base.AddSeconds(30)
$e=@(Update-NetworkHistory $s $true $base.AddMinutes(10))
Assert $e[0].Event 'NETWORK_MONITORING_GAP' 'sleep gap recorded'
Assert $e[-1].ContainsMonitoringGap $true 'gap not presented as continuous downtime'
$s=New-NetworkHistory
$null=Update-NetworkHistory $s $false $base
$e=@(Update-NetworkHistory $s $true $base.AddSeconds(-5))
Assert $e[-1].DurationSeconds $null 'clock rollback does not invent duration'
$json=($s | ConvertTo-Json)
$restored=ConvertTo-NetworkHistory ($json | ConvertFrom-Json)
Assert $restored.FailureCount 0 'history survives serialization'
$bad=ConvertTo-NetworkHistory ([pscustomobject]@{FirstFailureAt='bad'})
Assert $bad $null 'invalid saved state rejected'
