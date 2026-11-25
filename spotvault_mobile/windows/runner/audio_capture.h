#ifndef RUNNER_AUDIO_CAPTURE_H_
#define RUNNER_AUDIO_CAPTURE_H_

// Short audio recordings for song recognition (WASAPI).
//
// Dart calls "spotvault/capture" record {source, ms}:
//   source "system": what the PC is playing right now (loopback of the default
//                    speakers/headphones, no microphone needed)
//   source "mic":    the default microphone
// and gets back 16 kHz mono 16-bit little-endian PCM (Uint8List). The recording
// runs on its own thread; the result is posted back to the window and sent
// from the platform thread.

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

class AudioCapture {
 public:
  AudioCapture(flutter::BinaryMessenger* messenger, HWND window);
  ~AudioCapture();

  static constexpr UINT kMessage = WM_APP + 0x52;
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void OnMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Record(bool loopback, int ms);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::thread worker_;
  std::mutex mutex_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> pending_;
  std::vector<uint8_t> pcm_;
  std::string error_;
};

#endif  // RUNNER_AUDIO_CAPTURE_H_
