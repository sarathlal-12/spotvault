#ifndef RUNNER_SMTC_H_
#define RUNNER_SMTC_H_

// Windows media controls (System Media Transport Controls) for SpotVault.
//
// The Win+A media box, the lock screen, keyboard media keys and apps that read
// Windows media sessions all see what SpotVault plays. Dart drives it over the
// "spotvault/smtc" channel:
//   update {title, artist, album, art}      the song (art: a local image path, or "")
//   state  {status, position, duration}     "playing" | "paused" | "stopped", in ms
//   clear                                   nothing loaded: hide from Windows
// Buttons come back as onButton("play" | "pause" | "next" | "previous" | "stop")
// and seeks as onSeek(ms).

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <atomic>
#include <memory>
#include <mutex>

#include <winrt/Windows.Media.h>

class Smtc {
 public:
  Smtc(flutter::BinaryMessenger* messenger, HWND window);
  ~Smtc();

  // Button and seek events arrive on a Windows thread pool thread; they are
  // posted to the window as this message and forwarded to Dart from there.
  static constexpr UINT kMessage = WM_APP + 0x51;
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void OnMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  winrt::Windows::Media::SystemMediaTransportControls controls_{nullptr};
  winrt::event_token button_token_{};
  winrt::event_token seek_token_{};
  std::mutex mutex_;                       // guards the display updater
  std::shared_ptr<std::atomic<int>> generation_ = std::make_shared<std::atomic<int>>(0);
  std::atomic<int64_t> pending_seek_ms_{0};
};

#endif  // RUNNER_SMTC_H_
