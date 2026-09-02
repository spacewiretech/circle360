import '../app/assets.dart';

/// Everything on the site that is a business fact rather than a design decision.
///
/// All of it is a placeholder today. Fill these in — and only these — before the site goes
/// live; nothing else in `lib/website/` hard-codes an address, an email or a store URL.
abstract final class SitePlaceholders {
  // TODO(circle360): replace before going live.
  static const legalEntity = 'Spacewire Tech';
  static const address = '15th Cross Rd, 6Th Sector, HSR Layout, Bengaluru, Karnataka 560102';
  static const supportEmail = 'contact@circle360.com';
  static const supportPhone = '+91 XXXXX XXXXX';
  static const siteDomain = 'spacewiretech.com';

  /// Set either to a real listing URL and every download button on the site goes live —
  /// no other edit. Null renders the "coming soon" state instead.
  static const String? playStoreUrl = null;
  static const String? appStoreUrl = null;

  /// Shown in the footer and at the top of each policy page.
  static const lastUpdated = '2 September 2026';
  static const copyrightYear = '2026';
}

/// Marketing copy for the home page.
abstract final class SiteCopy {
  static const appName = 'Circle360';
  static const tagline = 'Family location sharing, made simple';

  static const heroHeadline = "Know they're safe. Always.";
  static const heroSub =
      'Circle360 keeps your family’s live location, emergency contacts and instant '
      'invites in one simple app. Built for Indian families.';

  /// Mirrors the paywall defaults in `lib/data/repositories/app_config_repository.dart`
  /// (`trial_price_label`, `plan_price_label`, `cashfree_trial_days`). Those are the real
  /// source of truth — the server can override them at runtime — so if they change there,
  /// change them here too.
  static const trialPrice = '₹3';
  static const planPrice = '₹499';
  static const trialDays = 2;

  static const priceLine =
      '$trialPrice for $trialDays days · then $planPrice/month · cancel anytime';

  static const maxPeople = 3;

  static const features = <FeatureCopy>[
    // Four visually distinct marks — pin, crosshair, plus, handset. `actionShareLive` is
    // almost the same drawing as `placePin`, so it is deliberately not used here.
    FeatureCopy(
      icon: Svg.placePin,
      title: 'Live family map',
      body: 'Everyone you’ve added on one map, updating as they move. No refreshing, '
          'no asking "where are you?"',
    ),
    FeatureCopy(
      icon: Svg.actionShareCurrent,
      title: 'Distance at a glance',
      body: 'Each person shows how far away they are and when their location last came '
          'through, so you know the map is current.',
    ),
    FeatureCopy(
      icon: Svg.addPlus,
      title: 'Invite in seconds',
      body: 'Send a link over your own SMS app. They install Circle360, sign in with that '
          'number, and you’re connected automatically.',
    ),
    FeatureCopy(
      icon: Svg.actionCall,
      title: 'Emergency contacts',
      body: 'Keep the people who matter one tap from a call, saved on the same screen as '
          'the map.',
    ),
  ];

  static const steps = <StepCopy>[
    StepCopy(
      title: 'Verify your number',
      body: 'One OTP on your phone number. No passwords, no email, no social login.',
    ),
    StepCopy(
      title: 'Add up to $maxPeople people',
      body: 'Already on Circle360? They get a request. Not yet? You send an invite link.',
    ),
    StepCopy(
      title: 'See everyone on the map',
      body: 'Live location, distance and last update for each person, whenever you open '
          'the app.',
    ),
  ];

  static const faqs = <FaqCopy>[
    FaqCopy(
      question: 'Who can see my location?',
      answer:
          'Only people you have added and who have accepted, up to $maxPeople of them. '
          'There is no public directory, no way to look someone up by number, and your '
          'location is never shown to anyone outside your circle.',
    ),
    FaqCopy(
      question: 'Can I stop sharing?',
      answer:
          'Yes. Remove a person from your circle and they stop seeing you immediately. You '
          'can also revoke location permission from your phone’s system settings at '
          'any time — the app keeps working, it just has nothing to share.',
    ),
    FaqCopy(
      question: 'What does it cost?',
      answer:
          '$trialPrice authorises a UPI Autopay mandate and opens a $trialDays-day trial. '
          'After that $planPrice is auto-debited every month. Cancel any time before the '
          'trial ends and nothing further is charged.',
    ),
    FaqCopy(
      question: 'What is UPI Autopay?',
      answer:
          'A standing instruction you approve once inside your own UPI app. Your bank shows '
          'you the amount and the frequency before you approve it, and you can cancel the '
          'mandate from your UPI app or from Circle360 whenever you like.',
    ),
    FaqCopy(
      question: 'How do I cancel?',
      answer:
          'Cancel the mandate in your own UPI app — look under AutoPay or Mandates — or '
          'write to ${SitePlaceholders.supportEmail} and we will cancel it for you. Access '
          'continues until the end of the period you have already paid for.',
    ),
    FaqCopy(
      question: 'How do I delete my account?',
      answer:
          'From the account deletion page on this site, or by writing to '
          '${SitePlaceholders.supportEmail}. Your profile, your circle and your stored '
          'location history are erased.',
    ),
  ];
}

class FeatureCopy {
  const FeatureCopy({required this.icon, required this.title, required this.body});

  final String icon;
  final String title;
  final String body;
}

class StepCopy {
  const StepCopy({required this.title, required this.body});

  final String title;
  final String body;
}

class FaqCopy {
  const FaqCopy({required this.question, required this.answer});

  final String question;
  final String answer;
}
