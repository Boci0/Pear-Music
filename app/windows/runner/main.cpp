#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  wchar_t exe_path[MAX_PATH] = {0};
  ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  const bool is_beta = (::wcsstr(exe_path, L"Pear Music Beta") != nullptr) ||
                       (command_line != nullptr && ::wcsstr(command_line, L"--beta") != nullptr);

  const wchar_t* const mutex_name =
      is_beta ? L"PearMusic_Beta_SingleInstance_Mutex" : L"PearMusic_SingleInstance_Mutex";
  const wchar_t* const window_title =
      is_beta ? L"Pear Music (Beta)" : L"Pear Music";

  // Prevent multiple concurrent instances on Windows.
  // A second instance running against the same local databases causes
  // port/socket conflicts, mutual signaling disconnections, and high CPU/RAM spikes.
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, mutex_name);
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing_window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", window_title);
    if (existing_window) {
      if (::IsIconic(existing_window)) {
        ::ShowWindow(existing_window, SW_RESTORE);
      }
      ::SetForegroundWindow(existing_window);
      if (mutex) {
        ::CloseHandle(mutex);
      }
      return EXIT_SUCCESS;
    }
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
  Win32Window::Size size(412, 780);
  if (!window.Create(window_title, origin, size)) {
    if (mutex) ::CloseHandle(mutex);
    return EXIT_FAILURE;
  }
  // Centre on first launch (no saved window state); otherwise the restored
  // position from the previous run is kept.
  if (!window.RestoredBounds()) {
    window.CenterOnScreen();
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (mutex) ::CloseHandle(mutex);
  return EXIT_SUCCESS;
}
