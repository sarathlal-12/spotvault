import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Shazam audio fingerprint ("signature"): spectral peaks in four frequency
/// bands, in the binary format Shazam's recognition service takes (the same
/// format open-source clients such as SongRec and shazamio produce).
/// Input: 16 kHz mono 16-bit samples. Output: the signature URI.
class ShazamSignature {
  static const int sampleRate = 16000;

  final Int16List _ring = Int16List(2048);
  int _ringIndex = 0;
  final Float64List _reordered = Float64List(2048);

  final List<Float64List> _fft = List.generate(256, (_) => Float64List(1025));
  int _fftIndex = 0;

  final List<Float64List> _spread = List.generate(256, (_) => Float64List(1025));
  int _spreadIndex = 0;
  int _spreadWritten = 0;

  /// band (0..3) -> peaks
  final Map<int, List<_Peak>> _peaks = {};
  int _samples = 0;

  static final Float64List _hanning = Float64List.fromList(
      [for (var i = 0; i < 2048; i++) 0.5 - 0.5 * math.cos(2 * math.pi * (i + 1) / 2049)]);

  final _Fft2048 _fftObj = _Fft2048();

  /// Feeds samples; call [encode] after.
  void addSamples(Int16List pcm) {
    for (var off = 0; off + 128 <= pcm.length; off += 128) {
      _doFft(pcm, off);
      _doSpreading();
      if (_spreadWritten >= 46) _doRecognition();
    }
    _samples += pcm.length - pcm.length % 128;
  }

  int get sampleMs => (_samples * 1000 / sampleRate).round();

  void _doFft(Int16List pcm, int off) {
    for (var i = 0; i < 128; i++) {
      _ring[_ringIndex + i] = pcm[off + i];
    }
    _ringIndex = (_ringIndex + 128) & 2047;
    for (var i = 0; i < 2048; i++) {
      _reordered[i] = _ring[(i + _ringIndex) & 2047] * _hanning[i];
    }
    final out = _fft[_fftIndex];
    _fftObj.power(_reordered, out);
    _fftIndex = (_fftIndex + 1) & 255;
  }

  void _doSpreading() {
    final last = _fft[(_fftIndex - 1) & 255];
    final spread = _spread[_spreadIndex];
    spread.setAll(0, last);
    for (var p = 0; p <= 1022; p++) {
      spread[p] = math.max(spread[p], math.max(spread[p + 1], spread[p + 2]));
    }
    for (var p = 0; p <= 1024; p++) {
      for (final back in const [1, 3, 6]) {
        final former = _spread[(_spreadIndex - back) & 255];
        if (spread[p] > former[p]) former[p] = spread[p];
      }
    }
    _spreadIndex = (_spreadIndex + 1) & 255;
    _spreadWritten++;
  }

  void _doRecognition() {
    final f46 = _fft[(_fftIndex - 46) & 255];
    final s49 = _spread[(_spreadIndex - 49) & 255];
    for (var bin = 10; bin <= 1014; bin++) {
      final v = f46[bin];
      if (v < 1 / 64 || v < s49[bin - 1]) continue;
      var maxN = 0.0;
      for (final o in const [-10, -7, -4, -3, 1, 2, 5, 8]) {
        maxN = math.max(maxN, s49[bin + o]);
      }
      if (v <= maxN) continue;
      var maxOther = maxN;
      for (final o in const [-53, -45, 165, 172, 179, 186, 193, 200, 214, 221, 228, 235, 242, 249]) {
        maxOther = math.max(maxOther, _spread[(_spreadIndex + o) & 255][bin - 1]);
      }
      if (v <= maxOther) continue;
      final fftNumber = _spreadWritten - 46;
      double mag(double x) => math.log(math.max(1 / 64, x)) * 1477.3 + 6144;
      final m = mag(v), before = mag(f46[bin - 1]), after = mag(f46[bin + 1]);
      final var1 = m * 2 - before - after;
      if (var1 <= 0) continue;
      final var2 = (after - before) * 32 / var1;
      final corrected = (bin * 64 + var2.truncate()) & 0xFFFF;
      final hz = corrected * (16000 / 2 / 1024 / 64);
      final h = hz.truncate();
      final int band;
      if (h >= 250 && h <= 519) {
        band = 0;
      } else if (h >= 520 && h <= 1449) {
        band = 1;
      } else if (h >= 1450 && h <= 3499) {
        band = 2;
      } else if (h >= 3500 && h <= 5500) {
        band = 3;
      } else {
        continue;
      }
      (_peaks[band] ??= []).add(_Peak(fftNumber, m.truncate() & 0xFFFF, corrected));
    }
  }

  /// The binary signature, as Shazam's "data:audio/vnd.shazam.sig;base64,..." URI.
  String encode() {
    final contents = BytesBuilder();
    for (final band in (_peaks.keys.toList()..sort())) {
      final peaks = BytesBuilder();
      var pass = 0;
      for (final p in _peaks[band]!) {
        if (p.pass - pass >= 255) {
          peaks.addByte(0xff);
          peaks.add(_u32(p.pass));
          pass = p.pass;
        }
        peaks.addByte(p.pass - pass);
        peaks.add(_u16(p.magnitude));
        peaks.add(_u16(p.bin));
        pass = p.pass;
      }
      final bytes = peaks.toBytes();
      contents.add(_u32(0x60030040 + band));
      contents.add(_u32(bytes.length));
      contents.add(bytes);
      for (var i = 0; i < (4 - bytes.length % 4) % 4; i++) {
        contents.addByte(0);
      }
    }
    final body = contents.toBytes();
    final out = BytesBuilder();
    out.add(_u32(0xcafe2580)); // magic
    out.add(_u32(0)); // crc32, filled below
    out.add(_u32(body.length + 8)); // size minus header
    out.add(_u32(0x94119c00)); // magic 2
    out.add(_u32(0));
    out.add(_u32(0));
    out.add(_u32(0));
    out.add(_u32(3 << 27)); // 16 kHz
    out.add(_u32(0));
    out.add(_u32(0));
    out.add(_u32((_samples + sampleRate * 0.24).truncate()));
    out.add(_u32((15 << 19) + 0x40000));
    out.add(_u32(0x40000000));
    out.add(_u32(body.length + 8));
    out.add(body);
    final all = out.toBytes();
    final crc = _crc32(Uint8List.sublistView(all, 8));
    ByteData.sublistView(all).setUint32(4, crc, Endian.little);
    return 'data:audio/vnd.shazam.sig;base64,${base64.encode(all)}';
  }

  static Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v & 0xFFFFFFFF, Endian.little)).buffer.asUint8List();
  static Uint8List _u16(int v) => (ByteData(2)..setUint16(0, v & 0xFFFF, Endian.little)).buffer.asUint8List();

  static final List<int> _crcTable = List.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  static int _crc32(Uint8List data) {
    var c = 0xFFFFFFFF;
    for (final b in data) {
      c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

class _Peak {
  final int pass, magnitude, bin;
  _Peak(this.pass, this.magnitude, this.bin);
}

/// 2048-point FFT of real input; [power] writes |X[k]|^2 / 2^17 for k = 0..1024.
class _Fft2048 {
  static const int n = 2048;
  final Float64List _re = Float64List(n);
  final Float64List _im = Float64List(n);
  final Float64List _cos = Float64List(n ~/ 2);
  final Float64List _sin = Float64List(n ~/ 2);
  final Int32List _rev = Int32List(n);

  _Fft2048() {
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / n);
      _sin[i] = -math.sin(2 * math.pi * i / n);
    }
    var bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if ((i >> b) & 1 != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  void power(Float64List input, Float64List out) {
    for (var i = 0; i < n; i++) {
      _re[_rev[i]] = input[i];
      _im[_rev[i]] = 0;
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step], wi = _sin[k * step];
          final a = start + k, b = a + half;
          final tr = _re[b] * wr - _im[b] * wi;
          final ti = _re[b] * wi + _im[b] * wr;
          _re[b] = _re[a] - tr;
          _im[b] = _im[a] - ti;
          _re[a] += tr;
          _im[a] += ti;
        }
      }
    }
    for (var k = 0; k <= 1024; k++) {
      out[k] = math.max((_re[k] * _re[k] + _im[k] * _im[k]) / (1 << 17), 0.0000000001);
    }
  }
}
