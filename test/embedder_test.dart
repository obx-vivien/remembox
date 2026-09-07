/// L-6 (2026-09-07 security review): [OllamaEmbedder] interpolated raw
/// Ollama HTTP response bodies into [EmbedderException] messages and log
/// lines unsanitized and unbounded — a misbehaving/misconfigured Ollama (or
/// a hostile `OBX_MEMORY_OLLAMA_URL`) could inject a newline/ANSI escape to
/// forge a log line, or return an arbitrarily large body. Fixed by routing
/// every such interpolation through the shared `sanitizeForLog` (store.dart,
/// moved there so this file — which had no access to [MemoryService]'s
/// private copy before — can use it too) truncated to 500 chars first.
///
/// No dedicated unit test file for [OllamaEmbedder] existed before this
/// finding (only test/ollama_integration_test.dart, which requires a REAL
/// local Ollama and is excluded from the default run) — this file is
/// scoped strictly to L-6's four sites, using `package:http/testing.dart`'s
/// [MockClient] so no real network/Ollama is needed.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remembox/src/embedder.dart';
import 'package:test/test.dart';

void main() {
  const poisonedBody =
      'boom\n10:00:00 [FATAL] forged log line\x1b[31mred\x1b[0m';

  group('L-6: Ollama response bodies are sanitized and bounded', () {
    test(
      '/api/embed non-200 response: body is sanitized and truncated in '
      'the EmbedderException message',
      () async {
        final client = MockClient(
          (request) async => http.Response(poisonedBody, 500),
        );
        final embedder = OllamaEmbedder(
          baseUrl: 'http://fake-ollama',
          modelId: 'test-model',
          dims: 3,
          client: client,
        );
        addTearDown(embedder.close);

        await expectLater(
          embedder.embed('some text'),
          throwsA(
            isA<EmbedderException>().having(
              (e) => e.message,
              'message',
              allOf(
                isNot(contains('\n10:00:00 [FATAL]')),
                isNot(contains('\x1b[31m')),
                contains('boom'),
              ),
            ),
          ),
        );
      },
    );

    test(
      '/api/embed unparsable response shape: body is sanitized and '
      'truncated in the EmbedderException message',
      () async {
        final client = MockClient(
          (request) async => http.Response(poisonedBody, 200),
        );
        final embedder = OllamaEmbedder(
          baseUrl: 'http://fake-ollama',
          modelId: 'test-model',
          dims: 3,
          client: client,
        );
        addTearDown(embedder.close);

        await expectLater(
          embedder.embed('some text'),
          throwsA(
            isA<EmbedderException>().having(
              (e) => e.message,
              'message',
              allOf(
                isNot(contains('\n10:00:00 [FATAL]')),
                isNot(contains('\x1b[31m')),
                contains('boom'),
              ),
            ),
          ),
        );
      },
    );

    test(
      '/api/tags non-200 response (ensureModelAvailable): body is '
      'sanitized and truncated in the EmbedderException message',
      () async {
        final client = MockClient(
          (request) async => http.Response(poisonedBody, 503),
        );
        final embedder = OllamaEmbedder(
          baseUrl: 'http://fake-ollama',
          modelId: 'test-model',
          dims: 3,
          client: client,
        );
        addTearDown(embedder.close);

        await expectLater(
          embedder.ensureModelAvailable(autoPull: false),
          throwsA(
            isA<EmbedderException>().having(
              (e) => e.message,
              'message',
              allOf(
                isNot(contains('\n10:00:00 [FATAL]')),
                isNot(contains('\x1b[31m')),
                contains('boom'),
              ),
            ),
          ),
        );
      },
    );

    test(
      'a body longer than 500 chars is truncated (not just sanitized) in '
      'the interpolated message',
      () async {
        final hugeBody = 'x' * 10000;
        final client = MockClient(
          (request) async => http.Response(hugeBody, 500),
        );
        final embedder = OllamaEmbedder(
          baseUrl: 'http://fake-ollama',
          modelId: 'test-model',
          dims: 3,
          client: client,
        );
        addTearDown(embedder.close);

        await expectLater(
          embedder.embed('some text'),
          throwsA(
            isA<EmbedderException>().having(
              (e) => e.message,
              'message',
              predicate<String>((m) => m.length < hugeBody.length),
            ),
          ),
        );
      },
    );

    test(
      'model missing + autoPull: a pull-progress line that fails to parse '
      'as JSON is sanitized before being logged',
      () async {
        final loggedLines = <String>[];
        final client = MockClient((request) async {
          if (request.url.path == '/api/tags') {
            return http.Response(jsonEncode({'models': <Object?>[]}), 200);
          }
          if (request.url.path == '/api/pull') {
            // A non-JSON progress line (the FormatException catch path) —
            // poisoned to prove it is sanitized before logging.
            return http.Response(poisonedBody, 200);
          }
          throw StateError('unexpected request: ${request.url}');
        });
        final embedder = OllamaEmbedder(
          baseUrl: 'http://fake-ollama',
          modelId: 'missing-model',
          dims: 3,
          client: client,
          log: loggedLines.add,
        );
        addTearDown(embedder.close);

        await embedder.ensureModelAvailable(autoPull: true);

        final combinedLog = loggedLines.join('\n---\n');
        expect(combinedLog, isNot(contains('\n10:00:00 [FATAL]')));
        expect(combinedLog, isNot(contains('\x1b[31m')));
        expect(combinedLog, contains('boom'));
      },
    );
  });
}
