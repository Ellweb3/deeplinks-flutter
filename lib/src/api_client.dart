import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const sdkVersion = '0.1.0';

class ApiResponse {
  const ApiResponse(this.statusCode, this.body);

  final int statusCode;
  final Map<String, Object?> body;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
  bool get isRetryable => statusCode == 408 || statusCode == 429 || statusCode >= 500;
}

class ApiUnavailable implements Exception {
  const ApiUnavailable(this.cause);

  final Object cause;

  @override
  String toString() => 'ApiUnavailable($cause)';
}

class ApiClient {
  ApiClient({
    required Uri baseUrl,
    required String appKey,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 10),
  }) : _baseUrl = baseUrl,
       _appKey = appKey,
       _http = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri _baseUrl;
  final String _appKey;
  final http.Client _http;
  final Duration _timeout;

  Future<ApiResponse> post(String path, Map<String, Object?> body) async {
    final uri = _baseUrl.resolve(path);
    try {
      final response = await _http
          .post(
            uri,
            headers: {'Content-Type': 'application/json', 'X-App-Key': _appKey, 'X-Client-SDK': 'flutter/$sdkVersion'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      return ApiResponse(response.statusCode, _decode(response.body));
    } on TimeoutException catch (e) {
      throw ApiUnavailable(e);
    } on http.ClientException catch (e) {
      throw ApiUnavailable(e);
    }
  }

  void close() => _http.close();

  static Map<String, Object?> _decode(String raw) {
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }
}

Uri validateBaseUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw ArgumentError.value(raw, 'baseUrl', 'must be an absolute url');
  }
  const localHosts = {'localhost', '127.0.0.1', '10.0.2.2', '::1'};
  final isLocal = localHosts.contains(uri.host) || uri.host.endsWith('.localhost');
  if (uri.scheme != 'https' && !(uri.scheme == 'http' && isLocal)) {
    throw ArgumentError.value(raw, 'baseUrl', 'must use https outside of localhost');
  }
  final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
  return uri.replace(path: path, query: null, fragment: null);
}
