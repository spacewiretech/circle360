import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/assets.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_theme.dart';
import '../../app/theme/app_typography.dart';
import '../../data/fake/fake_session.dart';
import '../../data/models/emergency_contact.dart';
import '../../widgets/add_person_sheet.dart';
import '../../widgets/avatar.dart';
import '../../widgets/floating_pill.dart';
import '../../widgets/map_background.dart';
import '../../widgets/person_card.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/sheet_surface.dart';
import 'emergency_viewmodel.dart';

/// Figma `12330:11580` (empty) and `12330:11606` (list).
class EmergencyView extends ConsumerWidget {
  const EmergencyView({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final draft = await showAddPersonSheet(
      context,
      title: 'Add Emergency Contact',
      actionLabel: 'Add Contact',
    );
    if (draft == null) return;
    await ref
        .read(emergencyViewModelProvider.notifier)
        .add(name: draft.name, phone: draft.phone);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(emergencyViewModelProvider);
    final viewModel = ref.read(emergencyViewModelProvider.notifier);

    ref.listen(emergencyViewModelProvider.select((s) => s.message), (_, message) {
      if (message == null) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
      viewModel.consumeMessage();
    });

    return Scaffold(
      // A Stack sizes itself to its non-positioned children, so it is told to fill
      // the screen — otherwise Positioned.fill resolves against a collapsed box.
      body: SizedBox.expand(
        child: Stack(
          children: [
            const Positioned.fill(child: MapBackground(center: FakeSession.home)),
            Align(
              alignment: Alignment.bottomCenter,
              child: SheetSurface(
                padding: const EdgeInsets.symmetric(horizontal: 25),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 50),
                    Row(
                      children: [
                        CircleBackButton(onTap: () => context.pop()),
                        Expanded(
                          child: Text(
                            'Emergency Contacts',
                            style: AppText.display,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 40),
                      ],
                    ),
                    const SizedBox(height: 24),
                    if (state.loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (state.isEmpty)
                      const _EmptyState()
                    else
                      for (final contact in state.contacts) ...[
                        _ContactRow(
                          contact: contact,
                          onCall: () => viewModel.call(contact),
                          onRemove: () => viewModel.remove(contact),
                        ),
                        const SizedBox(height: 9),
                      ],
                    const SizedBox(height: 8),
                    if (state.isEmpty)
                      PrimaryButton(
                        label: 'Add Contact',
                        onPressed: () => _add(context, ref),
                      )
                    else if (state.canAddMore)
                      AddPersonCard(onTap: () => _add(context, ref)),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 20),
        Image.asset(Img.emergencyArt, width: 75, height: 72, fit: BoxFit.contain),
        const SizedBox(height: 12),
        Text('No Emergency Contacts', style: AppText.body),
        const SizedBox(height: 20),
      ],
    );
  }
}

/// Avatar + name + number, with a call button and a dismiss button.
class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.contact, required this.onCall, required this.onRemove});

  final EmergencyContact contact;
  final VoidCallback onCall;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.cardBlue,
        borderRadius: AppShape.card,
      ),
      padding: const EdgeInsets.fromLTRB(15, 10, 15, 10),
      child: Row(
        children: [
          Avatar(asset: contact.avatarAsset ?? Img.avatarMe),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(contact.name, style: AppText.title),
                Text(contact.phone, style: AppText.meta),
              ],
            ),
          ),
          _RoundButton(
            icon: Icons.call,
            background: AppColors.brand,
            foreground: Colors.white,
            tooltip: 'Call ${contact.name}',
            onTap: onCall,
          ),
          const SizedBox(width: 10),
          _RoundButton(
            icon: Icons.close,
            background: AppColors.chipBlue,
            foreground: AppColors.brand,
            tooltip: 'Remove ${contact.name}',
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.background,
    required this.foreground,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: foreground),
          ),
        ),
      ),
    );
  }
}
