import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_credentials.dart';

/// Maximum page size the Planning Center API accepts. Asking for more silently
/// returns 100, so the UI clamps to this rather than quietly under-delivering.
const int maxPerPage = 100;

/// A failure that is worth showing to the user rather than only logging.
class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PcoEvent {
  const PcoEvent({required this.id, required this.name});

  final String id;
  final String name;
}

class PlanningCenterApi {
  PlanningCenterApi({http.Client? client}) : _client = client ?? http.Client();

  static const String _base =
      'https://api.planningcenteronline.com/check-ins/v2';

  /// Safety net so a malformed `links.next` cannot loop forever.
  static const int _maxPages = 20;

  final http.Client _client;

  Map<String, String> get _headers => {
        'Authorization': ApiCredentials.basicAuthHeader,
        'Accept': 'application/json',
      };

  /// Fetches every event, following pagination. Without this the dropdown only
  /// ever showed the API's default first page.
  Future<List<PcoEvent>> fetchEvents() async {
    final events = <PcoEvent>[];
    var offset = 0;

    for (var page = 0; page < _maxPages; page++) {
      final body = await _getJson(
        Uri.parse('$_base/events?per_page=$maxPerPage&offset=$offset'),
      );

      final data = body['data'];
      if (data is! List || data.isEmpty) break;

      for (final entry in data) {
        final id = entry['id'];
        if (id is! String) continue;
        final attrs = entry['attributes'];
        final name = attrs is Map ? attrs['name'] : null;
        events.add(
          PcoEvent(id: id, name: name is String && name.isNotEmpty ? name : 'Untitled'),
        );
      }

      final links = body['links'];
      if (links is! Map || links['next'] == null) break;
      offset += maxPerPage;
    }

    events.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return events;
  }

  /// Returns the raw `data` array of checked-out check-ins, newest first.
  Future<List<dynamic>> fetchCheckIns({
    required String eventId,
    required int limit,
  }) async {
    final perPage = limit.clamp(1, maxPerPage);
    final body = await _getJson(
      Uri.parse(
        '$_base/check_ins?include=event,person,checked_out_by'
        '&order=-checked_out_at&where[event_id]=$eventId'
        '&filter=checked_out&per_page=$perPage',
      ),
    );

    final data = body['data'];
    return data is List ? data : const [];
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw ApiException('Could not reach Planning Center. Check your network.');
    }

    if (response.statusCode != 200) {
      throw ApiException(_describeStatus(response.statusCode));
    }

    try {
      final decoded = json.decode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw ApiException('Unexpected response from Planning Center.');
      }
      return decoded;
    } on FormatException {
      throw ApiException('Could not read the response from Planning Center.');
    }
  }

  String _describeStatus(int status) {
    switch (status) {
      case 401:
        return 'Not authorized (401). Check PCO_APP_ID and PCO_SECRET in secrets.json.';
      case 403:
        return 'Access denied (403). This token lacks Check-Ins permission.';
      case 404:
        return 'Not found (404). The selected event may no longer exist.';
      case 429:
        return 'Rate limited (429). Try a longer poll interval.';
      default:
        if (status >= 500) {
          return 'Planning Center is having trouble ($status). Retrying.';
        }
        return 'Request failed ($status).';
    }
  }

  void dispose() => _client.close();
}
