import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Dart copy of native diagnostics (safe after FFI buffer is freed).
class OrpheusNativeDiagnosticsData {
  const OrpheusNativeDiagnosticsData({
    required this.sampleRate,
    required this.framesPerBurst,
    required this.bufferSizeInFrames,
    required this.xRunCount,
    required this.performanceMode,
    required this.sharingMode,
    required this.apiUsed,
    required this.inputStreamOpened,
    required this.outputStreamOpened,
    required this.wavWriteSuccess,
    required this.requestedSampleRate,
    required this.actualSampleRate,
    required this.requestedSharingMode,
    required this.actualSharingMode,
    required this.requestedPerformanceMode,
    required this.actualPerformanceMode,
    required this.exclusiveAttempted,
    required this.sharedFallbackUsed,
    required this.unspecifiedAudioApi,
    required this.lastOpenErrorCode,
    required this.androidSdkVersion,
  });

  final int sampleRate;
  final int framesPerBurst;
  final int bufferSizeInFrames;
  final int xRunCount;
  final int performanceMode;
  final int sharingMode;
  final int apiUsed;
  final int inputStreamOpened;
  final int outputStreamOpened;
  final int wavWriteSuccess;

  final int requestedSampleRate;
  final int actualSampleRate;
  final int requestedSharingMode;
  final int actualSharingMode;
  final int requestedPerformanceMode;
  final int actualPerformanceMode;
  final int exclusiveAttempted;
  final int sharedFallbackUsed;
  final int unspecifiedAudioApi;
  final int lastOpenErrorCode;
  final int androidSdkVersion;
}

/// Native Phase N1 diagnostics — must match OrpheusStreamDiagnostics in audio_types.h.
@Packed(4)
final class OrpheusStreamDiagnostics extends Struct {
  @Int32()
  external int sampleRate;

  @Int32()
  external int framesPerBurst;

  @Int32()
  external int bufferSizeInFrames;

  @Int32()
  external int xRunCount;

  @Int32()
  external int performanceMode;

  @Int32()
  external int sharingMode;

  @Int32()
  external int apiUsed;

  @Int32()
  external int inputStreamOpened;

  @Int32()
  external int outputStreamOpened;

  @Int32()
  external int wavWriteSuccess;

  @Int32()
  external int requestedSampleRate;

  @Int32()
  external int actualSampleRate;

  @Int32()
  external int requestedSharingMode;

  @Int32()
  external int actualSharingMode;

  @Int32()
  external int requestedPerformanceMode;

  @Int32()
  external int actualPerformanceMode;

  @Int32()
  external int exclusiveAttempted;

  @Int32()
  external int sharedFallbackUsed;

  @Int32()
  external int unspecifiedAudioApi;

  @Int32()
  external int lastOpenErrorCode;

  @Int32()
  external int androidSdkVersion;
}

/// Loads liborpheus_native.so (Android N1 Oboe handshake).
class OrpheusNativeBindings {
  OrpheusNativeBindings._(this._lib);

  static OrpheusNativeBindings? _instance;

  static OrpheusNativeBindings get instance {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Orpheus native audio is Android-only in Phase N1');
    }
    return _instance ??= OrpheusNativeBindings._(
      DynamicLibrary.open('liborpheus_native.so'),
    );
  }

  /// Clears cached library handle so a new process load can occur after hot restart.
  static void resetInstance() {
    _instance = null;
  }

  final DynamicLibrary _lib;

  late final int Function() init = _lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_native_init')
      .asFunction();

  late final int Function() openStreams = _lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_native_open_streams')
      .asFunction();

  late final int Function() playImpulse = _lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_native_play_impulse')
      .asFunction();

  late final int Function(Pointer<Utf8> wavPath, int durationMs) startRecord =
      _lib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Utf8> wavPath, Int32 durationMs)>>(
            'orpheus_native_start_record',
          )
          .asFunction();

  late final int Function() stopRecord = _lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_native_stop_record')
      .asFunction();

  late final void Function(Pointer<OrpheusStreamDiagnostics> out)
      getDiagnostics = _lib
          .lookup<
              NativeFunction<
                  Void Function(Pointer<OrpheusStreamDiagnostics> out)>>(
            'orpheus_native_get_diagnostics',
          )
          .asFunction();

  late final void Function() shutdown = _lib
      .lookup<NativeFunction<Void Function()>>('orpheus_native_shutdown')
      .asFunction();

  late final Pointer<Utf8> Function() lastError = _lib
      .lookup<NativeFunction<Pointer<Utf8> Function()>>(
        'orpheus_native_last_error',
      )
      .asFunction();

  OrpheusNativeDiagnosticsData readDiagnostics() {
    final ptr = calloc<OrpheusStreamDiagnostics>();
    try {
      getDiagnostics(ptr);
      final d = ptr.ref;
      return OrpheusNativeDiagnosticsData(
        sampleRate: d.sampleRate,
        framesPerBurst: d.framesPerBurst,
        bufferSizeInFrames: d.bufferSizeInFrames,
        xRunCount: d.xRunCount,
        performanceMode: d.performanceMode,
        sharingMode: d.sharingMode,
        apiUsed: d.apiUsed,
        inputStreamOpened: d.inputStreamOpened,
        outputStreamOpened: d.outputStreamOpened,
        wavWriteSuccess: d.wavWriteSuccess,
        requestedSampleRate: d.requestedSampleRate,
        actualSampleRate: d.actualSampleRate,
        requestedSharingMode: d.requestedSharingMode,
        actualSharingMode: d.actualSharingMode,
        requestedPerformanceMode: d.requestedPerformanceMode,
        actualPerformanceMode: d.actualPerformanceMode,
        exclusiveAttempted: d.exclusiveAttempted,
        sharedFallbackUsed: d.sharedFallbackUsed,
        unspecifiedAudioApi: d.unspecifiedAudioApi,
        lastOpenErrorCode: d.lastOpenErrorCode,
        androidSdkVersion: d.androidSdkVersion,
      );
    } finally {
      calloc.free(ptr);
    }
  }

  String readLastError() => lastError().toDartString();
}
