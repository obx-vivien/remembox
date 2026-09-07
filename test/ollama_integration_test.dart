/// Integration test against a REAL local Ollama instance.
///
/// Excluded from the default run — requires Ollama running with the
/// embeddinggemma model pulled. Run explicitly with:
///
///     dart test -P ollama
///
/// (FIX-5a: `-t ollama` alone selects the tag but does NOT override the
/// `skip:` set on it in dart_test.yaml — the preset form above is required
/// to actually run these tests; see dart_test.yaml.)
@Tags(['ollama'])
library;

import 'dart:io';

import 'package:remembox/src/embedder.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:test/test.dart';

import 'helpers/test_store_gate.dart';

void main() {
  test(
    'real Ollama embed + remember/recall round trip',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('remembox_ollama_');
      // 2026-09-01 (Store-Gate): persistent-mode StoreGate wrapping a fresh
      // temp store — see test/helpers/test_store_gate.dart.
      final testGate = await openTestGate(tempDir.path);
      final embedder = OllamaEmbedder(
        baseUrl:
            Platform.environment['OBX_MEMORY_OLLAMA_URL'] ??
            'http://localhost:11434',
        modelId:
            Platform.environment['OBX_MEMORY_EMBED_MODEL'] ?? 'embeddinggemma',
        dims: 768,
      );
      final service = MemoryService(gate: testGate.gate, embedder: embedder);
      addTearDown(() async {
        await service.dispose();
        embedder.close();
        await testGate.close();
        tempDir.deleteSync(recursive: true);
      });

      final vector = await embedder.embed('sanity check');
      expect(vector, hasLength(768));

      await service.remember(
        text: 'The capital of France is Paris, home of the Louvre.',
        project: 'test',
      );
      await service.remember(
        text: 'ObjectBox is a fast embedded database with vector search.',
        project: 'test',
      );
      await service.remember(
        text: 'Sourdough bread needs a mature starter and long fermentation.',
        project: 'test',
      );

      final result = await service.recall(
        query: 'Which database has vector search?',
        k: 1,
      );
      final hits = result['hits'] as List;
      expect(hits, hasLength(1));
      expect(
        (hits.single as Map)['text'],
        contains('ObjectBox'),
        reason: 'semantic recall should surface the database memory',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
