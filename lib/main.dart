import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'boot/mobile_boot.dart';
import 'website/site_app.dart';
import 'website/url_strategy.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The marketing site is the whole of the web build. The app itself is phone-only — a native
  // background location service and a UPI checkout that only exists inside the Cashfree app —
  // so there is nothing on web for it to fall through to.
  if (kIsWeb) {
    configureUrlStrategy();
    runApp(const Circle360SiteApp());
    return;
  }

  await bootMobileApp();
}
