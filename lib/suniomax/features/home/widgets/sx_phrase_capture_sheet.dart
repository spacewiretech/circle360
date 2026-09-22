import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/sx_colors.dart';
import '../../../app/theme/sx_theme.dart';
import '../../../app/theme/sx_typography.dart';
import '../../../data/providers.dart';
import '../../../widgets/sx_mic_blob.dart';
import '../../../widgets/sx_primary_button.dart';
import '../../../widgets/sx_sheet_surface.dart';

/// Records a lock or unlock phrase by speaking it.
///
/// Figma `13511:14662` — the "Tap to Start" blob, then the captured result and Continue.
///
/// **The transcription is shown before it is saved, and that is the point.** What gets stored is
/// what the recogniser heard, not what the user meant, because that is the only string the
/// listener will ever be able to match. Showing it is what turns "the lock never works" into
/// "the recogniser thinks I said this — let me try again".
///
/// Returns the captured phrase, or null if the sheet was dismissed.
Future<String?> showSxPhraseCaptureSheet(
  BuildContext context, {
  required String title,
  required String message,
  required String analyticsId,
  String? currentPhrase,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    // Named so the navigator observer reports it as a real surface rather than an anonymous
    // route — the same reason every other modal in this project passes routeSettings.
    routeSettings: RouteSettings(name: analyticsId),
    builder: (context) => _PhraseCaptureSheet(
      title: title,
      message: message,
      analyticsId: analyticsId,
      currentPhrase: currentPhrase,
    ),
  );
}

enum _Stage { idle, listening, captured, failed }

class _PhraseCaptureSheet extends ConsumerStatefulWidget {
  const _PhraseCaptureSheet({
    required this.title,
    required this.message,
    required this.analyticsId,
    this.currentPhrase,
  });

  final String title;
  final String message;
  final String analyticsId;
  final String? currentPhrase;

  @override
  ConsumerState<_PhraseCaptureSheet> createState() =>
      _PhraseCaptureSheetState();
}

class _PhraseCaptureSheetState extends ConsumerState<_PhraseCaptureSheet> {
  _Stage _stage = _Stage.idle;
  String? _captured;

  /// Why the last attempt failed, in the native side's own words. Shown verbatim: it is the
  /// difference between "the microphone is busy" and "you said nothing", and guessing between
  /// those on the user's behalf is what made this screen useless.
  String? _reason;

  Future<void> _record() async {
    if (_stage == _Stage.listening) return;
    setState(() => _stage = _Stage.listening);

    final repository = ref.read(voiceLockRepositoryProvider);

    // The microphone is usually first needed here rather than at the switch, so this is where
    // it is asked for.
    var permissions = await repository.permissions();
    if (!permissions.microphone) {
      permissions = await repository.requestMicrophone();
    }
    if (!permissions.microphone) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _reason =
              'SunioMax needs the microphone to record your phrase. Allow it in '
              'Settings, then try again.';
        });
      }
      return;
    }

    // Captured in the language chosen during onboarding, so a Hindi phrase is recorded by the
    // Hindi model — and matched by it later.
    final language = ref.read(selectedLanguageProvider).valueOrNull;
    final result = await repository.capturePhrase(language: language?.code);
    if (!mounted) return;

    setState(() {
      _captured = result.phrase;
      _reason = result.reason;
      _stage = result.captured ? _Stage.captured : _Stage.failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SxSheetSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            height: 4,
            width: 44,
            decoration: BoxDecoration(
              color: SxColors.cardBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            widget.title,
            style: SxText.outcome,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(widget.message, style: SxText.body, textAlign: TextAlign.center),
          const SizedBox(height: 22),
          SxMicBlob(
            icon: _stage == _Stage.listening
                ? Icons.graphic_eq
                : Icons.mic_none,
            size: 190,
            onTap: _stage == _Stage.listening ? null : _record,
          ),
          const SizedBox(height: 10),
          // Under the artwork, not over it. The export has its own caption painted in, so an
          // overlaid label just prints a second line of text across the first.
          Text(
            switch (_stage) {
              _Stage.listening => 'Listening…',
              _Stage.captured ||
              _Stage.failed => 'Tap the circle to record again',
              _Stage.idle => 'Tap the circle to start',
            },
            style: SxText.rowTitle.copyWith(color: SxColors.brand),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          _Result(
            stage: _stage,
            captured: _captured,
            reason: _reason,
            current: widget.currentPhrase,
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'Cancel',
                    style: SxText.rowAction.copyWith(color: SxColors.muted),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SxPrimaryButton(
                  label: 'Continue',
                  analyticsId: '${widget.analyticsId}_continue',
                  onPressed: _stage == _Stage.captured
                      ? () => Navigator.of(context).pop(_captured)
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// What happened, in the user's terms.
class _Result extends StatelessWidget {
  const _Result({
    required this.stage,
    required this.captured,
    required this.reason,
    required this.current,
  });

  final _Stage stage;
  final String? captured;
  final String? reason;
  final String? current;

  @override
  Widget build(BuildContext context) {
    return switch (stage) {
      _Stage.listening => Text(
        'Say your phrase now.',
        style: SxText.rowSubtitle,
        textAlign: TextAlign.center,
      ),
      _Stage.captured => Column(
        children: [
          Text('Heard', style: SxText.rowSubtitle, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: SxColors.enabledBg,
              borderRadius: SxShape.card,
              border: Border.all(
                color: SxColors.accent.withValues(alpha: 0.45),
              ),
            ),
            child: Text(
              '“$captured”',
              style: SxText.rowTitle,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 10),
          // The load-bearing sentence on this screen.
          Text(
            'This is exactly what will be listened for. If it is not what you said, '
            'tap the circle and try again.',
            style: SxText.legal.copyWith(color: SxColors.muted, height: 1.5),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      // Shown exactly as the native side worded it, because it knows which of half a dozen
      // failures this was and the screen does not.
      _Stage.failed => Text(
        reason ?? 'Nothing was heard. Tap the circle and try again.',
        style: SxText.rowSubtitle.copyWith(color: SxColors.danger),
        textAlign: TextAlign.center,
      ),
      _Stage.idle => Text(
        current == null
            ? 'Tap the circle, then say your phrase.'
            : 'Currently “$current”. Tap the circle to record a new one.',
        style: SxText.rowSubtitle,
        textAlign: TextAlign.center,
      ),
    };
  }
}
