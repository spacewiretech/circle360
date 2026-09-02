// Starts the phone app.
//
// Resolved at compile time, not at runtime: the app tree reaches `dart:io` in four places
// (`edge_functions.dart`, `fast2sms_client.dart`, `location_permission_view.dart`,
// `tracking_diagnostics_screen.dart`), and dart2js rejects that import before tree-shaking
// ever gets a chance to drop it. A plain `if (kIsWeb)` in `main.dart` would still compile
// the whole tree, so the web build has to be unable to see it at all.
export 'mobile_boot_stub.dart' if (dart.library.io) 'mobile_boot_io.dart';
