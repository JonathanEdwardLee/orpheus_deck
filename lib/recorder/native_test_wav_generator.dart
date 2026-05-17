/// Debug WAV generation for native_test projects (N3E-G).
library;

import 'dart:io';
import 'dart:typed_data';

const int kNativeTestWavSampleRate = 48000;
const int kNativeTestWavDurationSeconds = 10;

/// Writes a mono PCM16 WAV matching N3D test-track click pattern.
Future<void> writeNativeTestTrackWav({
  required String path,
  required int trackIndex,
  int sampleRate = kNativeTestWavSampleRate,
  int durationSeconds = kNativeTestWavDurationSeconds,
}) async {
  final int rate = sampleRate > 0 ? sampleRate : kNativeTestWavSampleRate;
  final int seconds =
      durationSeconds > 0 ? durationSeconds : kNativeTestWavDurationSeconds;
  final int totalFrames = rate * seconds;
  final Float32List samples = Float32List(totalFrames);
  const int burstFrames = 96;

  for (int sec = 0; sec < seconds; sec++) {
    final int clickStart = sec * rate;
    if (trackIndex == 3) {
      const double doubleLevel = 0.30;
      for (int burst = 0; burst < 2; burst++) {
        final int burstStart = clickStart + burst * 48;
        for (int i = 0; i < burstFrames; i++) {
          final int idx = burstStart + i;
          if (idx < totalFrames) {
            samples[idx] = doubleLevel;
          }
        }
      }
      continue;
    }

    double level = 0.35;
    if (trackIndex == 1) {
      level = 0.45;
    } else if (trackIndex == 2) {
      level = 0.55;
    }

    for (int i = 0; i < burstFrames; i++) {
      final int idx = clickStart + i;
      if (idx < totalFrames) {
        samples[idx] = level;
      }
    }
  }

  final bytes = _encodeMonoPcm16Wav(samples, rate);
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
}

/// Placeholder waveform for UI (50 ms buckets).
List<double> nativeTestTrackWaveformPlaceholder(int trackIndex) {
  const int buckets = kNativeTestWavDurationSeconds * 20;
  final w = List<double>.filled(buckets, 0.02);
  for (int sec = 0; sec < kNativeTestWavDurationSeconds; sec++) {
    final int idx = sec * 20;
    if (idx < buckets) {
      w[idx] = trackIndex == 3 ? 0.35 : 0.25 + trackIndex * 0.08;
    }
  }
  return w;
}

Uint8List _encodeMonoPcm16Wav(Float32List samples, int sampleRate) {
  final int numSamples = samples.length;
  final int dataBytes = numSamples * 2;
  final int fileSize = 44 + dataBytes;
  final bd = ByteData(fileSize);

  void writeStr(int offset, String s) {
    for (int i = 0; i < s.length; i++) {
      bd.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeStr(0, 'RIFF');
  bd.setUint32(4, fileSize - 8, Endian.little);
  writeStr(8, 'WAVE');
  writeStr(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * 2, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  writeStr(36, 'data');
  bd.setUint32(40, dataBytes, Endian.little);

  int o = 44;
  for (int i = 0; i < numSamples; i++) {
    final int pcm =
        (samples[i].clamp(-1.0, 1.0) * 32767.0).round().clamp(-32768, 32767);
    bd.setInt16(o, pcm, Endian.little);
    o += 2;
  }

  return bd.buffer.asUint8List();
}
