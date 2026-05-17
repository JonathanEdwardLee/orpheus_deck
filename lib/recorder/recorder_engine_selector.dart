/// Pure-Dart engine selection for N3E (no native calls, no session I/O).
library;

/// Dev-only: set `true` locally to simulate a native-eligible project in debug UI.
/// Must stay `false` in committed builds until N3F/N3E-A explicitly enable eligibility.
const bool kOrpheusDevNativeProjectEligibleOverride = false;

enum OrpheusAudioEngineKind {
  legacy,
  nativeExperimental,
}

/// Result of [selectRecorderEngine] — describes what would run, not what is running.
class RecorderEngineSelection {
  const RecorderEngineSelection({
    required this.selectedKind,
    required this.nativeRequested,
    required this.nativeEligible,
    required this.reason,
  });

  final OrpheusAudioEngineKind selectedKind;
  final bool nativeRequested;
  final bool nativeEligible;
  final String reason;

  bool get isLegacy => selectedKind == OrpheusAudioEngineKind.legacy;
}

/// Chooses legacy vs native-experimental without touching audio devices.
RecorderEngineSelection selectRecorderEngine({
  required bool experimentalNativeAudioEngineEnabled,
  required bool isDebugBuild,
  required bool projectIsNativeEligible,
  required bool projectHasLegacyM4aTracks,
  required bool platformIsAndroid,
}) {
  final bool nativeRequested = experimentalNativeAudioEngineEnabled;

  if (!nativeRequested) {
    return const RecorderEngineSelection(
      selectedKind: OrpheusAudioEngineKind.legacy,
      nativeRequested: false,
      nativeEligible: false,
      reason: '',
    );
  }

  if (!isDebugBuild) {
    return const RecorderEngineSelection(
      selectedKind: OrpheusAudioEngineKind.legacy,
      nativeRequested: true,
      nativeEligible: false,
      reason: '',
    );
  }

  if (!platformIsAndroid) {
    return const RecorderEngineSelection(
      selectedKind: OrpheusAudioEngineKind.legacy,
      nativeRequested: true,
      nativeEligible: false,
      reason: '',
    );
  }

  if (projectHasLegacyM4aTracks) {
    return const RecorderEngineSelection(
      selectedKind: OrpheusAudioEngineKind.legacy,
      nativeRequested: true,
      nativeEligible: false,
      reason: 'LEGACY M4A PROJECT',
    );
  }

  if (!projectIsNativeEligible) {
    return const RecorderEngineSelection(
      selectedKind: OrpheusAudioEngineKind.legacy,
      nativeRequested: true,
      nativeEligible: false,
      reason: 'NATIVE TEST PROJECT REQUIRED',
    );
  }

  return const RecorderEngineSelection(
    selectedKind: OrpheusAudioEngineKind.nativeExperimental,
    nativeRequested: true,
    nativeEligible: true,
    reason: '',
  );
}

/// Debug deck header line (kDebugMode only).
String formatRecorderEngineDebugLine(RecorderEngineSelection selection) {
  switch (selection.selectedKind) {
    case OrpheusAudioEngineKind.nativeExperimental:
      return 'ENGINE: NATIVE EXPERIMENTAL SELECTED - NOT WIRED';
    case OrpheusAudioEngineKind.legacy:
      switch (selection.reason) {
        case 'LEGACY M4A PROJECT':
          return 'ENGINE: LEGACY - LEGACY M4A PROJECT';
        case 'NATIVE TEST PROJECT REQUIRED':
          return 'ENGINE: LEGACY - NATIVE TEST PROJECT REQUIRED';
        default:
          return 'ENGINE: LEGACY';
      }
  }
}
