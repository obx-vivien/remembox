/// Pins the user-facing setup templates in `templates/` (2026-10-07):
///
/// - The templates are English only (maintainer decision, 2026-10-08).
/// - The short "Instructions for Claude" block exists in several places
///   (README, usage guide, docs/quickstart.md, templates/
///   instructions-for-claude.md) because each must stay copyable where a
///   reader meets it. Every copy must be identical – a fix in one place
///   would otherwise drift from the others.
/// - Every tool name the global CLAUDE.md template mentions is a real,
///   registered tool (lib/src/server.dart), so the template never teaches
///   a call that does not exist.
/// - The release ships templates/ and the acceptance test checks it.
/// - Prose style: spaced en dashes, never an em dash.
library;

import 'dart:io';

import 'package:remembox/src/model.dart' show LinkType;
import 'package:test/test.dart';

const _templates = [
  'templates/cockpit.md',
  'templates/instructions-for-claude.md',
  'templates/global-CLAUDE.md',
];

/// The single line in [path] that starts with [prefix] (the paste block is
/// one line inside a ```text fence).
String _blockLine(String path, String prefix) {
  final lines = File(path)
      .readAsLinesSync()
      .where((l) => l.startsWith(prefix))
      .toList();
  expect(lines, hasLength(1), reason: '$path: exactly one "$prefix" line');
  return lines.single;
}

/// Every tool name registered in lib/src/server.dart (`Tool(name: '...')`).
Set<String> _registeredTools(String server) => {
  for (final m in RegExp(r"""\bname:\s*'([a-zA-Z0-9_]+)'""").allMatches(
    server,
  ))
    m.group(1)!,
};

/// Every tool argument name declared in a tool schema in
/// lib/src/server.dart (`'name': Schema.…`).
Set<String> _schemaKeys(String server) => {
  for (final m in RegExp(r"'([a-zA-Z0-9_]+)':\s*Schema\.").allMatches(server))
    m.group(1)!,
};

void main() {
  test('every template exists, uses " – " and stays short', () {
    for (final path in _templates) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: path);
      final text = file.readAsStringSync();
      expect(text, isNot(contains('\u2014')), reason: '$path: em dash');
      // The global rules are the one long form (usage guide §3 only
      // summarizes them); the others stay short.
      final maxLines = path.endsWith('global-CLAUDE.md') ? 160 : 120;
      expect(
        text.split('\n').length,
        lessThanOrEqualTo(maxLines),
        reason: '$path: keep templates short',
      );
    }
  });

  test('the templates are English only', () {
    final names = Directory('templates')
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .toSet();
    expect(names, {for (final t in _templates) t.split('/').last});
    expect(
      File('templates/instructions-for-claude.md').readAsStringSync(),
      isNot(contains('Gedächtnis (RememBox):')),
    );
  });

  test('the Instructions for Claude block is identical everywhere', () {
    const en = 'Memory (RememBox):';
    final template = 'templates/instructions-for-claude.md';
    final enBlock = _blockLine(template, en);
    for (final path in [
      'README.md',
      'docs/usage-guide.md',
      'docs/quickstart.md',
    ]) {
      expect(_blockLine(path, en), enBlock, reason: '$path differs');
    }
  });

  test('every tool named in templates/global-CLAUDE.md is a registered '
      'tool', () {
    final server = File('lib/src/server.dart').readAsStringSync();
    final tools = _registeredTools(server);
    final template = File('templates/global-CLAUDE.md').readAsStringSync();
    // Backticked snake_case words (`tag_define`) are tool names.
    final named = {
      for (final m in RegExp(r'`([a-z]+(?:_[a-z]+)+)`').allMatches(template))
        m.group(1)!,
    };
    expect(named, isNotEmpty);
    expect(named.difference(tools), isEmpty, reason: 'unknown tool names');
    for (final tool in ['recall', 'remember', 'supersede', 'forget', 'link']) {
      expect(tools, contains(tool));
      expect(template, contains('`$tool`'));
    }
  });

  test('the release ships templates/ and the acceptance test checks it', () {
    final release = File('tool/release.sh').readAsStringSync();
    expect(
      RegExp(r'^KEEP_ITEMS="[^"]*\btemplates\b', multiLine: true)
          .hasMatch(release),
      isTrue,
      reason: 'tool/release.sh must keep templates/ in the zip',
    );
    final acceptance = File('tool/release_acceptance.sh').readAsStringSync();
    for (final path in _templates) {
      expect(acceptance, contains('remembox/$path'), reason: path);
    }
  });

  group('release acceptance layout (unpack in tool/release_acceptance.sh)',
      () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('remembox_layout_test_');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    /// Builds a synthetic release-shaped zip (empty placeholder files,
    /// executable launcher/binary) with or without templates/.
    String makeZip(String name, {required bool withTemplates}) {
      final root = Directory('${tmp.path}/$name/remembox');
      final files = [
        'dist/remembox',
        'dist/bin/remembox',
        'dist/lib/libobjectbox.dylib',
        'skill/SKILL.md',
        'README.md',
        'LICENSE',
        if (withTemplates)
          for (final t in _templates) t,
      ];
      for (final f in files) {
        File('${root.path}/$f')
          ..createSync(recursive: true)
          ..writeAsStringSync('placeholder\n');
      }
      Process.runSync('chmod', [
        '+x',
        '${root.path}/dist/remembox',
        '${root.path}/dist/bin/remembox',
      ]);
      final zip = '${tmp.path}/$name.zip';
      final r = Process.runSync('zip', [
        '-qr',
        zip,
        'remembox',
      ], workingDirectory: '${tmp.path}/$name');
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return zip;
    }

    ProcessResult unpack(String zip, String dir, String layout) {
      final work = Directory('${tmp.path}/work')..createSync();
      return Process.runSync('bash', [
        '-c',
        'export RELEASE_ACCEPTANCE_LIB_ONLY=1 WORK="\$1"; '
            'source tool/release_acceptance.sh; unpack "\$2" "\$3" "\$4"',
        'bash',
        work.path,
        zip,
        dir,
        layout,
      ]);
    }

    test('the zip under test must contain templates/', () {
      final current = makeZip('new', withTemplates: true);
      expect(unpack(current, 'a', 'current').exitCode, 0);
      final old = makeZip('old', withTemplates: false);
      final r = unpack(old, 'b', 'current');
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('does not contain remembox/templates/'));
    });

    test('a previous release without templates/ is accepted', () {
      final old = makeZip('old', withTemplates: false);
      final r = unpack(old, 'c', 'previous');
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, contains('/remembox/dist/remembox'));
    });

    test('the upgrade path unpacks the previous zip with the previous '
        'layout', () {
      final script = File('tool/release_acceptance.sh').readAsStringSync();
      expect(
        script,
        contains(r'unpack "$PREVIOUS_ZIP" previous previous'),
      );
      expect(script, contains(r'unpack "$NEW_ZIP" new current'));
    });
  });

  test('every camelCase argument name in templates/global-CLAUDE.md is a '
      'real tool argument', () {
    final keys = _schemaKeys(File('lib/src/server.dart').readAsStringSync());
    expect(keys, containsAll(['sourceType', 'addAreas', 'addAliases']));
    final template = File('templates/global-CLAUDE.md').readAsStringSync();
    // Values, not arguments: a tag example and the link types.
    final tagExamples = {'deadEnd', ...LinkType.all};
    final named = {
      for (final m in RegExp(r'`([a-z]+[A-Z][A-Za-z0-9]*)`').allMatches(
        template,
      ))
        m.group(1)!,
    }.difference(tagExamples);
    expect(named, isNotEmpty);
    expect(named.difference(keys), isEmpty, reason: 'unknown argument names');
  });

  test('every tool named in the short block is a registered tool', () {
    final tools = _registeredTools(
      File('lib/src/server.dart').readAsStringSync(),
    );
    final block = File('templates/instructions-for-claude.md')
        .readAsLinesSync()
        .where((l) => l.startsWith('Memory (RememBox):'))
        .single;
    final named = {
      for (final m in RegExp(r'\b[a-z]+(?:_[a-z]+)+\b').allMatches(block))
        m.group(0)!,
    };
    expect(named, containsAll(['areas_list', 'tag_define', 'fact_set']));
    expect(named.difference(tools), isEmpty, reason: 'unknown tool names');
  });

  test('the long-form global rules exist only in the template', () {
    // A distinctive heading and rule of the long form; the usage guide
    // (§3) only points to the template.
    const markers = [
      '## Register rule: look up, register, use',
      'Dead ends matter most',
    ];
    for (final path in [
      'README.md',
      'docs/usage-guide.md',
      'docs/quickstart.md',
      'docs/quickstart.de.md',
      'skill/SKILL.md',
    ]) {
      final text = File(path).readAsStringSync();
      for (final marker in markers) {
        expect(text, isNot(contains(marker)), reason: '$path: second copy');
      }
      expect(
        text,
        isNot(contains('## Persistent memory (MCP server `remembox`)')),
        reason: '$path: the old long-form snippet',
      );
    }
    final template = File('templates/global-CLAUDE.md').readAsStringSync();
    for (final marker in markers) {
      expect(template, contains(marker));
    }
  });

  group('release script test hooks never pass when executed', () {
    // Each script is copied into a temp dir and executed from there, so a
    // broken guard could never start a real release or acceptance run
    // against this checkout.
    for (final (script, variable, message) in [
      (
        'tool/release_acceptance.sh',
        'RELEASE_ACCEPTANCE_LIB_ONLY',
        'no check was run',
      ),
      ('tool/release.sh', 'RELEASE_GATE_LIB_ONLY', 'nothing was built'),
    ]) {
      test('$script with $variable=1 exits non-zero with an error', () {
        final tmp = Directory.systemTemp.createTempSync('remembox_hook_');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final copy = File('${tmp.path}/$script')
          ..createSync(recursive: true)
          ..writeAsStringSync(File(script).readAsStringSync());
        final r = Process.runSync(
          'bash',
          [copy.path, '/nonexistent.zip'],
          environment: {variable: '1'},
          workingDirectory: tmp.path,
        );
        expect(r.exitCode, isNot(0));
        expect(r.stderr, contains('ERROR: $variable=1 is a test hook'));
        expect(r.stderr, contains(message));
      });
    }

    test('sourcing with the hook set still defines the functions', () {
      final r = Process.runSync('bash', [
        '-c',
        'RELEASE_ACCEPTANCE_LIB_ONLY=1 source tool/release_acceptance.sh && '
            'type unpack >/dev/null && '
            'RELEASE_GATE_LIB_ONLY=1 source tool/release.sh && '
            'type run_trace_gate >/dev/null && echo ok',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, contains('ok'));
    });
  });
}
