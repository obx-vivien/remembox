/// Pins [StoreMode]/[MemoryConfig]'s `OBX_MEMORY_STORE_MODE` handling
/// (2026-09-01, Store-Gate feature, the 2026-09-01 store-gate engineering
/// log (internal), plan §1/§9). No dedicated test file for
/// `MemoryConfig.fromEnvironment`
/// existed before this feature (only inline coverage inside
/// memory_service_test.dart's constructor tests) — this file is scoped
/// strictly to the two new WP1 cases, not a general config-test backfill.
library;

import 'dart:io';

import 'package:remembox/src/store.dart';
import 'package:test/test.dart';

Map<String, String> _env({
  String? storeMode,
  String? syncUrl,
  String? exclusive,
}) => {
  'OBX_MEMORY_STORE_MODE': ?storeMode,
  'OBX_MEMORY_SYNC_URL': ?syncUrl,
  'OBX_MEMORY_EXCLUSIVE': ?exclusive,
};

void main() {
  group('StoreMode.fromEnvironment', () {
    test('unset / empty defaults to persistent (unchanged behavior)', () {
      expect(StoreMode.fromEnvironment(null), StoreMode.persistent);
      expect(StoreMode.fromEnvironment(''), StoreMode.persistent);
    });

    test('"persistent" parses to StoreMode.persistent', () {
      expect(StoreMode.fromEnvironment('persistent'), StoreMode.persistent);
      expect(StoreMode.fromEnvironment('Persistent'), StoreMode.persistent);
    });

    test('"gated" parses to StoreMode.gated', () {
      expect(StoreMode.fromEnvironment('gated'), StoreMode.gated);
      expect(StoreMode.fromEnvironment('GATED'), StoreMode.gated);
    });

    test('an unknown value throws ArgumentError naming the bad value', () {
      expect(
        () => StoreMode.fromEnvironment('turbo'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('OBX_MEMORY_STORE_MODE'), contains('turbo')),
          ),
        ),
      );
    });
  });

  group('MemoryConfig.fromEnvironment: OBX_MEMORY_STORE_MODE', () {
    test('defaults to StoreMode.persistent when unset', () {
      final config = MemoryConfig.fromEnvironment(env: _env());
      expect(config.storeMode, StoreMode.persistent);
    });

    test('honors an explicit "gated" value with no other conflicts', () {
      final config = MemoryConfig.fromEnvironment(env: _env(storeMode: 'gated'));
      expect(config.storeMode, StoreMode.gated);
    });

    test(
      'gated + a non-empty OBX_MEMORY_SYNC_URL throws ArgumentError '
      'naming both the mode and the sync URL (plan §1.2)',
      () {
        expect(
          () => MemoryConfig.fromEnvironment(
            env: _env(storeMode: 'gated', syncUrl: 'ws://example:9997'),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('OBX_MEMORY_STORE_MODE=gated'),
                contains('OBX_MEMORY_SYNC_URL'),
                contains('ws://example:9997'),
              ),
            ),
          ),
        );
      },
    );

    test(
      'gated + OBX_MEMORY_EXCLUSIVE=true throws ArgumentError (§14 MINOR: '
      'self-defeating combination, rejected with an actionable message '
      'rather than confusing the operator with the wrong lock\'s error)',
      () {
        expect(
          () => MemoryConfig.fromEnvironment(
            env: _env(storeMode: 'gated', exclusive: 'true'),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('OBX_MEMORY_STORE_MODE=gated'),
                contains('OBX_MEMORY_EXCLUSIVE'),
              ),
            ),
          ),
        );
      },
    );

    test(
      'persistent + OBX_MEMORY_SYNC_URL set is unaffected (no new '
      'validation for the unchanged default path)',
      () {
        final config = MemoryConfig.fromEnvironment(
          env: _env(storeMode: 'persistent', syncUrl: 'ws://example:9997'),
        );
        expect(config.storeMode, StoreMode.persistent);
        expect(config.syncUrl, 'ws://example:9997');
      },
    );

    test(
      'persistent + OBX_MEMORY_EXCLUSIVE=true is unaffected (unchanged '
      'pre-existing behavior)',
      () {
        final config = MemoryConfig.fromEnvironment(
          env: _env(storeMode: 'persistent', exclusive: 'true'),
        );
        expect(config.storeMode, StoreMode.persistent);
        expect(config.exclusive, isTrue);
      },
    );

    test('an invalid OBX_MEMORY_STORE_MODE value propagates ArgumentError', () {
      expect(
        () => MemoryConfig.fromEnvironment(env: _env(storeMode: 'bogus')),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('openMemoryStore permissions (M-2, 2026-09-07 security review)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('remembox_perms_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test(
      'a freshly created store directory is 0700 and its data files are '
      '0600 (world-readable by default umask otherwise)',
      () {
        // A not-yet-existing subdirectory — openMemoryStore must be the one
        // to create it, exercising the "just created" chmod path (not an
        // already-tightened directory from a prior open).
        final storeDir = '${tempDir.path}/fresh-store';
        final store = openMemoryStore(storeDir, log: (_) {});
        addTearDown(store.close);

        int modeOf(String path) => FileStat.statSync(path).mode & 0x1FF;
        expect(
          modeOf(storeDir).toRadixString(8),
          '700',
          reason: 'the store directory must not be group/other readable',
        );
        expect(
          modeOf('$storeDir/data.mdb').toRadixString(8),
          '600',
          reason: 'data.mdb holds the entire memory corpus',
        );
        expect(modeOf('$storeDir/lock.mdb').toRadixString(8), '600');
      },
      skip: Platform.isWindows ? 'POSIX chmod semantics only' : false,
    );

    test(
      'a pre-existing store directory/files loosened after creation '
      '(upgrade-path follow-up, M-2, 2026-09-07 re-verification) are '
      'tightened on the NEXT open, with a log line naming the previous '
      'mode',
      () {
        final storeDir = '${tempDir.path}/upgraded-store';
        // Create a real store first, then close it — this is standing in
        // for a store from BEFORE this project chmod'd on creation (or
        // any other means by which a store directory ends up loose); what
        // matters is that openMemoryStore did NOT just create these paths
        // this call.
        final firstOpen = openMemoryStore(storeDir, log: (_) {});
        firstOpen.close();

        Process.runSync('chmod', ['755', storeDir]);
        Process.runSync('chmod', ['644', '$storeDir/data.mdb']);
        Process.runSync('chmod', ['644', '$storeDir/lock.mdb']);

        int modeOf(String path) => FileStat.statSync(path).mode & 0x1FF;
        expect(modeOf(storeDir).toRadixString(8), '755');
        expect(modeOf('$storeDir/data.mdb').toRadixString(8), '644');
        expect(modeOf('$storeDir/lock.mdb').toRadixString(8), '644');

        final logLines = <String>[];
        final store = openMemoryStore(storeDir, log: logLines.add);
        addTearDown(store.close);

        expect(
          modeOf(storeDir).toRadixString(8),
          '700',
          reason:
              'a pre-existing loose store directory must be tightened on '
              'the next open, not left as-is',
        );
        expect(modeOf('$storeDir/data.mdb').toRadixString(8), '600');
        expect(modeOf('$storeDir/lock.mdb').toRadixString(8), '600');

        expect(
          logLines.any(
            (l) =>
                l.contains('[perms] tightening pre-existing') &&
                l.contains(storeDir) &&
                l.contains('0755') &&
                l.contains('700'),
          ),
          isTrue,
          reason:
              'must log the pre-existing-loose remediation for the '
              'directory: $logLines',
        );
        expect(
          logLines.any(
            (l) =>
                l.contains('[perms] tightening pre-existing') &&
                l.contains('data.mdb') &&
                l.contains('0644') &&
                l.contains('600'),
          ),
          isTrue,
          reason:
              'must log the pre-existing-loose remediation for data.mdb: '
              '$logLines',
        );
      },
      skip: Platform.isWindows ? 'POSIX chmod semantics only' : false,
    );
  });

  group('warnIfSyncInsecure (L-2, 2026-09-07 security review)', () {
    // Calls the pure log-only function directly with a FAKE syncUrl/
    // credentials pair — no [Store]/[SyncClient] is constructed and no
    // network connection is attempted (see warnIfSyncInsecure's own doc for
    // why it is a standalone testable function).
    late List<String> logLines;
    void capture(String line) => logLines.add(line);

    setUp(() {
      logLines = [];
    });

    test('plaintext ws:// to a non-loopback host warns', () {
      warnIfSyncInsecure('ws://example.com:9997', 'shared-secret', capture);
      final combined = logLines.join('\n');
      expect(
        combined,
        allOf(
          contains('WARN'),
          contains('plaintext ws://'),
          contains('example.com'),
        ),
      );
    });

    test(
      'ws:// to localhost does NOT warn about plaintext (loopback is the '
      'documented same-machine trust model)',
      () {
        warnIfSyncInsecure('ws://localhost:9997', 'shared-secret', capture);
        expect(
          logLines.where((l) => l.contains('plaintext ws://')),
          isEmpty,
        );
      },
    );

    test('empty credentials warns regardless of host', () {
      warnIfSyncInsecure('ws://localhost:9997', '', capture);
      expect(
        logLines.join('\n'),
        allOf(contains('WARN'), contains('OBX_MEMORY_SYNC_CREDENTIALS')),
      );
    });

    test(
      'wss:// (TLS) to a non-loopback host WITH credentials warns about '
      'neither condition',
      () {
        warnIfSyncInsecure('wss://example.com:9997', 'shared-secret', capture);
        expect(logLines, isEmpty);
      },
    );

    test(
      'plaintext ws:// to a non-loopback host with NO credentials warns '
      'about both conditions',
      () {
        warnIfSyncInsecure('ws://example.com:9997', '', capture);
        expect(logLines, hasLength(2));
        expect(logLines[0], contains('AND the (absent) credentials'));
      },
    );
  });

  group('warnIfOllamaRemote (S3, 2026-09-08 pre-publication audit)', () {
    // Same pattern as warnIfSyncInsecure above: calls the pure log-only
    // function directly with a FAKE ollamaUrl — no [OllamaEmbedder] is
    // constructed and no network connection is attempted.
    late List<String> logLines;
    void capture(String line) => logLines.add(line);

    setUp(() {
      logLines = [];
    });

    test('http:// to localhost does NOT warn (loopback is the default)', () {
      warnIfOllamaRemote('http://localhost:11434', capture);
      expect(logLines, isEmpty);
    });

    test('http:// to 127.0.0.1 does NOT warn', () {
      warnIfOllamaRemote('http://127.0.0.1:11434', capture);
      expect(logLines, isEmpty);
    });

    test(
      'http:// to a non-loopback host warns about both the export and '
      'the plaintext transport',
      () {
        warnIfOllamaRemote('http://example.com:11434', capture);
        expect(logLines, hasLength(2));
        expect(
          logLines[0],
          allOf(
            contains('WARN'),
            contains('non-loopback host'),
            contains('memory text and queries are sent to this URL'),
          ),
        );
        expect(
          logLines[1],
          allOf(contains('WARN'), contains('plaintext http://')),
        );
      },
    );

    test(
      'https:// (TLS) to a non-loopback host still warns about the '
      'export — but not about plaintext',
      () {
        warnIfOllamaRemote('https://example.com:11434', capture);
        expect(logLines, hasLength(1));
        expect(
          logLines[0],
          allOf(
            contains('WARN'),
            contains('memory text and queries are sent to this URL'),
          ),
        );
        expect(logLines.where((l) => l.contains('plaintext')), isEmpty);
      },
    );
  });
}
