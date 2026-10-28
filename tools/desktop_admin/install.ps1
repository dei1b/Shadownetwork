[CmdletBinding()]
param(
    [string] $ReleaseDirectory = (Join-Path $PSScriptRoot 'app'),
    [string] $InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs/ShadowNetworkAdmin'),
    [string] $DesktopDirectory = [Environment]::GetFolderPath('Desktop'),
    [string] $StartMenuDirectory = [Environment]::GetFolderPath('Programs')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$release = Get-AdminRelease $ReleaseDirectory
$install = Get-AdminFullPath $InstallDirectory
if ([IO.Path]::GetFileName($install) -ne 'ShadowNetworkAdmin') {
    throw 'The application installation directory must be named ShadowNetworkAdmin.'
}
if ((Test-AdminPathWithin $install $release.Root) -or (Test-AdminPathWithin $release.Root $install)) {
    throw 'Source and installation directories must not overlap.'
}
# Roaming application data contains administrator databases and protected storage.
# This installer writes only its application directory and the two shortcut files.
$roaming = Get-AdminFullPath $env:APPDATA
if ((Test-AdminPathWithin $install $roaming) -or (Test-AdminPathWithin $roaming $install)) {
    throw 'Installation must be separate from roaming application data and protected keys.'
}
$desktop = Get-AdminFullPath $DesktopDirectory
$startMenu = Get-AdminFullPath $StartMenuDirectory
$shortcutPaths = @((Join-Path $desktop 'Shadow Network Admin.lnk'), (Join-Path $startMenu 'Shadow Network Admin.lnk'))
foreach ($path in @($install, $desktop, $startMenu) + $shortcutPaths) { Assert-AdminNoReparseAncestors $path }

# Preflight every file before copying. Locked files require the user to close the
# app normally; never identify or terminate arbitrary processes.
foreach ($item in $release.Entries) {
    $target = Join-Path $install ($item.FullName.Substring($release.Root.Length + 1))
    Assert-AdminNoReparseAncestors $target
    if (-not $item.PSIsContainer -and [IO.File]::Exists($target)) {
        try {
            $probe = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $probe.Dispose()
        } catch {
            throw "Cannot update $target. Close Shadow Network Admin and retry. No process has been stopped."
        }
    }
}
Copy-AdminRelease $release $install
$executable = Join-Path $install 'ShadowNetworkAdmin.exe'
$shell = New-Object -ComObject WScript.Shell
foreach ($shortcutPath in $shortcutPaths) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($shortcutPath)) | Out-Null
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $executable
    $shortcut.WorkingDirectory = $install
    $shortcut.IconLocation = "$executable,0"
    $shortcut.Description = 'Shadow Network Admin'
    $shortcut.Save()
}
Write-Output "Installed Shadow Network Admin: $executable"
Write-Output 'Desktop and Start-menu shortcuts created. Administrator data and protected keys were preserved.'
