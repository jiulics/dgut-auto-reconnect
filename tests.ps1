$ErrorActionPreference = 'Stop'
if (!(Test-Path "$PSScriptRoot/guardian.ps1")) { throw 'FAIL: guardian implementation is missing' }
. "$PSScriptRoot/guardian.ps1" -LibraryOnly
function Assert($actual, $expected, $name) {
    if ($actual -ne $expected) { throw "FAIL $name : expected $expected, got $actual" }
    Write-Output "PASS $name"
}
$s = New-MonitorState
Assert (Step-Monitor $s $false $true 0) 'wait' 'first failure'
Assert (Step-Monitor $s $false $true 15) 'wait' 'second failure'
Assert (Step-Monitor $s $false $true 30) 'open' 'third failure opens portal'
Assert (Step-Monitor $s $false $true 40) 'wait' 'cooldown prevents tab storm'
Assert (Step-Monitor $s $false $true 330) 'open' 'retry after cooldown'
Assert (Step-Monitor $s $true $true 340) 'online' 'recovery'
Assert $s.Failures 0 'recovery resets failures'
Assert (Step-Monitor $s $false $true 350) 'wait' 'new outage starts fresh'
$s = New-MonitorState
1..4 | ForEach-Object { $null = Step-Monitor $s $false $false ($_ * 15) }
Assert (Step-Monitor $s $false $false 100) 'wait' 'physical disconnect does not open browser'
Assert (Step-Monitor $s $false $true 115) 'open' 'portal returning triggers recovery'
$s = New-MonitorState
1..3 | ForEach-Object { $null = Step-Monitor $s $false $true ($_ * 15) $true }
Assert (Step-Monitor $s $false $true 60 $true) 'wait' 'live page prevents duplicate tabs'
Assert (Step-Monitor $s $false $true 120 $false) 'open' 'expired page lease permits recovery'
Assert (Test-ExpectedResponse 200 'Microsoft Connect Test' 'Microsoft Connect Test') $true 'exact online response'
Assert (Test-ExpectedResponse 302 'Microsoft Connect Test' 'Microsoft Connect Test') $false 'redirect is not online'
Assert (Test-ExpectedResponse 200 '<html>login</html>' 'Microsoft Connect Test') $false 'portal HTML is not online'
