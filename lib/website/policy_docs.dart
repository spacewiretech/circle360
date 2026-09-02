import 'site_copy.dart';

/// One legal page. Rendered by `pages/policy_page.dart`.
class PolicyDoc {
  const PolicyDoc({
    required this.slug,
    required this.title,
    required this.intro,
    required this.sections,
    this.shortTitle,
  });

  /// Path segment, without the leading slash. Matches `SiteRoutes`.
  final String slug;

  /// The heading on the page itself.
  final String title;

  /// Set only where the page heading is too long to sit in a footer column.
  final String? shortTitle;

  /// How the page is named in the footer and in cross-links.
  String get navLabel => shortTitle ?? title;

  /// Standfirst under the title.
  final String intro;

  final List<PolicySection> sections;
}

class PolicySection {
  const PolicySection({
    required this.heading,
    this.paragraphs = const [],
    this.bullets = const [],
  });

  final String heading;
  final List<String> paragraphs;

  /// Rendered under [paragraphs] as a dotted list.
  final List<String> bullets;
}

const _entity = SitePlaceholders.legalEntity;
const _email = SitePlaceholders.supportEmail;

/// The five legal pages.
///
/// Written to describe what the app actually does — phone-number OTP through Fast2SMS,
/// location stored in Supabase, payments through Cashfree UPI Autopay, a three-person circle,
/// no advertising SDKs. Every business-specific detail is a placeholder from
/// [SitePlaceholders]. These are drafts, not legal advice: have them reviewed before
/// publishing.
abstract final class PolicyDocs {
  static const all = [privacy, terms, refund, shipping, deleteAccount];

  static PolicyDoc? bySlug(String slug) {
    for (final doc in all) {
      if (doc.slug == slug) return doc;
    }
    return null;
  }

  // ---------------------------------------------------------------------------------------
  static const privacy = PolicyDoc(
    slug: 'privacy',
    title: 'Privacy Policy',
    intro:
        'Circle360 exists to share one of the most sensitive things you have — where you '
        'are. This page explains exactly what we collect, why, who sees it, and how to make '
        'it stop.',
    sections: [
      PolicySection(
        heading: 'Who we are',
        paragraphs: [
          'Circle360 ("the app") is operated by $_entity, ${SitePlaceholders.address}. '
              'In this policy "we" and "us" mean $_entity, and "you" means the person using '
              'the app.',
          'If you have a question about anything here, write to $_email.',
        ],
      ),
      PolicySection(
        heading: 'What we collect',
        bullets: [
          'Your phone number. Required — it is how you sign in and how other people add you '
              'to their circle.',
          'Your name, and a profile photo if you set one.',
          'Your device location, including while the app is in the background, once you '
              'grant that permission.',
          'The people in your circle: the names and phone numbers you enter when you add '
              'someone or save an emergency contact.',
          'Subscription state: whether your trial or paid month is active, and the '
              'identifier our payment provider gives us for your mandate.',
          'Basic technical information needed to run the service, such as your device '
              'platform and app version.',
        ],
      ),
      PolicySection(
        heading: 'What we do not collect',
        bullets: [
          'Card numbers, UPI PINs or bank credentials. Payment is completed inside your own '
              'UPI app; those details never reach us and never reach the Circle360 app.',
          'Your contacts list. The app never reads your address book — you type in the '
              'people you want to add.',
          'Your messages, calls, photos, or anything else on your device.',
          'Advertising identifiers. There are no advertising or tracking SDKs in the app, '
              'and we do not sell or rent your data to anyone.',
        ],
      ),
      PolicySection(
        heading: 'Why we collect it',
        paragraphs: [
          'Location is the product: it is collected so the people in your circle — and only '
              'them — can see where you are. Your phone number identifies your account and '
              'lets someone add you. Names and photos make the map readable. Subscription '
              'state decides whether the app is unlocked.',
          'We do not use your location for any purpose beyond showing it to your circle. We '
              'do not profile you, build advertising audiences, or analyse where you go.',
        ],
      ),
      PolicySection(
        heading: 'Who your location is shared with',
        paragraphs: [
          'Only the people you have added to your circle and who are connected to you — at '
              'most ${SiteCopy.maxPeople}. There is no public directory and no way for a '
              'stranger to look you up. Remove someone from your circle and they stop '
              'seeing you straight away.',
        ],
      ),
      PolicySection(
        heading: 'Service providers',
        paragraphs: [
          'We use a small number of processors to run the service. Each receives only what '
              'it needs to do its job:',
        ],
        bullets: [
          'Supabase — hosts our database and backend functions, and therefore stores your '
              'profile, your circle and your location updates.',
          'Fast2SMS — receives your phone number in order to deliver your sign-in OTP.',
          'Cashfree Payments — processes the subscription. They receive what a payment '
              'processor needs to open and debit a UPI Autopay mandate. We receive back only '
              'the status of the mandate.',
          'OpenStreetMap — supplies the map tiles the app draws. Tile requests come from '
              'your device as you pan the map.',
        ],
      ),
      PolicySection(
        heading: 'How long we keep it',
        paragraphs: [
          'Your account data is kept while your account exists. Location updates are kept '
              'for as long as they are useful to your circle and are then overwritten by '
              'newer ones. When you delete your account, your profile, your circle and your '
              'stored location are erased — see the account deletion page.',
          'We may retain payment and transaction records for as long as Indian tax and '
              'accounting law requires, even after your account is gone. These records '
              'contain no location data.',
        ],
      ),
      PolicySection(
        heading: 'Security',
        paragraphs: [
          'Traffic between the app and our servers is encrypted in transit. Your session '
              'token is held in your device’s own secure storage — the Keychain on iOS, the '
              'Keystore on Android. Access to the backend is restricted and audited.',
          'No system is perfect. If we ever become aware of a breach affecting your data, we '
              'will tell you.',
        ],
      ),
      PolicySection(
        heading: 'Your choices',
        bullets: [
          'Turn location off. Revoke the permission in your phone’s settings at any time. '
              'The app keeps working; it simply has nothing to share.',
          'Remove someone. Take a person out of your circle and the sharing ends both ways.',
          'Get a copy of your data, or correct it. Write to $_email.',
          'Delete everything. See the account deletion page.',
        ],
      ),
      PolicySection(
        heading: 'Children',
        paragraphs: [
          'Circle360 is not intended for children to set up on their own. A parent or '
              'guardian should create and manage the circle, and should have the consent of '
              'everyone in it — including any child whose location is being shared.',
        ],
      ),
      PolicySection(
        heading: 'Changes to this policy',
        paragraphs: [
          'If we change how we handle your data we will update this page and change the '
              '"last updated" date above. Material changes will also be announced in the app.',
        ],
      ),
      PolicySection(
        heading: 'Contact',
        paragraphs: [
          'Questions, requests or complaints: $_email, or write to $_entity, '
              '${SitePlaceholders.address}.',
        ],
      ),
    ],
  );

  // ---------------------------------------------------------------------------------------
  static const terms = PolicyDoc(
    slug: 'terms',
    title: 'Terms & Conditions',
    intro:
        'These terms govern your use of the Circle360 app and this website. By creating an '
        'account you accept them.',
    sections: [
      PolicySection(
        heading: 'The agreement',
        paragraphs: [
          'This is an agreement between you and $_entity, ${SitePlaceholders.address}. If '
              'you do not accept these terms, do not use the app.',
        ],
      ),
      PolicySection(
        heading: 'Your account',
        paragraphs: [
          'You sign in with your phone number and a one-time password. You are responsible '
              'for the number on your account and for anything done through it. Tell us at '
              '$_email if you lose control of that number.',
          'You must be old enough to enter into a contract under Indian law to hold an '
              'account.',
        ],
      ),
      PolicySection(
        heading: 'Consent is the whole point',
        paragraphs: [
          'Circle360 is for families and people who have agreed to share their location with '
              'each other. Every person in a circle installs the app, signs in with their own '
              'number, and accepts the connection themselves.',
          'You must not use Circle360 to track anyone without their knowledge and agreement, '
              'and you must not set up the app on a device belonging to someone who has not '
              'consented. Doing so may be a criminal offence, and it is grounds for us '
              'closing your account without a refund.',
        ],
      ),
      PolicySection(
        heading: 'Acceptable use',
        bullets: [
          'Do not use the app to stalk, harass, intimidate or endanger anyone.',
          'Do not try to break, probe or reverse-engineer the service, or access accounts '
              'that are not yours.',
          'Do not send invites to people who have not asked for them, in bulk or otherwise.',
          'Do not resell, sublicense or rebrand the service.',
        ],
      ),
      PolicySection(
        heading: 'Subscription',
        paragraphs: [
          'Circle360 is a paid subscription. ${SiteCopy.trialPrice} authorises a UPI Autopay '
              'mandate and opens a ${SiteCopy.trialDays}-day trial; after the trial '
              '${SiteCopy.planPrice} is debited every month until you cancel. Prices are '
              'shown in the app before you pay and include applicable taxes.',
          'We may change the price. If we do, we will tell you before it applies to you, and '
              'you can cancel rather than accept the new price.',
          'Cancellation and refunds are covered on the Cancellation & Refund page.',
        ],
      ),
      PolicySection(
        heading: 'What the app does not promise',
        paragraphs: [
          'Circle360 reports a location that a phone reports to it. That location can be '
              'wrong, stale or missing entirely — a phone can lose signal, run out of '
              'battery, be switched off, lose GPS accuracy indoors, or have its permissions '
              'revoked. Some Android devices aggressively stop background apps.',
          'Circle360 is not an emergency service, a medical device, or a security system. Do '
              'not rely on it where a wrong or missing location could cause harm. In an '
              'emergency, call the emergency services.',
          'The service is provided "as is". We do not warrant that it will be uninterrupted '
              'or error-free.',
        ],
      ),
      PolicySection(
        heading: 'Liability',
        paragraphs: [
          'To the extent Indian law allows, we are not liable for indirect or consequential '
              'loss, and our total liability to you is limited to the amount you paid us in '
              'the twelve months before the claim.',
          'Nothing in these terms limits liability that cannot lawfully be limited.',
        ],
      ),
      PolicySection(
        heading: 'Ending the agreement',
        paragraphs: [
          'You can stop at any time by cancelling your subscription and deleting your '
              'account. We may suspend or close an account that breaches these terms — in '
              'particular the consent rules above — or where we are required to by law.',
        ],
      ),
      PolicySection(
        heading: 'Governing law',
        paragraphs: [
          'These terms are governed by the laws of India, and the courts at '
              '${SitePlaceholders.address} have exclusive jurisdiction.',
        ],
      ),
      PolicySection(
        heading: 'Contact',
        paragraphs: [_email],
      ),
    ],
  );

  // ---------------------------------------------------------------------------------------
  static const refund = PolicyDoc(
    slug: 'refund',
    title: 'Cancellation & Refund',
    intro:
        'How the trial works, how to cancel, and when money comes back. The short version: '
        'cancel before the trial ends and you are never charged '
        '${SiteCopy.planPrice}.',
    sections: [
      PolicySection(
        heading: 'How billing works',
        paragraphs: [
          'Paying ${SiteCopy.trialPrice} does two things: it charges you '
              '${SiteCopy.trialPrice}, and it authorises a UPI Autopay mandate with your '
              'bank. That opens a ${SiteCopy.trialDays}-day trial.',
          'When the trial ends, ${SiteCopy.planPrice} is debited automatically, and then '
              'again every month on the same date, until the mandate is cancelled. Your bank '
              'notifies you before each debit, as UPI Autopay requires.',
        ],
      ),
      // TODO(circle360): nothing in the app calls the `subscription-cancel` Edge Function
      // yet, so an in-app cancel button does not exist. Add it to this list once it ships.
      PolicySection(
        heading: 'How to cancel',
        bullets: [
          'In your UPI app: find the Circle360 mandate under AutoPay or Mandates and cancel '
              'or pause it. This stops the debit at source and takes effect immediately.',
          'By email: write to $_email from the number registered on your account and we will '
              'cancel it for you.',
        ],
      ),
      PolicySection(
        heading: 'What happens when you cancel',
        paragraphs: [
          'Cancelling stops future debits. It does not shorten the period you have already '
              'paid for — you keep access until the end of that trial or month, and then the '
              'app returns to its locked state.',
        ],
      ),
      PolicySection(
        heading: 'Refunds',
        paragraphs: [
          'The ${SiteCopy.trialPrice} trial charge is not refundable once the mandate has '
              'been authorised. It is the price of the trial itself, and the trial gives you '
              '${SiteCopy.trialDays} days to decide before any larger amount is due.',
          'A monthly ${SiteCopy.planPrice} charge is not refundable for a period that has '
              'already started, because access is granted immediately and in full. Cancel '
              'before the renewal date to avoid the next one.',
          'We will refund in full, without argument, where:',
        ],
        bullets: [
          'you were charged after cancelling;',
          'you were charged twice for the same period;',
          'a technical fault on our side left you without access for a significant part of a '
              'paid period and we could not fix it.',
        ],
      ),
      PolicySection(
        heading: 'How to ask for a refund',
        paragraphs: [
          'Write to $_email from your registered number within 7 days of the charge, with '
              'the date and amount. We aim to respond within 3 working days. Approved '
              'refunds are returned to the account that was debited, normally within 5–7 '
              'working days once processed by our payment provider.',
        ],
      ),
      PolicySection(
        heading: 'Failed payments',
        paragraphs: [
          'If a debit fails, we retry it. Access may continue during a short grace period so '
              'that a bank delay does not lock you out mid-month. If it keeps failing, the '
              'subscription lapses and the app locks.',
        ],
      ),
    ],
  );

  // ---------------------------------------------------------------------------------------
  static const shipping = PolicyDoc(
    slug: 'shipping',
    title: 'Shipping & Delivery',
    intro:
        'Circle360 is a digital service. Nothing is physically shipped, and there is nothing '
        'to wait for.',
    sections: [
      PolicySection(
        heading: 'Nothing is shipped',
        paragraphs: [
          'Circle360 is a mobile application and an online subscription. There is no physical '
              'product, no packaging and no courier. No shipping charge is ever collected, '
              'and no delivery address is required.',
        ],
      ),
      PolicySection(
        heading: 'How the service is delivered',
        paragraphs: [
          'Access is granted electronically, to the account registered against your phone '
              'number, as soon as your payment is confirmed. In practice this is immediate; '
              'if a bank or network delay holds up confirmation it may take a few minutes.',
          'The app itself is downloaded from the Google Play Store or the Apple App Store.',
        ],
      ),
      PolicySection(
        heading: 'If access does not arrive',
        paragraphs: [
          'If you have been charged and the app has not unlocked, first close and reopen it '
              '— confirmation is reconciled with our payment provider on launch. If it is '
              'still locked after a few minutes, write to $_email with the date and amount '
              'and we will sort it out.',
        ],
      ),
      PolicySection(
        heading: 'Service area',
        paragraphs: [
          'Circle360 is offered in India and billed in Indian rupees.',
        ],
      ),
    ],
  );

  // ---------------------------------------------------------------------------------------
  static const deleteAccount = PolicyDoc(
    slug: 'delete-account',
    title: 'Delete your account',
    shortTitle: 'Delete Account',
    intro:
        'You can delete your Circle360 account and everything in it at any time. Here is how, '
        'and exactly what goes.',
    sections: [
      // TODO(circle360): the app has no in-app deletion yet — Settings only offers Sign out,
      // and there is no delete-account Edge Function. Google Play requires an in-app route
      // as well as this page. When that ships, add the in-app steps here as the first
      // section; until then this page must not promise it.
      PolicySection(
        heading: 'How to ask',
        paragraphs: [
          'Write to $_email from the phone number registered on the account, with the '
              'subject "Delete my account". We may ask you to confirm the number by OTP, so '
              'that nobody else can delete your account by naming your number.',
          'We act on verified requests within 7 working days and email you when it is done.',
        ],
      ),
      PolicySection(
        heading: 'What is deleted',
        bullets: [
          'Your profile: name, phone number and photo.',
          'Your circle: the connections between you and everyone you added, in both '
              'directions.',
          'Your stored location, including any history held on our servers.',
          'Your emergency contacts.',
          'Your device session, so nothing on your phone can sign back in.',
        ],
      ),
      PolicySection(
        heading: 'What is kept, and why',
        paragraphs: [
          'Payment and transaction records are retained for as long as Indian tax and '
              'accounting law requires. These show that a payment happened; they contain no '
              'location data. Anonymous, aggregated counts that cannot be traced back to you '
              'may also remain.',
        ],
      ),
      PolicySection(
        heading: 'Cancel your subscription first',
        paragraphs: [
          'Deleting your account does not by itself cancel a UPI Autopay mandate held at '
              'your bank. Cancel the subscription before you delete the account — see the '
              'Cancellation & Refund page — or cancel the mandate directly in your UPI app.',
        ],
      ),
      PolicySection(
        heading: 'This cannot be undone',
        paragraphs: [
          'Deletion is permanent. If you sign up again later with the same number you start '
              'with an empty account, and everyone you were connected to will need to be '
              'added again.',
        ],
      ),
    ],
  );
}
