import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/sx_colors.dart';
import '../../../app/theme/sx_theme.dart';
import '../../../app/theme/sx_typography.dart';
import '../../../widgets/sx_primary_button.dart';
import '../../../widgets/sx_sheet_surface.dart';

/// Collects one short value in a modal sheet — the voice phrase, the backup passcode.
///
/// A function rather than a widget class, like `showAddPersonSheet`, because what the caller
/// wants is the value and not a widget. Returns null when dismissed.
///
/// The Figma set has no frame for either of these: the design shows the rows and their "Change"
/// affordance, but not what opens. This reuses the sheet styling the rest of the app already has,
/// so the flow is complete and the eventual frames replace one file.
Future<String?> showSxPromptSheet(
  BuildContext context, {
  required String title,
  required String message,
  required String hint,
  required String analyticsId,
  String? initialValue,
  String? existingNote,
  bool digitsOnly = false,
  int? maxLength,
  int? exactLength,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Named so the navigator observer reports it as a real surface rather than an anonymous
    // route — the same reason every other modal in this project passes routeSettings.
    routeSettings: RouteSettings(name: analyticsId),
    builder: (context) => _PromptSheet(
      title: title,
      message: message,
      hint: hint,
      existingNote: existingNote,
      initialValue: initialValue,
      digitsOnly: digitsOnly,
      maxLength: maxLength,
      exactLength: exactLength,
      analyticsId: analyticsId,
    ),
  );
}

class _PromptSheet extends StatefulWidget {
  const _PromptSheet({
    required this.title,
    required this.message,
    required this.hint,
    required this.analyticsId,
    this.existingNote,
    this.initialValue,
    this.digitsOnly = false,
    this.maxLength,
    this.exactLength,
  });

  final String title;
  final String message;
  final String hint;
  final String analyticsId;

  /// Shown when a value already exists but cannot be displayed back.
  ///
  /// The backup passcode is stored as a salted hash, so there is nothing to pre-fill — and a
  /// blank field is indistinguishable from never having set one, which is exactly how a user
  /// ends up believing the app forgot it.
  final String? existingNote;

  final String? initialValue;
  final bool digitsOnly;
  final int? maxLength;
  final int? exactLength;

  @override
  State<_PromptSheet> createState() => _PromptSheetState();
}

class _PromptSheetState extends State<_PromptSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _valid {
    final value = _controller.text.trim();
    if (value.isEmpty) return false;
    final exact = widget.exactLength;
    return exact == null || value.length == exact;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Lifts the sheet clear of the keyboard, which otherwise covers the field it contains.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SxSheetSurface(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                height: 4,
                width: 44,
                decoration: BoxDecoration(
                  color: SxColors.cardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(widget.title, style: SxText.outcome),
            const SizedBox(height: 8),
            Text(widget.message, style: SxText.body),
            if (widget.existingNote != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: SxColors.enabledBg,
                  borderRadius: SxShape.card,
                  border: Border.all(
                    color: SxColors.accent.withValues(alpha: 0.45),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      size: 18,
                      color: SxColors.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.existingNote!,
                        style: SxText.rowSubtitle,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            Container(
              height: SxShape.inputHeight,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                borderRadius: SxShape.control,
                border: Border.all(color: SxColors.heading, width: 1.2),
              ),
              child: Center(
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  // The passcode is a credential; the phrase is one too, and both are being set
                  // rather than recalled, so neither is obscured — a user mistyping a phrase they
                  // cannot see is locked out of their own phone.
                  keyboardType: widget.digitsOnly
                      ? TextInputType.number
                      : TextInputType.text,
                  textCapitalization: TextCapitalization.words,
                  style: SxText.input,
                  maxLength: widget.maxLength,
                  inputFormatters: [
                    if (widget.digitsOnly)
                      FilteringTextInputFormatter.digitsOnly,
                  ],
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _valid ? _submit() : null,
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    hintStyle: SxText.input.copyWith(color: SxColors.muted),
                    counterText: '',
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            SxPrimaryButton(
              label: 'Save',
              analyticsId: '${widget.analyticsId}_save',
              onPressed: _valid ? _submit : null,
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());
}
