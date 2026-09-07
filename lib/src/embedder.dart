/// Embedding abstraction: [Embedder] interface + the production
/// [OllamaEmbedder]. Tests inject a deterministic fake instead.
///
/// Failure handling is typed and actionable — no silent failures
/// (docs/contract/objectbox-capabilities.md §8).
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'store.dart' show LogSink, sanitizeForLog, stderrLog;

/// L-6 (2026-09-07 security review): Ollama response bodies were
/// interpolated into exceptions/log lines unsanitized and unbounded (a
/// misbehaving/misconfigured Ollama, or a hostile OBX_MEMORY_OLLAMA_URL,
/// could return arbitrarily large content, or content containing
/// newlines/ANSI escapes that forge log lines). Truncates to 500 chars
/// THEN strips C0 control chars ([sanitizeForLog], shared via store.dart —
/// SEC-5) at every site below that interpolates raw Ollama response
/// content into a log line or an [EmbedderException] message.
String _sanitizeExternal(String value) => sanitizeForLog(
  value.length > 500 ? '${value.substring(0, 500)}…' : value,
);

/// Typed embedding failure with an operator-actionable message.
class EmbedderException implements Exception {
  final String message;

  EmbedderException(this.message);

  @override
  String toString() => 'EmbedderException: $message';
}

/// Produces embedding vectors for text.
abstract interface class Embedder {
  /// Model identifier stored on every index row ([MemoryIndex.embedModel]).
  String get modelId;

  /// Dimensionality every returned vector is guaranteed to have.
  int get dims;

  Future<List<double>> embed(String text);
}

/// Embeds via a local Ollama server (`POST /api/embed`).
class OllamaEmbedder implements Embedder {
  final String baseUrl;
  @override
  final String modelId;
  @override
  final int dims;
  final http.Client _client;
  final LogSink _log;

  OllamaEmbedder({
    required this.baseUrl,
    required this.modelId,
    required this.dims,
    http.Client? client,
    LogSink log = stderrLog,
  }) : _client = client ?? http.Client(),
       _log = log;

  static const _hintNotRunning =
      'Is Ollama running? Start it with `ollama serve` (or launch the '
      'Ollama app), and check OBX_MEMORY_OLLAMA_URL.';

  @override
  Future<List<double>> embed(String text) async {
    final uri = Uri.parse('$baseUrl/api/embed');
    late final http.Response response;
    try {
      response = await _client.post(
        uri,
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'model': modelId, 'input': text}),
      );
    } on SocketException catch (err) {
      throw EmbedderException(
        'Cannot reach Ollama at $baseUrl ($err). $_hintNotRunning',
      );
    } on http.ClientException catch (err) {
      throw EmbedderException(
        'HTTP error talking to Ollama at $baseUrl ($err). $_hintNotRunning',
      );
    }
    if (response.statusCode != 200) {
      throw EmbedderException(
        'Ollama /api/embed returned HTTP ${response.statusCode} for model '
        '"$modelId": ${_sanitizeExternal(response.body)}. If the model is '
        'missing, run `ollama pull $modelId`.',
      );
    }
    final List<dynamic> embeddings;
    try {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      embeddings = decoded['embeddings'] as List<dynamic>;
    } catch (err) {
      throw EmbedderException(
        'Unexpected /api/embed response shape from Ollama: $err — body: '
        '${_sanitizeExternal(response.body)}',
      );
    }
    if (embeddings.isEmpty) {
      throw EmbedderException(
        'Ollama returned zero embeddings for a non-empty input '
        '(model "$modelId").',
      );
    }
    final vector = (embeddings.first as List<dynamic>)
        .map((v) => (v as num).toDouble())
        .toList(growable: false);
    if (vector.length != dims) {
      // Dimension mismatch names BOTH numbers (spec + contract §8).
      throw EmbedderException(
        'Embedding dimension mismatch: model "$modelId" returned '
        '${vector.length} dims but OBX_MEMORY_DIMS/schema expects $dims. '
        'Changing models requires matching dims (schema is fixed at '
        'the @HnswIndex dimensions) and a full reindex.',
      );
    }
    return vector;
  }

  /// Startup probe: verifies Ollama is reachable and the model is present.
  ///
  /// - Ollama unreachable => [EmbedderException] (caller decides whether to
  ///   keep serving; tools will surface the error per request).
  /// - Model missing and [autoPull] => pulls it via `POST /api/pull`,
  ///   streaming progress lines to the log (visible, never silent).
  /// - Model missing and !autoPull => [EmbedderException] telling the user
  ///   to run `ollama pull`.
  Future<void> ensureModelAvailable({required bool autoPull}) async {
    final tagsUri = Uri.parse('$baseUrl/api/tags');
    late final http.Response tagsResponse;
    try {
      tagsResponse = await _client.get(tagsUri);
    } on SocketException catch (err) {
      throw EmbedderException(
        'Cannot reach Ollama at $baseUrl ($err). $_hintNotRunning',
      );
    } on http.ClientException catch (err) {
      throw EmbedderException(
        'HTTP error talking to Ollama at $baseUrl ($err). $_hintNotRunning',
      );
    }
    if (tagsResponse.statusCode != 200) {
      throw EmbedderException(
        'Ollama /api/tags returned HTTP ${tagsResponse.statusCode}: '
        '${_sanitizeExternal(tagsResponse.body)}',
      );
    }
    final models =
        ((jsonDecode(tagsResponse.body) as Map<String, dynamic>)['models']
                    as List<dynamic>? ??
                [])
            .map((m) => (m as Map<String, dynamic>)['name'] as String)
            .toList();
    final present = models.any(
      (name) => name == modelId || name.startsWith('$modelId:'),
    );
    if (present) {
      _log('[embedder] Ollama model "$modelId" is available at $baseUrl');
      return;
    }
    if (!autoPull) {
      throw EmbedderException(
        'Embedding model "$modelId" is not installed in Ollama at $baseUrl '
        'and OBX_MEMORY_AUTO_PULL=false. Run `ollama pull $modelId`.',
      );
    }
    _log(
      '[embedder] model "$modelId" missing — pulling via Ollama '
      '(POST /api/pull), this may take a while...',
    );
    final request =
        http.Request('POST', Uri.parse('$baseUrl/api/pull'))
          ..headers['content-type'] = 'application/json'
          ..body = jsonEncode({'model': modelId});
    final streamed = await _client.send(request);
    if (streamed.statusCode != 200) {
      final body = await streamed.stream.bytesToString();
      throw EmbedderException(
        'Ollama /api/pull for "$modelId" returned HTTP '
        '${streamed.statusCode}: $body',
      );
    }
    String? lastStatus;
    await for (final line in streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      try {
        final obj = jsonDecode(line) as Map<String, dynamic>;
        final status = obj['status'] as String? ?? line;
        if (obj['error'] != null) {
          throw EmbedderException(
            'Ollama pull of "$modelId" failed: ${obj['error']}',
          );
        }
        if (status != lastStatus) {
          _log('[embedder] pull $modelId: $status');
          lastStatus = status;
        }
      } on FormatException {
        _log('[embedder] pull $modelId: ${_sanitizeExternal(line)}');
      }
    }
    _log('[embedder] pull of "$modelId" finished');
  }

  void close() => _client.close();
}
