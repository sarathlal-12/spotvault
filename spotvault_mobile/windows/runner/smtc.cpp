#include "smtc.h"

#include <flutter/standard_method_codec.h>
#include <systemmediatransportcontrolsinterop.h>

#include <algorithm>
#include <iostream>
#include <string>
#include <thread>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties;
using winrt::Windows::Media::PlaybackPositionChangeRequestedEventArgs;

namespace {

// Button codes posted to the window (WPARAM).
enum Code : WPARAM { kPlay = 1, kPause, kNext, kPrevious, kStop, kSeek };

std::string StringArg(const EncodableMap& args, const char* key) {
  auto it = args.find(EncodableValue(key));
  if (it == args.end()) return "";
  if (auto s = std::get_if<std::string>(&it->second)) return *s;
  return "";
}

int64_t IntArg(const EncodableMap& args, const char* key) {
  auto it = args.find(EncodableValue(key));
  if (it == args.end()) return 0;
  if (auto i = std::get_if<int32_t>(&it->second)) return *i;
  if (auto l = std::get_if<int64_t>(&it->second)) return *l;
  if (auto d = std::get_if<double>(&it->second)) return static_cast<int64_t>(*d);
  return 0;
}

// Milliseconds to a WinRT TimeSpan (100 ns ticks).
winrt::Windows::Foundation::TimeSpan Ms(int64_t ms) {
  return winrt::Windows::Foundation::TimeSpan{ms * 10000};
}

}  // namespace

Smtc::Smtc(flutter::BinaryMessenger* messenger, HWND window) : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "spotvault/smtc", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { OnMethodCall(call, std::move(result)); });

  try {
    auto interop = winrt::get_activation_factory<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(window_, winrt::guid_of<SystemMediaTransportControls>(), winrt::put_abi(controls_)));
    controls_.IsPlayEnabled(true);
    controls_.IsPauseEnabled(true);
    controls_.IsNextEnabled(true);
    controls_.IsPreviousEnabled(true);
    controls_.IsStopEnabled(true);
    controls_.IsEnabled(false);  // until a song is loaded
    controls_.DisplayUpdater().Type(MediaPlaybackType::Music);

    HWND hwnd = window_;
    button_token_ = controls_.ButtonPressed([hwnd](SystemMediaTransportControls const&, SystemMediaTransportControlsButtonPressedEventArgs const& args) {
      WPARAM code = 0;
      switch (args.Button()) {
        case SystemMediaTransportControlsButton::Play: code = kPlay; break;
        case SystemMediaTransportControlsButton::Pause: code = kPause; break;
        case SystemMediaTransportControlsButton::Next: code = kNext; break;
        case SystemMediaTransportControlsButton::Previous: code = kPrevious; break;
        case SystemMediaTransportControlsButton::Stop: code = kStop; break;
        default: return;
      }
      PostMessage(hwnd, kMessage, code, 0);
    });
    seek_token_ = controls_.PlaybackPositionChangeRequested([this, hwnd](SystemMediaTransportControls const&, PlaybackPositionChangeRequestedEventArgs const& args) {
      pending_seek_ms_ = args.RequestedPlaybackPosition().count() / 10000;
      PostMessage(hwnd, kMessage, kSeek, 0);
    });
  } catch (...) {
    controls_ = nullptr;  // older Windows or no media controls: the app works without them
  }
}

Smtc::~Smtc() {
  if (!controls_) return;
  try {
    controls_.ButtonPressed(button_token_);
    controls_.PlaybackPositionChangeRequested(seek_token_);
    std::lock_guard<std::mutex> lock(mutex_);
    controls_.DisplayUpdater().ClearAll();
    controls_.DisplayUpdater().Update();
    controls_.PlaybackStatus(MediaPlaybackStatus::Closed);
    controls_.IsEnabled(false);
  } catch (...) {
  }
}

bool Smtc::HandleMessage(UINT message, WPARAM wparam, LPARAM) {
  if (message != kMessage || !channel_) return false;
  switch (wparam) {
    case kPlay: channel_->InvokeMethod("onButton", std::make_unique<EncodableValue>("play")); break;
    case kPause: channel_->InvokeMethod("onButton", std::make_unique<EncodableValue>("pause")); break;
    case kNext: channel_->InvokeMethod("onButton", std::make_unique<EncodableValue>("next")); break;
    case kPrevious: channel_->InvokeMethod("onButton", std::make_unique<EncodableValue>("previous")); break;
    case kStop: channel_->InvokeMethod("onButton", std::make_unique<EncodableValue>("stop")); break;
    case kSeek: channel_->InvokeMethod("onSeek", std::make_unique<EncodableValue>(static_cast<int64_t>(pending_seek_ms_.load()))); break;
  }
  return true;
}

void Smtc::OnMethodCall(const flutter::MethodCall<EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (!controls_) {
    result->Success();  // no media controls on this PC: quietly do nothing
    return;
  }
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  const EncodableMap empty;
  const EncodableMap& a = args ? *args : empty;
  try {
    const std::string& name = call.method_name();
    if (name == "update") {
      const int gen = ++*generation_;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        auto updater = controls_.DisplayUpdater();
        updater.ClearAll();
        updater.Type(MediaPlaybackType::Music);
        auto music = updater.MusicProperties();
        music.Title(winrt::to_hstring(StringArg(a, "title")));
        music.Artist(winrt::to_hstring(StringArg(a, "artist")));
        music.AlbumTitle(winrt::to_hstring(StringArg(a, "album")));
        updater.Update();
        controls_.IsEnabled(true);
      }
      const std::string art = StringArg(a, "art");
      if (!art.empty()) {
        // Loading the image file is async; do it off the UI thread. A newer song
        // (higher generation) wins, so a slow old cover never replaces a new one.
        auto controls = controls_;
        auto generation = generation_;
        auto* mutex = &mutex_;
        std::thread([controls, generation, gen, art, mutex]() {
          try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            // The Windows file API only takes backslashes.
            std::string path = art;
            std::replace(path.begin(), path.end(), '/', '\\');
            auto file = winrt::Windows::Storage::StorageFile::GetFileFromPathAsync(winrt::to_hstring(path)).get();
            auto ref = winrt::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromFile(file);
            if (generation->load() != gen) return;
            std::lock_guard<std::mutex> lock(*mutex);
            if (generation->load() != gen) return;
            auto updater = controls.DisplayUpdater();
            updater.Thumbnail(ref);
            updater.Update();
          } catch (const winrt::hresult_error& e) {
            std::cerr << "SMTC cover failed: " << winrt::to_string(e.message()) << " (" << art << ")" << std::endl;
          } catch (...) {
            std::cerr << "SMTC cover failed (" << art << ")" << std::endl;
          }
        }).detach();
      }
      result->Success();
    } else if (name == "state") {
      const std::string status = StringArg(a, "status");
      controls_.PlaybackStatus(status == "playing"   ? MediaPlaybackStatus::Playing
                               : status == "stopped" ? MediaPlaybackStatus::Stopped
                                                     : MediaPlaybackStatus::Paused);
      const int64_t duration = IntArg(a, "duration");
      SystemMediaTransportControlsTimelineProperties timeline;
      timeline.StartTime(Ms(0));
      timeline.MinSeekTime(Ms(0));
      timeline.EndTime(Ms(duration));
      timeline.MaxSeekTime(Ms(duration));
      timeline.Position(Ms(std::min(IntArg(a, "position"), duration)));
      controls_.UpdateTimelineProperties(timeline);
      result->Success();
    } else if (name == "clear") {
      ++*generation_;
      std::lock_guard<std::mutex> lock(mutex_);
      controls_.DisplayUpdater().ClearAll();
      controls_.DisplayUpdater().Update();
      controls_.PlaybackStatus(MediaPlaybackStatus::Closed);
      controls_.IsEnabled(false);
      result->Success();
    } else {
      result->NotImplemented();
    }
  } catch (const winrt::hresult_error& e) {
    result->Error("smtc", winrt::to_string(e.message()));
  } catch (...) {
    result->Error("smtc", "Media controls failed");
  }
}
