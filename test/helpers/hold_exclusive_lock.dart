/// Standalone helper script (NOT a test-framework file): acquires an
/// EXCLUSIVE [StoreInstanceGuard] lock on the store directory given as
/// `args[0]`, signals readiness on stdout, then blocks until the parent
/// process closes stdin, at which point it releases the lock and exits
/// cleanly.
///
/// Used by test/instance_guard_test.dart to spawn a genuine second OS
/// process holding an exclusive lock, exercising real cross-process
/// advisory file locking (not just in-process behavior).
///
/// `print()`/direct stdout writes are acceptable here ONLY because this is a
/// throwaway standalone script under test/helpers/ — never in production
/// lib/ or bin/ code.
library;

import 'dart:io';

import 'package:remembox/src/instance_guard.dart';

Future<void> main(List<String> args) async {
  final storeDir = args[0];
  final guard = StoreInstanceGuard.acquire(
    storeDir,
    log: (m) => stderr.writeln(m),
    exclusive: true,
  );
  stdout.writeln('LOCK_HELD');
  await stdout.flush();
  await stdin.drain<void>();
  guard.release(log: (m) => stderr.writeln(m));
  exit(0);
}
