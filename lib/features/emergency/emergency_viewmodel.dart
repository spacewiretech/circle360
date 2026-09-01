import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    try {
      await _repository.add(name: name, phone: phone);
      final contacts = await _repository.list();
      state = state.copyWith(contacts: contacts, message: '$name added');
    } on StateError catch (e) {
      state = state.copyWith(message: e.message);
    }
  }

  Future<void> remove(EmergencyContact contact) async {
    await _repository.remove(contact.id);
    final contacts = await _repository.list();
    state = state.copyWith(contacts: contacts, message: '${contact.name} removed');
  }

  /// No dialer wired up yet — the confirmation stands in for the call.
  void call(EmergencyContact contact) =>
      state = state.copyWith(message: 'Calling ${contact.name} on ${contact.phone}');

  void consumeMessage() => state = state.copyWith(clearMessage: true);
}

final emergencyViewModelProvider =
    NotifierProvider<EmergencyViewModel, EmergencyState>(EmergencyViewModel.new);
