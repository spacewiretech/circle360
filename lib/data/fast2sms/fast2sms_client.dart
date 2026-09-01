import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'fast2sms_exception.dart';

/// Outcome of a verify call, so the caller can tell a wrong code from an expired one.
enum VerifyResult { verified, wrongCode, expiredOrUsed }

/// Thin wrapper over the Fast2SMS OTP endpoints.
///
/// [baseUrl] and the auth header are injected rather than hardcoded: pointing this at a
/// Supabase Edge Function later — which is where the API key really belongs — is a change to
/// the constructor, not to any call site.
class Fast2SmsClient {
  Fast2SmsClient({
    required this.apiKey,
    required this.otpId,
    http.Client? httpClient,
    Uri? baseUrl,
    this.timeout = const Duration(seconds: 20),
  })  : _http = httpClient ?? http.Client(),
        _baseUrl = baseUrl ?? Uri.parse('https://www.fast2sms.com');

  final String apiKey;
  final String otpId;
  final Duration timeout;
  final http.Client _http;
  final Uri _baseUrl;

  /// Fast2SMS caps this at 4–10; the OTP screen renders 6 boxes.
  static const otpLength = 6;

  /// Minutes. Kept short so a leaked SMS ages out quickly.
  static const otpExpiryMinutes = 5;

  /// Sends a freshly generated code. Fast2SMS owns generation, expiry and verification, so
  /// the correct code never exists inside the app.
  Future<void> sendOtp(String mobile) => _post('/dev/otp/send', {
        'mobile': mobile,
        'otp_id': otpId,
        'otp_length': otpLength,
        'otp_expiry': otpExpiryMinutes,
      });

  /// Redelivers the *same* code. Valid for 10 minutes after the original send and capped at
  /// 5 attempts server-side; throws with code 404 once that window closes.
  Future<void> resendOtp(String mobile) => _post('/dev/otp/resend', {'mobile': mobile});

  Future<VerifyResult> verifyOtp({required String mobile, required String otp}) async {
    print("innnnn");
    try {
      await _post('/dev/otp/verify', {'mobile': mobile, 'otp': otp});
      return VerifyResult.verified;
    } on Fast2SmsException catch (e) {
      // 400 covers a wrong code, an expired one and too many attempts; 404 means there is no
      // outstanding OTP for this number, so it was already used or has aged out.
      return switch (e.code) {
        400 => VerifyResult.wrongCode,
        404 => VerifyResult.expiredOrUsed,
        _ => throw e,
      };
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body) async {
    late final http.Response response;
    try {
      response = await _http
          .post(
            _baseUrl.replace(path: path),
            headers: {
              'Authorization': apiKey,
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on SocketException catch (e) {
      throw Fast2SmsException(
        code: null,
        userMessage: 'No internet connection. Check your network and try again.',
        developerDetail: 'SocketException on $path: $e',
      );
    } on TimeoutException {
      throw Fast2SmsException(
        code: null,
        userMessage: 'The network is slow right now. Please try again.',
        developerDetail: 'Timed out after ${timeout.inSeconds}s on $path',
      );
    } on http.ClientException catch (e) {
      throw Fast2SmsException(
        code: null,
        userMessage: 'Could not reach the verification service. Please try again.',
        developerDetail: 'ClientException on $path: $e',
      );
    }

    final Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(response.body);
      if (parsed is! Map<String, dynamic>) throw const FormatException('not an object');
      decoded = parsed;
    } catch (e) {
      throw Fast2SmsException(
        code: null,
        userMessage: 'Something went wrong. Please try again.',
        developerDetail:
            'Unreadable body on $path (HTTP ${response.statusCode}): '
            '${response.body.length > 200 ? '${response.body.substring(0, 200)}…' : response.body}',
      );
    }

    // Fast2SMS returns failures as `return:false` inside an HTTP 200 as readily as with a 4xx,
    // so the body decides — never the status line.
    if (decoded['return'] == true) return decoded;

    final code = switch (decoded['status_code']) {
      final int c => c,
      final String c => int.tryParse(c),
      _ => response.statusCode == 200 ? null : response.statusCode,
    };
    final providerMessage = switch (decoded['message']) {
      final String m => m,
      final List<dynamic> m => m.join(', '),
      _ => null,
    };

    final failure = mapFast2SmsError(code, providerMessage);
    if (failure.isConfigurationProblem) debugPrint('[Fast2SMS] ${failure.developerDetail}');
    throw failure;
  }

  void dispose() => _http.close();
}
