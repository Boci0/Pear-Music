#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Dedicated channel to launch updater scripts outside the job object.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> updater_channel_;

  // Pushes WM_ACTIVATE focus changes to Dart. The Flutter app lifecycle on
  // Windows only reports minimize/restore, so the visualizer cannot otherwise
  // learn that the window lost focus while still being visible.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> focus_channel_;

  // Forwards hardware media keys (delivered as WM_APPCOMMAND on Windows, which
  // the Flutter engine ignores) so they can drive playback controls.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> media_channel_;

  // Mirrors the playing song into the window caption ("Song · Pear Music"),
  // the way desktop players show what is playing in the title bar.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> title_channel_;

  // Caption the window had before the app started rewriting it.
  std::wstring original_title_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
