import 'package:flutter_test/flutter_test.dart';
import 'package:loc_360/data/repositories/app_config_repository.dart';
import 'package:loc_360/suniomax/data/app_variant.dart';
import 'package:loc_360/suniomax/data/install_referrer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The gate that decides whether a device runs Circle360 or SunioMax.
///
/// Worth this much coverage because it is the one branch nobody can see going wrong: a user who
/// lands in the wrong app has no way to say so, and the mistake is invisible in the funnel — it
/// looks like a campaign that simply did not convert.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The real link from the campaign brief, as Play hands it over — decoded once already.
  const campaign =
      'utm_source=facebook&utm_medium=paid'
      '&utm_campaign=palm_diwali_oct26&utm_term=hindi_25_45&utm_content=palm_reel_v1';

  /// What Play answers for an install nobody was referred to.
  const organic = 'utm_source=google-play&utm_medium=organic';

  Map<String, String> rules({
    String enabled = 'true',
    String sources = 'facebook',
    String campaigns = '',
  }) => {
    sunioMaxEnabledKey: enabled,
    sunioMaxUtmSourcesKey: sources,
    sunioMaxUtmCampaignsKey: campaigns,
  };

  group('parseReferrer', () {
    test('reads the campaign link', () {
      expect(parseReferrer(campaign), {
        'utm_source': 'facebook',
        'utm_medium': 'paid',
        'utm_campaign': 'palm_diwali_oct26',
        'utm_term': 'hindi_25_45',
        'utm_content': 'palm_reel_v1',
      });
    });

    test('reads the organic default', () {
      expect(parseReferrer(organic)['utm_source'], 'google-play');
      expect(parseReferrer(organic)['utm_medium'], 'organic');
    });

    test('null, empty and whitespace are all no answer', () {
      expect(parseReferrer(null), isEmpty);
      expect(parseReferrer(''), isEmpty);
      expect(parseReferrer('   '), isEmpty);
    });

    test('decodes escaped values', () {
      expect(
        parseReferrer('utm_campaign=diwali%20sale%26more')['utm_campaign'],
        'diwali sale&more',
      );
    });

    test('a value that will not decode is kept verbatim rather than lost', () {
      // A stray `%` makes Uri.decodeComponent throw. Losing the whole referrer over a malformed
      // campaign name would silently drop a real campaign.
      expect(parseReferrer('utm_source=face%book')['utm_source'], 'face%book');
    });

    test('keys are lowercased so one campaign cannot become two', () {
      expect(parseReferrer('UTM_Source=Facebook')['utm_source'], 'Facebook');
    });

    test('malformed input yields an empty map rather than throwing', () {
      // This runs before runApp. A throw here would be a boot failure, not a missed campaign.
      expect(parseReferrer('&&&'), isEmpty);
      expect(parseReferrer('novalue'), isEmpty);
      expect(parseReferrer('=orphan'), isEmpty);
      expect(parseReferrer('a=1&&b=2'), {'a': '1', 'b': '2'});
    });
  });

  group('matchesSunioMax', () {
    test('the campaign link matches', () {
      expect(
        AppVariant.matchesSunioMax(parseReferrer(campaign), rules()),
        isTrue,
      );
    });

    test('an organic install never matches', () {
      expect(
        AppVariant.matchesSunioMax(parseReferrer(organic), rules()),
        isFalse,
      );
    });

    test('the kill switch beats everything else', () {
      expect(
        AppVariant.matchesSunioMax(
          parseReferrer(campaign),
          rules(enabled: 'false'),
        ),
        isFalse,
      );
    });

    test('an empty source allowlist matches nothing, not everything', () {
      // The opposite reading would hand SunioMax to every organic install in the store the day
      // somebody blanked a config row.
      expect(
        AppVariant.matchesSunioMax(parseReferrer(campaign), rules(sources: '')),
        isFalse,
      );
    });

    test('a source outside the allowlist does not match', () {
      expect(
        AppVariant.matchesSunioMax(
          parseReferrer(campaign),
          rules(sources: 'google-ads'),
        ),
        isFalse,
      );
    });

    test(
      'the allowlist takes several sources and ignores spacing and case',
      () {
        expect(
          AppVariant.matchesSunioMax(
            parseReferrer(campaign),
            rules(sources: ' Google-Ads , FACEBOOK '),
          ),
          isTrue,
        );
      },
    );

    test('a blank campaign list means any campaign from an allowed source', () {
      expect(
        AppVariant.matchesSunioMax(
          parseReferrer('utm_source=facebook'),
          rules(),
        ),
        isTrue,
      );
    });

    test('a campaign list narrows to named campaigns', () {
      expect(
        AppVariant.matchesSunioMax(
          parseReferrer(campaign),
          rules(campaigns: 'palm_diwali_oct26'),
        ),
        isTrue,
      );
      expect(
        AppVariant.matchesSunioMax(
          parseReferrer(campaign),
          rules(campaigns: 'some_other_campaign'),
        ),
        isFalse,
      );
    });

    test('a named campaign list excludes a referrer carrying no campaign', () {
      expect(
        AppVariant.matchesSunioMax(
          parseReferrer('utm_source=facebook'),
          rules(campaigns: 'palm_diwali_oct26'),
        ),
        isFalse,
      );
    });

    test('an empty referrer never matches', () {
      expect(AppVariant.matchesSunioMax(const {}, rules()), isFalse);
    });

    test('config that says nothing at all means Circle360', () {
      // A fresh clone, and every existing test suite, runs on exactly this.
      expect(
        AppVariant.matchesSunioMax(parseReferrer(campaign), const {}),
        isFalse,
      );
    });
  });

  group('resolve', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

    test('no referrer channel means Circle360', () async {
      // iOS, the web build, and every widget test: there is nothing registered to answer.
      final variant = await AppVariant.resolve(
        preferences: await prefs(),
        readReferrer: () async => null,
        config: rules(),
      );
      expect(variant, AppVariant.circle360);
    });

    test('a campaign referrer resolves to SunioMax and is stored', () async {
      final store = await prefs();
      final variant = await AppVariant.resolve(
        preferences: store,
        readReferrer: () async => campaign,
        config: rules(),
      );

      expect(variant, AppVariant.sunioMax);
      expect(store.getString('loc360.install_referrer'), campaign);
    });

    test(
      'an organic referrer resolves to Circle360 and is still stored',
      () async {
        // Storing it is what stops every launch asking Play again.
        final store = await prefs();
        final variant = await AppVariant.resolve(
          preferences: store,
          readReferrer: () async => organic,
          config: rules(),
        );

        expect(variant, AppVariant.circle360);
        expect(store.getString('loc360.install_referrer'), organic);
      },
    );

    test(
      'an unanswered fetch stores nothing, so the next launch asks again',
      () async {
        final store = await prefs();
        await AppVariant.resolve(
          preferences: store,
          readReferrer: () async => null,
          config: rules(),
        );

        expect(store.getString('loc360.install_referrer'), isNull);
      },
    );

    test('a slow Play does not become a permanent verdict', () async {
      final store = await prefs();
      // Longer than the three-second budget in front of runApp.
      final variant = await AppVariant.resolve(
        preferences: store,
        readReferrer: () =>
            Future.delayed(const Duration(seconds: 10), () => campaign),
        config: rules(),
      );

      expect(variant, AppVariant.circle360);
      expect(store.getString('loc360.install_referrer'), isNull);
    });

    test('a stored referrer is never fetched twice', () async {
      await AppVariant.seedReferrer(campaign);
      var fetched = false;

      final variant = await AppVariant.resolve(
        preferences: await prefs(),
        readReferrer: () async {
          fetched = true;
          return null;
        },
        config: rules(),
      );

      expect(variant, AppVariant.sunioMax);
      expect(
        fetched,
        isFalse,
        reason: 'the referrer is read once per install, not per launch',
      );
    });

    test('a stored referrer is re-judged when the rule changes', () async {
      await AppVariant.seedReferrer(campaign);

      // The campaign shipped before the dashboard knew about this source.
      expect(
        await AppVariant.resolve(
          preferences: await prefs(),
          readReferrer: () async => null,
          config: rules(sources: 'google-ads'),
        ),
        AppVariant.circle360,
      );

      // Widened the next day, with no release.
      expect(
        await AppVariant.resolve(
          preferences: await prefs(),
          readReferrer: () async => null,
          config: rules(sources: 'google-ads,facebook'),
        ),
        AppVariant.sunioMax,
      );
    });

    test('a pinned verdict outranks a changed rule', () async {
      await AppVariant.seedReferrer(campaign);
      await AppVariant.pin(AppVariant.sunioMax);

      // The kill switch would otherwise move this user out of the app they signed in to.
      final variant = await AppVariant.resolve(
        preferences: await prefs(),
        readReferrer: () async => null,
        config: rules(enabled: 'false'),
      );

      expect(variant, AppVariant.sunioMax);
    });

    test('a pinned Circle360 user is never pulled into SunioMax', () async {
      await AppVariant.pin(AppVariant.circle360);

      final variant = await AppVariant.resolve(
        preferences: await prefs(),
        readReferrer: () async => campaign,
        config: rules(),
      );

      expect(variant, AppVariant.circle360);
    });

    test('an existing install is pinned to Circle360 and never judged', () async {
      // The most expensive bug available here. Circle360 is itself bought through Facebook Ads,
      // so its own users' referrers carry utm_source=facebook — the same value a SunioMax
      // campaign carries. Judged on the referrer alone, the update that introduces this gate
      // would move every ad-acquired Circle360 subscriber into a different app.
      SharedPreferences.setMockInitialValues({
        'loc360.analytics_install_id': 'minted-on-an-earlier-launch',
      });

      var fetched = false;
      final variant = await AppVariant.resolve(
        preferences: await prefs(),
        readReferrer: () async {
          fetched = true;
          return campaign;
        },
        config: rules(),
      );

      expect(variant, AppVariant.circle360);
      expect(
        fetched,
        isFalse,
        reason: 'an existing install must not be re-judged at all',
      );
    });

    test('that pin survives, so a later launch cannot undo it', () async {
      SharedPreferences.setMockInitialValues({
        'loc360.analytics_install_id': 'minted-on-an-earlier-launch',
      });

      await AppVariant.resolve(
        preferences: await prefs(),
        readReferrer: () async => campaign,
        config: rules(),
      );
      final second = await AppVariant.resolve(
        preferences: await prefs(),
        readReferrer: () async => campaign,
        config: rules(),
      );

      expect(second, AppVariant.circle360);
      expect((await prefs()).getString('loc360.app_variant'), 'circle360');
    });

    test('a fresh install is not mistaken for an upgrade', () async {
      // No install id yet: AppVariant.resolve runs before _startAnalytics, which is what mints
      // it, so a genuinely new device has none on its first launch.
      final variant = await AppVariant.resolve(
        preferences: await prefs(),
        readReferrer: () async => campaign,
        config: rules(),
      );

      expect(variant, AppVariant.sunioMax);
    });

    test('a timed-out first launch is still SunioMax on the second', () async {
      // The false negative the gate_seen marker exists to prevent. Launch 1 times out and stores
      // no referrer, but _startAnalytics still mints an install id — so launch 2 would otherwise
      // look exactly like an upgrade and pin this campaign user to Circle360 for good.
      final store = await prefs();
      expect(
        await AppVariant.resolve(
          preferences: store,
          readReferrer: () async => null,
          config: rules(),
        ),
        AppVariant.circle360,
      );

      // What the first launch's analytics boot would have written afterwards.
      await store.setString(
        'loc360.analytics_install_id',
        'minted-on-launch-one',
      );

      expect(
        await AppVariant.resolve(
          preferences: await prefs(),
          readReferrer: () async => campaign,
          config: rules(),
        ),
        AppVariant.sunioMax,
      );
    });

    test('a thrown fetch is Circle360, not a failed boot', () async {
      final variant = await AppVariant.resolve(
        preferences: await prefs(),
        readReferrer: () async => throw StateError('play services exploded'),
        config: rules(),
      );

      expect(variant, AppVariant.circle360);
    });

    test('an unrecognised pinned value falls through to the rule', () async {
      // A half-written preference, or one left by an older spelling, must not pin anything.
      SharedPreferences.setMockInitialValues({
        'loc360.app_variant': 'sunio_max_typo',
      });

      final variant = await AppVariant.resolve(
        preferences: await prefs(),
        readReferrer: () async => campaign,
        config: rules(),
      );

      expect(variant, AppVariant.sunioMax);
    });
  });

  group('id', () {
    test('the stored and reported spellings are stable', () {
      // These are the `app` super property in Mixpanel. Renaming one splits a funnel for good.
      expect(AppVariant.circle360.id, 'circle360');
      expect(AppVariant.sunioMax.id, 'suniomax');
      expect(AppVariant.sunioMax.isSunioMax, isTrue);
      expect(AppVariant.circle360.isSunioMax, isFalse);
    });

    test('Circle360 keeps the Facebook content id its live campaigns already use', () {
      // Both apps report to one Facebook app and Facebook has no super properties, so this is
      // the only field separating them there. Renaming Circle360's would silently stop an
      // existing Custom Audience matching.
      expect(AppVariant.circle360.fbContentId, 'circle360_subscription');
    });

    test('SunioMax reports under its own Facebook content id', () {
      expect(AppVariant.sunioMax.fbContentId, 'suniomax_subscription');
      expect(
        AppVariant.sunioMax.fbContentId,
        isNot(AppVariant.circle360.fbContentId),
      );
    });
  });
}
