import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/theme/app_colors.dart';
import '../app/theme/app_typography.dart';

/// The boxed code entry from the design.
///
/// Deliberately **one** `TextField` holding the whole code, with the boxes as decoration over
/// it. Six separate fields cannot work here: a per-box `maxLength: 1` truncates a pasted or
/// SMS-autofilled code to a single character before any handler sees it, so paste filled only
/// the first box and iOS autofill did the same. With a single input the value arrives whole and
/// the formatters filter it.
class OtpField extends StatefulWidget {
  const OtpField({
    super.key,
    required this.length,
    required this.onChanged,
    this.onCompleted,
    this.controller,
  });

  final int length;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onCompleted;

  /// Lets the screen empty the boxes when the provider rejects a code.
  final OtpFieldController? controller;

  @override
  State<OtpField> createState() => _OtpFieldState();
}

class _OtpFieldState extends State<OtpField> {
  final _text = TextEditingController();
  final _node = FocusNode();

  /// Guards against [OtpField.onCompleted] firing twice for one full code — the field can
  /// rebuild while the code is still complete.
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _node.addListener(() {
      _pinCaretToEnd();
      setState(() {});
    });
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _text.dispose();
    _node.dispose();
    super.dispose();
  }

  String get _code => _text.text;

  /// The field is invisible, so a tap lands the caret at an arbitrary offset and the next digit
  /// would be inserted mid-code. Typing only ever appends here.
  void _pinCaretToEnd() {
    final end = TextSelection.collapsed(offset: _text.text.length);
    if (_text.selection != end) _text.selection = end;
  }

  void _onChanged(String value) {
    _pinCaretToEnd();
    setState(() {});
    widget.onChanged(value);

    if (value.length == widget.length) {
      if (!_completed) {
        _completed = true;
        widget.onCompleted?.call(value);
      }
    } else {
      _completed = false;
    }
  }

  /// Empties the boxes and returns focus, so a rejected code can be retyped without the user
  /// deleting six digits by hand.
  void _reset() {
    _text.clear();
    _completed = false;
    setState(() {});
    _node.requestFocus();
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    // The box awaiting the next digit, which is the one the design highlights.
    final activeIndex = code.length.clamp(0, widget.length - 1);

    return AutofillGroup(
      child: Stack(
        children: [
          Row(
            children: [
              for (var i = 0; i < widget.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: _Box(
                      digit: i < code.length ? code[i] : '',
                      focused: _node.hasFocus && i == activeIndex,
                    ),
                  ),
                ),
              ],
            ],
          ),
          // Invisible, but a real field: it owns the keyboard, the paste menu and autofill.
          Positioned.fill(
            child: TextField(
              controller: _text,
              focusNode: _node,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.oneTimeCode],
              autocorrect: false,
              enableSuggestions: false,
              // Long-press Paste depends on this; the selection is invisible anyway.
              enableInteractiveSelection: true,
              showCursor: false,
              cursorColor: Colors.transparent,
              style: const TextStyle(color: Colors.transparent, fontSize: 20),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(widget.length),
              ],
              onChanged: _onChanged,
              onTap: _pinCaretToEnd,
              decoration: const InputDecoration(
                counterText: '',
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                enabledBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                filled: false,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lets a parent clear the boxes after the provider rejects a code.
class OtpFieldController {
  _OtpFieldState? _state;

  void _attach(_OtpFieldState state) => _state = state;

  void _detach(_OtpFieldState state) {
    if (identical(_state, state)) _state = null;
  }

  void clear() => _state?._reset();
}

/// One square: a border and a digit. Holds no input of its own.
class _Box extends StatelessWidget {
  const _Box({required this.digit, required this.focused});

  final String digit;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: focused ? AppColors.brand : const Color(0xFFCFCFCF),
          width: focused ? 1.5 : 1,
        ),
      ),
      child: Center(
        child: Text(digit, style: AppText.input, textAlign: TextAlign.center),
      ),
    );
  }
}
