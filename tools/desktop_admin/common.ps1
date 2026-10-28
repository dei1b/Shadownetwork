Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AdminFullPath([string] $Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A non-empty filesystem path is required.' }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-AdminPathWithin([string] $Path, [string] $Parent) {
    return $Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-AdminNoReparseAncestors([string] $Path) {
    $current = $Path
    while (-not [string]::IsNullOrEmpty($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in distribution paths: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Get-AdminRelease([string] $Directory) {
    $root = Get-AdminFullPath $Directory
    Assert-AdminNoReparseAncestors $root
    if (-not [IO.Directory]::Exists($root)) { throw "Release directory not found: $root" }
    foreach ($required in @('ShadowNetworkAdmin.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat')) {
        if (-not [IO.File]::Exists((Join-Path $root $required))) {
            throw "Incomplete Windows release; missing $required. Build lib/admin_desktop_main.dart in release mode first."
        }
    }
    if (-not [IO.Directory]::Exists((Join-Path $root 'data/flutter_assets'))) {
        throw 'Incomplete Windows release; missing data/flutter_assets.'
    }
    $entries = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Release contains a reparse point: $($item.FullName)"
            }
            $entries.Add($item)
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
    return [pscustomobject]@{ Root = $root; Entries = $entries }
}

function Copy-AdminRelease($Release, [string] $Destination) {
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($item in $Release.Entries) {
        $relativePath = $item.FullName.Substring($Release.Root.Length + 1)
        $target = Join-Path $Destination $relativePath
        if ($item.PSIsContainer) {
            [IO.Directory]::CreateDirectory($target) | Out-Null
        } else {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            [IO.File]::Copy($item.FullName, $target, $true)
        }
    }
}
