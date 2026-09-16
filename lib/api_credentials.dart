import 'dart:convert';

/// Planning Center credentials, supplied at build time rather than compiled in
/// from source. Provide them with:
///
///   flutter run --dart-define-from-file=secrets.json
///
/// `secrets.json` is git-ignored; copy `secrets.example.json` to create it.
class ApiCredentials {
  static const String appId = String.fromEnvironment('PCO_APP_ID');
  static const String secret = String.fromEnvironment('PCO_SECRET');

  static bool get isConfigured => appId.isNotEmpty && secret.isNotEmpty;

  static String get basicAuthHeader =>
      'Basic ${base64.encode(utf8.encode('$appId:$secret'))}';
}
