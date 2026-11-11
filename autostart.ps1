param(
    [ValidateSet('Enable', 'Disable', 'Status')]
    [string]$Action = 'Status',
    [switch]$LibraryOnly
)
$ErrorActionPreference = 'Stop'

function Set-DgutAutostart([string]$Mode, [string]$ProjectDirectory, [string]$StartupDirectory) {
    if ($Mode -notin @('Enable','Disable','Status')) { throw 'Invalid action' }
    $project = (Resolve-Path -LiteralPath $ProjectDirectory).ProviderPath
    $guardian = Join-Path $project 'guardian.ps1'
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $guardian + '"'
    $description = 'DGUT Auto Reconnect user-logon startup v1'
    $shortcut = Join-Path $StartupDirectory 'DGUT Auto Reconnect.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $link = $null
    try {
        $exists = Test-Path -LiteralPath $shortcut
        $managed = $false
        if ($exists) {
            $link = $shell.CreateShortcut($shortcut)
            $managed = ($link.Description -eq $description -and $link.TargetPath -eq $exe -and $link.Arguments -eq $arguments)
            if (!$managed -and $Mode -ne 'Status') { throw 'Existing startup shortcut belongs to another configuration; nothing changed.' }
        }
        if ($Mode -eq 'Enable') {
            if (!(Test-Path -LiteralPath $guardian -PathType Leaf)) { throw 'guardian.ps1 missing' }
            if (!(Test-Path -LiteralPath $StartupDirectory -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $StartupDirectory
            }
            if (!$link) { $link = $shell.CreateShortcut($shortcut) }
            $link.TargetPath = $exe
            $link.Arguments = $arguments
            $link.WorkingDirectory = $project
            $link.WindowStyle = 7
            $link.Description = $description
            $link.Save()
            $exists = $true
            $managed = $true
        } elseif ($Mode -eq 'Disable' -and $exists) {
            # Only our exact, verified shortcut is removed. No recursive deletion.
            Remove-Item -LiteralPath $shortcut
            $exists = $false
            $managed = $false
        }
        return [pscustomobject]@{
            Registered = [bool]$exists
            Managed = [bool]$managed
            Trigger = 'Current user sign-in (not pre-login boot)'
            Shortcut = $shortcut
            Project = $project
        }
    } finally {
        if ($link) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
        $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}

if ($LibraryOnly) { return }
if ($Action -eq 'Enable') {
    foreach ($required in @('guardian.ps1','ocr_service.py','.venv\Scripts\pythonw.exe')) {
        if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot $required) -PathType Leaf)) {
            throw "Install this project's runtime first: missing $required"
        }
    }
}
$startup = [Environment]::GetFolderPath('Startup')
if (!$startup) { throw 'Current user Startup folder unavailable' }
Set-DgutAutostart $Action $PSScriptRoot $startup | ConvertTo-Json
