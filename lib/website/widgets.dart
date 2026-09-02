import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/theme/app_colors.dart';
import 'site_copy.dart';
import 'site_theme.dart';

/// Opens an external URL, swallowing the failure rather than throwing into a build.
Future<void> openExternal(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// The site's filled button. [onPressed] null renders the muted, non-interactive state used
/// by the "coming soon" download buttons.
class SiteButton extends StatelessWidget {
  const SiteButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.filled = true,
    this.onDark = false,
    this.subLabel,
  });

  final String label;

  /// Small second line under [label] — "Coming soon" under "Google Play".
  final String? subLabel;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// False renders the outlined variant.
  final bool filled;

  /// Inverts the outlined variant for use on the dark CTA band.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;

    final Color background;
    final Color foreground;
    final Color? border;

    if (filled) {
      background = enabled
          ? (onDark ? Colors.white : AppColors.brand)
          : (onDark ? Colors.white24 : const Color(0xFFDCE4F3));
      foreground = enabled
          ? (onDark ? AppColors.brand : Colors.white)
          : (onDark ? Colors.white70 : const Color(0xFF8794B0));
      border = null;
    } else {
      background = Colors.transparent;
      foreground = onDark ? Colors.white : AppColors.heading;
      border = onDark ? Colors.white38 : SiteColors.border;
    }

    return Semantics(
      button: true,
      enabled: enabled,
      label: subLabel == null ? label : '$label — $subLabel',
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: EdgeInsets.symmetric(horizontal: 22, vertical: subLabel == null ? 16 : 11),
            decoration: BoxDecoration(
              color: background,
              borderRadius: SiteShape.pillRadius,
              border: border == null ? null : Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: foreground),
                  const SizedBox(width: 10),
                ],
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        color: foreground,
                        height: 1.25,
                      ),
                    ),
                    if (subLabel != null)
                      Text(
                        subLabel!,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: foreground.withValues(alpha: 0.78),
                          height: 1.3,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The download buttons.
///
/// Both stores are wired to [SitePlaceholders]; while those are null the buttons render the
/// "coming soon" state, and filling either constant in makes that button live.
class StoreCta extends StatelessWidget {
  const StoreCta({super.key, this.onDark = false, this.alignment = WrapAlignment.start});

  final bool onDark;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    const play = SitePlaceholders.playStoreUrl;
    const appStore = SitePlaceholders.appStoreUrl;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: alignment,
      children: [
        SiteButton(
          label: 'Google Play',
          subLabel: play == null ? 'Coming soon' : 'Download the app',
          icon: Icons.shop_outlined,
          onDark: onDark,
          onPressed: play == null ? null : () => openExternal(play),
        ),
        SiteButton(
          label: 'App Store',
          subLabel: appStore == null ? 'Coming soon' : 'Download the app',
          icon: Icons.apple,
          filled: false,
          onDark: onDark,
          onPressed: appStore == null ? null : () => openExternal(appStore),
        ),
      ],
    );
  }
}

/// One card in the feature grid.
class FeatureCard extends StatelessWidget {
  const FeatureCard({super.key, required this.feature});

  final FeatureCopy feature;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: SiteShape.cardRadius,
        border: Border.all(color: SiteColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              color: AppColors.chipBlue,
              borderRadius: BorderRadius.all(Radius.circular(14)),
            ),
            alignment: Alignment.center,
            child: SvgPicture.asset(
              feature.icon,
              width: 22,
              height: 22,
              colorFilter: const ColorFilter.mode(AppColors.brand, BlendMode.srcIn),
            ),
          ),
          const SizedBox(height: 20),
          Text(feature.title, style: SiteText.cardTitle(context)),
          const SizedBox(height: 8),
          Text(feature.body, style: SiteText.cardBody(context)),
        ],
      ),
    );
  }
}

/// A numbered step in "How it works".
class StepCard extends StatelessWidget {
  const StepCard({super.key, required this.index, required this.step});

  final int index;
  final StepCopy step;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(color: AppColors.brand, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text(
            '${index + 1}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(step.title, style: SiteText.cardTitle(context)),
        const SizedBox(height: 8),
        Text(step.body, style: SiteText.cardBody(context)),
      ],
    );
  }
}

/// One expandable FAQ row.
class FaqItem extends StatelessWidget {
  const FaqItem({super.key, required this.faq});

  final FaqCopy faq;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: SiteShape.cardRadius,
        border: Border.all(color: SiteColors.border),
      ),
      child: Theme(
        // The default tile draws its own dividers, which fight the card border.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: const RoundedRectangleBorder(borderRadius: SiteShape.cardRadius),
          collapsedShape: const RoundedRectangleBorder(borderRadius: SiteShape.cardRadius),
          tilePadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(24, 0, 24, 22),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          iconColor: AppColors.brand,
          collapsedIconColor: AppColors.muted,
          title: Text(faq.question, style: SiteText.cardTitle(context)),
          children: [Text(faq.answer, style: SiteText.prose(context))],
        ),
      ),
    );
  }
}

/// A text link that behaves like one: pointer cursor, brand colour, underline on hover.
class SiteLink extends StatefulWidget {
  const SiteLink({
    super.key,
    required this.label,
    required this.onTap,
    this.style,
    this.color,
  });

  final String label;
  final VoidCallback onTap;
  final TextStyle? style;
  final Color? color;

  @override
  State<SiteLink> createState() => _SiteLinkState();
}

class _SiteLinkState extends State<SiteLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppColors.brand;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.label,
          style: (widget.style ?? const TextStyle()).copyWith(
            color: color,
            decoration: _hovered ? TextDecoration.underline : TextDecoration.none,
            decorationColor: color,
          ),
        ),
      ),
    );
  }
}
