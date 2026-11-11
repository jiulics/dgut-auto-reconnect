$ErrorActionPreference = 'Stop'
if (!(Test-Path "$PSScriptRoot/setup.ps1")) { throw 'FAIL: setup implementation missing' }
. "$PSScriptRoot/setup.ps1" -LibraryOnly
function Assert($actual, $expected, $name) {
    if ($actual -ne $expected) { throw "FAIL $name : expected $expected, got $actual" }
    Write-Output "PASS $name"
}
Assert (Test-PythonInfo @{version=@(3,10,0);bits=64}) $true 'Python 3.10 x64 supported'
Assert (Test-PythonInfo @{version=@(3,13,1);bits=64}) $true 'Python 3.13 x64 supported'
Assert (Test-PythonInfo @{version=@(3,9,9);bits=64}) $false 'old Python rejected'
Assert (Test-PythonInfo @{version=@(3,13,1);bits=32}) $false '32-bit Python rejected'
Assert (Test-PythonInfo $null) $false 'missing Python rejected'
Assert (Test-StoreAlias 'C:\Users\someone\AppData\Local\Microsoft\WindowsApps\python.exe') $true 'store alias not launched'
Assert (Test-StoreAlias 'D:\Python with spaces\python.exe') $false 'ordinary path accepted'
Assert (Test-OcrHealth @{ready=$true;offline_ocr=$true;version=2}) $true 'expected service accepted'
Assert (Test-OcrHealth @{ready=$true;version=99}) $false 'unrelated service rejected'
Assert (Test-OcrHealth $null) $false 'missing service rejected'
$config = Get-LaunchSpec 'C:\example space\中文项目'
Assert ($config.Arguments.Contains('"C:\example space\中文项目\guardian.ps1"')) $true 'Chinese and spaced path quoted'
Assert ($config.Arguments.Contains('-WindowStyle Hidden')) $true 'hidden child launch'
Assert (Test-FreshStatus @{Updated='2000-01-01T00:00:00+00:00'}) $false 'old status rejected'
Assert (Test-FreshStatus @{Updated=[DateTimeOffset]::Now.ToString('o')}) $true 'fresh status accepted'
Assert (Test-FreshStatus @{Updated='broken'}) $false 'corrupt status rejected'
Assert (Test-FreshStatus @{Updated=[DateTimeOffset]::Now.AddDays(1).ToString('o')}) $false 'future status rejected'
$foreign='not-json'
Assert (ConvertFrom-JsonSafe $foreign) $null 'invalid JSON handled'
Assert ((ConvertFrom-JsonSafe '{"ok":true}').ok) $true 'valid JSON handled'
Assert (Test-StoreAlias '') $false 'empty path handled'
Assert (Test-ProjectEnvironment @{prefix='C:\project\.venv';base_prefix='C:\Python'} 'C:\project') $true 'project venv accepted'
Assert (Test-ProjectEnvironment @{prefix='C:\Python';base_prefix='C:\Python'} 'C:\project') $false 'global Python cannot receive project pip installs'
Assert (Test-ProjectEnvironment @{prefix='C:\other\.venv';base_prefix='C:\Python'} 'C:\project') $false 'another project environment rejected'
