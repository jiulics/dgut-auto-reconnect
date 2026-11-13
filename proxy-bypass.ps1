param([switch]$Restore, [switch]$EnableGuard, [switch]$DisableGuard, [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'

function Get-ProxyOverrideUpdate([string]$Current, [bool]$Remove) {
    $domain = 'login.dgut.edu.cn'
    $entries = @($Current -split ';' | Where-Object { $_ })
    $present = @($entries | Where-Object { $_.Trim() -ieq $domain }).Count -gt 0
    if ($Remove) { return (@($entries | Where-Object { $_.Trim() -ine $domain }) -join ';') }
    if ($present) { return $Current }
    if (!$Current.Trim(';').Trim()) { return $domain }
    return ($Current.TrimEnd(';') + ';' + $domain)
}
function Get-ProxyGuardAction([bool]$Enabled, [bool]$ProxyOn, [bool]$Present, [double]$Now, [double]$LastAttempt) {
    if (!$Enabled) { return 'disabled' }
    if (!$ProxyOn) { return 'proxy_off' }
    if ($Present) { return 'present' }
    if ($Now - $LastAttempt -lt 60) { return 'cooldown' }
    return 'repair'
}
function Get-ProxyGuardEnabled([string]$Root = $PSScriptRoot) {
    try {
        $policy = Get-Content -LiteralPath (Join-Path $Root 'proxy-bypass-policy.json') -Raw | ConvertFrom-Json
        return ($policy.Enabled -is [bool] -and $policy.Enabled)
    } catch { return $false }
}
function Set-ProxyGuardPolicy([bool]$Enabled, [string]$Root) {
    $path = Join-Path $Root 'proxy-bypass-policy.json'
    @{Enabled=$Enabled;Domain='login.dgut.edu.cn';Updated=(Get-Date).ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath "$path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}
function Publish-ProxySettings {
    if (!('DGUTInternetSettings' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DGUTInternetSettings {
    [DllImport("wininet.dll", SetLastError=true)]
    public static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);
}
'@
    }
    $null = [DGUTInternetSettings]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    $null = [DGUTInternetSettings]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}
function Invoke-ProxyBypass([string]$Mode, [string]$Root = $PSScriptRoot,
    [string]$SettingsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') {
    if ($Mode -notin @('Add','Restore','EnableGuard','DisableGuard','Ensure')) { throw 'Invalid proxy operation' }
    $mutex = New-Object Threading.Mutex($false, 'Local\DGUTProxyBypassV2')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(3000) } catch [Threading.AbandonedMutexException] { $owned=$true }
        if (!$owned) { throw 'Proxy settings are busy; retry later' }
        if ($Mode -in @('Restore','DisableGuard')) { Set-ProxyGuardPolicy $false $Root }
        if ($Mode -eq 'DisableGuard') { return 'guard_disabled' }
        if ($Mode -eq 'Ensure' -and !(Get-ProxyGuardEnabled $Root)) { return 'disabled' }
        $key = $SettingsKey
        $settings = Get-ItemProperty -LiteralPath $key
        if ($Mode -eq 'Ensure' -and $settings.ProxyEnable -ne 1) { return 'proxy_off' }
        $current = [string]$settings.ProxyOverride
        $backup = Join-Path $Root 'proxy-bypass-backup.json'
        if ($Mode -eq 'Restore') {
            if (!(Test-Path -LiteralPath $backup)) { return 'guard_disabled_no_backup' }
            $record = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
            if ($record.Domain -ne 'login.dgut.edu.cn') { throw 'Unexpected proxy backup; refused to remove anything' }
            if (!$record.Added) { return 'guard_disabled_preexisting_exception_preserved' }
            $updated = Get-ProxyOverrideUpdate $current $true
        } else {
            $updated = Get-ProxyOverrideUpdate $current $false
            if (!(Test-Path -LiteralPath $backup)) {
                @{PreviousOverride=$current;Added=($updated -ne $current);Domain='login.dgut.edu.cn';Created=(Get-Date).ToString('o')} |
                    ConvertTo-Json | Set-Content -LiteralPath $backup -Encoding UTF8
            }
            if ($Mode -eq 'EnableGuard') { Set-ProxyGuardPolicy $true $Root }
        }
        if ($updated -ne $current) {
            Set-ItemProperty -LiteralPath $key -Name ProxyOverride -Value $updated
            if ($key -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') { Publish-ProxySettings }
            if ($Mode -eq 'Restore') { return 'restored_guard_disabled' }
            return 'repaired'
        }
        return 'unchanged'
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
if ($LibraryOnly) { return }
if (([int]$Restore.IsPresent + [int]$EnableGuard.IsPresent + [int]$DisableGuard.IsPresent) -gt 1) { throw 'Choose only one operation' }
$mode = if($Restore){'Restore'}elseif($EnableGuard){'EnableGuard'}elseif($DisableGuard){'DisableGuard'}else{'Add'}
$result = Invoke-ProxyBypass $mode
Write-Output "Proxy bypass: $result. Only login.dgut.edu.cn exception is managed; proxy address, enable switch and subscriptions unchanged."
