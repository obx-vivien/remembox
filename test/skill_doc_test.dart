/// Pinning test: every MCP tool the server registers must be mentioned (in
/// backticks) in the shipped skill file (`skill/SKILL.md`).
///
/// Why this matters: `skill/SKILL.md` is what teaches Claude Code, Claude
/// Desktop and Cowork the RememBox workflow (see README.md "Make it part of
/// the assistant's normal workflow" and docs/usage-guide.md §6). A tool the
/// skill never mentions is invisible to a session that relies on the skill
/// alone – the assistant has no reason to ever call it, even though the
/// server exposes it. This test fails the moment a new tool is registered in
/// lib/src/server.dart without a matching update to skill/SKILL.md, instead
/// of that gap being discovered later by a user whose skill never taught
/// Claude about (say) `fact_set` or `tags_list`.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Extracts every registered MCP tool name from lib/src/server.dart.
///
/// Each tool is declared as a top-level `Tool(name: 'toolName', ...)` value
/// (see the `static final _xTool = Tool(...)` declarations in server.dart).
/// The regex below deliberately requires the UNQUOTED key `name:` followed
/// by a single-quoted string literal – this matches every `Tool(name: ...)`
/// declaration in the file, but not other `name:` usages that appear for
/// unrelated reasons (e.g. `Implementation(name: serverName, ...)`, which
/// has no quotes around its value, or a JSON Schema map key written as
/// `'name': Schema.string(...)`, which quotes the KEY, not this pattern).
/// Robust in the sense that any *new* tool following the same `Tool(name:
/// '...', ...)` convention is picked up automatically without touching this
/// test – it does not hardcode the tool list.
List<String> _registeredToolNames(String serverSource) {
  final pattern = RegExp(r"""\bname:\s*'([a-zA-Z0-9_]+)'""");
  final names = [
    for (final match in pattern.allMatches(serverSource)) match.group(1)!,
  ];
  return names;
}

void main() {
  group('skill/SKILL.md documents every registered tool', () {
    late String serverSource;
    late String skillSource;
    late List<String> toolNames;

    setUpAll(() {
      serverSource = File('lib/src/server.dart').readAsStringSync();
      skillSource = File('skill/SKILL.md').readAsStringSync();
      toolNames = _registeredToolNames(serverSource);
    });

    test('the extraction found a realistic number of tools', () {
      // Sanity floor: catches a regex silently broken by a future refactor
      // of server.dart (e.g. a rename of the `Tool(` constructor call)
      // returning zero or a suspiciously small tool list instead of failing
      // loudly. 20 is comfortably below the 23 tools registered as of
      // 0.3.1, so raising the tool count further will not make this flaky.
      expect(
        toolNames.length,
        greaterThanOrEqualTo(20),
        reason:
            'Expected to find at least 20 registered tool names in '
            'lib/src/server.dart via the name: \'...\' pattern – found '
            '${toolNames.length}: $toolNames. If server.dart\'s Tool '
            'declarations changed shape, update the extraction regex in '
            'this test, not just the assertion.',
      );
    });

    test('every registerTool( call has a matching name: literal', () {
      // Catches a tool that is registered (registerTool(...) called) but
      // whose Tool(...) declaration does not use the plain `name: '...'`
      // literal this test's extraction relies on – e.g. a name built from
      // a constant or expression instead of a string literal. Without this
      // check such a tool would silently never be checked against
      // skill/SKILL.md at all (it would not appear in toolNames, so it
      // could never show up as "missing" either) – a silent gap, not a
      // loud one.
      final registerToolCalls = RegExp(
        r'registerTool\(',
      ).allMatches(serverSource).length;
      expect(
        toolNames.length,
        registerToolCalls,
        reason:
            'lib/src/server.dart has $registerToolCalls registerTool( '
            'call(s) but only ${toolNames.length} name: \'...\' literal(s) '
            'were extracted – some registered tool\'s Tool(...) declaration '
            'does not use a plain string literal for its name, so it '
            'cannot be checked against skill/SKILL.md by this test at all.',
      );
    });

    test('every registered tool name has no duplicates', () {
      final duplicates = <String>{
        for (final name in toolNames.toSet())
          if (toolNames.where((n) => n == name).length > 1) name,
      };
      expect(
        duplicates,
        isEmpty,
        reason: 'lib/src/server.dart registers the same tool name twice: '
            '$duplicates.',
      );
    });

    test('every registered tool name appears in skill/SKILL.md', () {
      final missing = [
        for (final name in toolNames)
          if (!skillSource.contains('`$name`')) name,
      ];
      expect(
        missing,
        isEmpty,
        reason:
            'skill/SKILL.md does not mention these registered tools in '
            'backticks: $missing. A tool the skill does not name is '
            'invisible to a Claude Desktop/Cowork/Code session that relies '
            'on the skill alone – add it to skill/SKILL.md.',
      );
    });

    test('the skill frontmatter names it remembox-memory', () {
      // Both README.md and docs/usage-guide.md instruct installing the
      // skill under ~/.claude/skills/remembox-memory/SKILL.md – the
      // frontmatter `name:` is what Claude Code/Desktop/Cowork show for the
      // skill, and it should match that directory name.
      expect(skillSource, contains('name: remembox-memory'));
    });
  });
}
