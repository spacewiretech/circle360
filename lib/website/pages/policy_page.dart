import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_colors.dart';
import '../policy_docs.dart';
import '../site_copy.dart';
import '../site_shell.dart';
import '../site_theme.dart';
import '../widgets.dart';

/// Renders any [PolicyDoc]. All five legal pages go through here.
class PolicyPage extends StatelessWidget {
  const PolicyPage({super.key, required this.doc});

  final PolicyDoc doc;

  @override
  Widget build(BuildContext context) {
    return Title(
      title: '${doc.title} — ${SiteCopy.appName}',
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LAST UPDATED ${SitePlaceholders.lastUpdated.toUpperCase()}',
                        style: SiteText.eyebrow,
                      ),
                      const SizedBox(height: 14),
                      Text(doc.title, style: SiteText.section(context)),
                      const SizedBox(height: 16),
                      Text(doc.intro, style: SiteText.sectionSub(context)),
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
                      for (final section in doc.sections) _Section(section: section),
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 24),
                      _OtherPolicies(current: doc.slug),
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

class _Section extends StatelessWidget {
  const _Section({required this.section});

  final PolicySection section;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 38),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(section.heading, style: SiteText.policyHeading(context)),
          const SizedBox(height: 14),
          for (final paragraph in section.paragraphs) ...[
            Text(paragraph, style: SiteText.prose(context)),
            const SizedBox(height: 14),
          ],
          for (final bullet in section.bullets) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 9, right: 12),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: AppColors.brand,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(child: Text(bullet, style: SiteText.prose(context))),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

/// Cross-links, so someone who landed on one policy from a store listing can find the rest.
class _OtherPolicies extends StatelessWidget {
  const _OtherPolicies({required this.current});

  final String current;

  @override
  Widget build(BuildContext context) {
    final others = PolicyDocs.all.where((doc) => doc.slug != current);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Other policies', style: SiteText.policyHeading(context)),
        const SizedBox(height: 14),
        Wrap(
          spacing: 24,
          runSpacing: 10,
          children: [
            for (final doc in others)
              SiteLink(
                label: doc.navLabel,
                style: SiteText.prose(context),
                onTap: () => context.go('/${doc.slug}'),
              ),
          ],
        ),
      ],
    );
  }
}
