# Shadow Network Admin for Windows

Extract the entire ZIP before using it. Start `app\ShadowNetworkAdmin.exe` for
portable use, or double-click `install.cmd` to install for your Windows user.
Installation needs Windows PowerShell 5.1 (included with Windows) and no
administrator rights or installer compiler. Managed Windows execution policies
may require your organization's approval. The app is not started by installation.

The installer copies all application binaries, DLLs, Flutter data and native
assets to `%LOCALAPPDATA%\Programs\ShadowNetworkAdmin` and creates **Shadow Network
Admin** shortcuts on the Desktop and in your Start menu. Keep all release files
together; copying the EXE alone does not work. Use the matching Windows x64 build
and the Microsoft Visual C++ 2015-2022 x64 runtime required by Flutter Windows.
This package does not silently install system prerequisites.

Close Shadow Network Admin normally before updating. Run the new package's
`install.cmd` to copy the new binaries. Locked destination files are refused;
the installer never stops processes. Updates copy files without deleting old
ones. Copy failure (for example, loss of disk space) can leave a partial binary
update; retry the complete package after resolving the error. The installer is
not a transactional or signed setup program.

Administrator databases live separately at `%APPDATA%\ShadowNetwork\Admin`;
Windows-protected identity keys are also outside the binaries. Installation and
updates never remove those locations. Portable use still uses the same per-user
data and identity, rather than a registry stored beside the EXE. Only one admin
process runs per Windows session; another launch focuses the existing window.

This package does not transfer an identity from browser storage or recover a
lost administrator key. Use the app's encrypted administrator backup for identity
and registry recovery. Imported validation JSON evidence needs its own original
files and separate imports. Never delete support data or protected keys as an
installation troubleshooting step.

To remove the binaries, close the app, delete only the installation directory
above and its two shortcuts. Keep the separate support data and protected keys
for future reinstallation. There is intentionally no data-purge/uninstall script.

## Building and packaging

From the repository root, with Flutter's Windows desktop prerequisites installed:

The Windows secure-storage plugin additionally requires **C++ ATL for v143 build
tools (x86 & x64)** in Visual Studio Build Tools 2022. A compiler error for
`atlstr.h` means that optional component is missing. Add the ATL component that
matches the installed MSVC toolset through Visual Studio Installer; do not alter
the plugin source or replace protected storage to bypass this prerequisite.
Keep the Windows runner's CompanyName/ProductName stable across updates because
the secure-storage plugin uses that metadata to locate protected files.

```powershell
flutter pub get
flutter build windows --release -t lib/admin_desktop_main.dart
powershell -NoProfile -ExecutionPolicy Bypass -File tools/desktop_admin/package.ps1 `
  -ReleaseDirectory build/windows/x64/runner/Release `
  -OutputDirectory dist/windows-admin-2026-10-27
```

The result is `ShadowNetworkAdmin-windows-x64.zip` and an equivalent unpacked
directory. Each includes the complete `app` tree and installation helpers. Use a
fresh output directory for each release; existing packages are never overwritten.
The packager does not inspect private signing or Firebase configuration because
it only consumes the compiled Windows release directory. Review those settings
before building or sharing any artifact.

The per-user install can also run directly from the repository:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/desktop_admin/install.ps1 `
  -ReleaseDirectory build/windows/x64/runner/Release
```

For isolated verification, `install.ps1` accepts `-InstallDirectory`,
`-DesktopDirectory`, and `-StartMenuDirectory`. The install directory must have
the leaf name `ShadowNetworkAdmin`, be separate from the release and roaming
application data, and contain no reparse points. None of these scripts launches
the executable, creates/removes administrator identities, or deletes files.

Run the self-contained file-copy, portable ZIP and real Windows shortcut tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/desktop_admin/tests/distribution_test.ps1
```

Tests substitute isolated temporary application-data and shortcut directories,
use stub binary files, and clean only the verified unique test directory. They do
not launch or install the live application or write the actual user's shortcuts.
