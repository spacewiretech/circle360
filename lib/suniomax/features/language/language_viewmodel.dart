import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/analytics/analytics_events.dart';
import '../../../data/providers.dart';
import '../../data/language_preference.dart';
import '../../data/providers.dart';

/// The language picker's state.
///
/// [selected] is never null: the frame shows English pre-selected with the continue button live,
/// so a user who agrees with the default taps once rather than twice.
@immutable
class LanguageState {
  const LanguageState({this.selected = SxLanguage.english, this.busy = false});

  final SxLanguage selected;
  final bool busy;

  bool get canContinue => !busy;

  LanguageState copyWith({SxLanguage? selected, bool? busy}) => LanguageState(
    selected: selected ?? this.selected,
    busy: busy ?? this.busy,
  );
}

class LanguageViewModel extends Notifier<LanguageState> {
  @override
  LanguageState build() {
    _restore();
    return const LanguageState();
  }

  /// Pre-selects whatever was chosen before, for the case where this screen is reached again
  /// from settings rather than from onboarding.
  Future<void> _restore() async {
    final stored = await ref.read(languagePreferenceProvider).read();
    if (stored != null) state = state.copyWith(selected: stored);
  }

  void select(SxLanguage language) =>
      state = state.copyWith(selected: language);

  /// Stores the choice. Returns false only if the write threw, which the repository already
  /// swallows — so in practice this always advances.
  Future<bool> submit() async {
    if (state.busy) return false;
    state = state.copyWith(busy: true);

    final language = state.selected;
    await ref.read(languagePreferenceProvider).write(language);

    // Registered as a super property, not just an event property: every later event should carry
    // the language, because it is the main thing that distinguishes one campaign cohort from
    // another and the reason the picker is in front of the funnel at all.
    final analytics = ref.read(analyticsProvider);
    analytics.registerSuper({
      P.appLanguage: language.latin,
      P.appLocale: language.code,
    });
    analytics.track(Ev.languageSelected, {
      P.appLanguage: language.latin,
      P.appLocale: language.code,
    });

    // So the splash's `selectedLanguageProvider` re-reads rather than serving the null it
    // resolved before this screen was shown.
    ref.invalidate(selectedLanguageProvider);

    state = state.copyWith(busy: false);
    return true;
  }
}

final languageViewModelProvider =
    NotifierProvider<LanguageViewModel, LanguageState>(LanguageViewModel.new);
