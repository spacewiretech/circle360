/// The web half of [mobile_boot.dart]. Never called — `main()` takes the site branch on web
/// — but it has to exist so the conditional export resolves.
Future<void> bootMobileApp() async {
  throw UnsupportedError('The Circle360 app runs on Android and iOS; the web build serves '
      'the marketing site instead.');
}
