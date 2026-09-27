/// Fetch seam for the community identity index
/// (docs/architecture/phase3-slice3.md §4–§5).
///
/// The injectable [CommunityIndexTransport] keeps the network out of
/// the refresh unit tests — and out of the Settings UI's widget tests
/// (docs/architecture/phase3-slice4.md §6);
/// [HttpCommunityIndexTransport] is the production vehicle. Failures
/// surface only as [CommunityFetchException] — a message naming the
/// mirror, never a secret.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Thrown by [CommunityIndexTransport.fetch] on any failure: network
/// error, timeout, redirect loop, non-200 status. [message] says what
/// failed and names the mirror host — it never carries credentials,
/// tokens, or response secrets.
class CommunityFetchException implements Exception {
  const CommunityFetchException(this.message);

  final String message;

  @override
  String toString() => 'CommunityFetchException: $message';
}

/// One GET of a community index doc. Injected into
/// `StoreHost.refreshCommunityIndex` so tests can script mirrors
/// without touching the network.
abstract class CommunityIndexTransport {
  /// GETs [url] and returns the response body as a string.
  ///
  /// Throws [CommunityFetchException] (message only, no secrets) on
  /// any failure.
  Future<String> fetch(Uri url);
}

/// Production [CommunityIndexTransport] over `dart:io` [HttpClient]:
/// a 30s budget per phase (connect, response, body), redirects
/// followed ([HttpClient]'s default), non-200 → throw. HTTPS
/// enforcement happens in the refresh loop — a non-https mirror never
/// reaches the transport.
class HttpCommunityIndexTransport implements CommunityIndexTransport {
  HttpCommunityIndexTransport({HttpClient? client})
    : _client = client ?? HttpClient();

  final HttpClient _client;

  /// Budget per fetch phase (connect / response / body).
  static const _budget = Duration(seconds: 30);

  @override
  Future<String> fetch(Uri url) async {
    try {
      final request = await _client.getUrl(url).timeout(_budget);
      final response = await request.close().timeout(_budget);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_budget);
      if (response.statusCode != HttpStatus.ok) {
        throw CommunityFetchException(
          'mirror ${url.host} returned HTTP ${response.statusCode}',
        );
      }
      return body;
    } on CommunityFetchException {
      rethrow;
    } on TimeoutException {
      throw CommunityFetchException('mirror ${url.host} timed out after 30s');
    } on IOException catch (e) {
      throw CommunityFetchException('mirror ${url.host} unreachable: $e');
    }
  }
}
