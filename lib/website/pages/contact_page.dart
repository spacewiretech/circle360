import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_colors.dart';
import '../site_copy.dart';
import '../site_router.dart';
import '../site_shell.dart';
import '../site_theme.dart';
import '../widgets.dart';

/// Contact Us — required by the payment provider's merchant checklist, and the page the FAQ
/// and every policy page point at.
class ContactPage extends StatelessWidget {
  const ContactPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Title(
      title: 'Contact Us — ${SiteCopy.appName}',
      color: AppColors.brand,
      child: SiteShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SiteSection(
              background: SiteColors.tint,
              tight: true,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeading(
                        eyebrow: 'Contact',
                        title: 'Talk to us',
                        subtitle: 'Billing, a bug, a privacy request, or an account you need '
                            'deleted — one address reaches all of it.',
                        centered: false,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SiteSection(
              tight: true,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ContactRow(
                        icon: Icons.mail_outline_rounded,
                        label: 'Email',
                        value: SitePlaceholders.supportEmail,
                        onTap: () =>
                            openExternal('mailto:${SitePlaceholders.supportEmail}'),
                      ),
                      _ContactRow(
                        icon: Icons.call_outlined,
                        label: 'Phone',
                        value: SitePlaceholders.supportPhone,
                      ),
                      _ContactRow(
                        icon: Icons.business_outlined,
                        label: 'Registered office',
                        value: '${SitePlaceholders.legalEntity}\n'
                            '${SitePlaceholders.address}',
                      ),
                      const SizedBox(height: 28),
                      Text(
                        'We aim to reply within 3 working days. For anything about a charge, '
                        'write from the phone number registered on your account and include '
                        'the date and amount — it gets sorted much faster.',
                        style: SiteText.prose(context),
                      ),
                      const SizedBox(height: 32),
                      const Divider(),
                      const SizedBox(height: 24),
                      Text('Common requests', style: SiteText.policyHeading(context)),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 24,
                        runSpacing: 10,
                        children: [
                          SiteLink(
                            label: 'Cancel or get a refund',
                            style: SiteText.prose(context),
                            onTap: () => context.go(SiteRoutes.refund),
                          ),
                          SiteLink(
                            label: 'Delete my account',
                            style: SiteText.prose(context),
                            onTap: () => context.go(SiteRoutes.deleteAccount),
                          ),
                          SiteLink(
                            label: 'How my data is handled',
                            style: SiteText.prose(context),
                            onTap: () => context.go(SiteRoutes.privacy),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: const BoxDecoration(
              color: AppColors.chipBlue,
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 20, color: AppColors.brand),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: SiteText.cardBody(context).copyWith(fontSize: 13.5),
                ),
                const SizedBox(height: 3),
                if (onTap != null)
                  SiteLink(
                    label: value,
                    style: SiteText.cardTitle(context),
                    onTap: onTap!,
                  )
                else
                  Text(value, style: SiteText.cardTitle(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
