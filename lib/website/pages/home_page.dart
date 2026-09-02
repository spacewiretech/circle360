import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/assets.dart';
import '../../app/theme/app_colors.dart';
import '../site_copy.dart';
import '../site_router.dart';
import '../site_shell.dart';
import '../site_theme.dart';
import '../widgets.dart';

/// The landing page: hero → features → how it works → pricing → FAQ → download.
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.anchor});

  /// `?to=features` — set when the nav jumps here from another page. Scrolled to once, after
  /// the first frame.
  final String? anchor;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _scroll = ScrollController();

  final _keys = <String, GlobalKey>{
    'features': GlobalKey(),
    'how': GlobalKey(),
    'pricing': GlobalKey(),
    'faq': GlobalKey(),
    'download': GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    HomeAnchors.request.addListener(_onAnchorRequested);
    if (widget.anchor != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(widget.anchor!));
    }
  }

  @override
  void dispose() {
    HomeAnchors.request.removeListener(_onAnchorRequested);
    _scroll.dispose();
    super.dispose();
  }

  void _onAnchorRequested() {
    final request = HomeAnchors.request.value;
    if (request != null) _scrollTo(request.$1);
  }

  void _scrollTo(String anchor) {
    final target = _keys[anchor]?.currentContext;
    if (target == null || !mounted) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubic,
      // Leaves the section heading clear of the sticky nav rather than tucked under it.
      alignment: 0.02,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Title(
      title: '${SiteCopy.appName} — ${SiteCopy.tagline}',
      color: AppColors.brand,
      child: SiteShell(
        controller: _scroll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Hero(),
            _Features(anchorKey: _keys['features']!),
            _HowItWorks(anchorKey: _keys['how']!),
            _Pricing(anchorKey: _keys['pricing']!),
            _Faq(anchorKey: _keys['faq']!),
            _FinalCta(anchorKey: _keys['download']!),
          ],
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
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
          child: Text('MADE FOR INDIAN FAMILIES', style: SiteText.eyebrow),
        ),
        const SizedBox(height: 24),
        Text(
          SiteCopy.heroHeadline,
          style: SiteText.hero(context),
          textAlign: stacked ? TextAlign.center : TextAlign.start,
        ),
        const SizedBox(height: 20),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            SiteCopy.heroSub,
            style: SiteText.heroSub(context),
            textAlign: stacked ? TextAlign.center : TextAlign.start,
          ),
        ),
        const SizedBox(height: 32),
        StoreCta(alignment: stacked ? WrapAlignment.center : WrapAlignment.start),
        const SizedBox(height: 18),
        Text(
          SiteCopy.priceLine,
          style: SiteText.cardBody(context).copyWith(fontSize: 14),
          textAlign: stacked ? TextAlign.center : TextAlign.start,
        ),
      ],
    );

    const art = _HeroArt();

    return SiteSection(
      background: SiteColors.tint,
      child: stacked
          ? Column(
              children: [
                copy,
                const SizedBox(height: 48),
                art,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(flex: 6, child: copy),
                const SizedBox(width: 48),
                const Expanded(flex: 5, child: art),
              ],
            ),
    );
  }
}

class _HeroArt extends StatelessWidget {
  const _HeroArt();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        // The mockup is 562x1172, so its height is a little over twice its width — anything
        // wider than this and the hero band grows taller than a laptop screen.
        constraints: const BoxConstraints(maxWidth: 340),
        child: Image.asset(
          Img.inviteHeroWeb,
          fit: BoxFit.contain,
          // Decorative: the same information is in the copy beside it.
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}

/// Lays cards out in 4 / 2 / 1 columns without a nested scroll view.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.children, this.maxColumns = 4, this.spacing = 20});

  final List<Widget> children;
  final int maxColumns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final columns = gridColumns(context, max: maxColumns);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

class _Features extends StatelessWidget {
  const _Features({required this.anchorKey});

  final GlobalKey anchorKey;

  @override
  Widget build(BuildContext context) {
    return SiteSection(
      anchorKey: anchorKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: SectionHeading(
              eyebrow: 'Features',
              title: 'Everything you need. Nothing you don’t.',
              subtitle: 'One map, the people on it, and a way to reach them fast.',
            ),
          ),
          const SizedBox(height: 48),
          _CardGrid(
            children: [
              for (final feature in SiteCopy.features) FeatureCard(feature: feature),
            ],
          ),
        ],
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks({required this.anchorKey});

  final GlobalKey anchorKey;

  @override
  Widget build(BuildContext context) {
    return SiteSection(
      anchorKey: anchorKey,
      background: SiteColors.tint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: SectionHeading(
              eyebrow: 'How it works',
              title: 'Set up in under two minutes',
            ),
          ),
          const SizedBox(height: 48),
          _CardGrid(
            maxColumns: 3,
            spacing: 32,
            children: [
              for (final (index, step) in SiteCopy.steps.indexed)
                StepCard(index: index, step: step),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pricing extends StatelessWidget {
  const _Pricing({required this.anchorKey});

  final GlobalKey anchorKey;

  static const _included = [
    'Live location for up to ${SiteCopy.maxPeople} people',
    'Distance and last-updated time for everyone',
    'Emergency contacts, one tap from a call',
    'Invite links you send from your own SMS app',
    'No ads, and no data sold to anyone',
  ];

  @override
  Widget build(BuildContext context) {
    return SiteSection(
      anchorKey: anchorKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: SectionHeading(
              eyebrow: 'Pricing',
              title: 'One plan. No surprises.',
              subtitle: 'Try it for two days first. Cancel any time, from inside the app or '
                  'from your UPI app.',
            ),
          ),
          const SizedBox(height: 48),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Container(
                padding: EdgeInsets.all(isMobile(context) ? 28 : 40),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: SiteShape.cardRadius,
                  border: Border.all(color: AppColors.brand, width: 1.5),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14026BFE),
                      blurRadius: 40,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${SiteCopy.trialDays}-day trial', style: SiteText.eyebrow),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          SiteCopy.trialPrice,
                          style: SiteText.hero(context).copyWith(fontSize: 52),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'for the first ${SiteCopy.trialDays} days',
                            style: SiteText.cardBody(context),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Then ${SiteCopy.planPrice}/month by UPI Autopay. Cancel any time '
                      'before the trial ends and you pay nothing more.',
                      style: SiteText.cardBody(context),
                    ),
                    const SizedBox(height: 28),
                    const Divider(),
                    const SizedBox(height: 24),
                    for (final item in _included) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Icon(
                              Icons.check_circle_rounded,
                              size: 19,
                              color: AppColors.presence,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Text(item, style: SiteText.cardBody(context))),
                        ],
                      ),
                      const SizedBox(height: 14),
                    ],
                    const SizedBox(height: 14),
                    const StoreCta(alignment: WrapAlignment.start),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Faq extends StatelessWidget {
  const _Faq({required this.anchorKey});

  final GlobalKey anchorKey;

  @override
  Widget build(BuildContext context) {
    return SiteSection(
      anchorKey: anchorKey,
      background: SiteColors.tint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: SectionHeading(eyebrow: 'FAQ', title: 'Questions people ask first'),
          ),
          const SizedBox(height: 44),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                children: [
                  for (final faq in SiteCopy.faqs) FaqItem(faq: faq),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
          Center(
            child: SiteLink(
              label: 'Still stuck? Contact us →',
              style: SiteText.cardBody(context).copyWith(fontWeight: FontWeight.w600),
              onTap: () => context.go(SiteRoutes.contact),
            ),
          ),
        ],
      ),
    );
  }
}

class _FinalCta extends StatelessWidget {
  const _FinalCta({required this.anchorKey});

  final GlobalKey anchorKey;

  @override
  Widget build(BuildContext context) {
    return SiteSection(
      anchorKey: anchorKey,
      background: SiteColors.ink,
      child: Column(
        children: [
          Text(
            'Bring everyone into one circle.',
            style: SiteText.section(context).copyWith(color: Colors.white),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(
              'Install ${SiteCopy.appName}, verify your number, and add the people you want '
              'to stay close to.',
              style: SiteText.sectionSub(context).copyWith(color: SiteColors.onInkMuted),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 32),
          const StoreCta(onDark: true, alignment: WrapAlignment.center),
        ],
      ),
    );
  }
}
