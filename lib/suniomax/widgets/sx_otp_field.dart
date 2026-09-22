import 'package:flutter/material.dart';

import '../../widgets/otp_field.dart';
import '../app/theme/sx_colors.dart';
import '../app/theme/sx_typography.dart';

/// SunioMax's code entry — the same field as Circle360's, drawn as circles.
///
/// Figma `13511:14662`. Only the boxes are restyled: everything that makes code entry work at all
/// — one input behind the boxes, pinned caret, paste, SMS autofill, the completion guard — stays
/// in [OtpField], because it is subtle enough that a second copy would drift out of step with it.
///
/// **The frame shows four circles; this renders as many as the backend issues.** Codes are six
/// digits (`app_config.otp_length`, and the Fast2SMS template behind it), and four boxes for a
/// six-digit code is a screen a user cannot finish. The count is passed in rather than fixed here
/// so it follows config, exactly as Circle360's does.
class SxOtpField extends StatelessWidget {
  const SxOtpField({
    super.key,
    required this.length,
    required this.onChanged,
    this.onCompleted,
    this.controller,
  });

  final int length;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onCompleted;
  final OtpFieldController? controller;

  @override
  Widget build(BuildContext context) {
    return OtpField(
      length: length,
      onChanged: onChanged,
      onCompleted: onCompleted,
      controller: controller,
      spacing: 14,
      boxBuilder: (context, digit, focused) => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: SxColors.surface,
          border: Border.all(
            color: focused ? SxColors.brand : SxColors.cardBorder,
            width: focused ? 1.8 : 1.4,
          ),
        ),
        child: Center(
          child: Text(digit, style: SxText.input, textAlign: TextAlign.center),
        ),
      ),
    );
  }
}

/// The +91 number box and the plain text box, in SunioMax's fully-rounded shape.
///
/// Mirrors `PhoneField` / `TextFieldBox`. Separate rather than parameterised because the two
/// brands disagree about the border radius, the divider and the height, which is all these
/// widgets are.
class SxPhoneField extends StatelessWidget {
  const SxPhoneField({
    super.key,
    required this.controller,
    this.dialCode = '+91',
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String dialCode;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => _FieldBox(
    leading: Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The flag is type, not an asset: one glyph beats shipping a PNG for a field that
          // only ever serves India.
          const Text('🇮🇳', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          Text(dialCode, style: SxText.input),
          const SizedBox(width: 12),
          Container(width: 1, height: 24, color: SxColors.cardBorder),
        ],
      ),
    ),
    child: TextField(
      controller: controller,
      autofocus: true,
      keyboardType: TextInputType.phone,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.telephoneNumberNational],
      maxLength: 10,
      style: SxText.input,
      onSubmitted: onSubmitted,
      decoration: const InputDecoration(
        counterText: '',
        border: InputBorder.none,
        isCollapsed: true,
      ),
    ),
  );
}

/// A single-line text box — the name step.
class SxTextFieldBox extends StatelessWidget {
  const SxTextFieldBox({
    super.key,
    required this.controller,
    required this.hint,
    this.keyboardType,
    this.autofocus = true,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => _FieldBox(
    child: TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: keyboardType ?? TextInputType.name,
      textInputAction: TextInputAction.done,
      textCapitalization: TextCapitalization.words,
      style: SxText.input,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: SxText.input.copyWith(color: SxColors.muted),
        border: InputBorder.none,
        isCollapsed: true,
      ),
    ),
  );
}

/// The rounded outline both fields sit in.
class _FieldBox extends StatelessWidget {
  const _FieldBox({required this.child, this.leading});

  final Widget child;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: SxColors.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: SxColors.heading, width: 1.2),
      ),
      child: Row(
        children: [
          ?leading,
          Expanded(child: child),
        ],
      ),
    );
  }
}
