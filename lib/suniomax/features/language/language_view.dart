import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/analytics/analytics.dart';
import '../../app/router.dart';
import '../../app/theme/sx_colors.dart';
import '../../app/theme/sx_theme.dart';
import '../../app/theme/sx_typography.dart';
import '../../data/language_preference.dart';
import '../../data/onboarding_audio.dart';
import '../../widgets/sx_audio_button.dart';
import '../../widgets/sx_primary_button.dart';
import '../../widgets/sx_wordmark.dart';
import 'language_viewmodel.dart';

/// Figma `13511:14745` — the wordmark, nine options, and a continue button pinned at the foot.
///
/// The first screen of the flow. It comes before the phone number because it needs no account,
/// and because a user who abandons at the OTP has still told us which language to advertise in.
class LanguageView extends ConsumerWidget {
  const LanguageView({super.key});

  Future<void> _submit(BuildContext context, WidgetRef ref) async {
    final saved = await ref.read(languageViewModelProvider.notifier).submit();
    if (saved && context.mounted) context.go(SxRoutes.phone);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(languageViewModelProvider);

    return Scaffold(
      backgroundColor: SxColors.surface,
      body: SafeArea(
        // A Stack only so the audio control can sit in the corner over the list. `Positioned.fill`
        // around the column is load-bearing: a bare Column in a Stack gets loose constraints, and
        // the `Expanded` below it would have no height to take.
        child: Stack(
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  const SxWordmark(height: 30),
                  const SizedBox(height: 18),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: SxShape.gutter,
                      ),
                      itemCount: SxLanguage.values.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final language = SxLanguage.values[index];
                        return _LanguageOption(
                          language: language,
                          selected: language == state.selected,
                          onTap: () => ref
                              .read(languageViewModelProvider.notifier)
                              .select(language),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      SxShape.gutter,
                      12,
                      SxShape.gutter,
                      12,
                    ),
                    child: SxPrimaryButton(
                      label: 'continue',
                      // Pinned: every step in this flow labels its button `continue`, so without an
                      // explicit id they would all report the same tap.
                      analyticsId: 'sx_language_continue',
                      busy: state.busy,
                      onPressed: state.canContinue
                          ? () => _submit(context, ref)
                          : null,
                    ),
                  ),
                ],
              ),
            ),
            // Top-left, the same corner the three onboarding steps put it in, so it is in one
            // place for the whole flow rather than moving with the layout.
            const Positioned(
              top: 0,
              left: SxShape.gutter,
              child: SxAudioButton(clip: SxAudioClip.language),
            ),
          ],
        ),
      ),
    );
  }
}

/// One option: the native script over the English name, in a rounded outlined card.
class _LanguageOption extends StatelessWidget {
  const _LanguageOption({
    required this.language,
    required this.selected,
    required this.onTap,
  });

  final SxLanguage language;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SxColors.surface,
      borderRadius: SxShape.control,
      child: InkWell(
        // The id carries the language, so the picker's distribution is readable without having
        // to join against a property.
        onTap: trackedTap(
          onTap,
          id: 'sx_language_${language.name}',
          label: language.latin,
        ),
        borderRadius: SxShape.control,
        child: Ink(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: SxShape.control,
            border: Border.all(
              color: selected ? SxColors.brand : SxColors.cardBorder,
              width: selected ? 1.8 : 1.3,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(language.native, style: SxText.languageNative),
              const SizedBox(height: 2),
              Text(language.latin, style: SxText.languageLatin),
            ],
          ),
        ),
      ),
    );
  }
}
