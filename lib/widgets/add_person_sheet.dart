import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import '../app/theme/app_theme.dart';
import '../app/theme/app_typography.dart';
import 'phone_field.dart';
import 'primary_button.dart';

/// Name + number, collected in a modal sheet.
///
/// The Figma flow for inviting someone is not designed yet, so this reuses the onboarding
/// field styling and returns the pair to the caller.
typedef PersonDraft = ({String name, String phone});

Future<PersonDraft?> showAddPersonSheet(
  BuildContext context, {
  required String title,
  String actionLabel = 'Add',
}) {
  return showModalBottomSheet<PersonDraft>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _AddPersonSheet(title: title, actionLabel: actionLabel),
  );
}

class _AddPersonSheet extends StatefulWidget {
  const _AddPersonSheet({required this.title, required this.actionLabel});

  final String title;
  final String actionLabel;

  @override
  State<_AddPersonSheet> createState() => _AddPersonSheetState();
}

class _AddPersonSheetState extends State<_AddPersonSheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController();

  @override
  void initState() {
    super.initState();
    _name.addListener(_refresh);
    _phone.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().isNotEmpty && _phone.text.length == 10;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppShape.sheetRadius)),
        ),
        padding: const EdgeInsets.fromLTRB(
          AppShape.gutter,
          28,
          AppShape.gutter,
          AppShape.gutter,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, style: AppText.display),
              const SizedBox(height: 20),
              TextFieldBox(controller: _name, hint: 'Name'),
              const SizedBox(height: 12),
              PhoneField(controller: _phone),
              const SizedBox(height: 24),
              PrimaryButton(
                label: widget.actionLabel,
                onPressed: _valid
                    ? () => Navigator.of(context).pop(
                          (name: _name.text.trim(), phone: '+91 ${_phone.text}'),
                        )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
