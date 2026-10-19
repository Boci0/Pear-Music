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

  // The design gallery (lib/dev/gallery_main.dart, installed as PearGallery*)
  // runs beside the real app, so it gets its own instance lock and caption.
  const bool is_gallery = ::wcsstr(exe_path, L"PearGallery") != nullptr;
  const wchar_t* const mutex_name =
      is_gallery ? L"PearMusic_Gallery_SingleInstance_Mutex"
      : is_beta  ? L"PearMusic_Beta_SingleInstance_Mutex"
                 : L"PearMusic_SingleInstance_Mutex";
  const wchar_t* const window_title =
      is_gallery ? L"Pear Gallery" : is_beta ? L"Pear Music (Beta)" : L"Pear Music";

  // Prevent multiple concurrent instances on Windows.
  // A second instance running against the same local databases causes
  // port/socket conflicts, mutual signaling disconnections, and high CPU/RAM spikes.
  // Restart launches us with --relaunch while the old instance is still
  // shutting down. Wait for it to let go of the mutex (released when that
  // process exits) instead of handing off to its window, which is about to
  // close. Past the timeout, fall back to the normal hand-off.
  const bool is_relaunch =
      command_line != nullptr && ::wcsstr(command_line, L"--relaunch") != nullptr;
  // Automated checks: never take focus (see Win32Window::SetNoFocus).
  const bool no_focus =
      command_line != nullptr && ::wcsstr(command_line, L"--no-focus") != nullptr;
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, mutex_name);
  bool another_instance = ::GetLastError() == ERROR_ALREADY_EXISTS;
  if (is_relaunch && mutex && another_instance) {
    const DWORD waited = ::WaitForSingleObject(mutex, 15000);
    another_instance = !(waited == WAIT_OBJECT_0 || waited == WAIT_ABANDONED);
  }
  // The gallery writes nothing, so several may run side by side.
  if (another_instance && !is_gallery) {
    HWND existing_window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", window_title);
    if (existing_window) {
      if (!no_focus) {
        if (::IsIconic(existing_window)) {
          ::ShowWindow(existing_window, SW_RESTORE);
        }
        ::SetForegroundWindow(existing_window);
      }
      if (mutex) {
        ::CloseHandle(mutex);
      }
      return EXIT_SUCCESS;
    }
  }

  // Ensure all child and descendant processes (e.g. yt-dlp.exe, ffmpeg.exe)
  // are automatically terminated by Windows kernel when the app process exits or closes.
  HANDLE job = ::CreateJobObjectW(nullptr, nullptr);
  if (job != nullptr) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli = {0};
    jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                                           | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
    ::SetInformationJobObject(job, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
    ::AssignProcessToJobObject(job, ::GetCurrentProcess());
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
  window.SetNoFocus(no_focus);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(432, 960);
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
  if (job) ::CloseHandle(job);
  if (mutex) ::CloseHandle(mutex);
  return EXIT_SUCCESS;
}
