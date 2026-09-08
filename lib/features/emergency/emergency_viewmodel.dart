import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/analytics/analytics_events.dart';
import '../../data/dialer.dart';
import '../../data/models/emergency_contact.dart';
import '../../data/providers.dart';
import '../../data/repositories/emergency_repository.dart';

@immutable
class EmergencyState {
  const EmergencyState({
    this.contacts = const [],
    this.loading = true,
    this.message,
  });

  final List<EmergencyContact> contacts;
  final bool loading;
  final String? message;

  bool get isEmpty => !loading && contacts.isEmpty;

  bool get canAddMore => contacts.length < EmergencyRepository.maxContacts;

  EmergencyState copyWith({
    List<EmergencyContact>? contacts,
    bool? loading,
    String? message,
    bool clearMessage = false,
  }) {
    return EmergencyState(
      contacts: contacts ?? this.contacts,
      loading: loading ?? this.loading,
      message: clearMessage ? null : (message ?? this.message),
    );
  }
}

class EmergencyViewModel extends Notifier<EmergencyState> {
  @override
  EmergencyState build() {
    _load();
    return const EmergencyState();
  }

  EmergencyRepository get _repository => ref.read(emergencyRepositoryProvider);

  Future<void> _load() async {
    final contacts = await _repository.list();
    state = state.copyWith(contacts: contacts, loading: false);
  }

  Future<void> add({required String name, required String phone}) async {
    final analytics = ref.read(analyticsProvider);
    try {
      await _repository.add(name: name, phone: phone);
      final contacts = await _repository.list();
      state = state.copyWith(contacts: contacts, message: '$name added');
      analytics.track(Ev.emergencyContactAdded, {P.count: contacts.length});
    } on StateError catch (e) {
      state = state.copyWith(message: e.message);
      // Almost always the three-contact cap. Worth counting: users hitting a limit they did not
      // know about is a product decision to revisit, not a failure to shrug at.
      analytics.track(Ev.errorShown, {
        P.source: 'add_emergency_contact',
        P.message: e.message,
      });
    }
  }

  Future<void> remove(EmergencyContact contact) async {
    await _repository.remove(contact.id);
    final contacts = await _repository.list();
    state = state.copyWith(contacts: contacts, message: '${contact.name} removed');
    ref.read(analyticsProvider).track(Ev.emergencyContactRemoved, {
      P.count: contacts.length,
    });
  }

  /// Hands the number to the phone's dialer. Silent on success — the dialer coming up is the
  /// confirmation, and a SnackBar underneath it would only be read after the call.
  Future<void> call(EmergencyContact contact) async {
    ref.read(analyticsProvider).track(Ev.emergencyContactCalled);
    final error = await dialNumber(contact.phone);
    if (error != null) state = state.copyWith(message: error);
  }

  void consumeMessage() => state = state.copyWith(clearMessage: true);
}

final emergencyViewModelProvider =
    NotifierProvider<EmergencyViewModel, EmergencyState>(EmergencyViewModel.new);
