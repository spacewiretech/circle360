import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../data/analytics/analytics_events.dart';
import '../../../data/entitlement.dart';
import '../../../data/providers.dart';
import '../../data/language_preference.dart';
import '../../data/providers.dart';

/// What the Settings screen shows.
@immutable
class SxSettingsState {
  const SxSettingsState({
    this.name,
    this.version,
    this.batteryOptimised = true,
  });

  /// The account's name, from the server rather than from a local copy.
  final String? name;

  /// `1.0.2 (6)` — shown at the foot and in About.
  final String? version;

  /// True while Android may still doze the listener.
  ///
  /// Not cosmetic: this is the single most likely reason a voice lock that worked in testing
  /// stops hearing the phrase after a few hours in a pocket.
  final bool batteryOptimised;

  SxSettingsState copyWith({
    String? name,
    String? version,
    bool? batteryOptimised,
  }) => SxSettingsState(
    name: name ?? this.name,
    version: version ?? this.version,
    batteryOptimised: batteryOptimised ?? this.batteryOptimised,
  );
}

class SxSettingsViewModel extends Notifier<SxSettingsState> {
  @override
  SxSettingsState build() {
    _load();
    return const SxSettingsState();
  }

  Future<void> _load() async {
    // Three independent reads; none of them should hold up the others.
    final user = await ref.read(authRepositoryProvider).currentUser();
    final info = await PackageInfo.fromPlatform();
    final permissions = await ref
        .read(voiceLockRepositoryProvider)
        .permissions();

    state = state.copyWith(
      name: user?.name,
      version: '${info.version} (${info.buildNumber})',
      batteryOptimised: permissions.batteryOptimised,
    );
  }

  /// Re-reads the battery exemption. Called when the screen resumes, because the exemption is a
  /// system dialog the user answers outside the app.
  Future<void> refresh() async {
    final permissions = await ref
        .read(voiceLockRepositoryProvider)
        .permissions();
    state = state.copyWith(batteryOptimised: permissions.batteryOptimised);
  }

  Future<void> setName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    // Through the shared auth repository, so the name is the account's and not a second copy
    // that drifts from it.
    final user = await ref.read(authRepositoryProvider).saveName(trimmed);
    state = state.copyWith(name: user.name);
    ref.read(entitlementProvider.notifier).set(user);
  }

  Future<void> setLanguage(SxLanguage language) async {
    await ref.read(languagePreferenceProvider).write(language);
    ref.invalidate(selectedLanguageProvider);

    final analytics = ref.read(analyticsProvider);
    analytics.registerSuper({
      P.appLanguage: language.latin,
      P.appLocale: language.code,
    });
    analytics.track(Ev.languageSelected, {
      P.appLanguage: language.latin,
      P.appLocale: language.code,
      P.source: 'settings',
    });
  }

  Future<void> requestBatteryExemption() async {
    final permissions = await ref
        .read(voiceLockRepositoryProvider)
        .requestIgnoreBatteryOptimizations();
    state = state.copyWith(batteryOptimised: permissions.batteryOptimised);
  }
}

final sxSettingsViewModelProvider =
    NotifierProvider<SxSettingsViewModel, SxSettingsState>(
      SxSettingsViewModel.new,
    );
