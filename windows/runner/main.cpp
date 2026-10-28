#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <memory>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kAdminWindowTitle[] = L"Shadow Network Admin";
// Local\\ confines the mutex to this Windows session, including portable launches.
constexpr wchar_t kAdminMutexName[] =
    L"Local\\ShadowNetworkAdmin.SessionInstance";

void FocusExistingAdminWindow() {
  // Another launch may still be creating its window after acquiring the mutex.
  for (int attempt = 0; attempt < 50; ++attempt) {
    HWND existing =
        ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", kAdminWindowTitle);
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      }
      ::BringWindowToTop(existing);
      ::SetForegroundWindow(existing);
      return;
    }
    ::Sleep(100);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE mutex_handle = ::CreateMutexW(nullptr, FALSE, kAdminMutexName);
  const DWORD mutex_error = ::GetLastError();
  // Keep this handle until after the Flutter window is destroyed, on every exit
  // path. Windows also closes it if the process crashes; no stale lock remains.
  const std::unique_ptr<void, decltype(&::CloseHandle)> instance_mutex(
      mutex_handle, &::CloseHandle);
  if (mutex_handle == nullptr) {
    ::MessageBoxW(nullptr, L"Cannot establish the administrator app instance.",
                  kAdminWindowTitle, MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  if (mutex_error == ERROR_ALREADY_EXISTS) {
    FocusExistingAdminWindow();
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kAdminWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
