$ErrorActionPreference='Stop'
if ((Get-Content "$PSScriptRoot/proxy-bypass.ps1" -Raw) -notmatch '\[switch\]\$LibraryOnly') { throw 'Library-only proxy API missing; refusing to run mutating legacy script' }
. "$PSScriptRoot/proxy-bypass.ps1" -LibraryOnly
function Assert($a,$b,$name) { if($a -ne $b){ throw "FAIL $name : $a != $b" }; "PASS $name" }
Assert (Get-ProxyOverrideUpdate '<local>;localhost' $false) '<local>;localhost;login.dgut.edu.cn' 'append missing domain'
Assert (Get-ProxyOverrideUpdate '<local>; LOGIN.DGUT.EDU.CN ' $false) '<local>; LOGIN.DGUT.EDU.CN ' 'case and whitespace do not duplicate domain'
Assert (Get-ProxyOverrideUpdate '' $false) 'login.dgut.edu.cn' 'empty override supported'
Assert (Get-ProxyOverrideUpdate 'localhost;login.dgut.edu.cn;other.test' $true) 'localhost;other.test' 'restore keeps unrelated exceptions'
Assert (Get-ProxyOverrideUpdate 'localhost;login.dgut.edu.cn; LOGIN.DGUT.EDU.CN ' $true) 'localhost' 'restore removes matching duplicates'
Assert (Get-ProxyGuardAction $false $true $false 1000 0) 'disabled' 'guard opt-in required'
Assert (Get-ProxyGuardAction $true $false $false 1000 0) 'proxy_off' 'disabled proxy is not modified'
Assert (Get-ProxyGuardAction $true $true $true 1000 0) 'present' 'existing exception not rewritten'
Assert (Get-ProxyGuardAction $true $true $false 1000 990) 'cooldown' 'repair writes rate limited'
Assert (Get-ProxyGuardAction $true $true $false 1000 900) 'repair' 'missing exception repaired'

# Exercise real registry round trips only in a new private test key, never Internet Settings.
$id=[guid]::NewGuid().ToString('N')
$testKey='HKCU:\Software\DGUTReconnectTests\'+$id
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('dgut-proxy-test-'+$id)
$null=New-Item -Path $testKey -Force
$null=New-Item -ItemType Directory -Path $testRoot
try {
    Set-ItemProperty -LiteralPath $testKey -Name ProxyEnable -Value 1
    Set-ItemProperty -LiteralPath $testKey -Name ProxyServer -Value 'unchanged-test-server'
    Set-ItemProperty -LiteralPath $testKey -Name ProxyOverride -Value 'localhost;other.test'
    Assert (Invoke-ProxyBypass 'Ensure' $testRoot $testKey) 'disabled' 'ensure does not grant itself permission'
    Assert (Invoke-ProxyBypass 'EnableGuard' $testRoot $testKey) 'repaired' 'explicit enable adds exception'
    Assert (Get-ProxyGuardEnabled $testRoot) $true 'guard consent persisted'
    Set-ItemProperty -LiteralPath $testKey -Name ProxyOverride -Value 'localhost;new.test'
    Assert (Invoke-ProxyBypass 'Ensure' $testRoot $testKey) 'repaired' 'client rewrite repaired in isolated fixture'
    $v=Get-ItemProperty -LiteralPath $testKey
    Assert $v.ProxyOverride 'localhost;new.test;login.dgut.edu.cn' 'new unrelated entries preserved'
    Assert $v.ProxyServer 'unchanged-test-server' 'proxy server untouched'
    Assert $v.ProxyEnable 1 'enable flag untouched'
    Assert (Invoke-ProxyBypass 'Restore' $testRoot $testKey) 'restored_guard_disabled' 'restore removes managed entry'
    Assert (Get-ProxyGuardEnabled $testRoot) $false 'restore also disables guard'
    Assert (Invoke-ProxyBypass 'Ensure' $testRoot $testKey) 'disabled' 'no re-add after restore'
    Assert (Get-ItemProperty -LiteralPath $testKey).ProxyOverride 'localhost;new.test' 'rollback preserves later user entries'
} finally {
    Remove-Item -LiteralPath $testKey
    foreach($name in @('proxy-bypass-policy.json','proxy-bypass-backup.json','proxy-bypass-policy.json.tmp')) {
        $path=Join-Path $testRoot $name
        if(Test-Path -LiteralPath $path){ Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $testRoot
}
