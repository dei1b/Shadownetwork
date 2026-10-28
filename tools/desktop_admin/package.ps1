[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ReleaseDirectory,
    [Parameter(Mandatory = $true)][string] $OutputDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$release = Get-AdminRelease $ReleaseDirectory
$output = Get-AdminFullPath $OutputDirectory
Assert-AdminNoReparseAncestors $output
if ((Test-AdminPathWithin $output $release.Root) -or (Test-AdminPathWithin $release.Root $output)) {
    throw 'Output and release directories must be separate, without overlapping.'
}
$packageDirectory = Join-Path $output 'ShadowNetworkAdmin-windows-x64'
$archivePath = Join-Path $output 'ShadowNetworkAdmin-windows-x64.zip'
if ((Test-Path -LiteralPath $packageDirectory) -or (Test-Path -LiteralPath $archivePath)) {
    throw 'Distribution already exists. Choose a new output directory; existing packages are never overwritten.'
}
[IO.Directory]::CreateDirectory($packageDirectory) | Out-Null
Copy-AdminRelease $release (Join-Path $packageDirectory 'app')
foreach ($file in @('common.ps1', 'install.ps1', 'install.cmd', 'README.md')) {
    [IO.File]::Copy((Join-Path $PSScriptRoot $file), (Join-Path $packageDirectory $file), $false)
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($packageDirectory, $archivePath, [IO.Compression.CompressionLevel]::Optimal, $false)
Write-Output "Portable directory: $packageDirectory"
Write-Output "Portable ZIP: $archivePath"
