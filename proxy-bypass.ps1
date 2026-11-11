param([switch]$Restore)
$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$backup = Join-Path $PSScriptRoot 'proxy-bypass-backup.json'
$domain = 'login.dgut.edu.cn'
$current = [string](Get-ItemProperty -LiteralPath $key -Name ProxyOverride -ErrorAction SilentlyContinue).ProxyOverride
$entries = @($current -split ';' | Where-Object { $_ })
if ($Restore) {
    if (!(Test-Path $backup)) { throw 'No backup record. Nothing changed.' }
    $record = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
    if (!$record.Added) { Write-Output 'Original configuration already contained the domain; nothing removed.'; return }
    # Preserve any unrelated proxy exceptions added since installation.
    $updated = (@($entries | Where-Object { $_ -ne $domain }) -join ';')
} else {
    if ($entries -contains $domain) { Write-Output 'Portal domain already bypassed.'; return }
    if (!(Test-Path $backup)) {
        @{ PreviousOverride = $current; Added = $true; Domain = $domain; Created = (Get-Date).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $backup -Encoding UTF8
    }
    $updated = (@($entries) + $domain) -join ';'
}
Set-ItemProperty -LiteralPath $key -Name ProxyOverride -Value $updated
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DGUTInternetSettings {
    [DllImport("wininet.dll", SetLastError=true)]
    public static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);
}
'@
$null = [DGUTInternetSettings]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
$null = [DGUTInternetSettings]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
Write-Output "Updated only ProxyOverride for $domain. ProxyEnable and ProxyServer unchanged."
