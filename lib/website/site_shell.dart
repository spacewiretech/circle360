import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/assets.dart';
import '../app/theme/app_colors.dart';
import 'policy_docs.dart';
import 'site_copy.dart';
import 'site_router.dart';
import 'site_theme.dart';
import 'widgets.dart';

/// Centres content and caps it at [SiteShape.maxWidth], with the right gutter for the width.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth});

  final Widget child;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final gutter = isMobile(context) ? SiteShape.gutterMobile : SiteShape.gutter;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: gutter),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth ?? SiteShape.maxWidth),
          child: child,
        ),
      ),
    );
  }
}

/// A full-width band with vertical rhythm and an optional ground colour.
class SiteSection extends StatelessWidget {
  const SiteSection({
    super.key,
    required this.child,
    this.background,
    this.anchorKey,
    this.tight = false,
  });

  final Widget child;
  final Color? background;

  /// Target for the nav's in-page links.
  final GlobalKey? anchorKey;

  /// Halves the vertical padding, for bands that sit directly against another.
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final vertical = isMobile(context) ? (tight ? 44.0 : 64.0) : (tight ? 64.0 : 104.0);
    return Container(
      key: anchorKey,
      width: double.infinity,
      color: background,
      padding: EdgeInsets.symmetric(vertical: vertical),
      child: ContentWidth(child: child),
    );
  }
}

/// Section heading + optional standfirst, centred or left-aligned.
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    this.eyebrow,
    this.subtitle,
    this.centered = true,
  });

  final String title;
  final String? eyebrow;
  final String? subtitle;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final align = centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final textAlign = centered ? TextAlign.center : TextAlign.start;

    return Column(
      crossAxisAlignment: align,
      children: [
        if (eyebrow != null) ...[
          Text(eyebrow!.toUpperCase(), style: SiteText.eyebrow, textAlign: textAlign),
          const SizedBox(height: 12),
        ],
        Text(title, style: SiteText.section(context), textAlign: textAlign),
        if (subtitle != null) ...[
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Text(
              subtitle!,
              style: SiteText.sectionSub(context),
              textAlign: textAlign,
            ),
          ),
        ],
      ],
    );
  }
}

/// Every page's frame: sticky nav on top, page content and footer scrolling beneath.
class SiteShell extends StatelessWidget {
  const SiteShell({super.key, required this.child, this.controller});

  final Widget child;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      endDrawer: isMobile(context) ? const _NavDrawer() : null,
      body: Column(
        children: [
          const SiteNav(),
          Expanded(
            child: SingleChildScrollView(
              controller: controller,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [child, const SiteFooter()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The nav links that jump to a part of the home page.
const _sectionLinks = <({String label, String anchor})>[
  (label: 'Features', anchor: 'features'),
  (label: 'How it works', anchor: 'how'),
  (label: 'Pricing', anchor: 'pricing'),
  (label: 'FAQ', anchor: 'faq'),
];

/// Navigates to a home-page section, whichever page you are currently on.
void goToSection(BuildContext context, String anchor) {
  final onHome = GoRouterState.of(context).uri.path == SiteRoutes.home;
  if (onHome) {
    // The keys live in HomePage; it exposes the scroll through this notifier so the nav does
    // not have to reach into the page's state.
    HomeAnchors.request.value = (anchor, DateTime.now().microsecondsSinceEpoch);
  } else {
    context.go(SiteRoutes.homeSection(anchor));
  }
}

/// Channel between the nav and `HomePage`'s section keys.
///
/// The timestamp makes each request distinct, so tapping the same link twice scrolls twice.
abstract final class HomeAnchors {
  static final request = ValueNotifier<(String, int)?>(null);
}

class SiteNav extends StatelessWidget {
  const SiteNav({super.key});

  @override
  Widget build(BuildContext context) {
    final mobile = isMobile(context);

    return Container(
      height: SiteShape.navHeight,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: SiteColors.border)),
      ),
      child: ContentWidth(
        child: Row(
          children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => context.go(SiteRoutes.home),
                child: Semantics(
                  label: '${SiteCopy.appName} home',
                  child: Image.asset(Img.logoWordmark, height: 26, fit: BoxFit.contain),
                ),
              ),
            ),
            const Spacer(),
            if (!mobile) ...[
              for (final link in _sectionLinks) ...[
                SiteLink(
                  label: link.label,
                  style: SiteText.navLink,
                  color: AppColors.heading,
                  onTap: () => goToSection(context, link.anchor),
                ),
                const SizedBox(width: 28),
              ],
              SiteLink(
                label: 'Contact',
                style: SiteText.navLink,
                color: AppColors.heading,
                onTap: () => context.go(SiteRoutes.contact),
              ),
              const SizedBox(width: 28),
              SiteButton(
                label: 'Get the app',
                onPressed: () => goToSection(context, 'download'),
              ),
            ] else
              Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu_rounded, color: AppColors.heading),
                  tooltip: 'Menu',
                  onPressed: () => Scaffold.of(context).openEndDrawer(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavDrawer extends StatelessWidget {
  const _NavDrawer();

  @override
  Widget build(BuildContext context) {
    void go(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    return Drawer(
      backgroundColor: AppColors.surface,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Image.asset(Img.logoWordmark, height: 24, fit: BoxFit.contain),
            ),
            for (final link in _sectionLinks)
              ListTile(
                title: Text(link.label, style: SiteText.navLink),
                onTap: () => go(() => goToSection(context, link.anchor)),
              ),
            ListTile(
              title: Text('Contact', style: SiteText.navLink),
              onTap: () => go(() => context.go(SiteRoutes.contact)),
            ),
            const Divider(height: 24),
            ListTile(
              title: Text('Privacy Policy', style: SiteText.navLink),
              onTap: () => go(() => context.go(SiteRoutes.privacy)),
            ),
            ListTile(
              title: Text('Terms & Conditions', style: SiteText.navLink),
              onTap: () => go(() => context.go(SiteRoutes.terms)),
            ),
          ],
        ),
      ),
    );
  }
}

class SiteFooter extends StatelessWidget {
  const SiteFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final mobile = isMobile(context);

    final columns = <Widget>[
      SizedBox(
        width: mobile ? double.infinity : 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _FooterWordmark(),
            const SizedBox(height: 16),
            Text(
              SiteCopy.tagline,
              style: SiteText.footerLink.copyWith(height: 1.6),
            ),
          ],
        ),
      ),
      _FooterColumn(
        heading: 'Company',
        links: [
          (label: 'Home', onTap: () => context.go(SiteRoutes.home)),
          (label: 'Contact Us', onTap: () => context.go(SiteRoutes.contact)),
        ],
      ),
      _FooterColumn(
        heading: 'Policies',
        // Driven off PolicyDocs so a new legal page appears here by existing, and the label
        // can never drift from the page it opens.
        links: [
          for (final doc in PolicyDocs.all)
            (label: doc.navLabel, onTap: () => context.go('/${doc.slug}')),
        ],
      ),
      _FooterColumn(
        heading: 'Support',
        links: [
          (
            label: SitePlaceholders.supportEmail,
            onTap: () => openExternal('mailto:${SitePlaceholders.supportEmail}'),
          ),
        ],
      ),
    ];

    return Container(
      width: double.infinity,
      color: SiteColors.ink,
      padding: EdgeInsets.symmetric(vertical: mobile ? 48 : 72),
      child: ContentWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 56,
              runSpacing: 40,
              children: columns,
            ),
            const SizedBox(height: 48),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 24),
            Text(
              '© ${SitePlaceholders.copyrightYear} ${SitePlaceholders.legalEntity}. '
              'All rights reserved.',
              style: SiteText.footerLink.copyWith(fontSize: 13.5, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

/// The wordmark set as text rather than the PNG.
///
/// `logo_wordmark.png` is navy-and-blue artwork made for a white ground; tinting it white for
/// the ink band collapses the "360" into a solid block, so the footer draws the mark instead.
class _FooterWordmark extends StatelessWidget {
  const _FooterWordmark();

  @override
  Widget build(BuildContext context) {
    final base = GoogleFonts.poppins(
      fontSize: 26,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.6,
      height: 1.1,
    );

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'Circle', style: base.copyWith(color: Colors.white)),
          TextSpan(text: '360', style: base.copyWith(color: SiteColors.brandOnInk)),
        ],
      ),
      semanticsLabel: SiteCopy.appName,
    );
  }
}

class _FooterColumn extends StatelessWidget {
  const _FooterColumn({required this.heading, required this.links});

  final String heading;
  final List<({String label, VoidCallback onTap})> links;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(heading, style: SiteText.footerHeading),
          const SizedBox(height: 12),
          for (final link in links)
            SiteLink(
              label: link.label,
              style: SiteText.footerLink,
              color: SiteColors.onInkMuted,
              onTap: link.onTap,
            ),
        ],
      ),
    );
  }
}
