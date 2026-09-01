import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/theme/app_colors.dart';
import '../app/theme/app_theme.dart';
import '../app/theme/app_typography.dart';

/// Country code + 10-digit number, in the bordered 50pt box from the design.
class PhoneField extends StatelessWidget {
  const PhoneField({
    super.key,
    required this.controller,
    this.dialCode = '+91',
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String dialCode;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return _FieldBox(
      child: Row(
        children: [
          const _IndiaFlag(),
          const SizedBox(width: 8),
          Text(dialCode, style: AppText.input),
          const SizedBox(width: 10),
          const _Divider(),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.phone,
              style: AppText.input,
              cursorColor: AppColors.brand,
              maxLength: 10,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: onSubmitted,
              decoration: const InputDecoration(
                counterText: '',
                border: InputBorder.none,
                isCollapsed: true,
                hintText: '00000 00000',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Single-line text field in the same 50pt box — used for the name step.
class TextFieldBox extends StatelessWidget {
  const TextFieldBox({
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
  Widget build(BuildContext context) {
    return _FieldBox(
      focused: false,
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        keyboardType: keyboardType,
        textCapitalization: TextCapitalization.words,
        style: AppText.input,
        cursorColor: AppColors.brand,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          border: InputBorder.none,
          isCollapsed: true,
          hintText: hint,
          hintStyle: AppText.input.copyWith(color: AppColors.muted),
        ),
      ),
    );
  }
}

class _FieldBox extends StatelessWidget {
  const _FieldBox({required this.child, this.focused = true});

  final Widget child;

  /// The design draws the active field with a brand border and the resting one in grey.
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AppShape.inputHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppShape.control,
        border: Border.all(
          color: focused ? AppColors.brand : const Color(0xFFBDBDBD),
        ),
      ),
      child: Center(child: child),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 24, color: const Color(0xFFBDBDBD));
  }
}

/// 24x16 tricolour. Drawn rather than exported so it stays sharp at every density.
class _IndiaFlag extends StatelessWidget {
  const _IndiaFlag();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              children: const [
                Expanded(child: ColoredBox(color: Color(0xFFFF9933), child: SizedBox.expand())),
                Expanded(child: ColoredBox(color: Colors.white, child: SizedBox.expand())),
                Expanded(child: ColoredBox(color: Color(0xFF138808), child: SizedBox.expand())),
              ],
            ),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF000080), width: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
