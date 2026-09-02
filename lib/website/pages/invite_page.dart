import 'package:flutter/material.dart';

import '../../app/assets.dart';
import '../../app/theme/app_colors.dart';
import '../site_copy.dart';
import '../site_shell.dart';
import '../site_theme.dart';
import '../widgets.dart';

/// Where an SMS invite lands when the recipient does not have the app.
///
/// The URL shape — `/invite/<code>?from=<name>` — has to keep matching `parseInvite` in
/// `lib/data/deeplink_service.dart`. If the link format changes there, change it here and in
/// `SiteRoutes.invite` too.
class InvitePage extends StatelessWidget {
  const InvitePage({super.key, required this.code, this.inviterName});

  final String code;
  final String? inviterName;

  /// The custom scheme the installed app registers. Mirrors `parseInvite`'s
  /// `loc360://invite?code=…` branch — a browser that knows the scheme hands straight over
  /// to the app; one that does not simply ignores the tap.
  String get _appLink => 'loc360://invite?code=${Uri.encodeComponent(code)}'
      '${inviterName == null ? '' : '&from=${Uri.encodeComponent(inviterName!)}'}';

  @override
  Widget build(BuildContext context) {
    final who = inviterName?.trim();
    final headline = who == null || who.isEmpty
        ? 'You’ve been invited to ${SiteCopy.appName}'
        : '$who invited you to ${SiteCopy.appName}';

    final stacked = !isDesktop(context);

    final copy = Column(
      crossAxisAlignment: stacked ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.chipBlue,
            borderRadius: SiteShape.pillRadius,
          ),
          child: Text('INVITATION', style: SiteText.eyebrow),
        ),
        const SizedBox(height: 24),
        Text(
          headline,
          style: SiteText.hero(context).copyWith(fontSize: isMobile(context) ? 32 : 44),
          textAlign: stacked ? TextAlign.center : TextAlign.start,
        ),
        const SizedBox(height: 20),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            'Install ${SiteCopy.appName} and sign in with the phone number this invite was '
            'sent to. You’ll be connected automatically — there is no code to type in.',
            style: SiteText.heroSub(context),
            textAlign: stacked ? TextAlign.center : TextAlign.start,
          ),
        ),
        const SizedBox(height: 32),
        StoreCta(alignment: stacked ? WrapAlignment.center : WrapAlignment.start),
        if (code.isNotEmpty) ...[
          const SizedBox(height: 14),
          SiteButton(
            label: 'Already have the app? Open it',
            filled: false,
            icon: Icons.open_in_new_rounded,
            onPressed: () => openExternal(_appLink),
          ),
        ],
        const SizedBox(height: 24),
        Text(
          'Sharing is always two-way and always consented: you choose whether to accept, and '
          'you can leave the circle at any time.',
          style: SiteText.cardBody(context).copyWith(fontSize: 14),
          textAlign: stacked ? TextAlign.center : TextAlign.start,
        ),
      ],
    );

    final art = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Image.asset(
          Img.inviteHeroWeb,
          fit: BoxFit.contain,
          excludeFromSemantics: true,
        ),
      ),
    );

    return Title(
      title: '$headline — ${SiteCopy.appName}',
      color: AppColors.brand,
      child: SiteShell(
        child: SiteSection(
          background: SiteColors.tint,
          child: stacked
              ? Column(children: [copy, const SizedBox(height: 48), art])
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(flex: 6, child: copy),
                    const SizedBox(width: 48),
                    Expanded(flex: 5, child: art),
                  ],
                ),
        ),
      ),
    );
  }
}
