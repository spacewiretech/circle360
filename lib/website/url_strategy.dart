// Clean `/privacy` URLs instead of the default `/#/privacy`.
//
// Not cosmetic: the SMS invite links built in `deeplink_service.dart` are real paths
// (`https://loc360.app/invite/CODE`), and a policy URL handed to Play Console or Cashfree
// should not carry a fragment. `flutter_web_plugins` only exists on the web target, hence
// the conditional export.
export 'url_strategy_stub.dart' if (dart.library.js_interop) 'url_strategy_web.dart';
