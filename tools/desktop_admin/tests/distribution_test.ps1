[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Rejected([scriptblock] $Action, [string] $Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Message
}
function Write-Fixture([string] $Path, [string] $Value) {
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Value)
}

$toolDirectory = Split-Path -Parent $PSScriptRoot
$packageScript = Join-Path $toolDirectory 'package.ps1'
$installScript = Join-Path $toolDirectory 'install.ps1'
Assert-True (Test-Path -LiteralPath $packageScript) 'Distribution packaging command is missing.'
Assert-True (Test-Path -LiteralPath $installScript) 'Per-user installer is missing.'

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $temporaryRoot ('shadow-admin-distribution-test-' + [guid]::NewGuid().ToString('N'))
$savedAppData = $env:APPDATA
$savedLocalAppData = $env:LOCALAPPDATA
$passed = 0
try {
    $env:APPDATA = Join-Path $fixtureRoot 'Roaming'
    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'Local'
    $release = Join-Path $fixtureRoot 'release with spaces'
    $fixtures = @{
        'ShadowNetworkAdmin.exe' = 'stub executable v1'
        'flutter_windows.dll' = 'flutter runtime'
        'sqlite3.dll' = 'database native asset'
        'data/app.so' = 'aot snapshot'
        'data/icudtl.dat' = 'icu'
        'data/flutter_assets/assets/map/tile.pbf' = 'offline asset'
        'data/flutter_assets/.assetkeep' = 'hidden-name asset'
        'native_assets/plugin/helper.dll' = 'nested native asset'
    }
    foreach ($entry in $fixtures.GetEnumerator()) {
        Write-Fixture (Join-Path $release $entry.Key) $entry.Value
    }
    $output = Join-Path $fixtureRoot 'packages'
    & $packageScript -ReleaseDirectory $release -OutputDirectory $output | Out-Null
    $archive = Join-Path $output 'ShadowNetworkAdmin-windows-x64.zip'
    Assert-True (Test-Path -LiteralPath $archive) 'Portable ZIP was not produced.'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $expanded = Join-Path $fixtureRoot 'extracted'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $expanded)
    foreach ($entry in $fixtures.GetEnumerator()) {
        $actual = [IO.File]::ReadAllText((Join-Path $expanded ('app/' + $entry.Key)))
        Assert-True ($actual -eq $entry.Value) ('Portable package lost or changed ' + $entry.Key)
    }
    Assert-True (Test-Path (Join-Path $expanded 'install.cmd')) 'One-click installer was not packaged.'
    $passed++; Write-Output 'PASS portable ZIP preserves executable, DLLs, data, and nested/hidden-name assets'

    $install = Join-Path $env:LOCALAPPDATA 'Programs/ShadowNetworkAdmin'
    $desktop = Join-Path $fixtureRoot 'Desktop'
    $startMenu = Join-Path $fixtureRoot 'Start Menu/Programs'
    $support = Join-Path $env:APPDATA 'ShadowNetwork/Admin'
    Write-Fixture (Join-Path $support 'admin_registry.sqlite') 'registry sentinel'
    Write-Fixture (Join-Path $support 'admin_validation.sqlite') 'validation sentinel'
    Write-Fixture (Join-Path $env:APPDATA 'protected-key-sentinel') 'protected key sentinel'
    & (Join-Path $expanded 'install.ps1') -InstallDirectory $install -DesktopDirectory $desktop -StartMenuDirectory $startMenu | Out-Null
    foreach ($entry in $fixtures.GetEnumerator()) {
        Assert-True ([IO.File]::ReadAllText((Join-Path $install $entry.Key)) -eq $entry.Value) ('Install lost ' + $entry.Key)
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($shortcutPath in @((Join-Path $desktop 'Shadow Network Admin.lnk'), (Join-Path $startMenu 'Shadow Network Admin.lnk'))) {
        Assert-True (Test-Path -LiteralPath $shortcutPath) 'Shortcut was not created.'
        $shortcut = $shell.CreateShortcut($shortcutPath)
        Assert-True ($shortcut.TargetPath -eq (Join-Path $install 'ShadowNetworkAdmin.exe')) 'Shortcut points at the wrong executable.'
        Assert-True ($shortcut.WorkingDirectory -eq $install) 'Shortcut must start with installed data directory available.'
    }
    $passed++; Write-Output 'PASS extracted installer copies the complete payload and creates real Desktop/Start-menu shortcuts'

    Write-Fixture (Join-Path $release 'ShadowNetworkAdmin.exe') 'stub executable v2'
    Write-Fixture (Join-Path $install 'old-plugin.dll') 'existing file retained'
    & $installScript -ReleaseDirectory $release -InstallDirectory $install -DesktopDirectory $desktop -StartMenuDirectory $startMenu | Out-Null
    Assert-True ([IO.File]::ReadAllText((Join-Path $install 'ShadowNetworkAdmin.exe')) -eq 'stub executable v2') 'Update did not replace binaries.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $support 'admin_registry.sqlite')) -eq 'registry sentinel') 'Update changed registry data.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $support 'admin_validation.sqlite')) -eq 'validation sentinel') 'Update changed imported evidence.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $env:APPDATA 'protected-key-sentinel')) -eq 'protected key sentinel') 'Update changed protected storage.'
    Assert-True (Test-Path (Join-Path $install 'old-plugin.dll')) 'Update deleted an existing file.'
    $passed++; Write-Output 'PASS update replaces binaries and preserves existing files, support databases, and protected-storage sentinel'

    foreach ($unsafeTarget in @($support, (Join-Path $support 'ShadowNetworkAdmin'), $env:APPDATA, $fixtureRoot, $release, (Join-Path $release 'ShadowNetworkAdmin'))) {
        Assert-Rejected { & $installScript -ReleaseDirectory $release -InstallDirectory $unsafeTarget -DesktopDirectory $desktop -StartMenuDirectory $startMenu } ('Unsafe install target accepted: ' + $unsafeTarget)
    }
    $passed++; Write-Output 'PASS installer rejects data storage, ancestors, and source-overlapping destinations'

    Assert-Rejected { & $packageScript -ReleaseDirectory $release -OutputDirectory (Join-Path $release 'package') } 'Packaging inside release recursively includes its own output.'
    Assert-Rejected { & $packageScript -ReleaseDirectory $release -OutputDirectory $output } 'Packaging overwrote an existing distribution.'
    $passed++; Write-Output 'PASS packaging rejects recursive output and existing distribution overwrite'

    $invalidRelease = Join-Path $fixtureRoot 'invalid-release'
    Write-Fixture (Join-Path $invalidRelease 'ShadowNetworkAdmin.exe') 'missing runtime'
    $unusedTarget = Join-Path $fixtureRoot 'unused/ShadowNetworkAdmin'
    Assert-Rejected { & $installScript -ReleaseDirectory $invalidRelease -InstallDirectory $unusedTarget -DesktopDirectory $desktop -StartMenuDirectory $startMenu } 'Incomplete release was accepted.'
    Assert-True (-not (Test-Path -LiteralPath $unusedTarget)) 'Invalid release changed installation.'
    $passed++; Write-Output 'PASS incomplete release is refused before creating an installation'

    $lockedFile = [IO.File]::Open((Join-Path $install 'ShadowNetworkAdmin.exe'), 'Open', 'Read', 'None')
    try {
        Assert-Rejected { & $installScript -ReleaseDirectory $release -InstallDirectory $install -DesktopDirectory $desktop -StartMenuDirectory $startMenu } 'Installer accepted a locked running executable.'
    } finally { $lockedFile.Dispose() }
    $passed++; Write-Output 'PASS locked executable is refused without stopping a process'

    $junction = Join-Path $release 'data/redirected'
    New-Item -ItemType Junction -Path $junction -Target $support | Out-Null
    try {
        Assert-Rejected { & $packageScript -ReleaseDirectory $release -OutputDirectory (Join-Path $fixtureRoot 'unsafe-package') } 'Packaging followed a reparse point into data storage.'
        Assert-Rejected { & $installScript -ReleaseDirectory $release -InstallDirectory $install -DesktopDirectory $desktop -StartMenuDirectory $startMenu } 'Install followed a release reparse point.'
    } finally { [IO.Directory]::Delete($junction) }
    $passed++; Write-Output 'PASS source reparse points cannot introduce external files into a distribution or install'

    $junctionParent = Join-Path $fixtureRoot 'redirected-install'
    New-Item -ItemType Junction -Path $junctionParent -Target $support | Out-Null
    try {
        Assert-Rejected { & $installScript -ReleaseDirectory $release -InstallDirectory (Join-Path $junctionParent 'ShadowNetworkAdmin') -DesktopDirectory $desktop -StartMenuDirectory $startMenu } 'Install target junction escaped validation.'
    } finally { [IO.Directory]::Delete($junctionParent) }
    $passed++; Write-Output 'PASS destination ancestor reparse points are rejected'

    Write-Output ("All $passed distribution tests passed. No app was executed and all writes used isolated test targets.")
} finally {
    $env:APPDATA = $savedAppData
    $env:LOCALAPPDATA = $savedLocalAppData
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if ($resolvedFixture.StartsWith($temporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
        ([IO.Path]::GetFileName($resolvedFixture)).StartsWith('shadow-admin-distribution-test-')) {
        if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
    } else { throw 'Refusing to clean an unverified test directory.' }
}
