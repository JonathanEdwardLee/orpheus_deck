import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'orpheus_native_duplex_bindings.dart';
import 'orpheus_native_n3_bindings.dart';
import 'orpheus_native_n3c_bindings.dart';
import 'orpheus_native_n3d_bindings.dart';

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
  OrpheusNativeBindings._(this.lib);

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

  final DynamicLibrary lib;

  late final int Function() init = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_native_init')
      .asFunction();

  late final int Function() openStreams = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_native_open_streams')
      .asFunction();

  late final int Function() playImpulse = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_native_play_impulse')
      .asFunction();

  late final int Function(Pointer<Utf8> wavPath, int durationMs) startRecord =
      lib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Utf8> wavPath, Int32 durationMs)>>(
            'orpheus_native_start_record',
          )
          .asFunction();

  late final int Function() stopRecord = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_native_stop_record')
      .asFunction();

  late final void Function(Pointer<OrpheusStreamDiagnostics> out)
      getDiagnostics = lib
          .lookup<
              NativeFunction<
                  Void Function(Pointer<OrpheusStreamDiagnostics> out)>>(
            'orpheus_native_get_diagnostics',
          )
          .asFunction();

  late final void Function() shutdown = lib
      .lookup<NativeFunction<Void Function()>>('orpheus_native_shutdown')
      .asFunction();

  late final Pointer<Utf8> Function() lastError = lib
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

  late final int Function() n2Init = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_native_n2_init')
      .asFunction();

  late final int Function() n2OpenStreams = lib
      .lookup<NativeFunction<Int32 Function()>>(
        'orpheus_native_n2_open_streams',
      )
      .asFunction();

  late final int Function(Pointer<Utf8> recordPath) n2StartDuplex = lib
      .lookup<NativeFunction<Int32 Function(Pointer<Utf8> recordPath)>>(
        'orpheus_native_n2_start_duplex',
      )
      .asFunction();

  late final int Function() n2IsComplete = lib
      .lookup<NativeFunction<Int32 Function()>>(
        'orpheus_native_n2_is_complete',
      )
      .asFunction();

  late final void Function(Pointer<OrpheusDuplexDiagnostics> out)
      n2GetDiagnostics = lib
          .lookup<
              NativeFunction<
                  Void Function(Pointer<OrpheusDuplexDiagnostics> out)>>(
            'orpheus_native_n2_get_diagnostics',
          )
          .asFunction();

  late final void Function() n2Shutdown = lib
      .lookup<NativeFunction<Void Function()>>('orpheus_native_n2_shutdown')
      .asFunction();

  late final int Function() n3Init = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_n3_init')
      .asFunction();

  late final int Function(Pointer<Utf8> path) n3GenerateTestWav = lib
      .lookup<NativeFunction<Int32 Function(Pointer<Utf8> path)>>(
        'orpheus_n3_generate_test_wav',
      )
      .asFunction();

  late final int Function(Pointer<Utf8> path) n3LoadWav = lib
      .lookup<NativeFunction<Int32 Function(Pointer<Utf8> path)>>(
        'orpheus_n3_load_wav',
      )
      .asFunction();

  late final int Function() n3OpenStreams = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_n3_open_streams')
      .asFunction();

  late final int Function(int startSample) n3StartPlayback = lib
      .lookup<NativeFunction<Int32 Function(Int64 startSample)>>(
        'orpheus_n3_start_playback',
      )
      .asFunction();

  late final void Function() n3StopPlayback = lib
      .lookup<NativeFunction<Void Function()>>('orpheus_n3_stop_playback')
      .asFunction();

  late final int Function() n3GetTransportSample = lib
      .lookup<NativeFunction<Int64 Function()>>('orpheus_n3_get_transport_sample')
      .asFunction();

  late final int Function() n3IsPlaybackComplete = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_n3_is_playback_complete')
      .asFunction();

  late final void Function(Pointer<OrpheusN3PlaybackDiagnostics> out)
      n3GetDiagnostics = lib
          .lookup<
              NativeFunction<
                  Void Function(Pointer<OrpheusN3PlaybackDiagnostics> out)>>(
            'orpheus_n3_get_diagnostics',
          )
          .asFunction();

  late final void Function() n3Shutdown = lib
      .lookup<NativeFunction<Void Function()>>('orpheus_n3_shutdown')
      .asFunction();

  late final int Function() n3cInit = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_n3c_init')
      .asFunction();

  late final int Function(Pointer<Utf8> backingPath) n3cGenerateBackingWav = lib
      .lookup<NativeFunction<Int32 Function(Pointer<Utf8> backingPath)>>(
        'orpheus_n3c_generate_backing_wav',
      )
      .asFunction();

  late final int Function(int offsetSamples) n3cSetDefaultRecordLatencyOffset =
      lib
          .lookup<NativeFunction<Int32 Function(Int64 offsetSamples)>>(
            'orpheus_n3c_set_default_record_latency_offset_samples',
          )
          .asFunction();

  late final int Function() n3cOpenStreams = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_n3c_open_streams')
      .asFunction();

  late final int Function(Pointer<Utf8> recordPath, int backingStartSample)
      n3cStartOverdub = lib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Utf8> recordPath,
                      Int64 backingStartSample)>>(
            'orpheus_n3c_start_overdub',
          )
          .asFunction();

  late final void Function() n3cStopOverdub = lib
      .lookup<NativeFunction<Void Function()>>('orpheus_n3c_stop_overdub')
      .asFunction();

  late final int Function() n3cIsComplete = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_n3c_is_complete')
      .asFunction();

  late final void Function(Pointer<OrpheusN3OverdubDiagnostics> out)
      n3cGetDiagnostics = lib
          .lookup<
              NativeFunction<
                  Void Function(Pointer<OrpheusN3OverdubDiagnostics> out)>>(
            'orpheus_n3c_get_diagnostics',
          )
          .asFunction();

  late final void Function() n3cShutdown = lib
      .lookup<NativeFunction<Void Function()>>('orpheus_n3c_shutdown')
      .asFunction();

  late final int Function() n3dInit = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_n3d_init')
      .asFunction();

  late final int Function(Pointer<Utf8> cacheDir) n3dGenerateAndLoadTestTracks =
      lib
          .lookup<NativeFunction<Int32 Function(Pointer<Utf8> cacheDir)>>(
            'orpheus_n3d_generate_and_load_test_tracks',
          )
          .asFunction();

  late final void Function() n3dUnloadAllTracks = lib
      .lookup<NativeFunction<Void Function()>>('orpheus_n3d_unload_all_tracks')
      .asFunction();

  late final int Function(
    int trackIndex,
    Pointer<Utf8> path,
    int tapeStartSample,
    int recordLatencyOffsetSamples,
  ) n3dLoadTrack = lib
      .lookup<
          NativeFunction<
              Int32 Function(
                Int32 trackIndex,
                Pointer<Utf8> path,
                Int64 tapeStartSample,
                Int64 recordLatencyOffsetSamples,
              )>>('orpheus_n3d_load_track')
      .asFunction();

  late final void Function(int tapeLengthSamples) n3dSetTapeLengthSamples = lib
      .lookup<NativeFunction<Void Function(Int64 tapeLengthSamples)>>(
        'orpheus_n3d_set_tape_length_samples',
      )
      .asFunction();

  late final int Function() n3dOpenStreams = lib
      .lookup<NativeFunction<Int32 Function()>>('orpheus_n3d_open_streams')
      .asFunction();

  late final int Function(int startSample) n3dStartMix = lib
      .lookup<NativeFunction<Int32 Function(Int64 startSample)>>(
        'orpheus_n3d_start_mix',
      )
      .asFunction();

  late final void Function() n3dStopMix = lib
      .lookup<NativeFunction<Void Function()>>('orpheus_n3d_stop_mix')
      .asFunction();

  late final void Function() n3dResetMixer = lib
      .lookup<NativeFunction<Void Function()>>('orpheus_n3d_reset_mixer')
      .asFunction();

  late final int Function(int trackIndex, double gain) n3dSetTrackGain = lib
      .lookup<NativeFunction<Int32 Function(Int32 trackIndex, Float gain)>>(
        'orpheus_n3d_set_track_gain',
      )
      .asFunction();

  late final int Function(int trackIndex, int muted) n3dSetTrackMute = lib
      .lookup<NativeFunction<Int32 Function(Int32 trackIndex, Int32 muted)>>(
        'orpheus_n3d_set_track_mute',
      )
      .asFunction();

  late final int Function(int trackIndex, int solo) n3dSetTrackSolo = lib
      .lookup<NativeFunction<Int32 Function(Int32 trackIndex, Int32 solo)>>(
        'orpheus_n3d_set_track_solo',
      )
      .asFunction();

  late final int Function() n3dGetTransportSample = lib
      .lookup<NativeFunction<Int64 Function()>>(
        'orpheus_n3d_get_transport_sample',
      )
      .asFunction();

  late final int Function() n3dIsPlaybackComplete = lib
      .lookup<NativeFunction<Int32 Function()>>(
        'orpheus_n3d_is_playback_complete',
      )
      .asFunction();

  late final void Function(Pointer<OrpheusN3MixerDiagnostics> out)
      n3dGetDiagnostics = lib
          .lookup<
              NativeFunction<
                  Void Function(Pointer<OrpheusN3MixerDiagnostics> out)>>(
            'orpheus_n3d_get_diagnostics',
          )
          .asFunction();

  late final void Function() n3dShutdown = lib
      .lookup<NativeFunction<Void Function()>>('orpheus_n3d_shutdown')
      .asFunction();

  OrpheusN3PlaybackDiagnosticsData readN3Diagnostics() {
    final ptr = calloc<OrpheusN3PlaybackDiagnostics>();
    try {
      n3GetDiagnostics(ptr);
      final d = ptr.ref;
      return OrpheusN3PlaybackDiagnosticsData(
        sampleRate: d.sampleRate,
        framesPerBurst: d.framesPerBurst,
        bufferSizeInFrames: d.bufferSizeInFrames,
        xRunCount: d.xRunCount,
        apiUsed: d.apiUsed,
        performanceMode: d.performanceMode,
        sharingMode: d.sharingMode,
        outputStreamOpened: d.outputStreamOpened,
        wavLoadSuccess: d.wavLoadSuccess,
        wavSampleRate: d.wavSampleRate,
        wavChannels: d.wavChannels,
        playbackComplete: d.playbackComplete,
        isPlaying: d.isPlaying,
        errorCode: d.errorCode,
        exclusiveAttempted: d.exclusiveAttempted,
        sharedFallbackUsed: d.sharedFallbackUsed,
        wavTotalFrames: d.wavTotalFrames,
        playbackStartSample: d.playbackStartSample,
        playbackStopSample: d.playbackStopSample,
        currentTransportSample: d.currentTransportSample,
        outputCallbackCount: d.outputCallbackCount,
      );
    } finally {
      calloc.free(ptr);
    }
  }

  OrpheusDuplexDiagnosticsData readDuplexDiagnostics() {
    final ptr = calloc<OrpheusDuplexDiagnostics>();
    try {
      n2GetDiagnostics(ptr);
      final d = ptr.ref;
      return OrpheusDuplexDiagnosticsData(
        sampleRate: d.sampleRate,
        framesPerBurst: d.framesPerBurst,
        bufferSizeInFrames: d.bufferSizeInFrames,
        xRunCount: d.xRunCount,
        apiUsed: d.apiUsed,
        performanceMode: d.performanceMode,
        sharingMode: d.sharingMode,
        outputStreamOpened: d.outputStreamOpened,
        inputStreamOpened: d.inputStreamOpened,
        wavWriteSuccess: d.wavWriteSuccess,
        backingPlaySuccess: d.backingPlaySuccess,
        recordSuccess: d.recordSuccess,
        exclusiveAttempted: d.exclusiveAttempted,
        sharedFallbackUsed: d.sharedFallbackUsed,
        lastOpenErrorCode: d.lastOpenErrorCode,
        androidSdkVersion: d.androidSdkVersion,
        backingFramesGenerated: d.backingFramesGenerated,
        recordedFramesWritten: d.recordedFramesWritten,
        transportStartSample: d.transportStartSample,
        transportStopSample: d.transportStopSample,
        outputCallbackCount: d.outputCallbackCount,
        inputCallbackCount: d.inputCallbackCount,
        firstOutputFrameSample: d.firstOutputFrameSample,
        firstInputFrameSample: d.firstInputFrameSample,
        estimatedInputOutputDeltaSamples: d.estimatedInputOutputDeltaSamples,
        clicksExpected: d.clicksExpected,
        clicksDetected: d.clicksDetected,
        analysisSuccess: d.analysisSuccess,
        analysisFailureReason: d.analysisFailureReason,
        confidencePercent: d.confidencePercent,
        medianOffsetMsTimes1000: d.medianOffsetMsTimes1000,
        medianOffsetSamples: d.medianOffsetSamples,
        minOffsetSamples: d.minOffsetSamples,
        maxOffsetSamples: d.maxOffsetSamples,
        spreadSamples: d.spreadSamples,
        recordLatencyOffsetSamples: d.recordLatencyOffsetSamples,
        compensatedAlignmentSuccess: d.compensatedAlignmentSuccess,
        compensatedQualityPercent: d.compensatedQualityPercent,
        compensatedMedianResidualMsTimes1000:
            d.compensatedMedianResidualMsTimes1000,
        perClickOffsetCount: d.perClickOffsetCount,
        appliedCompensationSamples: d.appliedCompensationSamples,
        compensatedMedianResidualSamples: d.compensatedMedianResidualSamples,
        compensatedResidualMinSamples: d.compensatedResidualMinSamples,
        compensatedResidualMaxSamples: d.compensatedResidualMaxSamples,
        compensatedResidualSpreadSamples: d.compensatedResidualSpreadSamples,
        perClickOffsets: [
          d.perClickOffset0,
          d.perClickOffset1,
          d.perClickOffset2,
          d.perClickOffset3,
          d.perClickOffset4,
          d.perClickOffset5,
        ],
        perClickResiduals: [
          d.perClickResidual0,
          d.perClickResidual1,
          d.perClickResidual2,
          d.perClickResidual3,
          d.perClickResidual4,
          d.perClickResidual5,
        ],
      );
    } finally {
      calloc.free(ptr);
    }
  }

  OrpheusN3OverdubDiagnosticsData readN3cDiagnostics() {
    final ptr = calloc<OrpheusN3OverdubDiagnostics>();
    try {
      n3cGetDiagnostics(ptr);
      final d = ptr.ref;
      return OrpheusN3OverdubDiagnosticsData(
        sampleRate: d.sampleRate,
        framesPerBurst: d.framesPerBurst,
        bufferSizeInFrames: d.bufferSizeInFrames,
        xRunCount: d.xRunCount,
        apiUsed: d.apiUsed,
        performanceMode: d.performanceMode,
        sharingMode: d.sharingMode,
        inputStreamOpened: d.inputStreamOpened,
        outputStreamOpened: d.outputStreamOpened,
        backingWavLoadSuccess: d.backingWavLoadSuccess,
        wavWriteSuccess: d.wavWriteSuccess,
        playbackComplete: d.playbackComplete,
        recordSuccess: d.recordSuccess,
        errorCode: d.errorCode,
        exclusiveAttempted: d.exclusiveAttempted,
        sharedFallbackUsed: d.sharedFallbackUsed,
        analysisSuccess: d.analysisSuccess,
        compensatedAlignmentSuccess: d.compensatedAlignmentSuccess,
        clicksDetected: d.clicksDetected,
        clicksExpected: d.clicksExpected,
        confidencePercent: d.confidencePercent,
        medianOffsetMsTimes1000: d.medianOffsetMsTimes1000,
        compensatedQualityPercent: d.compensatedQualityPercent,
        profileResidualMsTimes1000: d.profileResidualMsTimes1000,
        profileCompensationResult: d.profileCompensationResult,
        recordedFramesSanity: d.recordedFramesSanity,
        backingWavTotalFrames: d.backingWavTotalFrames,
        backingStartSample: d.backingStartSample,
        recordStartSample: d.recordStartSample,
        defaultRecordLatencyOffsetSamples: d.defaultRecordLatencyOffsetSamples,
        effectiveRecordStartSample: d.effectiveRecordStartSample,
        recordedFramesWritten: d.recordedFramesWritten,
        currentTransportSample: d.currentTransportSample,
        transportStopSample: d.transportStopSample,
        outputCallbackCount: d.outputCallbackCount,
        inputCallbackCount: d.inputCallbackCount,
        measuredMedianOffsetSamples: d.measuredMedianOffsetSamples,
        measuredSelfResidualSamples: d.measuredSelfResidualSamples,
        profileResidualSamples: d.profileResidualSamples,
        expectedRecordedFrames: d.expectedRecordedFrames,
      );
    } finally {
      calloc.free(ptr);
    }
  }

  OrpheusN3MixerDiagnosticsData readN3dDiagnostics() {
    final ptr = calloc<OrpheusN3MixerDiagnostics>();
    try {
      n3dGetDiagnostics(ptr);
      final d = ptr.ref;
      return OrpheusN3MixerDiagnosticsData(
        sampleRate: d.sampleRate,
        framesPerBurst: d.framesPerBurst,
        bufferSizeInFrames: d.bufferSizeInFrames,
        xRunCount: d.xRunCount,
        apiUsed: d.apiUsed,
        performanceMode: d.performanceMode,
        sharingMode: d.sharingMode,
        outputStreamOpened: d.outputStreamOpened,
        tracksLoaded: d.tracksLoaded,
        tracksActive: d.tracksActive,
        soloActive: d.soloActive,
        playbackComplete: d.playbackComplete,
        isPlaying: d.isPlaying,
        errorCode: d.errorCode,
        exclusiveAttempted: d.exclusiveAttempted,
        sharedFallbackUsed: d.sharedFallbackUsed,
        track0GainTimes1000: d.track0GainTimes1000,
        track1GainTimes1000: d.track1GainTimes1000,
        track2GainTimes1000: d.track2GainTimes1000,
        track3GainTimes1000: d.track3GainTimes1000,
        track0Muted: d.track0Muted,
        track1Muted: d.track1Muted,
        track2Muted: d.track2Muted,
        track3Muted: d.track3Muted,
        track0Solo: d.track0Solo,
        track1Solo: d.track1Solo,
        track2Solo: d.track2Solo,
        track3Solo: d.track3Solo,
        currentTransportSample: d.currentTransportSample,
        transportStartSample: d.transportStartSample,
        transportStopSample: d.transportStopSample,
        outputCallbackCount: d.outputCallbackCount,
        track0StartSample: d.track0StartSample,
        track1StartSample: d.track1StartSample,
        track2StartSample: d.track2StartSample,
        track3StartSample: d.track3StartSample,
        track0EffectiveStartSample: d.track0EffectiveStartSample,
        track1EffectiveStartSample: d.track1EffectiveStartSample,
        track2EffectiveStartSample: d.track2EffectiveStartSample,
        track3EffectiveStartSample: d.track3EffectiveStartSample,
        track0FramesMixed: d.track0FramesMixed,
        track1FramesMixed: d.track1FramesMixed,
        track2FramesMixed: d.track2FramesMixed,
        track3FramesMixed: d.track3FramesMixed,
      );
    } finally {
      calloc.free(ptr);
    }
  }
}
