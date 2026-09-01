import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A structured failure returned by an Edge Function.
///
/// [code] is the stable machine-readable string the functions emit (`invalid_otp`,
/// `otp_expired`, `throttled`, `unauthorized`, …); [message] is already safe to show.
class EdgeError implements Exception {
  const EdgeError(this.code, this.message);

  /// Null for transport failures that never reached the function.
  final String? code;
  final String message;

  @override
  String toString() => 'EdgeError($code): $message';
}

/// The one call the Supabase repositories make. Injected so the error paths can be tested
/// without a deployed project.
abstract interface class EdgeFunctions {
  Future<Map<String, dynamic>> call(
    String name, {
    Map<String, dynamic>? body,
    String? bearerToken,
    bool delete = false,
  });
}

class SupabaseEdgeFunctions implements EdgeFunctions {
  SupabaseEdgeFunctions(this._client, {this.timeout = const Duration(seconds: 20)});

  final SupabaseClient _client;
  final Duration timeout;

  @override
  Future<Map<String, dynamic>> call(
    String name, {
    Map<String, dynamic>? body,
    String? bearerToken,
    bool delete = false,
  }) async {
    final FunctionResponse response;
    try {
      response = await _client.functions
          .invoke(
            name,
            body: body,
            headers: bearerToken == null
                ? null
                : {'Authorization': 'Bearer $bearerToken'},
            method: delete ? HttpMethod.delete : HttpMethod.post,
          )
          .timeout(timeout);
    } on SocketException {
      throw const EdgeError(
        null,
        'No internet connection. Check your network and try again.',
      );
    } on TimeoutException {
      throw const EdgeError(null, 'The network is slow right now. Please try again.');
    } on FunctionException catch (e) {
      final decoded = _decodeError(e.details);
      if (decoded != null) throw decoded;
      // A function that is not deployed answers 404 here. That is a developer problem, so it
      // goes to the log while the user sees the same message as any other outage.
      debugPrint('[supabase] $name returned ${e.status}: ${e.details}');
      throw const EdgeError(
        null,
        'Verification is temporarily unavailable. Please try again later.',
      );
    } catch (e) {
      debugPrint('[supabase] $name failed: $e');
      throw const EdgeError(null, 'Something went wrong. Please try again.');
    }

    final data = response.data;
    if (data is Map<String, dynamic>) {
      final failure = _decodeError(data);
      if (failure != null) throw failure;
      return data;
    }
    return const {};
  }

  /// Functions report failures as `{"error": {"code": …, "message": …}}`.
  EdgeError? _decodeError(Object? payload) {
    if (payload is! Map) return null;
    final error = payload['error'];
    if (error is! Map) return null;
    return EdgeError(
      error['code'] as String?,
      error['message'] as String? ??
          'Verification is temporarily unavailable. Please try again later.',
    );
  }
}
