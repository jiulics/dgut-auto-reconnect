$ErrorActionPreference = 'Stop'
if (!(Test-Path "$PSScriptRoot/autostart.ps1")) { throw 'FAIL: autostart implementation missing' }
. "$PSScriptRoot/autostart.ps1" -LibraryOnly
function Assert($actual, $expected, $name) {
    if ($actual -ne $expected) { throw "FAIL $name : expected $expected, got $actual" }
    Write-Output "PASS $name"
}
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('dgut startup test ' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testDir
try {
    $s = Set-DgutAutostart 'Status' $PSScriptRoot $testDir
    Assert $s.Registered $false 'status does not install'
    $s = Set-DgutAutostart 'Enable' $PSScriptRoot $testDir
    Assert $s.Registered $true 'enable creates shortcut'
    Assert $s.Managed $true 'shortcut is owned by this project'
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($s.Shortcut)
    Assert ($link.Arguments.Contains('-WindowStyle Hidden')) $true 'background window is hidden'
    Assert ($link.Arguments.Contains('"' + (Join-Path $PSScriptRoot 'guardian.ps1') + '"')) $true 'script path quoted'
    Assert $link.WorkingDirectory $PSScriptRoot 'working directory set'
    $s = Set-DgutAutostart 'Enable' $PSScriptRoot $testDir
    Assert @(Get-ChildItem -LiteralPath $testDir).Count 1 'repeated enable is idempotent'
    $link.Description = 'Unrelated shortcut'
    $link.Save()
    foreach ($action in @('Enable','Disable')) {
        $rejected = $false
        try { $null = Set-DgutAutostart $action $PSScriptRoot $testDir } catch { $rejected = $true }
        Assert $rejected $true "$action refuses foreign shortcut"
    }
    $link.Description = 'DGUT Auto Reconnect user-logon startup v1'
    $link.Save()
    $s = Set-DgutAutostart 'Disable' $PSScriptRoot $testDir
    Assert $s.Registered $false 'disable removes only owned shortcut'
    $s = Set-DgutAutostart 'Disable' $PSScriptRoot $testDir
    Assert $s.Registered $false 'repeated disable is idempotent'
} finally {
    # Exact private test path; never touch the real Startup folder in tests.
    $testLink = Join-Path $testDir 'DGUT Auto Reconnect.lnk'
    if (Test-Path -LiteralPath $testLink) { Remove-Item -LiteralPath $testLink }
    Remove-Item -LiteralPath $testDir
}
