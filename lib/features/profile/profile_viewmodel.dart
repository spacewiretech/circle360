import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/app_user.dart';
import '../../data/providers.dart';

/// Read-only for now — editing details is a screen the design does not cover yet.
final profileViewModelProvider = FutureProvider.autoDispose<AppUser>(
  (ref) => ref.watch(profileRepositoryProvider).me(),
);
