#include "flutter_window.h"

#include <optional>

#include <shcore.h>
#include <shlwapi.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
// Posted from the System Media Transport Controls event handlers so the
// channel calls happen on the platform thread inside the message loop.
constexpr UINT kMediaButtonMessage = WM_APP + 3;
constexpr UINT kMediaSeekMessage = WM_APP + 4;
}  // namespace

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

  focus_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "peerm/window_focus",
          &flutter::StandardMethodCodec::GetInstance());

  media_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "peerm/media_keys",
          &flutter::StandardMethodCodec::GetInstance());

  title_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "peerm/window_title",
          &flutter::StandardMethodCodec::GetInstance());

  title_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setTitle") {
          const auto* title = std::get_if<std::string>(call.arguments());
          if (!title) {
            result->Error("INVALID_ARGS", "Expected string title");
            return;
          }
          int len = ::MultiByteToWideChar(CP_UTF8, 0, title->c_str(), -1, nullptr, 0);
          if (len <= 0) {
            result->Error("CONVERSION_FAILED", "Failed to convert title to UTF-16");
            return;
          }
          std::vector<wchar_t> wtitle(len);
          ::MultiByteToWideChar(CP_UTF8, 0, title->c_str(), -1, wtitle.data(), len);
          ::SetWindowTextW(GetHandle(), wtitle.data());
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "resetTitle") {
          if (original_title_.empty()) {
            wchar_t buffer[512];
            int copied = ::GetWindowTextW(GetHandle(), buffer, 512);
            original_title_.assign(buffer, copied > 0 ? copied : 0);
          }
          ::SetWindowTextW(GetHandle(), original_title_.c_str());
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "getTitle") {
          wchar_t buffer[512];
          int copied = ::GetWindowTextW(GetHandle(), buffer, 512);
          if (copied < 0) {
            copied = 0;
          }
          if (original_title_.empty() && copied > 0) {
            original_title_.assign(buffer, copied);
          }
          int utf8_len = ::WideCharToMultiByte(CP_UTF8, 0, buffer, copied,
                                               nullptr, 0, nullptr, nullptr);
          std::string utf8(utf8_len > 0 ? utf8_len : 0, '\0');
          if (utf8_len > 0) {
            ::WideCharToMultiByte(CP_UTF8, 0, buffer, copied, utf8.data(),
                                  utf8_len, nullptr, nullptr);
          }
          result->Success(flutter::EncodableValue(utf8));
        } else {
          result->NotImplemented();
        }
      });

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

  media_session_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "peerm/media_session",
          &flutter::StandardMethodCodec::GetInstance());

  // Wire the Windows System Media Transport Controls (taskbar thumbnail
  // buttons and the volume flyout panel), the desktop counterpart of the
  // Android media notification.
  try {
    winrt::init_apartment(winrt::apartment_type::single_threaded);
  } catch (...) {
    // Already initialised on this thread.
  }
  try {
    auto interop = winrt::get_activation_factory<
        winrt::Windows::Media::SystemMediaTransportControls,
        ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(
        GetHandle(),
        winrt::guid_of<winrt::Windows::Media::SystemMediaTransportControls>(),
        winrt::put_abi(smtc_)));
    smtc_.IsEnabled(true);
    smtc_.IsPlayEnabled(true);
    smtc_.IsPauseEnabled(true);
    smtc_.IsNextEnabled(true);
    smtc_.IsPreviousEnabled(true);
    smtc_.IsStopEnabled(false);

    smtc_button_token_ = smtc_.ButtonPressed(
        [this](const winrt::Windows::Media::SystemMediaTransportControls&,
               const winrt::Windows::Media::
                   SystemMediaTransportControlsButtonPressedEventArgs& args) {
          static constexpr WPARAM kPlay = 1;
          static constexpr WPARAM kPause = 2;
          static constexpr WPARAM kNext = 3;
          static constexpr WPARAM kPrevious = 4;
          WPARAM command = 0;
          switch (args.Button()) {
            case winrt::Windows::Media::SystemMediaTransportControlsButton::Play:
              command = kPlay;
              break;
            case winrt::Windows::Media::SystemMediaTransportControlsButton::Pause:
              command = kPause;
              break;
            case winrt::Windows::Media::SystemMediaTransportControlsButton::Next:
              command = kNext;
              break;
            case winrt::Windows::Media::SystemMediaTransportControlsButton::
                Previous:
              command = kPrevious;
              break;
            default:
              return;
          }
          ::PostMessage(GetHandle(), kMediaButtonMessage, command, 0);
        });

    smtc_position_token_ = smtc_.PlaybackPositionChangeRequested(
        [this](const winrt::Windows::Media::SystemMediaTransportControls&,
               const winrt::Windows::Media::
                   PlaybackPositionChangeRequestedEventArgs& args) {
          int64_t ms = static_cast<int64_t>(
              std::chrono::duration_cast<std::chrono::milliseconds>(
                  args.RequestedPlaybackPosition())
                  .count());
          ::PostMessage(GetHandle(), kMediaSeekMessage, 0,
                        static_cast<LPARAM>(ms));
        });
  } catch (...) {
    smtc_ = nullptr;
  }

  media_session_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (!smtc_) {
          result->Success(flutter::EncodableValue(false));
          return;
        }
        const std::string& method = call.method_name();

        if (method == "setMetadata") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("INVALID_ARGS", "Expected map");
            return;
          }
          std::string title;
          std::string artist;
          auto t = args->find(flutter::EncodableValue("title"));
          if (t != args->end() &&
              std::holds_alternative<std::string>(t->second)) {
            title = std::get<std::string>(t->second);
          }
          auto a = args->find(flutter::EncodableValue("artist"));
          if (a != args->end() &&
              std::holds_alternative<std::string>(a->second)) {
            artist = std::get<std::string>(a->second);
          }
          try {
            auto updater = smtc_.DisplayUpdater();
            updater.Type(winrt::Windows::Media::MediaPlaybackType::Music);
            auto props = updater.MusicProperties();
            props.Title(winrt::to_hstring(title));
            props.Artist(winrt::to_hstring(artist));
            updater.Update();
            result->Success(flutter::EncodableValue(true));
          } catch (const winrt::hresult_error&) {
            result->Success(flutter::EncodableValue(false));
          }
        } else if (method == "setArtwork") {
          const auto* bytes =
              std::get_if<std::vector<uint8_t>>(call.arguments());
          if (!bytes || bytes->empty()) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          try {
            // Wrap the bytes in a memory stream synchronously. Waiting on
            // DataWriter's async Store/Flush here would block the UI (STA)
            // thread, which C++/WinRT rejects with an is_sta_thread assert.
            winrt::com_ptr<IStream> memory;
            memory.attach(::SHCreateMemStream(
                bytes->data(), static_cast<UINT>(bytes->size())));
            if (!memory) {
              result->Success(flutter::EncodableValue(false));
              return;
            }
            winrt::Windows::Storage::Streams::IRandomAccessStream stream{
                nullptr};
            winrt::check_hresult(::CreateRandomAccessStreamOverStream(
                memory.get(), BSOS_DEFAULT,
                winrt::guid_of<
                    winrt::Windows::Storage::Streams::IRandomAccessStream>(),
                winrt::put_abi(stream)));
            smtc_.DisplayUpdater().Thumbnail(
                winrt::Windows::Storage::Streams::
                    RandomAccessStreamReference::CreateFromStream(stream));
            smtc_.DisplayUpdater().Update();
            result->Success(flutter::EncodableValue(true));
          } catch (const winrt::hresult_error&) {
            result->Success(flutter::EncodableValue(false));
          }
        } else if (method == "setPlaybackState") {
          const auto* status = std::get_if<std::string>(call.arguments());
          if (!status) {
            result->Error("INVALID_ARGS", "Expected status string");
            return;
          }
          try {
            if (*status == "playing") {
              smtc_.PlaybackStatus(
                  winrt::Windows::Media::MediaPlaybackStatus::Playing);
            } else if (*status == "paused") {
              smtc_.PlaybackStatus(
                  winrt::Windows::Media::MediaPlaybackStatus::Paused);
            } else {
              smtc_.PlaybackStatus(
                  winrt::Windows::Media::MediaPlaybackStatus::Stopped);
            }
            smtc_.PlaybackRate(1.0);
            result->Success(flutter::EncodableValue(true));
          } catch (const winrt::hresult_error&) {
            result->Success(flutter::EncodableValue(false));
          }
        } else if (method == "setTimeline") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("INVALID_ARGS", "Expected map");
            return;
          }
          auto read_ms = [&args](const char* key) -> int64_t {
            auto it = args->find(flutter::EncodableValue(key));
            if (it == args->end()) return 0;
            if (std::holds_alternative<int64_t>(it->second)) {
              return std::get<int64_t>(it->second);
            }
            if (std::holds_alternative<int32_t>(it->second)) {
              return static_cast<int64_t>(std::get<int32_t>(it->second));
            }
            return 0;
          };
          int64_t position_ms = read_ms("positionMs");
          int64_t end_ms = read_ms("endMs");
          try {
            winrt::Windows::Media::
                SystemMediaTransportControlsTimelineProperties timeline;
            timeline.StartTime(winrt::Windows::Foundation::TimeSpan{0});
            timeline.MinSeekTime(winrt::Windows::Foundation::TimeSpan{0});
            timeline.Position(
                winrt::Windows::Foundation::TimeSpan{position_ms * 10000});
            timeline.EndTime(
                winrt::Windows::Foundation::TimeSpan{end_ms * 10000});
            timeline.MaxSeekTime(
                winrt::Windows::Foundation::TimeSpan{end_ms * 10000});
            smtc_.UpdateTimelineProperties(timeline);
            result->Success(flutter::EncodableValue(true));
          } catch (const winrt::hresult_error&) {
            result->Success(flutter::EncodableValue(false));
          }
        } else if (method == "setEnabled") {
          const auto* enabled = std::get_if<bool>(call.arguments());
          try {
            smtc_.IsEnabled(enabled != nullptr && *enabled);
            result->Success(flutter::EncodableValue(true));
          } catch (const winrt::hresult_error&) {
            result->Success(flutter::EncodableValue(false));
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
  focus_channel_ = nullptr;
  media_channel_ = nullptr;
  title_channel_ = nullptr;
  media_session_channel_ = nullptr;
  if (smtc_ != nullptr) {
    try {
      smtc_.ButtonPressed(smtc_button_token_);
      smtc_.PlaybackPositionChangeRequested(smtc_position_token_);
      smtc_.IsEnabled(false);
    } catch (...) {
      // Window going away; nothing to do.
    }
    smtc_ = nullptr;
  }
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

    case WM_ACTIVATE: {
      // WM_ACTIVATE also arrives as WA_INACTIVE when minimizing. Dart uses
      // this to pause visualizer rendering when the window is open on screen
      // but not being used.
      const bool active = LOWORD(wparam) != WA_INACTIVE;
      if (focus_channel_) {
        focus_channel_->InvokeMethod(
            "onActivate",
            std::make_unique<flutter::EncodableValue>(active));
      }
      break;
    }

    case WM_APPCOMMAND: {
      // Hardware media keys arrive here and the Flutter engine has no use for
      // them, so forward the transport commands to Dart and swallow them.
      const int command = GET_APPCOMMAND_LPARAM(lparam);
      const char* method = nullptr;
      switch (command) {
        case APPCOMMAND_MEDIA_PLAY_PAUSE:
          method = "playPause";
          break;
        case APPCOMMAND_MEDIA_NEXTTRACK:
          method = "next";
          break;
        case APPCOMMAND_MEDIA_PREVIOUSTRACK:
          method = "previous";
          break;
        default:
          break;
      }
      if (method != nullptr && media_channel_) {
        media_channel_->InvokeMethod(method, nullptr);
        return TRUE;
      }
      break;
    }

    case kMediaButtonMessage: {
      // Taskbar / volume-flyout transport buttons from the System Media
      // Transport Controls.
      if (media_session_channel_) {
        const char* command = nullptr;
        switch (wparam) {
          case 1:
            command = "play";
            break;
          case 2:
            command = "pause";
            break;
          case 3:
            command = "next";
            break;
          case 4:
            command = "previous";
            break;
        }
        if (command != nullptr) {
          media_session_channel_->InvokeMethod(
              "buttonPressed",
              std::make_unique<flutter::EncodableValue>(std::string(command)));
        }
      }
      return 0;
    }

    case kMediaSeekMessage: {
      // Seek request coming from the taskbar timeline scrubber.
      if (media_session_channel_) {
        const int64_t ms = static_cast<int64_t>(lparam);
        if (ms >= 0) {
          media_session_channel_->InvokeMethod(
              "seekTo", std::make_unique<flutter::EncodableValue>(ms));
        }
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
