/// Pure-Dart engine selection for N3E (no native calls, no session I/O).
library;

/// Normal four-track cassette projects (M4A / legacy path).
const String kOrpheusAudioEngineLegacy = 'legacy';

/// Dev-only native integration sandbox (WAV path in later phases).
const String kOrpheusAudioEngineNativeTest = 'native_test';

/// Prefix for auto-named dev native test projects on CassetteHomeScreen.
const String kOrpheusNativeTestProjectNamePrefix = 'NATIVE_TEST_';

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

/// Parses [session.json] `audioEngine`; missing/unknown → legacy.
String parseProjectAudioEngineFromSessionJson(Map<String, dynamic> json) {
  final raw = json['audioEngine'];
  if (raw == kOrpheusAudioEngineNativeTest) {
    return kOrpheusAudioEngineNativeTest;
  }
  return kOrpheusAudioEngineLegacy;
}

bool isNativeTestAudioEngine(String projectAudioEngine) =>
    projectAudioEngine == kOrpheusAudioEngineNativeTest;

/// Chooses legacy vs native-experimental without touching audio devices.
RecorderEngineSelection selectRecorderEngine({
  required bool experimentalNativeAudioEngineEnabled,
  required bool isDebugBuild,
  required String projectAudioEngine,
  required bool projectHasLegacyM4aTracks,
  required bool platformIsAndroid,
}) {
  final bool nativeRequested = experimentalNativeAudioEngineEnabled;
  final bool projectIsNativeTest = isNativeTestAudioEngine(projectAudioEngine);

  if (!nativeRequested) {
    if (projectIsNativeTest) {
      return const RecorderEngineSelection(
        selectedKind: OrpheusAudioEngineKind.legacy,
        nativeRequested: false,
        nativeEligible: true,
        reason: 'NATIVE AVAILABLE',
      );
    }
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

  if (!projectIsNativeTest) {
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

/// True when every non-null track path is `.wav` (null slots allowed).
bool projectNonNullTracksAreWav(List<String?> trackPaths) {
  for (final path in trackPaths) {
    if (path == null) continue;
    if (!path.toLowerCase().endsWith('.wav')) {
      return false;
    }
  }
  return true;
}

bool projectHasAtLeastOneWavTrack(List<String?> trackPaths) {
  for (final path in trackPaths) {
    if (path != null && path.toLowerCase().endsWith('.wav')) {
      return true;
    }
  }
  return false;
}

/// Debug deck header line (kDebugMode only).
String formatRecorderEngineDebugLine(RecorderEngineSelection selection) {
  switch (selection.selectedKind) {
    case OrpheusAudioEngineKind.nativeExperimental:
      return 'ENGINE: NATIVE EXPERIMENTAL SELECTED';
    case OrpheusAudioEngineKind.legacy:
      switch (selection.reason) {
        case 'LEGACY M4A PROJECT':
          return 'ENGINE: LEGACY - LEGACY M4A PROJECT';
        case 'NATIVE TEST PROJECT REQUIRED':
          return 'ENGINE: LEGACY - NATIVE TEST PROJECT REQUIRED';
        case 'NATIVE AVAILABLE':
          return 'ENGINE: LEGACY - NATIVE AVAILABLE';
        default:
          return 'ENGINE: LEGACY';
      }
  }
}

/// Debug project-type line (kDebugMode only).
String formatProjectEngineDebugLine(String projectAudioEngine) {
  if (isNativeTestAudioEngine(projectAudioEngine)) {
    return 'PROJECT ENGINE: NATIVE TEST';
  }
  return 'PROJECT ENGINE: LEGACY';
}
