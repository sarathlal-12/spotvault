#include "audio_capture.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

template <class T>
void SafeRelease(T** p) {
  if (*p) {
    (*p)->Release();
    *p = nullptr;
  }
}

// Mono float samples at [rate] -> 16 kHz mono int16 (linear interpolation).
std::vector<uint8_t> To16k(const std::vector<float>& mono, double rate) {
  std::vector<uint8_t> out;
  if (mono.empty() || rate <= 0) return out;
  const double step = rate / 16000.0;
  const size_t n = static_cast<size_t>(mono.size() / step);
  out.resize(n * 2);
  for (size_t i = 0; i < n; i++) {
    const double pos = i * step;
    const size_t a = static_cast<size_t>(pos);
    const size_t b = std::min(a + 1, mono.size() - 1);
    const double f = pos - a;
    double v = mono[a] * (1 - f) + mono[b] * f;
    v = std::max(-1.0, std::min(1.0, v));
    const int16_t s = static_cast<int16_t>(std::lround(v * 32767));
    out[i * 2] = static_cast<uint8_t>(s & 0xff);
    out[i * 2 + 1] = static_cast<uint8_t>((s >> 8) & 0xff);
  }
  return out;
}

}  // namespace

AudioCapture::AudioCapture(flutter::BinaryMessenger* messenger, HWND window) : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "spotvault/capture", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { OnMethodCall(call, std::move(result)); });
}

AudioCapture::~AudioCapture() {
  if (worker_.joinable()) worker_.join();
}

void AudioCapture::OnMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "record") {
    result->NotImplemented();
    return;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (pending_) {
    result->Error("busy", "Already listening");
    return;
  }
  bool loopback = true;
  int ms = 10000;
  if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
    auto src = args->find(flutter::EncodableValue("source"));
    if (src != args->end()) {
      if (const auto* s = std::get_if<std::string>(&src->second)) loopback = *s != "mic";
    }
    auto len = args->find(flutter::EncodableValue("ms"));
    if (len != args->end()) {
      if (const auto* v = std::get_if<int32_t>(&len->second)) ms = std::clamp(*v, 1000, 20000);
    }
  }
  pending_ = std::move(result);
  pcm_.clear();
  error_.clear();
  if (worker_.joinable()) worker_.join();
  worker_ = std::thread([this, loopback, ms] {
    Record(loopback, ms);
    PostMessage(window_, kMessage, 0, 0);
  });
}

void AudioCapture::Record(bool loopback, int ms) {
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  WAVEFORMATEX* format = nullptr;
  std::vector<float> mono;
  std::string error;

  do {
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator)))) {
      error = "No audio devices";
      break;
    }
    if (FAILED(enumerator->GetDefaultAudioEndpoint(loopback ? eRender : eCapture, eConsole, &device))) {
      error = loopback ? "No speakers or headphones found" : "No microphone found";
      break;
    }
    if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(&client))) ||
        FAILED(client->GetMixFormat(&format))) {
      error = "Couldn't open the audio device";
      break;
    }
    const REFERENCE_TIME buffer = 10000000;  // 1 s
    if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED, loopback ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0, buffer, 0,
                                  format, nullptr)) ||
        FAILED(client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void**>(&capture)))) {
      error = loopback ? "Couldn't listen to the PC's sound" : "Couldn't use the microphone. Check Windows privacy settings.";
      break;
    }
    // Float or 16-bit samples (the shared-mode mix format is almost always float).
    bool is_float = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
      auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(format);
      is_float = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    }
    const int channels = format->nChannels;
    const int bits = format->wBitsPerSample;
    const double rate = format->nSamplesPerSec;
    const size_t wanted = static_cast<size_t>(rate * ms / 1000.0);
    mono.reserve(wanted);
    client->Start();
    const ULONGLONG started = GetTickCount64();
    while (mono.size() < wanted && GetTickCount64() - started < static_cast<ULONGLONG>(ms) + 1500) {
      Sleep(20);
      UINT32 packet = 0;
      while (SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) break;
        for (UINT32 f = 0; f < frames; f++) {
          double sum = 0;
          if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
            for (int c = 0; c < channels; c++) {
              const size_t i = static_cast<size_t>(f) * channels + c;
              if (is_float && bits == 32) {
                sum += reinterpret_cast<float*>(data)[i];
              } else if (bits == 16) {
                sum += reinterpret_cast<int16_t*>(data)[i] / 32768.0;
              } else if (bits == 32) {
                sum += reinterpret_cast<int32_t*>(data)[i] / 2147483648.0;
              }
            }
          }
          mono.push_back(static_cast<float>(sum / channels));
        }
        capture->ReleaseBuffer(frames);
      }
    }
    client->Stop();
    // Loopback sends nothing while the PC is silent.
    double peak = 0;
    for (float v : mono) peak = std::max(peak, static_cast<double>(std::fabs(v)));
    if (mono.size() < wanted / 3 || peak < 0.003) {
      error = loopback ? "Nothing is playing on this PC." : "The microphone heard only silence.";
      break;
    }
    pcm_ = To16k(mono, rate);
  } while (false);

  if (format) CoTaskMemFree(format);
  SafeRelease(&capture);
  SafeRelease(&client);
  SafeRelease(&device);
  SafeRelease(&enumerator);
  if (SUCCEEDED(co)) CoUninitialize();
  error_ = error;
}

bool AudioCapture::HandleMessage(UINT message, WPARAM, LPARAM) {
  if (message != kMessage) return false;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    result = std::move(pending_);
  }
  if (!result) return true;
  if (!error_.empty()) {
    result->Error("capture", error_);
  } else {
    result->Success(flutter::EncodableValue(pcm_));
  }
  return true;
}
