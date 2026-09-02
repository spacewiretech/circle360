import 'package:flutter_web_plugins/url_strategy.dart';

/// Drops the `#` from site URLs. Requires the host to rewrite unknown paths to
/// `index.html`, or every route except `/` 404s on a hard refresh.
void configureUrlStrategy() => usePathUrlStrategy();
