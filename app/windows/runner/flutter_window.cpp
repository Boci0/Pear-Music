#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  updater_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "peerm/windows_updater",
          &flutter::StandardMethodCodec::GetInstance());

  updater_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "startDetachedProcess") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("INVALID_ARGS", "Expected argument map");
            return;
          }
          auto cmd_it = args->find(flutter::EncodableValue("commandLine"));
          if (cmd_it == args->end() ||
              !std::holds_alternative<std::string>(cmd_it->second)) {
            result->Error("INVALID_ARGS", "Expected string commandLine");
            return;
          }
          std::string cmd_str = std::get<std::string>(cmd_it->second);
          int len = ::MultiByteToWideChar(CP_UTF8, 0, cmd_str.c_str(), -1, nullptr, 0);
          if (len <= 0) {
            result->Error("CONVERSION_FAILED", "Failed to convert commandLine to UTF-16");
            return;
          }
          std::vector<wchar_t> wcmd(len);
          ::MultiByteToWideChar(CP_UTF8, 0, cmd_str.c_str(), -1, wcmd.data(), len);

          STARTUPINFOW si = {sizeof(si)};
          si.dwFlags = STARTF_USESHOWWINDOW;
          si.wShowWindow = SW_HIDE;
          PROCESS_INFORMATION pi = {0};

          // CREATE_BREAKAWAY_FROM_JOB is permitted because the Job Object was
          // created with JOB_OBJECT_LIMIT_BREAKAWAY_OK in main.cpp.
          BOOL ok = ::CreateProcessW(
              nullptr,
              wcmd.data(),
              nullptr,
              nullptr,
              FALSE,
              CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW,
              nullptr,
              nullptr,
              &si,
              &pi);

          if (ok) {
            ::CloseHandle(pi.hProcess);
            ::CloseHandle(pi.hThread);
            result->Success(flutter::EncodableValue(true));
          } else {
            DWORD err = ::GetLastError();
            result->Error("SPAWN_FAILED",
                          "CreateProcess failed with error code " + std::to_string(err));
          }
        } else {
          result->NotImplemented();
        }
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  updater_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
