// Acceptance driver for a built release: talks to the SHIPPED launcher
// (`<zip>/remembox/dist/remembox`) over stdio exactly like an MCP client
// does – spawn, `initialize`, `tools/list`, `tools/call` – and checks what
// comes back. Started by tool/release_acceptance.sh, which unpacks the
// zip(s) and passes the launcher paths; see that script's header for the
// user-facing description and tool/release.sh for where it gates a release.
//
// Two scenarios:
//
//   A. Fresh install – the new launcher on an empty store directory.
//   B. Upgrade – the PREVIOUS release's launcher creates a store and writes
//      entries with legacy tag spellings, then the new launcher opens the
//      same directory. Finally the previous launcher is pointed at the
//      upgraded store again (it must refuse it, or – when the schema did
//      not change between the two releases – still open it; which of the
//      two is expected is an explicit argument, never inferred).
//
// Deliberately dependency-free (dart:io / dart:convert / dart:async only):
// it runs as `dart tool/release_acceptance.dart …` without `dart pub get`,
// and it speaks raw newline-delimited JSON-RPC instead of going through an
// MCP client library – a client library validates arguments on ITS side
// (see the comment on `required:` in lib/src/server.dart's remember tool),
// which would hide exactly the server-side rejections checked here.
//
// Reporting rule: every check prints one line – PASS, FAIL, NOT RUN (an
// earlier check of the same scenario failed, so its precondition is gone)
// or SKIP (scenario not requested). Nothing is dropped silently, and any
// FAIL / NOT RUN makes the process exit 1.
//
// All test data is synthetic (`acme-app`, `garden`, `home`, `work`,
// `Flat B`, `alice`).
//
// Needs a local Ollama with the default embedding model – a fresh install
// embeds through it. Not reachable / model missing is a failure with a
// clear message, never a skip.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What a fresh install uses when nothing is configured (see
/// docs/configuration.md: `OBX_MEMORY_OLLAMA_URL`, `OBX_MEMORY_EMBED_MODEL`).
/// Inherited `OBX_*` variables are removed for the servers under test; only
/// `OBX_MEMORY_DIR` and `OBX_MEMORY_AUTO_PULL` are set explicitly. The
/// precondition check therefore has to look at exactly these defaults.
const _ollamaUrl = 'http://localhost:11434';
const _embedModel = 'embeddinggemma';

/// Generous on purpose: the first embedding after an idle period makes
/// Ollama load the model, which can take a while on a cold machine.
const _requestTimeout = Duration(seconds: 120);
const _exitTimeout = Duration(seconds: 30);

const _usage = '''
Usage: dart tool/release_acceptance.dart --preflight
         (only checks that Ollama and the embedding model are available)
   or: dart tool/release_acceptance.dart
         --new-launcher <path to the new release's dist/remembox>
         --server-source <path to lib/src/server.dart>
         --expect-version <version the new launcher must report>
         --work-dir <empty scratch directory>
         [--previous-launcher <path to the previous release's dist/remembox>]
         [--downgrade refused|opens]   (default: refused)
''';

/// A check that did not hold. Carries a complete, self-explanatory message
/// – it is printed as the FAIL line's reason.
final class CheckFailure implements Exception {
  final String message;
  CheckFailure(this.message);

  @override
  String toString() => message;
}

void _expect(bool condition, String message) {
  if (!condition) throw CheckFailure(message);
}

/// Canonical JSON with map keys sorted recursively – so two maps compare
/// equal regardless of key order, and an integral double (`950.0`) equals
/// the same integer (`950`).
String _canonical(Object? value) {
  Object? normalize(Object? v) {
    if (v is Map) {
      final keys = [for (final k in v.keys) k as String]..sort();
      return {for (final k in keys) k: normalize(v[k])};
    }
    if (v is Iterable) return [for (final e in v) normalize(e)];
    if (v is double && v == v.truncateToDouble() && v.isFinite) {
      return v.toInt();
    }
    return v;
  }

  return jsonEncode(normalize(value));
}

void _expectEquals(Object? actual, Object? expected, String what) {
  _expect(
    _canonical(actual) == _canonical(expected),
    '$what: expected ${_canonical(expected)}, got ${_canonical(actual)}',
  );
}

/// Reads a dotted path (`index.byStatus.ok`) out of a decoded JSON object.
/// A missing segment is a failure, not a null – a renamed response key
/// must not read as "0 == 0".
Object? _at(Map<String, Object?> json, String path) {
  Object? current = json;
  for (final key in path.split('.')) {
    if (current is! Map || !current.containsKey(key)) {
      throw CheckFailure(
        'response has no "$path" (missing at "$key"): ${_canonical(json)}',
      );
    }
    current = current[key];
  }
  return current;
}

List<Map<String, Object?>> _objects(Object? value, String what) {
  if (value is! List) {
    throw CheckFailure('$what: expected a list, got ${_canonical(value)}');
  }
  return [for (final e in value) (e as Map).cast<String, Object?>()];
}

List<String> _sortedStrings(Object? value, String what) {
  if (value is! List) {
    throw CheckFailure('$what: expected a list, got ${_canonical(value)}');
  }
  return [for (final e in value) e as String]..sort();
}

/// One `tools/call` answer: the decoded JSON payload from the text content
/// plus the MCP-level `isError` flag.
final class ToolOutcome {
  final String tool;
  final bool isError;
  final Map<String, Object?> payload;

  ToolOutcome(this.tool, this.isError, this.payload);

  /// The payload of a call that must have succeeded.
  Map<String, Object?> get ok {
    _expect(
      !isError,
      '$tool was expected to succeed but returned an error: '
      '${_canonical(payload)}',
    );
    return payload;
  }

  /// Asserts a server-side rejection (`invalid_input`) whose message
  /// mentions [messagePart].
  void expectRejected(String messagePart) {
    _expect(
      isError,
      '$tool was expected to be rejected but succeeded: '
      '${_canonical(payload)}',
    );
    _expectEquals(payload['error'], 'invalid_input', '$tool error code');
    final message = payload['message'];
    _expect(
      message is String && message.contains(messagePart),
      '$tool rejection message should mention "$messagePart", got: $message',
    );
  }
}

final class _Pending {
  final String method;
  final Completer<Map<String, Object?>> completer;
  _Pending(this.method, this.completer);
}

/// One server process plus the JSON-RPC conversation with it.
final class McpSession {
  final String label;

  /// True for the release under test: every stdout line must be a JSON-RPC
  /// message (stdout belongs to the protocol – a stray native log line
  /// there corrupts the channel for a real client). False for the previous
  /// release's launcher, which is not what is being accepted here; stray
  /// lines are still collected in [stdoutNoise] so the caller can report
  /// them.
  final bool strictStdout;

  final Process _process;
  final _pending = <int, _Pending>{};
  final _stderr = <String>[];
  final stdoutNoise = <String>[];
  late final Future<int> _exited;
  int? _exitCode;
  Object? _stdinError;
  int _nextId = 0;

  McpSession._(this.label, this._process, this.strictStdout) {
    final stdoutDone = _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onStdoutLine)
        .asFuture<void>();
    final stderrDone = _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_stderr.add)
        .asFuture<void>();
    // A write to a process that already exited surfaces here (broken
    // pipe). Kept, not dropped: it is quoted when the pending request is
    // failed below.
    unawaited(
      _process.stdin.done.then<void>(
        (_) {},
        onError: (Object err) {
          _stdinError = err;
        },
      ),
    );
    _exited = () async {
      final code = await _process.exitCode;
      // Drain both pipes first, so everything the process still wrote is
      // visible to whoever inspects the session after it exited.
      await stdoutDone;
      await stderrDone;
      _exitCode = code;
      for (final pending in _pending.values) {
        pending.completer.completeError(
          CheckFailure(
            '$label: the server exited with code $code before answering '
            '${pending.method}'
            '${_stdinError == null ? '' : ' (stdin: $_stdinError)'}',
          ),
        );
      }
      _pending.clear();
      return code;
    }();
  }

  /// Starts [launcher] the way an MCP client does: from a foreign working
  /// directory, with nothing but the store directory configured. Every
  /// inherited `OBX_*` variable is removed so a developer's own shell
  /// settings (a sync URL, a forced store mode, a log level) cannot change
  /// what is being accepted – the launcher's own defaults are part of the
  /// shipped artifact.
  static Future<McpSession> start({
    required String label,
    required String launcher,
    required String storeDir,
    required String cwd,
    required bool strictStdout,
  }) async {
    final environment = <String, String>{
      for (final entry in Platform.environment.entries)
        if (!entry.key.startsWith('OBX_')) entry.key: entry.value,
      'OBX_MEMORY_DIR': storeDir,
      'OBX_MEMORY_AUTO_PULL': 'false',
    };
    final process = await Process.start(
      launcher,
      const [],
      workingDirectory: cwd,
      environment: environment,
      includeParentEnvironment: false,
    );
    return McpSession._(label, process, strictStdout);
  }

  void _onStdoutLine(String line) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map<String, Object?>) {
      stdoutNoise.add(line);
      return;
    }
    final id = decoded['id'];
    if (decoded.containsKey('method')) {
      // A request or notification FROM the server. Nothing in this
      // conversation needs one; a request is answered with a proper
      // JSON-RPC error instead of being left hanging.
      if (id != null) {
        _send({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'not supported by this client'},
        });
      }
      return;
    }
    final pending = id is int ? _pending.remove(id) : null;
    if (pending == null) {
      stdoutNoise.add(line);
      return;
    }
    pending.completer.complete(decoded);
  }

  void _send(Map<String, Object?> message) {
    _process.stdin.writeln(jsonEncode(message));
  }

  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (_exitCode != null) {
      throw CheckFailure(
        '$label: cannot send $method – the server already exited with code '
        '$_exitCode',
      );
    }
    _expectCleanStdout();
    final id = ++_nextId;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = _Pending(method, completer);
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    final response = await completer.future.timeout(
      _requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw CheckFailure(
          '$label: no answer to $method within '
          '${_requestTimeout.inSeconds}s',
        );
      },
    );
    _expectCleanStdout();
    if (response['error'] != null) {
      throw CheckFailure(
        '$label: $method answered with a JSON-RPC error: '
        '${_canonical(response['error'])}',
      );
    }
    final result = response['result'];
    if (result is! Map<String, Object?>) {
      throw CheckFailure(
        '$label: $method answered without a result object: '
        '${_canonical(response)}',
      );
    }
    return result;
  }

  void _expectCleanStdout() {
    if (strictStdout && stdoutNoise.isNotEmpty) {
      throw CheckFailure(
        '$label: stdout carried ${stdoutNoise.length} line(s) that are not '
        'JSON-RPC answers – stdout belongs to the MCP protocol. First: '
        '${stdoutNoise.first}',
      );
    }
  }

  /// The MCP handshake. Returns the `initialize` result (`serverInfo` …).
  Future<Map<String, Object?>> initialize() async {
    final result = await request('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'release-acceptance', 'version': '0'},
    });
    _send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    return result;
  }

  /// Every tool name the server lists, following `nextCursor` pages.
  Future<List<String>> listToolNames() async {
    final names = <String>[];
    String? cursor;
    do {
      final page = await request('tools/list', {'cursor': ?cursor});
      for (final tool in _objects(page['tools'], 'tools/list "tools"')) {
        names.add(tool['name'] as String);
      }
      cursor = page['nextCursor'] as String?;
    } while (cursor != null);
    return names;
  }

  Future<ToolOutcome> call(
    String tool, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final result = await request('tools/call', {
      'name': tool,
      'arguments': arguments,
    });
    final content = result['content'];
    final first = content is List && content.isNotEmpty ? content.first : null;
    final text = first is Map ? first['text'] : null;
    Object? payload;
    if (text is String) {
      try {
        payload = jsonDecode(text);
      } on FormatException {
        payload = null;
      }
    }
    if (payload is! Map<String, Object?>) {
      throw CheckFailure(
        '$label: $tool did not answer with a JSON object as text content: '
        '${_canonical(result)}',
      );
    }
    return ToolOutcome(tool, result['isError'] == true, payload);
  }

  /// Closes stdin – how an MCP client ends a stdio session – and returns
  /// the exit code. A server that does not exit is killed and reported.
  Future<int> close() async {
    if (_exitCode == null) {
      try {
        await _process.stdin.close();
      } catch (err) {
        // The process went away between the check above and the close
        // (broken pipe). Kept for the message of whatever fails next; the
        // exit code is still what the caller asserts on.
        _stdinError = err;
      }
    }
    return waitForExit();
  }

  Future<int> waitForExit() => _exited.timeout(
    _exitTimeout,
    onTimeout: () {
      _process.kill(ProcessSignal.sigkill);
      throw CheckFailure(
        '$label: the server did not exit within ${_exitTimeout.inSeconds}s '
        '– killed',
      );
    },
  );

  /// Asserts the orderly end of a session: exit code 0 after stdin closed,
  /// and (for the release under test) nothing but JSON-RPC on stdout.
  Future<void> closeCleanly() async {
    final code = await close();
    _expectEquals(code, 0, '$label exit code after stdin closed');
    _expectCleanStdout();
  }

  bool get running => _exitCode == null;

  void kill() => _process.kill(ProcessSignal.sigkill);

  String get stderrText => _stderr.join('\n');

  String stderrTail([int lines = 15]) {
    final from = _stderr.length > lines ? _stderr.length - lines : 0;
    return _stderr.sublist(from).join('\n');
  }
}

/// Collects one line per check and prints it as it happens.
final class Report {
  int passed = 0;
  int failed = 0;
  int notRun = 0;
  final skipped = <String>[];

  void pass(String name) {
    passed++;
    stdout.writeln('PASS: $name');
  }

  void fail(String name, String reason) {
    failed++;
    stdout.writeln('FAIL: $name – $reason');
  }

  void notRunBecause(String name, String failedCheck) {
    notRun++;
    stdout.writeln('NOT RUN: $name – depends on the failed "$failedCheck"');
  }

  void skip(String name, String reason) {
    skipped.add(name);
    stdout.writeln('SKIP: $name – $reason');
  }

  bool get ok => failed == 0 && notRun == 0;
}

/// An ordered list of named checks that build on one another (same store,
/// same server session). The first failing check aborts the scenario: the
/// later ones would only fail for the same reason, so they are reported as
/// NOT RUN by name instead of producing a cascade – or worse, vanishing.
final class Scenario {
  final String label;
  final Report report;
  final _steps = <(String, Future<void> Function())>[];
  final sessions = <McpSession>[];

  Scenario(this.label, this.report);

  void check(String name, Future<void> Function() body) {
    _steps.add((name, body));
  }

  Future<void> run() async {
    stdout.writeln('== $label');
    String? failedCheck;
    for (final (name, body) in _steps) {
      final title = '$label: $name';
      if (failedCheck != null) {
        report.notRunBecause(title, failedCheck);
        continue;
      }
      try {
        await body();
        report.pass(title);
      } on CheckFailure catch (failure) {
        failedCheck = name;
        report.fail(title, failure.message);
      } catch (err, stack) {
        failedCheck = name;
        report.fail(title, 'unexpected ${err.runtimeType}: $err\n$stack');
      }
    }
    if (failedCheck != null && sessions.isNotEmpty) {
      // The most recently started server is the one the failed check was
      // talking to.
      final session = sessions.last;
      stdout.writeln('   ${session.label} stderr (last lines):');
      for (final line in session.stderrTail().split('\n')) {
        final shown = line.length > 300 ? '${line.substring(0, 300)}…' : line;
        stdout.writeln('     $shown');
      }
    }
    for (final session in sessions) {
      if (session.running) {
        // Only reachable after a failed check (every scenario's own last
        // checks close its sessions) – never leave a server behind.
        session.kill();
        stdout.writeln('   ${session.label}: still running – killed');
      }
    }
  }
}

final class Options {
  final String newLauncher;
  final String? previousLauncher;
  final String serverSource;
  final String expectVersion;
  final String workDir;
  final bool downgradeRefused;

  Options._({
    required this.newLauncher,
    required this.previousLauncher,
    required this.serverSource,
    required this.expectVersion,
    required this.workDir,
    required this.downgradeRefused,
  });

  static Options parse(List<String> argv) {
    const known = {
      '--new-launcher',
      '--previous-launcher',
      '--server-source',
      '--expect-version',
      '--work-dir',
      '--downgrade',
    };
    final values = <String, String>{};
    for (var i = 0; i < argv.length; i += 2) {
      final key = argv[i];
      if (!known.contains(key)) {
        throw FormatException('unknown argument "$key"');
      }
      if (i + 1 >= argv.length || argv[i + 1].isEmpty) {
        throw FormatException('$key needs a value');
      }
      values[key] = argv[i + 1];
    }
    String required(String key) =>
        values[key] ?? (throw FormatException('$key is required'));
    final downgrade = values['--downgrade'] ?? 'refused';
    if (downgrade != 'refused' && downgrade != 'opens') {
      throw FormatException(
        '--downgrade must be "refused" or "opens", got "$downgrade"',
      );
    }
    return Options._(
      newLauncher: required('--new-launcher'),
      previousLauncher: values['--previous-launcher'],
      serverSource: required('--server-source'),
      expectVersion: required('--expect-version'),
      workDir: required('--work-dir'),
      downgradeRefused: downgrade == 'refused',
    );
  }
}

/// The tool names registered in lib/src/server.dart – the expected answer
/// to `tools/list`, derived from the source so a newly added tool never
/// needs a second edit here. Same extraction as test/skill_doc_test.dart
/// (every tool is declared as `Tool(name: '…', …)`), with the same
/// cross-check against the number of `registerTool(` calls, so a
/// declaration the pattern cannot see is an error instead of a silently
/// shorter expected list.
List<String> _registeredToolNames(String serverSourcePath) {
  final file = File(serverSourcePath);
  if (!file.existsSync()) {
    throw CheckFailure('no server source at $serverSourcePath');
  }
  final source = file.readAsStringSync();
  final names = [
    for (final match in RegExp(
      r"""\bname:\s*'([a-zA-Z0-9_]+)'""",
    ).allMatches(source))
      match.group(1)!,
  ];
  final registerCalls = RegExp(r'registerTool\(').allMatches(source).length;
  if (names.isEmpty || names.length != registerCalls) {
    throw CheckFailure(
      '$serverSourcePath has $registerCalls registerTool( call(s) but '
      "${names.length} name: '…' literal(s) – the expected tool list "
      'cannot be derived. Update the extraction here and in '
      'test/skill_doc_test.dart together.',
    );
  }
  return names;
}

/// Fails unless the default Ollama is reachable and has the default
/// embedding model. Checked up front so the reason is stated once, clearly,
/// instead of surfacing as an `embedding_failed` in the middle of a run.
Future<void> _requireOllama() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(Uri.parse('$_ollamaUrl/api/tags'));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await utf8.decodeStream(response);
    if (response.statusCode != 200) {
      throw CheckFailure(
        'Ollama at $_ollamaUrl answered /api/tags with HTTP '
        '${response.statusCode}.',
      );
    }
    final models = [
      for (final model in _objects(
        (jsonDecode(body) as Map<String, Object?>)['models'],
        'Ollama /api/tags "models"',
      ))
        model['name'] as String,
    ];
    final present = models.any(
      (name) => name == _embedModel || name.startsWith('$_embedModel:'),
    );
    if (!present) {
      throw CheckFailure(
        'Ollama at $_ollamaUrl does not have the "$_embedModel" model '
        '(installed: ${models.join(', ')}). Run `ollama pull $_embedModel`.',
      );
    }
  } on CheckFailure {
    rethrow;
  } catch (err) {
    throw CheckFailure(
      'cannot reach Ollama at $_ollamaUrl ($err). The acceptance test '
      'stores and recalls real entries, which needs a local Ollama with '
      'the "$_embedModel" model – start it (`ollama serve` or the Ollama '
      'app) and run `ollama pull $_embedModel`.',
    );
  } finally {
    client.close(force: true);
  }
}

/// The part of `stats` every consistent store has in common: each entry
/// has exactly one healthy index row and nothing dangles.
void _expectHealthyStats(Map<String, Object?> stats, {required int entries}) {
  _expectEquals(_at(stats, 'store.entries'), entries, 'stats store.entries');
  _expectEquals(_at(stats, 'index.rows'), entries, 'stats index.rows');
  _expectEquals(_at(stats, 'index.byStatus.ok'), entries, 'stats index ok');
  _expectEquals(_at(stats, 'index.byStatus.stale'), 0, 'stats index stale');
  _expectEquals(_at(stats, 'index.byStatus.failed'), 0, 'stats index failed');
  _expectEquals(
    _at(stats, 'index.entriesWithoutIndex'),
    0,
    'stats index.entriesWithoutIndex',
  );
  _expectEquals(_at(stats, 'index.orphanedRows'), 0, 'stats orphanedRows');
  _expectEquals(_at(stats, 'orphanedTags'), 0, 'stats orphanedTags');
  _expectEquals(
    _at(stats, 'danglingMemoryLinks'),
    0,
    'stats danglingMemoryLinks',
  );
}

/// `tags_list` as a name -> live count map.
Future<Map<String, Object?>> _tagCounts(McpSession session) async {
  final listing = (await session.call('tags_list')).ok;
  return {
    for (final tag in _objects(listing['tags'], 'tags_list "tags"'))
      tag['name'] as String: tag['count'],
  };
}

List<Object?> _hitIds(Map<String, Object?> recall) {
  // The response key is "hits" – _at fails loudly if that ever changes.
  return [
    for (final hit in _objects(_at(recall, 'hits'), 'recall "hits"')) hit['id'],
  ];
}

// ---------------------------------------------------------------------------
// A. Fresh install
// ---------------------------------------------------------------------------

Scenario _freshInstall({
  required Report report,
  required Options options,
  required List<String> expectedTools,
  required String storeDir,
  required String cwd,
}) {
  final scenario = Scenario('A fresh install', report);
  late McpSession server;
  late int acmeEntryId;
  late int gardenEntryId;
  late int firstRentId;
  late int secondRentId;

  Future<McpSession> start(String label) async {
    final session = await McpSession.start(
      label: label,
      launcher: options.newLauncher,
      storeDir: storeDir,
      cwd: cwd,
      strictStdout: true,
    );
    scenario.sessions.add(session);
    return session;
  }

  scenario.check(
    'initialize reports remembox ${options.expectVersion}',
    () async {
      server = await start('new launcher (fresh store)');
      final init = await server.initialize();
      _expectEquals(
        _at(init, 'serverInfo.name'),
        'remembox',
        'serverInfo.name',
      );
      _expectEquals(
        _at(init, 'serverInfo.version'),
        options.expectVersion,
        'serverInfo.version',
      );
    },
  );

  scenario.check('tools/list returns exactly the ${expectedTools.length} tools '
      'registered in lib/src/server.dart', () async {
    final listed = await server.listToolNames();
    final missing = expectedTools.toSet().difference(listed.toSet());
    final unexpected = listed.toSet().difference(expectedTools.toSet());
    _expect(
      missing.isEmpty && unexpected.isEmpty,
      'tools/list differs from lib/src/server.dart – missing: '
      '${missing.toList()..sort()}, unexpected: '
      '${unexpected.toList()..sort()}',
    );
    _expectEquals(
      listed.length,
      expectedTools.length,
      'number of listed tools (duplicates?)',
    );
  });

  scenario.check('stats on the empty store', () async {
    final stats = (await server.call('stats')).ok;
    _expectHealthyStats(stats, entries: 0);
    _expectEquals(_at(stats, 'store.tags'), 0, 'stats store.tags');
    _expectEquals(_at(stats, 'registry.projects'), 0, 'stats projects');
    _expectEquals(_at(stats, 'registry.areas'), 0, 'stats areas');
    _expectEquals(_at(stats, 'facts.total'), 0, 'stats facts.total');
    _expectEquals(_at(stats, 'embedding.model'), _embedModel, 'embed model');
  });

  scenario.check(
    'remember normalises tags and drops the tag equal to the project, '
    'with a warning',
    () async {
      final stored = (await server.call('remember', {
        'text':
            'The acme-app build uploads nightly artifacts to a staging '
            'bucket.',
        'project': 'acme-app',
        'tags': ['build-notes', 'acme-app', 'alice'],
      })).ok;
      _expectEquals(stored['duplicate'], false, 'remember duplicate');
      _expectEquals(stored['indexed'], true, 'remember indexed');
      acmeEntryId = stored['id'] as int;
      final warning = stored['warning'];
      _expect(
        warning is String &&
            warning.contains('"build-notes" stored as "buildNotes"') &&
            warning.contains('dropped') &&
            warning.contains('project name'),
        'remember should warn that "build-notes" was stored as '
        '"buildNotes" and that the tag equal to the project was dropped, '
        'got warning: $warning',
      );
      final entry = (await server.call('get', {'id': acmeEntryId})).ok;
      _expectEquals(entry['project'], 'acme-app', 'stored project');
      _expectEquals(_sortedStrings(entry['tags'], 'stored tags'), [
        'alice',
        'buildNotes',
      ], 'stored tags');
    },
  );

  scenario.check('remember without project is rejected', () async {
    (await server.call('remember', {
      'text': 'An entry without a project must never be stored.',
    })).expectRejected('project is required');
  });

  scenario.check('recall returns the entry under "hits"', () async {
    gardenEntryId =
        (await server.call('remember', {
              'text':
                  'Tomatoes in the garden need watering every second day '
                  'in summer.',
              'project': 'garden',
              'tags': ['alice'],
            })).ok['id']
            as int;
    final recall = (await server.call('recall', {
      'query': 'where do the nightly build artifacts go',
      'project': 'acme-app',
    })).ok;
    final hits = _objects(_at(recall, 'hits'), 'recall "hits"');
    _expectEquals(_hitIds(recall), [acmeEntryId], 'recall hit ids');
    _expectEquals(hits.single['project'], 'acme-app', 'hit project');
    _expectEquals(hits.single['embedModel'], _embedModel, 'hit embedModel');
  });

  scenario.check('area_set creates the areas work and home', () async {
    for (final area in ['work', 'home']) {
      final result = (await server.call('area_set', {'name': area})).ok;
      _expectEquals(result['action'], 'created', 'area_set "$area" action');
    }
  });

  scenario.check('project_set assigns projects to areas', () async {
    for (final (project, area) in [('acme-app', 'work'), ('garden', 'home')]) {
      final result = (await server.call('project_set', {
        'name': project,
        'addAreas': [area],
      })).ok;
      _expectEquals(result['areas'], [area], 'project_set "$project" areas');
    }
  });

  scenario.check('project_set rejects an unknown area', () async {
    (await server.call('project_set', {
      'name': 'garden',
      'addAreas': ['nowhere'],
    })).expectRejected('unknown area');
  });

  scenario.check('recall with an area filter', () async {
    for (final (area, entryId) in [
      ('home', gardenEntryId),
      ('work', acmeEntryId),
    ]) {
      final recall = (await server.call('recall', {
        'query': 'watering the tomatoes',
        'area': area,
      })).ok;
      _expectEquals(_hitIds(recall), [entryId], 'recall area="$area" hits');
    }
  });

  scenario.check(
    'fact_set twice for one key closes the first value and keeps it as '
    'history',
    () async {
      final first = (await server.call('fact_set', {
        'project': 'garden',
        'subject': 'Flat B',
        'attribute': 'rent',
        'valueNumber': 900,
        'unit': 'EUR',
        'validFrom': '2025-01-01',
      })).ok;
      _expectEquals(first['action'], 'created', 'first fact_set action');
      firstRentId = first['id'] as int;
      final second = (await server.call('fact_set', {
        'project': 'garden',
        'subject': 'Flat B',
        'attribute': 'rent',
        'valueNumber': 950,
        'unit': 'EUR',
        'validFrom': '2026-01-01',
      })).ok;
      _expectEquals(second['action'], 'replaced', 'second fact_set action');
      _expectEquals(
        second['closedId'],
        firstRentId,
        'second fact_set closedId',
      );
      secondRentId = second['id'] as int;
    },
  );

  scenario.check(
    'fact_get returns the current value, and the old one with "at"',
    () async {
      final current = _objects(
        (await server.call('fact_get', {
          'subject': 'Flat B',
          'attribute': 'rent',
        })).ok['facts'],
        'fact_get "facts"',
      );
      _expectEquals(current.single['id'], secondRentId, 'current fact id');
      _expectEquals(current.single['value'], 950, 'current fact value');
      _expectEquals(current.single['current'], true, 'current fact "current"');
      final past = _objects(
        (await server.call('fact_get', {
          'subject': 'Flat B',
          'attribute': 'rent',
          'at': '2025-06-01',
        })).ok['facts'],
        'fact_get at "facts"',
      );
      _expectEquals(past.single['id'], firstRentId, 'fact id as of 2025-06-01');
      _expectEquals(past.single['value'], 900, 'fact value as of 2025-06-01');
      _expectEquals(
        past.single['validUntil'],
        '2026-01-01T00:00:00.000Z',
        'closed fact validUntil',
      );
    },
  );

  scenario.check(
    'fact_query with area, with and without includeHistory',
    () async {
      final history = (await server.call('fact_query', {
        'area': 'home',
        'includeHistory': true,
      })).ok;
      _expectEquals(
        [
          for (final fact in _objects(history['facts'], 'fact_query "facts"'))
            fact['id'],
        ]..sort(),
        [firstRentId, secondRentId]..sort(),
        'fact_query area=home includeHistory ids',
      );
      final currentOnly = (await server.call('fact_query', {
        'area': 'home',
      })).ok;
      _expectEquals(
        [
          for (final fact in _objects(
            currentOnly['facts'],
            'fact_query "facts"',
          ))
            fact['id'],
        ],
        [secondRentId],
        'fact_query area=home ids',
      );
      final otherArea = (await server.call('fact_query', {'area': 'work'})).ok;
      _expectEquals(otherArea['facts'], <Object?>[], 'fact_query area=work');
    },
  );

  scenario.check('fact_query without any filter is rejected', () async {
    (await server.call('fact_query')).expectRejected('requires at least one');
  });

  scenario.check(
    'tags_list shows the normalised tags with their counts',
    () async {
      _expectEquals(await _tagCounts(server), {
        'alice': 2,
        'buildNotes': 1,
      }, 'tags_list');
    },
  );

  scenario.check('the server exits cleanly when stdin closes', () async {
    await server.closeCleanly();
  });

  scenario.check(
    'a restarted server reports consistent stats (entries, index, facts)',
    () async {
      server = await start('new launcher (fresh store, restarted)');
      await server.initialize();
      final stats = (await server.call('stats')).ok;
      _expectHealthyStats(stats, entries: 2);
      _expectEquals(_at(stats, 'store.tags'), 2, 'stats store.tags');
      _expectEquals(_at(stats, 'byProject'), {
        'acme-app': 1,
        'garden': 1,
      }, 'stats byProject');
      _expectEquals(_at(stats, 'byArea'), {
        'work': 1,
        'home': 1,
      }, 'stats byArea');
      _expectEquals(_at(stats, 'registry.projects'), 2, 'stats projects');
      _expectEquals(_at(stats, 'registry.areas'), 2, 'stats areas');
      _expectEquals(
        _at(stats, 'registry.unregisteredProjects'),
        0,
        'stats unregisteredProjects',
      );
      _expectEquals(_at(stats, 'facts.total'), 2, 'stats facts.total');
      _expectEquals(_at(stats, 'facts.current'), 1, 'stats facts.current');
      _expectEquals(
        _at(stats, 'facts.conflictingKeys'),
        0,
        'stats facts.conflictingKeys',
      );
      await server.closeCleanly();
    },
  );

  return scenario;
}

// ---------------------------------------------------------------------------
// B. Upgrade from the previous release
// ---------------------------------------------------------------------------

/// What the legacy spellings written in scenario B fold into. A previous
/// release that already normalises on write stores exactly these.
const _normalisedTagCounts = {'buildNotes': 3, 'alice': 2, 'plantCare': 1};

/// The refusal documented in CHANGELOG.md's 0.3.0 upgrade note.
final _refusalMessage = RegExp(
  r"DB's last entity ID (\d+) is higher than (\d+) from model",
);

Scenario _upgrade({
  required Report report,
  required Options options,
  required String previousLauncher,
  required String storeDir,
  required String cwd,
}) {
  final scenario = Scenario('B upgrade from the previous release', report);
  late McpSession previous;
  late McpSession server;
  late String previousVersion;
  late Map<String, Object?> previousStats;
  late Set<String> tagsStoredByPrevious;
  late List<int> previousEntryIds;
  late int unregisteredBeforeReindex;

  /// The entries the previous release writes – three spellings of one tag,
  /// two of another, and one with a space.
  const legacyEntries = [
    (
      project: 'acme-app',
      text: 'The acme-app build uploads nightly artifacts to a staging bucket.',
      tags: ['build-notes', 'Alice'],
    ),
    (
      project: 'acme-app',
      text: 'The acme-app release checklist lives in the team wiki.',
      tags: ['Build_Notes', 'alice'],
    ),
    (
      project: 'garden',
      text: 'Tomatoes in the garden need watering every second day in summer.',
      tags: ['buildNotes', 'plant care'],
    ),
  ];

  Future<McpSession> start(
    String label,
    String launcher, {
    required bool strict,
  }) async {
    final session = await McpSession.start(
      label: label,
      launcher: launcher,
      storeDir: storeDir,
      cwd: cwd,
      strictStdout: strict,
    );
    scenario.sessions.add(session);
    return session;
  }

  /// The tag names the upgrade still has to fold.
  List<String> legacySpellings() =>
      tagsStoredByPrevious
          .difference(_normalisedTagCounts.keys.toSet())
          .toList()
        ..sort();

  List<String> renamedFrom(Map<String, Object?> normalize) => [
    for (final rename in _objects(normalize['renamed'], '"renamed"'))
      rename['from'] as String,
  ]..sort();

  scenario.check('the previous release starts on an empty store', () async {
    previous = await start(
      'previous launcher',
      previousLauncher,
      strict: false,
    );
    final init = await previous.initialize();
    _expectEquals(_at(init, 'serverInfo.name'), 'remembox', 'serverInfo.name');
    previousVersion = _at(init, 'serverInfo.version') as String;
    _expect(
      previousVersion != options.expectVersion,
      'the previous release zip reports version $previousVersion – the same '
      'as the release under test. Pass the zip of the previously PUBLISHED '
      'release.',
    );
    stdout.writeln('   previous release: remembox $previousVersion');
  });

  scenario.check(
    'the previous release writes entries with legacy tag spellings',
    () async {
      previousEntryIds = [];
      tagsStoredByPrevious = {};
      for (final entry in legacyEntries) {
        final stored = (await previous.call('remember', {
          'text': entry.text,
          'project': entry.project,
          'tags': entry.tags,
        })).ok;
        _expectEquals(stored['indexed'], true, 'previous remember indexed');
        final id = stored['id'] as int;
        previousEntryIds.add(id);
        final read = (await previous.call('get', {'id': id})).ok;
        tagsStoredByPrevious.addAll(
          _sortedStrings(read['tags'], 'stored tags'),
        );
      }
      previousStats = (await previous.call('stats')).ok;
      _expectHealthyStats(previousStats, entries: legacyEntries.length);
      stdout.writeln(
        '   tags as stored by $previousVersion: '
        '${tagsStoredByPrevious.toList()..sort()}',
      );
      if (legacySpellings().isEmpty) {
        stdout.writeln(
          '   NOTE: $previousVersion already normalises tags on write – '
          'tags_normalize has nothing to fold in this run and is checked to '
          'report exactly that.',
        );
      }
      final code = await previous.close();
      _expectEquals(code, 0, 'previous launcher exit code');
      if (previous.stdoutNoise.isNotEmpty) {
        stdout.writeln(
          '   NOTE: the previous launcher wrote '
          '${previous.stdoutNoise.length} non-JSON line(s) to stdout (not '
          'part of this acceptance – it is the old release).',
        );
      }
    },
  );

  scenario.check(
    'the new release opens the store: entry count and vector index intact',
    () async {
      server = await start(
        'new launcher (upgraded store)',
        options.newLauncher,
        strict: true,
      );
      final init = await server.initialize();
      _expectEquals(
        _at(init, 'serverInfo.version'),
        options.expectVersion,
        'serverInfo.version',
      );
      final stats = (await server.call('stats')).ok;
      _expectHealthyStats(stats, entries: legacyEntries.length);
      _expectEquals(
        _at(stats, 'store.tags'),
        _at(previousStats, 'store.tags'),
        'stats store.tags before any tidy-up',
      );
      _expectEquals(_at(stats, 'byProject'), {
        'acme-app': 2,
        'garden': 1,
      }, 'stats byProject');
      unregisteredBeforeReindex =
          _at(stats, 'registry.unregisteredProjects') as int;
      _expectEquals(
        unregisteredBeforeReindex + (_at(stats, 'registry.projects') as int),
        2,
        'registered + unregistered projects',
      );
    },
  );

  scenario.check(
    'recall finds the entries written by the previous release',
    () async {
      final acme = (await server.call('recall', {
        'query': 'where do the nightly build artifacts go',
        'project': 'acme-app',
      })).ok;
      _expectEquals(
        _hitIds(acme)..sort(),
        previousEntryIds.sublist(0, 2)..sort(),
        'recall project=acme-app hit ids',
      );
      _expectEquals(
        _hitIds(acme).first,
        previousEntryIds[0],
        'best hit for the build-artifacts question',
      );
      final garden = (await server.call('recall', {
        'query': 'watering the tomatoes',
        'project': 'garden',
      })).ok;
      _expectEquals(_hitIds(garden), [
        previousEntryIds[2],
      ], 'recall project=garden hit ids');
    },
  );

  scenario.check(
    'reindex keeps every vector and registers the projects',
    () async {
      final reindex = (await server.call('reindex')).ok;
      _expectEquals(
        reindex['entriesExamined'],
        legacyEntries.length,
        'examined',
      );
      _expectEquals(reindex['unchanged'], legacyEntries.length, 'unchanged');
      _expectEquals(reindex['created'], 0, 'reindex created');
      _expectEquals(reindex['reembedded'], 0, 'reindex reembedded');
      _expectEquals(reindex['orphanedRowsRemoved'], 0, 'orphanedRowsRemoved');
      _expectEquals(reindex['failed'], <Object?>[], 'reindex failed');
      _expectEquals(
        _at(reindex, 'registry.registered'),
        unregisteredBeforeReindex,
        'reindex registry.registered',
      );
      final stats = (await server.call('stats')).ok;
      _expectEquals(_at(stats, 'registry.projects'), 2, 'stats projects');
      _expectEquals(
        _at(stats, 'registry.unregisteredProjects'),
        0,
        'stats unregisteredProjects after reindex',
      );
    },
  );

  scenario.check(
    'tags_normalize dry run reports exactly the spellings left to fold '
    'and writes nothing',
    () async {
      final before = await _tagCounts(server);
      _expectEquals(
        before.keys.toList()..sort(),
        tagsStoredByPrevious.toList()..sort(),
        'tags_list before tags_normalize',
      );
      final dryRun = (await server.call('tags_normalize', {'dryRun': true})).ok;
      _expectEquals(dryRun['dryRun'], true, 'tags_normalize dryRun flag');
      _expectEquals(
        renamedFrom(dryRun),
        legacySpellings(),
        'dry run "renamed"',
      );
      _expectEquals(dryRun['skipped'], <Object?>[], 'dry run "skipped"');
      _expectEquals(
        await _tagCounts(server),
        before,
        'tags_list after dry run',
      );
    },
  );

  scenario.check(
    'tags_normalize folds them and tags_list shows the normalised tags',
    () async {
      final result = (await server.call('tags_normalize')).ok;
      _expectEquals(result['dryRun'], false, 'tags_normalize dryRun flag');
      _expectEquals(renamedFrom(result), legacySpellings(), '"renamed"');
      _expectEquals(result['skipped'], <Object?>[], '"skipped"');
      _expectEquals(
        await _tagCounts(server),
        _normalisedTagCounts,
        'tags_list after tags_normalize',
      );
      final again = (await server.call('tags_normalize', {'dryRun': true})).ok;
      _expectEquals(again['renamed'], <Object?>[], 'second dry run "renamed"');
    },
  );

  scenario.check('a new tag can be written after the upgrade', () async {
    final stored = (await server.call('remember', {
      'text': 'The compost bin was moved behind the garden shed.',
      'project': 'garden',
      'tags': ['yard-work', 'alice'],
    })).ok;
    _expectEquals(stored['indexed'], true, 'remember indexed');
    final entry = (await server.call('get', {'id': stored['id']})).ok;
    _expectEquals(_sortedStrings(entry['tags'], 'stored tags'), [
      'alice',
      'yardWork',
    ], 'stored tags');
  });

  scenario.check('fact_set works on the upgraded store', () async {
    final fact = (await server.call('fact_set', {
      'project': 'garden',
      'subject': 'Flat B',
      'attribute': 'rent',
      'valueNumber': 900,
      'unit': 'EUR',
      'validFrom': '2025-01-01',
    })).ok;
    _expectEquals(fact['action'], 'created', 'fact_set action');
    final read = _objects(
      (await server.call('fact_get', {
        'subject': 'Flat B',
        'attribute': 'rent',
      })).ok['facts'],
      'fact_get "facts"',
    );
    _expectEquals(read.single['id'], fact['id'], 'fact_get id');
    _expectEquals(read.single['value'], 900, 'fact_get value');
  });

  void expectFinalStats(Map<String, Object?> stats) {
    _expectHealthyStats(stats, entries: legacyEntries.length + 1);
    _expectEquals(_at(stats, 'store.tags'), 4, 'stats store.tags');
    _expectEquals(_at(stats, 'byProject'), {
      'acme-app': 2,
      'garden': 2,
    }, 'stats byProject');
    _expectEquals(_at(stats, 'registry.projects'), 2, 'stats projects');
    _expectEquals(
      _at(stats, 'registry.unregisteredProjects'),
      0,
      'stats unregisteredProjects',
    );
    _expectEquals(_at(stats, 'facts.total'), 1, 'stats facts.total');
    _expectEquals(_at(stats, 'facts.current'), 1, 'stats facts.current');
    _expectEquals(
      _at(stats, 'facts.conflictingKeys'),
      0,
      'stats facts.conflictingKeys',
    );
  }

  scenario.check(
    'final stats are consistent and the server exits cleanly',
    () async {
      expectFinalStats((await server.call('stats')).ok);
      await server.closeCleanly();
    },
  );

  if (options.downgradeRefused) {
    scenario.check(
      'the previous release refuses the upgraded store with the documented '
      'message',
      () async {
        previous = await start(
          'previous launcher (upgraded store)',
          previousLauncher,
          strict: false,
        );
        // The expected outcome is a process that dies instead of
        // answering, so a failed handshake is inspected below rather than
        // treated as the failure itself – unless the server is still
        // running, which is a timeout, not a refusal.
        Map<String, Object?>? answer;
        try {
          answer = await previous.initialize();
        } on CheckFailure {
          if (previous.running) rethrow;
        }
        if (answer != null) {
          final stats = await previous.call('stats');
          await previous.close();
          throw CheckFailure(
            'remembox $previousVersion still starts on the upgraded store '
            '(stats: ${stats.isError ? 'error' : 'ok'}) instead of refusing '
            'it. If this release did not change the database schema '
            'relative to $previousVersion, that is correct – re-run with '
            'the downgrade expectation set to "opens" (see '
            'tool/release_acceptance.sh). Otherwise CHANGELOG.md\'s upgrade '
            'note no longer describes what happens.',
          );
        }
        final code = await previous.waitForExit();
        _expect(code != 0, 'the refusing server exited with code 0');
        final match = _refusalMessage.firstMatch(previous.stderrText);
        _expect(
          match != null,
          'the previous release exited with code $code, but its stderr '
          'does not contain the documented message "DB\'s last entity ID … '
          'is higher than … from model". stderr (last lines):\n'
          '${previous.stderrTail()}',
        );
        stdout.writeln('   $previousVersion said: "${match!.group(0)}"');
      },
    );
  } else {
    scenario.check(
      'the previous release still opens the upgraded store (no schema '
      'change expected)',
      () async {
        previous = await start(
          'previous launcher (upgraded store)',
          previousLauncher,
          strict: false,
        );
        await previous.initialize();
        final stats = (await previous.call('stats')).ok;
        _expectHealthyStats(stats, entries: legacyEntries.length + 1);
        final code = await previous.close();
        _expectEquals(code, 0, 'previous launcher exit code');
      },
    );
  }

  scenario.check(
    'the new release still opens the store afterwards, unchanged',
    () async {
      server = await start(
        'new launcher (after the previous release touched the store)',
        options.newLauncher,
        strict: true,
      );
      await server.initialize();
      expectFinalStats((await server.call('stats')).ok);
      await server.closeCleanly();
    },
  );

  return scenario;
}

Future<void> main(List<String> argv) async {
  if (argv.length == 1 && argv.single == '--preflight') {
    // Only the precondition – lets tool/release.sh fail in its first
    // seconds instead of after the whole build.
    try {
      await _requireOllama();
    } on CheckFailure catch (failure) {
      stdout.writeln('FAIL: precondition – ${failure.message}');
      exit(1);
    }
    stdout.writeln(
      'PASS: precondition – Ollama at $_ollamaUrl has "$_embedModel"',
    );
    exit(0);
  }
  final Options options;
  try {
    options = Options.parse(argv);
  } on FormatException catch (err) {
    stderr.writeln('ERROR: ${err.message}');
    stderr.write(_usage);
    exit(64);
  }

  final report = Report();
  final List<String> expectedTools;
  final Directory freshStore;
  final Directory upgradeStore;
  final Directory cwd;
  try {
    for (final launcher in [options.newLauncher, ?options.previousLauncher]) {
      _expect(File(launcher).existsSync(), 'no launcher at $launcher');
    }
    expectedTools = _registeredToolNames(options.serverSource);
    final workDir = Directory(options.workDir);
    _expect(workDir.existsSync(), 'work dir ${workDir.path} does not exist');
    // "Empty directory" is the literal starting point of both scenarios –
    // created here, and refused if something is already there.
    freshStore = Directory('${workDir.path}/store-fresh');
    upgradeStore = Directory('${workDir.path}/store-upgrade');
    cwd = Directory('${workDir.path}/cwd');
    for (final dir in [freshStore, upgradeStore, cwd]) {
      _expect(
        !dir.existsSync(),
        '${dir.path} already exists – not a clean run',
      );
      dir.createSync();
    }
    await _requireOllama();
  } on CheckFailure catch (failure) {
    stdout.writeln('FAIL: precondition – ${failure.message}');
    stdout.writeln('acceptance: FAILED before any check could run');
    exit(1);
  }

  await _freshInstall(
    report: report,
    options: options,
    expectedTools: expectedTools,
    storeDir: freshStore.path,
    cwd: cwd.path,
  ).run();

  final previousLauncher = options.previousLauncher;
  if (previousLauncher == null) {
    stdout.writeln('== B upgrade from the previous release');
    report.skip(
      'B upgrade from the previous release',
      'no previous release zip was given, so the upgrade path of this '
          'build is UNTESTED',
    );
  } else {
    await _upgrade(
      report: report,
      options: options,
      previousLauncher: previousLauncher,
      storeDir: upgradeStore.path,
      cwd: cwd.path,
    ).run();
  }

  stdout.writeln(
    'acceptance: ${report.passed} passed, ${report.failed} failed, '
    '${report.notRun} not run, ${report.skipped.length} scenario(s) skipped',
  );
  exit(report.ok ? 0 : 1);
}
