/// Minimal MCP "streamable HTTP" transport (2025-03-26 / 2025-06-18 spec
/// revision) bridging `dart:io` `HttpServer` to the in-memory
/// `StreamChannel<String>` that [RememboxServer] (and dart_mcp's `Peer`
/// underneath it) expects.
///
/// Built 2026-07-18 (the 2026-07-18 HTTP-daemon engineering log, internal)
/// so that ONE daemon process can own the ObjectBox store (single writer —
/// see lib/src/instance_guard.dart / R2-6) while MANY Claude Code sessions
/// connect concurrently via HTTP instead of each spawning its own stdio
/// process (each of which would be an independent writer on the same store
/// directory — verified silent write loss, the 2026-07-06 engineering log
/// (internal), R2-6).
///
/// dart_mcp 0.5.2 (checked in ~/.pub-cache) ships NO HTTP transport, only
/// `StreamChannel`-based servers (see `package:dart_mcp/stdio.dart`) — this
/// file is the from-scratch bridge. Deliberately NOT built (documented, not
/// silently missing): SSE / server-initiated push (GET always 405 — we have
/// no server-initiated messages to deliver).
///
/// **Security model (revised 2026-09-07, the 2026-09-07 daemon-auth
/// engineering log, internal):** loopback binding alone is NOT the security
/// boundary — an
/// independent review that day proved a POST carrying a spoofed `Host` and
/// `Origin` and `Content-Type: text/plain` was served in full by the
/// PREVIOUS version of this file (any local process of any UID could reach
/// it, and so could any web page the developer visits, via DNS rebinding).
/// Every request now MUST pass, in order: (1) a loopback `Host` header
/// check, (2) an Origin check (any PRESENT non-loopback Origin is
/// rejected — real MCP clients send none), (3) a constant-time bearer-token
/// check against `OBX_MEMORY_HTTP_TOKEN` (required — `--serve` refuses to
/// start without one, see [resolveHttpToken]). POST additionally requires
/// `Content-Type: application/json` (415 otherwise), which alone kills the
/// non-preflighted `text/plain` cross-origin vector the review used.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart' show sha256;
import 'package:stream_channel/stream_channel.dart';

import 'instance_guard.dart';
import 'memory_service.dart';
import 'server.dart';
import 'store.dart' show LogSink, stderrLog;

/// Default HTTP port (matches README / launchd template).
const int defaultHttpPort = 3927;

/// Default idle-session TTL for the GC sweep.
const Duration defaultSessionTtl = Duration(seconds: 1800);

/// Default cap on concurrent HTTP sessions (2026-08-14, the 2026-07-18
/// HTTP-daemon engineering log (internal), "Review round 1 fixes" finding
/// 5). The actual security boundary for this daemon is the bearer-token
/// check plus the Host/Origin checks described in this file's doc above —
/// loopback binding (`HttpServer.bind('127.0.0.1', ...)`) is defence in
/// depth on top of that, not the boundary itself (see the 2026-09-07
/// revision note above for why: any local process, or any web page via
/// DNS rebinding, can still reach a loopback-bound port). This cap and
/// [defaultMaxBodyBytes] below are hygiene on top of ALL of that, guarding
/// against a buggy or runaway client opening unbounded sessions or sending
/// unbounded request bodies — not a substitute for the token/Host/Origin
/// checks.
const int defaultMaxSessions = 64;

/// Default cap on a single JSON-RPC POST request body, in bytes (4 MiB —
/// see [defaultMaxSessions] doc for the security-boundary framing).
const int defaultMaxBodyBytes = 4 * 1024 * 1024;

/// Whether CLI args request serve (HTTP daemon) mode: `--serve` or
/// `--serve=<port>`.
bool serveModeRequested(List<String> args) =>
    args.any((a) => a == '--serve' || a.startsWith('--serve='));

/// Resolves the HTTP port for serve mode: an explicit `--serve=<port>` CLI
/// arg wins, then `OBX_MEMORY_HTTP_PORT`, then [defaultHttpPort].
///
/// Throws [ArgumentError] on an unparsable `--serve=<port>` or
/// `OBX_MEMORY_HTTP_PORT` value — same fail-loud style as
/// [MemoryConfig.fromEnvironment] (never silently falls back to the default
/// on a typo'd value).
int resolveHttpPort(List<String> args, {Map<String, String>? env}) {
  for (final arg in args) {
    if (arg.startsWith('--serve=')) {
      final raw = arg.substring('--serve='.length);
      final parsed = int.tryParse(raw);
      if (parsed == null || parsed < 0 || parsed > 65535) {
        throw ArgumentError(
          '--serve=<port> requires an integer port in [0, 65535], got '
          '"$raw"',
        );
      }
      return parsed;
    }
  }
  final e = env ?? Platform.environment;
  final raw = e['OBX_MEMORY_HTTP_PORT'];
  if (raw == null || raw.isEmpty) return defaultHttpPort;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 0 || parsed > 65535) {
    throw ArgumentError(
      'OBX_MEMORY_HTTP_PORT must be an integer port in [0, 65535], got '
      '"$raw"',
    );
  }
  return parsed;
}

/// Resolves the idle-session GC TTL from `OBX_MEMORY_HTTP_SESSION_TTL_SECONDS`
/// (default: [defaultSessionTtl]). Same fail-loud parsing style as
/// [resolveHttpPort] — an unparsable value throws rather than silently
/// falling back.
Duration resolveSessionTtl({Map<String, String>? env}) {
  final e = env ?? Platform.environment;
  final raw = e['OBX_MEMORY_HTTP_SESSION_TTL_SECONDS'];
  if (raw == null || raw.isEmpty) return defaultSessionTtl;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed <= 0) {
    throw ArgumentError(
      'OBX_MEMORY_HTTP_SESSION_TTL_SECONDS must be a positive integer, got '
      '"$raw"',
    );
  }
  return Duration(seconds: parsed);
}

/// Resolves the max-concurrent-sessions cap from
/// `OBX_MEMORY_HTTP_MAX_SESSIONS` (default: [defaultMaxSessions]). Same
/// fail-loud parsing style as [resolveHttpPort]/[resolveSessionTtl].
int resolveMaxSessions({Map<String, String>? env}) {
  final e = env ?? Platform.environment;
  final raw = e['OBX_MEMORY_HTTP_MAX_SESSIONS'];
  if (raw == null || raw.isEmpty) return defaultMaxSessions;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed <= 0) {
    throw ArgumentError(
      'OBX_MEMORY_HTTP_MAX_SESSIONS must be a positive integer, got "$raw"',
    );
  }
  return parsed;
}

/// Resolves the max-request-body-size cap (bytes) from
/// `OBX_MEMORY_HTTP_MAX_BODY_BYTES` (default: [defaultMaxBodyBytes]). Same
/// fail-loud parsing style as [resolveHttpPort]/[resolveSessionTtl].
int resolveMaxBodyBytes({Map<String, String>? env}) {
  final e = env ?? Platform.environment;
  final raw = e['OBX_MEMORY_HTTP_MAX_BODY_BYTES'];
  if (raw == null || raw.isEmpty) return defaultMaxBodyBytes;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed <= 0) {
    throw ArgumentError(
      'OBX_MEMORY_HTTP_MAX_BODY_BYTES must be a positive integer, got '
      '"$raw"',
    );
  }
  return parsed;
}

/// Resolves the required bearer token for serve mode from
/// `OBX_MEMORY_HTTP_TOKEN`. Throws [StateError] with an actionable message
/// if it is unset or empty — `--serve` refuses to start without one (Fix 1,
/// 2026-09-07, the 2026-09-07 daemon-auth engineering log (internal)): a
/// 2026-09-07 security review proved loopback binding alone is not a
/// sufficient
/// boundary (any local process, or any web page via DNS rebinding, could
/// reach the daemon). Deliberately does NOT auto-generate a token here —
/// generation and file-permission handling stay in
/// `tool/install-daemon.sh` instead of this process (alternatives
/// considered and rejected are recorded in the internal engineering log).
String resolveHttpToken({Map<String, String>? env}) {
  final e = env ?? Platform.environment;
  final raw = e['OBX_MEMORY_HTTP_TOKEN'];
  if (raw == null || raw.isEmpty) {
    throw StateError(
      'OBX_MEMORY_HTTP_TOKEN is required for --serve mode. The HTTP daemon '
      'refuses to start without it: loopback binding alone is not a '
      'sufficient security boundary (see the 2026-09-07 daemon-auth '
      'engineering log, internal). Generate one with:\n'
      '  openssl rand -base64 32 | tr \'+/\' \'-_\' | tr -d \'=\'\n'
      'then export OBX_MEMORY_HTTP_TOKEN=<the generated value> before '
      'running --serve — or (preferred) just run tool/install-daemon.sh, '
      'which generates, persists (mode 0600), and bakes one in '
      'automatically.',
    );
  }
  return raw;
}

/// Computes the log-safe "handle" for a session id: the first 8 hex
/// characters of SHA-256(id) (Fix 3, 2026-09-07, the 2026-09-07 daemon-auth
/// engineering log, internal). Session ids are bearer-token-like (32 random
/// bytes,
/// base64url-encoded) — logging one verbatim into an on-disk log file would
/// let anyone who can read that file replay it as `Mcp-Session-Id` and
/// impersonate the session. The handle keeps enough entropy to correlate
/// log lines for one session across its whole lifecycle without ever
/// recovering the id from the log.
String sessionLogHandle(String sessionId) =>
    sha256.convert(utf8.encode(sessionId)).toString().substring(0, 8);

/// Compares two strings for equality in constant time, i.e. without
/// short-circuiting on the first mismatched byte (Fix 1, 2026-09-07,
/// the 2026-09-07 daemon-auth engineering log (internal), review finding
/// H-1). A plain
/// `==`/`String` comparison exits as soon as it finds a mismatch, which
/// leaks "how many leading bytes were correct" via response timing —
/// enough for a patient remote attacker to recover a bearer token one byte
/// at a time. This instead always walks every byte of the LONGER input and
/// folds a length mismatch into the same accumulator, so the POSITION of
/// the first mismatch is not observable from timing alone.
///
/// N-10 (2026-09-07 security-review re-verification) correction: the
/// claim above used to (wrongly) say neither length NOR position leaks.
/// That overstated it — the loop always runs `maxLen` iterations, so
/// total comparison time still scales with `max(a.length, b.length)`:
/// token LENGTH is not hidden by this function, only WHICH byte differs.
/// Accepted as-is here because the token generator
/// (`tool/install-daemon.sh`) publishes a fixed 43-character format, so
/// the length is already public — an attacker timing it learns nothing
/// they could not already read from the install script.
bool constantTimeEquals(String a, String b) {
  final aBytes = utf8.encode(a);
  final bBytes = utf8.encode(b);
  var result = aBytes.length == bBytes.length ? 0 : 1;
  final maxLen = math.max(aBytes.length, bBytes.length);
  for (var i = 0; i < maxLen; i++) {
    final byteA = i < aBytes.length ? aBytes[i] : 0;
    final byteB = i < bBytes.length ? bBytes[i] : 0;
    result |= byteA ^ byteB;
  }
  return result == 0;
}

/// Acquires the store instance guard for serve (HTTP daemon) mode.
///
/// ALWAYS exclusive, regardless of `OBX_MEMORY_EXCLUSIVE` — that env var
/// governs the legacy stdio path's "tolerate a second process" default; the
/// entire point of daemon mode is that it IS the single writer process (see
/// the 2026-07-18 HTTP-daemon engineering log (internal)). If another
/// RememBox process
/// (stdio or another daemon) already holds a lock on [storeDir], this fails
/// loudly via [StoreInstanceGuard.acquire]'s existing actionable
/// [StateError] rather than starting a second writer. Pinned by
/// test/http_transport_test.dart 'serve mode refuses to start when another
/// process holds the store lock'.
StoreInstanceGuard acquireServeModeGuard(
  String storeDir, {
  required LogSink log,
}) {
  log(
    '[http] serve mode acquires the instance guard in EXCLUSIVE mode '
    '(daemon is the sole intended writer) — if this fails, another '
    'RememBox process (stdio session or another daemon) is already '
    'attached to $storeDir; close it first (see error below for the '
    'exact command).',
  );
  return StoreInstanceGuard.acquire(storeDir, log: log, exclusive: true);
}

/// One HTTP-transport session: one client's `initialize` call gets its own
/// [RememboxServer] instance over a private in-memory duplex channel, so
/// concurrent Claude Code sessions never see each other's MCP protocol
/// state (capabilities negotiation, `initialized` flag, etc.) — only the
/// underlying [MemoryService] (and, per [ToolCallSerializer], tool-call
/// execution order) is actually shared.
class _Session {
  final String id;
  final RememboxServer server;

  /// When this session was created (Fix 3, 2026-09-07, the 2026-09-07
  /// daemon-auth engineering log, internal): used by
  /// `RememboxHttpDaemon._findEvictionCandidate` to pick the OLDEST
  /// never-used session to evict at the session cap,
  /// distinct from [lastActivity] (which a never-used session's own
  /// `initialize` response already bumps once, so it cannot double as
  /// "creation time" without conflating the two).
  final DateTime createdAt;

  /// Count of POST requests/notifications this session has handled AFTER
  /// its own `initialize` (Fix 3, see [createdAt] doc): incremented by
  /// `RememboxHttpDaemon._handlePost` for every request that reaches this
  /// session. Zero means "never used since initialize" — an attacker's
  /// abandoned session or a dead client's — and makes this session eligible
  /// for eviction at the session cap instead of rejecting a legitimate new
  /// client with 503.
  int postInitRequestCount = 0;

  /// Feeds raw JSON-RPC message strings INTO the server (one string per
  /// incoming HTTP request's decoded body).
  final StreamController<String> _toServer;

  /// The server's OUTGOING messages (responses + any notifications it
  /// sends); routed to whichever HTTP request is awaiting that response id.
  final StreamController<String> _fromServer;
  late final StreamSubscription<String> _fromServerSub;

  /// Pending client requests awaiting a response, keyed by the JSON-RPC
  /// `id` value exactly as decoded (so a JSON integer id matches a JSON
  /// integer id, a string id matches a string id — JSON-RPC ids of
  /// different types are never equal, and neither are these keys).
  final Map<Object?, Completer<Map<String, Object?>>> _pending = {};

  /// Refreshed both when a request STARTS (`RememboxHttpDaemon._handlePost`
  /// sets it before forwarding) and when one COMPLETES (`_onServerMessage`
  /// below, on receiving the matching response) — the latter added
  /// 2026-08-14 review round 2, M3 (the 2026-07-18 HTTP-daemon engineering
  /// log (internal), "Review round 2 polish"). Before that fix, a request
  /// whose in-flight
  /// duration exceeded `sessionTtl` (only reachable with a misconfigured
  /// tiny `OBX_MEMORY_HTTP_SESSION_TTL_SECONDS`) could still get its session
  /// disposed by `RememboxHttpDaemon._sweepIdleSessions` while the request
  /// was still in flight — the sweep also now skips any session with
  /// [hasPendingRequests], so this refresh and that guard work together.
  DateTime lastActivity;

  final LogSink _log;

  /// Whether this session currently has any request awaiting a response —
  /// consulted by `RememboxHttpDaemon._sweepIdleSessions` (M3, see
  /// [lastActivity] doc) so the idle-TTL sweep never disposes a session out
  /// from under a request that is still in flight.
  bool get hasPendingRequests => _pending.isNotEmpty;

  /// Number of requests currently awaiting a response (for the sweep's log
  /// line — see [hasPendingRequests]).
  int get pendingRequestCount => _pending.length;

  _Session._(
    this.id,
    this.server,
    this._toServer,
    this._fromServer,
    this.lastActivity,
    this._log,
    this.createdAt,
  ) {
    _fromServerSub = _fromServer.stream.listen(
      _onServerMessage,
      onDone: () {
        // The server closed its side (e.g. via shutdown()). Fail any requests
        // still waiting — never leave an HTTP caller hanging forever with no
        // signal (no-silent-failure).
        for (final pending in _pending.values) {
          if (!pending.isCompleted) {
            pending.completeError(
              // 2026-09-07 (Fix 3, the 2026-09-07 daemon-auth engineering
              // log (internal)): handle, not raw id — this StateError is
              // caught and logged
              // verbatim by RememboxHttpDaemon._handlePost's `on StateError`
              // branch.
              StateError(
                'session ${sessionLogHandle(id)} closed before a response '
                'arrived',
              ),
            );
          }
        }
        _pending.clear();
      },
    );
  }

  // NOTE: this runs inside a StreamSubscription data callback with no
  // onError handler attached — throwing here would become an uncaught async
  // error and could take down the whole daemon process. Every abnormal case
  // below is therefore LOGGED, never thrown (no-silent-failure via logging,
  // not via crashing).
  //
  // Latent constraint (2026-08-14, the 2026-07-18 HTTP-daemon engineering
  // log (internal), "Review round 1 fixes" finding 8): this method only
  // knows how to route
  // RESPONSES (a message with an `id` that matches something in `_pending`,
  // i.e. something the CLIENT asked for). A server-INITIATED *request*
  // (has an `id` too, but expects a fresh reply rather than answering a
  // pending one) would be misrouted here: `map['id']` would find no entry
  // in `_pending` and fall straight into the "no matching in-flight
  // request" branch below, which logs and drops it — there is no GET/SSE
  // channel this bridge could deliver a server-initiated request over
  // anyway (see the file doc's "SSE / server-initiated push" note).
  // Acceptable today because RememboxServer/dart_mcp never emits a
  // server-initiated request (no sampling/roots/elicitation support in this
  // codebase) — revisit this method if that ever changes.
  void _onServerMessage(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (err) {
      // The server (dart_mcp/json_rpc_2) is the ONLY writer to this stream —
      // it should never emit invalid JSON. If this ever fires it's a real
      // bug; surface it loudly in the log rather than silently dropping it.
      // Handle, not raw id (2026-09-07, Fix 3, the 2026-09-07 daemon-auth
      // engineering log (internal) — see [sessionLogHandle] doc).
      _log(
        '[http] session ${sessionLogHandle(id)}: RememboxServer emitted '
        'non-JSON on its outgoing channel ($err): $raw',
      );
      return;
    }
    if (decoded is! Map) return;
    final map = decoded.cast<String, Object?>();
    if (!map.containsKey('id')) {
      // A notification FROM the server (e.g. a log message). We have no
      // GET/SSE channel to deliver server-initiated messages to the client
      // over (deliberately not built — see file doc). Not an error, just an
      // unsupported delivery path.
      return;
    }
    final responseId = map['id'];
    final completer = _pending.remove(responseId);
    if (completer == null) {
      // A response with no matching in-flight request — expected when a
      // slow handler finishes AFTER sendRequest()'s timeout already fired
      // and removed the entry (not necessarily a bug), so log-and-drop
      // rather than throw.
      _log(
        '[http] session ${sessionLogHandle(id)}: received a response for '
        'id=$responseId with no pending request waiting for it (likely '
        'arrived after its own timeout) — dropping',
      );
      return;
    }
    // M3 (2026-08-14 review round 2, see the [lastActivity] field doc): a
    // response landing counts as activity too, not just the request that
    // started it — keeps a session whose request just took longer than
    // sessionTtl from immediately re-qualifying as idle the instant its
    // last in-flight request finishes.
    lastActivity = DateTime.now();
    completer.complete(map);
  }

  static _Session create({
    required String id,
    required MemoryService service,
    required LogSink log,
    required ToolCallSerializer serializer,
  }) {
    final toServer = StreamController<String>();
    final fromServer = StreamController<String>();
    final channel = StreamChannel<String>.withCloseGuarantee(
      toServer.stream,
      fromServer.sink,
    );
    final server = RememboxServer(
      channel,
      service: service,
      log: log,
      serializer: serializer,
    );
    final now = DateTime.now();
    return _Session._(id, server, toServer, fromServer, now, log, now);
  }

  /// Sends [rawBody] (a raw JSON-RPC request string, already containing an
  /// `id`) into the server and returns its decoded JSON-RPC response.
  ///
  /// Times out after [timeout] so a stuck server-side handler cannot hang an
  /// HTTP caller forever without any signal — this would otherwise be a
  /// silent failure mode (contract: no silent failure paths).
  Future<Map<String, Object?>> sendRequest(
    String rawBody,
    Object? id, {
    Duration timeout = const Duration(seconds: 120),
  }) {
    // A client reusing an in-flight JSON-RPC id (2026-08-14, the 2026-07-18
    // HTTP-daemon engineering log (internal), "Review round 1 fixes" finding
    // 4; comment reworded 2026-08-14 review round 2, M2 — see "Review round
    // 2 polish" in the same log): without this check, overwriting
    // `_pending[id]`
    // below would silently orphan the FIRST waiter — its completer becomes
    // unreachable from `_onServerMessage` (a response for `id` can only
    // resolve ONE completer, and the map now points at the second), so it
    // would just sit there until its own timeout fires with no other
    // signal. Detect it, log it (naming the session and id), and resolve
    // the OLD completer with an error immediately rather than making it
    // wait out the full timeout for no reason (no-silent-failure).
    //
    // What this DOES guarantee: the superseded (old) waiter always gets an
    // immediate, logged error — never a silent hang, never a real response
    // it didn't ask for. What this does NOT guarantee: that the surviving
    // (second) waiter receives the response to ITS OWN request.
    // `_onServerMessage` routes purely by JSON-RPC `id` — it has no notion
    // of "which HTTP call this response belongs to" — so whichever server
    // response carrying this `id` arrives first resolves whatever completer
    // currently occupies `_pending[id]` at that moment. In the common case
    // that is the surviving waiter's own response, but nothing here enforces
    // it: a THIRD reuse of the same id before the second's response lands
    // would repeat this supersession against the second waiter too, and an
    // out-of-order server reply (the in-flight request that originally held
    // this id responds AFTER the one that superseded it) would hand the
    // surviving waiter a response that was never meant for it. This is
    // best-effort routing for a protocol-violating client (JSON-RPC ids
    // must be unique per outstanding request); the only guarantees this
    // transport makes are no leaked completer and no silent hang. Pinned by
    // test/http_transport_test.dart 'a duplicate in-flight request id on
    // one session supersedes the first waiter with a logged error'.
    // Handle, not raw id, in both the log line and the thrown messages below
    // (2026-09-07, Fix 3, the 2026-09-07 daemon-auth engineering log
    // (internal) — see [sessionLogHandle] doc): the StateError's message is
    // relayed verbatim
    // to the HTTP caller AND logged by RememboxHttpDaemon._handlePost's `on
    // StateError` branch, so leaving the raw id in it would defeat the
    // point of hashing it everywhere else.
    final selfHandle = sessionLogHandle(this.id);
    final superseded = _pending.remove(id);
    if (superseded != null) {
      _log(
        '[http] session $selfHandle: duplicate in-flight request id=$id — '
        'the previous request waiting on this id is being superseded '
        '(client reused an id before the first response arrived)',
      );
      if (!superseded.isCompleted) {
        superseded.completeError(
          StateError(
            'request id=$id superseded by a duplicate id from session '
            '$selfHandle',
          ),
        );
      }
    }
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _toServer.add(rawBody);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(
          'session $selfHandle: no response for request id=$id within '
          '$timeout',
        );
      },
    );
  }

  /// Sends [rawBody] (a raw JSON-RPC notification string, no `id`) into the
  /// server. Fire-and-forget — notifications never get a response.
  void sendNotification(String rawBody) => _toServer.add(rawBody);

  Future<void> dispose() async {
    await server.shutdown();
    await _fromServerSub.cancel();
    if (!_toServer.isClosed) await _toServer.close();
    if (!_fromServer.isClosed) await _fromServer.close();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        // Handle, not raw id (S2 fix — same rationale as sendRequest's
        // duplicate-id branch above: this error is relayed verbatim to
        // the HTTP caller and logged by RememboxHttpDaemon._handlePost's
        // `on StateError` branch).
        pending.completeError(
          StateError('session ${sessionLogHandle(id)} disposed'),
        );
      }
    }
    _pending.clear();
  }
}

/// Standard JSON-RPC 2.0 error codes used by this transport.
const int _jsonRpcParseError = -32700;
const int _jsonRpcInvalidRequest = -32600;

Map<String, Object?> _rpcError(int code, String message) => {
  'jsonrpc': '2.0',
  'id': null,
  'error': {'code': code, 'message': message},
};

/// The streamable-HTTP MCP daemon: owns an `HttpServer` bound to
/// `127.0.0.1`, bridges POST/DELETE `/mcp` traffic to per-session
/// [RememboxServer] instances, and periodically garbage-collects idle
/// sessions.
///
/// Testable in isolation from `bin/remembox.dart`'s CLI/env wiring: pass a
/// pre-built [MemoryService] (tests use the existing `FakeEmbedder` seam) and
/// call [start] with `port: 0` for an ephemeral port.
class RememboxHttpDaemon {
  final MemoryService service;
  final LogSink log;
  final ToolCallSerializer serializer;
  final Duration sessionTtl;
  final Duration sweepInterval;

  /// Max concurrent sessions before `initialize` starts evicting or (if
  /// nothing is evictable) returning 503 (DoS hygiene, not the security
  /// boundary — see [defaultMaxSessions] doc; eviction is Fix 3, 2026-09-07,
  /// the 2026-09-07 daemon-auth engineering log (internal)).
  final int maxSessions;

  /// Max bytes read from a single POST body before it is rejected with 413
  /// (DoS hygiene, not the security boundary — see [defaultMaxBodyBytes]
  /// doc).
  final int maxBodyBytes;

  /// Required bearer token (Fix 1, 2026-09-07, the 2026-09-07 daemon-auth
  /// engineering log, internal) — every request must present it via an
  /// `Authorization: Bearer` header carrying this value, compared with
  /// [constantTimeEquals]. Never logged.
  /// Must be non-empty; enforced in the constructor body (not `assert`,
  /// which is stripped from AOT release builds — see `tool/build.sh` — and
  /// so would silently do nothing in the actual shipped binary).
  final String token;

  final math.Random _random;

  HttpServer? _httpServer;
  Timer? _gcTimer;
  final Map<String, _Session> _sessions = {};
  int _totalSessions = 0;
  int _totalRequests = 0;

  /// Rate-limiter state for pre-auth/auth rejection logging — originally
  /// 401-only (Fix 1: "one logged line per rejection... rate-limit to
  /// avoid flooding"), generalized N-5 (2026-09-07 security-review
  /// re-verification) to also cover the 403 Host and 403 Origin rejection
  /// paths in [_handleRequest]: those two log lines ran BEFORE the 401
  /// check and therefore before any authentication at all, so an
  /// unauthenticated caller sending a flood of requests with a bad Host
  /// or Origin header (300 requests with a 400-char Origin grew the log
  /// by 78,900 bytes, unrate-limited) had an even cheaper amplification
  /// than a bad bearer token. Keyed by `"<remotePort>:<rejectionClass>"`
  /// (see [_rateLimiterKey]) rather than remote port alone, so a flood of
  /// one rejection class from a port does not suppress logging of an
  /// unrelated class from the same port — see [_logRateLimitedRejection].
  /// Pruned periodically by [_pruneRejectionRateLimiter] so a long-running
  /// daemon fielding rejections from many distinct ephemeral ports does
  /// not accumulate these maps forever.
  final Map<String, DateTime> _lastRejectLog = {};
  final Map<String, int> _suppressedRejects = {};

  /// How long a rate-limiter entry survives with no further rejections of
  /// its class from its port before [_pruneRejectionRateLimiter] removes
  /// it (flushing any suppressed-count summary first — no silent drop).
  static const Duration _authRateLimiterEntryTtl = Duration(minutes: 5);

  RememboxHttpDaemon({
    required this.service,
    required this.token,
    this.log = stderrLog,
    ToolCallSerializer? serializer,
    this.sessionTtl = const Duration(seconds: 1800),
    this.sweepInterval = const Duration(seconds: 30),
    this.maxSessions = defaultMaxSessions,
    this.maxBodyBytes = defaultMaxBodyBytes,
    math.Random? random,
  }) : serializer = serializer ?? ToolCallSerializer(),
       _random = random ?? math.Random.secure() {
    // Fail loud, in the constructor body (not `assert`) — see [token] doc.
    // Callers are expected to have already validated this via
    // [resolveHttpToken] (bin/remembox.dart); this is defense in depth for
    // any other caller (including tests) that constructs the daemon
    // directly with an empty token by mistake.
    if (token.isEmpty) {
      throw ArgumentError(
        'RememboxHttpDaemon requires a non-empty token (see '
        'resolveHttpToken / OBX_MEMORY_HTTP_TOKEN) — refusing to construct '
        'an unauthenticated daemon.',
      );
    }
  }

  /// Bound port after [start] — throws [StateError] before [start] is
  /// called.
  int get port {
    final server = _httpServer;
    if (server == null) {
      throw StateError('RememboxHttpDaemon.start() has not been called yet');
    }
    return server.port;
  }

  /// Number of sessions currently tracked (for tests/diagnostics).
  int get sessionCount => _sessions.length;

  Future<int> start({String address = '127.0.0.1', int port = 3927}) async {
    if (_httpServer != null) {
      throw StateError('RememboxHttpDaemon.start() already called');
    }
    final server = await HttpServer.bind(address, port);
    _httpServer = server;
    log('[http] listening on http://$address:${server.port}/mcp');
    server.listen(
      _handleRequest,
      onError: (Object err, StackTrace stack) {
        // HttpServer-level errors (e.g. a client resetting a connection
        // mid-read) must not crash the daemon or vanish silently.
        log('[http] listener error (non-fatal, continuing): $err\n$stack');
      },
    );
    _gcTimer = Timer.periodic(sweepInterval, (_) {
      _sweepIdleSessions();
      _pruneRejectionRateLimiter();
    });
    return server.port;
  }

  Future<void> stop() async {
    _gcTimer?.cancel();
    _gcTimer = null;
    final server = _httpServer;
    if (server != null) {
      await server.close(force: true);
    }
    final ids = _sessions.keys.toList();
    for (final id in ids) {
      await _disposeSession(id, reason: 'daemon shutdown');
    }
    log(
      '[http] daemon stopped — served $_totalSessions session(s), '
      '$_totalRequests request(s) total',
    );
  }

  void _sweepIdleSessions() {
    final now = DateTime.now();
    final stale = <String>[];
    for (final entry in _sessions.entries) {
      if (now.difference(entry.value.lastActivity) <= sessionTtl) continue;
      if (entry.value.hasPendingRequests) {
        // Mid-flight GC guard (2026-08-14 review round 2, M3, the 2026-07-18
        // HTTP-daemon engineering log (internal), "Review round 2 polish" —
        // see the `_Session.lastActivity` field doc): `lastActivity` alone
        // cannot tell a genuinely idle session from one whose single
        // request has simply been running longer than sessionTtl (only
        // reachable with a misconfigured tiny
        // OBX_MEMORY_HTTP_SESSION_TTL_SECONDS). Disposing it here would
        // silently abort that in-flight request from the HTTP caller's
        // perspective. Skip disposal while requests are pending — logged,
        // since this is the only place that would otherwise notice a
        // session outliving its TTL.
        log(
          '[http] session ${sessionLogHandle(entry.key)} is past its idle '
          'TTL ($sessionTtl) but has ${entry.value.pendingRequestCount} '
          'request(s) still in flight — keeping it alive until they '
          'complete (next sweep in $sweepInterval will re-check)',
        );
        continue;
      }
      stale.add(entry.key);
    }
    for (final id in stale) {
      // Every disposal is logged — sessions "often vanish without DELETE"
      // (Claude Code client can simply stop making requests), so this sweep
      // is the ONLY place that ever notices — must not be silent.
      unawaited(_disposeSession(id, reason: 'idle timeout ($sessionTtl)'));
    }
  }

  /// Prunes stale entries from the rejection rate-limiter maps (Fix 1,
  /// generalized N-5 — see [_lastRejectLog] doc), flushing any
  /// still-pending suppressed count as one final log line first —
  /// no-silent-drop applies to the pruning itself, not just the rate
  /// limiting.
  void _pruneRejectionRateLimiter() {
    final now = DateTime.now();
    final staleKeys = <String>[];
    for (final entry in _lastRejectLog.entries) {
      if (now.difference(entry.value) > _authRateLimiterEntryTtl) {
        staleKeys.add(entry.key);
      }
    }
    for (final key in staleKeys) {
      _lastRejectLog.remove(key);
      final suppressed = _suppressedRejects.remove(key);
      if (suppressed != null && suppressed > 0) {
        log(
          '[http] rejection rate-limiter: flushing $suppressed suppressed '
          'rejection(s) for $key before pruning its stale rate-limit entry '
          '(no activity for $_authRateLimiterEntryTtl)',
        );
      }
    }
  }

  /// Session-id logging discipline (Fix 3, 2026-09-07, the 2026-09-07
  /// daemon-auth engineering log, internal): every log line naming a
  /// session uses
  /// [sessionLogHandle], never the raw id — see that function's doc.
  Future<void> _disposeSession(String id, {required String reason}) async {
    final session = _sessions.remove(id);
    if (session == null) return;
    await session.dispose();
    log('[http] session ${sessionLogHandle(id)} disposed ($reason)');
  }

  String _newSessionId() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Finds the oldest session that has served zero requests since its own
  /// `initialize` (Fix 3, see `_Session.postInitRequestCount` doc) — the
  /// eviction candidate at the session cap. Returns null if every current
  /// session has real traffic, in which case the cap falls back to 503.
  ///
  /// S6 (2026-09-08 pre-publication audit): `_handleInitialize` adds a
  /// brand-new session to `_sessions` BEFORE awaiting its own initialize
  /// handshake (`session.sendRequest`) — so a session whose own
  /// `initialize` is still in flight has `postInitRequestCount == 0` (that
  /// counter is only touched by `_handlePost`, which the initialize
  /// request itself never goes through) and used to look identical to a
  /// genuinely idle/abandoned session. A burst of concurrent `initialize`
  /// calls at the cap could therefore evict a legitimate client mid
  /// handshake instead of an actually-idle one. `hasPendingRequests`
  /// (`_pending.isNotEmpty`) is true for exactly that in-flight window, so
  /// skip those sessions too.
  String? _findEvictionCandidate() {
    String? bestId;
    DateTime? bestCreatedAt;
    for (final entry in _sessions.entries) {
      final session = entry.value;
      if (session.postInitRequestCount != 0) continue;
      if (session.hasPendingRequests) continue;
      if (bestCreatedAt == null || session.createdAt.isBefore(bestCreatedAt)) {
        bestId = entry.key;
        bestCreatedAt = session.createdAt;
      }
    }
    return bestId;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _totalRequests++;
    try {
      // Fix 2 + Fix 1 (2026-09-07, the 2026-09-07 daemon-auth engineering
      // log (internal)): checked before ANY routing or body parsing, and in
      // this specific
      // order — Host/Origin are cheap header-only checks that reject
      // browser-originated traffic (DNS rebinding, cross-origin) before we
      // even consider whether a bearer token was presented; an
      // unauthenticated caller therefore never learns whether `/mcp` (or
      // any other path) exists.
      final hostHeader = request.headers.value(HttpHeaders.hostHeader);
      if (!_isLoopbackHost(hostHeader)) {
        // N-5 (2026-09-07 security-review re-verification): this rejection
        // is pre-auth and was previously logged unconditionally — an
        // unauthenticated flood of bad-Host requests could grow the log
        // without bound. Rate-limited the same way as the 401 path below.
        _logRateLimitedRejection(
          request,
          '403-host',
          '[http] 403 rejected: non-loopback Host header '
              '${_sanitizeHeaderForLog(hostHeader)}',
        );
        await _respond(
          request,
          HttpStatus.forbidden,
          _rpcError(-32000, 'Host header must name loopback'),
        );
        return;
      }
      final originHeader = request.headers.value('origin');
      if (!_isAllowedOrigin(originHeader)) {
        // N-5: same rate-limiting rationale as the Host check above.
        _logRateLimitedRejection(
          request,
          '403-origin',
          '[http] 403 rejected: non-loopback Origin header '
              '${_sanitizeHeaderForLog(originHeader)}',
        );
        await _respond(
          request,
          HttpStatus.forbidden,
          _rpcError(-32000, 'Origin not allowed'),
        );
        return;
      }
      if (!_isAuthorized(request)) {
        _logAuthRejection(request);
        await _respond(
          request,
          HttpStatus.unauthorized,
          _rpcError(-32001, 'unauthorized'),
        );
        return;
      }
      if (request.uri.path != '/mcp') {
        await _respond(request, HttpStatus.notFound, null);
        return;
      }
      switch (request.method) {
        case 'POST':
          await _handlePost(request);
          break;
        case 'DELETE':
          await _handleDelete(request);
          break;
        case 'GET':
          // Spec-allowed: a server with no server-initiated messages may
          // refuse the SSE stream outright.
          request.response.headers.set('Allow', 'POST, DELETE');
          await _respond(request, HttpStatus.methodNotAllowed, null);
          break;
        default:
          request.response.headers.set('Allow', 'POST, DELETE');
          await _respond(request, HttpStatus.methodNotAllowed, null);
      }
    } catch (err, stack) {
      // Catch-all around one request must never take down the listener or
      // silently drop the client's connection without a response.
      log('[http] request handler error: $err\n$stack');
      try {
        await _respond(
          request,
          HttpStatus.internalServerError,
          _rpcError(-32603, 'internal error'),
        );
      } catch (_) {
        // Response stream may already be broken (client disconnected) —
        // nothing more we can do; the outer log line already captured it.
      }
    }
  }

  /// Fix 2 (DNS-rebinding defense, the 2026-09-07 daemon-auth engineering
  /// log (internal)): true iff [hostHeader] names loopback (`127.0.0.1`,
  /// `localhost`, or
  /// `[::1]`/`::1`), with an optional trailing `:port` ignored. A DNS name
  /// that resolves to `127.0.0.1` only at the moment of connection
  /// (attacker-controlled — "rebound" after a browser's same-origin check
  /// already passed against a different, attacker-owned answer) still
  /// carries its ORIGINAL name in this header, unaffected by which IP the
  /// TCP connection actually landed on — checking it is what closes the
  /// rebinding gap; binding the socket to 127.0.0.1 alone does not.
  ///
  /// N-9 (2026-09-07 security-review re-verification), two bugs fixed:
  ///
  /// 1. **A bare (unbracketed) IPv6 literal was dead code.** `Host: ::1`
  ///    contains two colons; the old `lastIndexOf(':')` split it into host
  ///    `::` + bogus "port" `1`, which never matched the `case '::1':`
  ///    below — so a real client sending a bare `::1` (`curl -H "Host:
  ///    ::1"`, or any client that does not bracket per RFC 3986) was
  ///    rejected as non-loopback. Fixed by treating an unbracketed header
  ///    with MORE THAN ONE colon as a bare IPv6 literal with no port
  ///    (single-colon headers are still `host:port`, e.g. IPv4/hostname).
  /// 2. **Userinfo/path-shaped headers were not rejected.** `Host:
  ///    localhost:39271@evil.com` split on `lastIndexOf(':')` into host
  ///    `localhost` (matching the loopback case) with "port"
  ///    `39271@evil.com` — the loopback check passed for a header that, in
  ///    the userinfo@host grammar a browser or naive downstream consumer
  ///    might apply to it, actually names `evil.com`. Fixed by rejecting
  ///    outright any header containing `@` or `/` before parsing at all.
  bool _isLoopbackHost(String? hostHeader) {
    if (hostHeader == null || hostHeader.isEmpty) return false;
    if (hostHeader.contains('@') || hostHeader.contains('/')) return false;
    String hostOnly;
    if (hostHeader.startsWith('[')) {
      // IPv6 literal, e.g. "[::1]:3927" or bare "[::1]".
      final end = hostHeader.indexOf(']');
      hostOnly = end == -1 ? hostHeader : hostHeader.substring(0, end + 1);
    } else if (':'.allMatches(hostHeader).length > 1) {
      // N-9: an unbracketed header with more than one colon is a bare
      // IPv6 literal (e.g. "::1") — take it whole, no port to strip.
      hostOnly = hostHeader;
    } else {
      final colon = hostHeader.lastIndexOf(':');
      hostOnly = colon == -1 ? hostHeader : hostHeader.substring(0, colon);
    }
    switch (hostOnly.toLowerCase()) {
      case 'localhost':
      case '127.0.0.1':
      case '[::1]':
      case '::1':
        return true;
      default:
        return false;
    }
  }

  /// Fix 2: true iff [originHeader] is absent (real MCP clients — this
  /// bridge's `dart_mcp` `Peer`, `curl`, etc. — never send one; only a
  /// browser page does, and cannot be made to omit it) or loopback. A
  /// PRESENT non-loopback Origin — including the literal string `"null"`,
  /// which browsers send for sandboxed/opaque contexts — is rejected
  /// outright; this daemon has no legitimate cross-origin caller, so there
  /// is no allowlist to maintain.
  bool _isAllowedOrigin(String? originHeader) {
    if (originHeader == null || originHeader.isEmpty) return true;
    if (originHeader == 'null') return false;
    Uri uri;
    try {
      uri = Uri.parse(originHeader);
    } on FormatException {
      return false;
    }
    switch (uri.host.toLowerCase()) {
      case 'localhost':
      case '127.0.0.1':
      case '::1':
        return true;
      default:
        return false;
    }
  }

  static const String _bearerPrefix = 'Bearer ';

  /// Fix 1: true iff [request] carries `Authorization: Bearer <token>`
  /// matching [token], compared with [constantTimeEquals].
  ///
  /// N-10 (2026-09-07 security-review re-verification): RFC 7235 §2.1
  /// defines the auth-scheme token ("Bearer") as case-insensitive, but the
  /// original `header.startsWith(_bearerPrefix)` was a case-SENSITIVE
  /// match — a client sending `Authorization: bearer <token>` (valid per
  /// the RFC) was rejected as unauthorized. Only the SCHEME prefix is
  /// case-folded for comparison; the presented token keeps its exact
  /// original bytes into [constantTimeEquals].
  bool _isAuthorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || header.length < _bearerPrefix.length) return false;
    final scheme = header.substring(0, _bearerPrefix.length).toLowerCase();
    if (scheme != _bearerPrefix.toLowerCase()) return false;
    final presented = header.substring(_bearerPrefix.length);
    return constantTimeEquals(presented, token);
  }

  /// Rate-limiter key for [_lastRejectLog]/[_suppressedRejects]: remote
  /// port + rejection class, so a flood of one class (say, bad Host
  /// headers) from a port does not suppress logging of a DIFFERENT class
  /// (say, a bad bearer token) from that same port.
  String _rateLimiterKey(HttpRequest request, String rejectionClass) {
    final remotePort = request.connectionInfo?.remotePort ?? -1;
    return '$remotePort:$rejectionClass';
  }

  /// Logs a rejection at most once per second per (remote port, rejection
  /// class) (Fix 1: "rate-limit the log to avoid flooding... no silent
  /// drop"; generalized N-5, 2026-09-07 security-review re-verification,
  /// from 401-only to also cover the pre-auth 403 Host/Origin rejections
  /// in [_handleRequest] — those ran unconditionally and unrate-limited,
  /// so 300 unauthenticated POSTs with a 400-char Origin grew the log by
  /// 78,900 bytes). Rejections suppressed within that window are counted,
  /// not dropped — the count is folded into the next line that IS logged
  /// for that (port, class) pair (or flushed by
  /// [_pruneRejectionRateLimiter] if it goes quiet). [message] is the full
  /// line to log (already built by the caller, e.g. with the sanitized
  /// header value) when this rejection is NOT suppressed.
  void _logRateLimitedRejection(
    HttpRequest request,
    String rejectionClass,
    String message,
  ) {
    final key = _rateLimiterKey(request, rejectionClass);
    final now = DateTime.now();
    final last = _lastRejectLog[key];
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      _suppressedRejects[key] = (_suppressedRejects[key] ?? 0) + 1;
      return;
    }
    final suppressed = _suppressedRejects.remove(key) ?? 0;
    _lastRejectLog[key] = now;
    final suffix =
        suppressed > 0
            ? ' ($suppressed similar rejection(s) from this port in the '
                'last second suppressed, not individually logged, to avoid '
                'flooding)'
            : '';
    log('$message$suffix');
  }

  /// Logs a 401 rejection — see [_logRateLimitedRejection].
  void _logAuthRejection(HttpRequest request) {
    _logRateLimitedRejection(
      request,
      '401',
      '[http] 401 rejected: missing or invalid bearer token',
    );
  }

  /// Truncates and control-character-strips an untrusted header value
  /// before it goes into the log (Fix 2: "log the rejected origin,
  /// sanitized, truncated") — bounds how much log space one rejected
  /// request can consume and defangs anything that slipped past dart:io's
  /// own header parsing.
  String _sanitizeHeaderForLog(String? value, {int maxLen = 200}) {
    if (value == null) return '(none)';
    final cleaned = value.replaceAll(RegExp('[\x00-\x1f\x7f]'), '?');
    return cleaned.length > maxLen
        ? '${cleaned.substring(0, maxLen)}…(truncated)'
        : cleaned;
  }

  Future<void> _handlePost(HttpRequest request) async {
    // Fix 2 (2026-09-07, the 2026-09-07 daemon-auth engineering log
    // (internal)): a POST without `Content-Type: application/json` (charset
    // suffix allowed —
    // ContentType.mimeType strips it) is rejected before we read a single
    // body byte. This alone kills the vector the 2026-09-07 security review
    // used: `Content-Type: text/plain` is one of the three MIME types a
    // browser can send in a "simple" (non-preflighted) cross-origin POST,
    // so requiring `application/json` forces a real CORS preflight — which
    // this daemon never answers with an Access-Control-Allow-Origin header,
    // so a browser-based cross-origin caller can never get a body through
    // regardless of the Origin check above.
    final contentType = request.headers.contentType;
    if (contentType == null || contentType.mimeType != 'application/json') {
      log(
        '[http] 415 rejected: POST Content-Type was '
        '${_sanitizeHeaderForLog(request.headers.value(HttpHeaders.contentTypeHeader))}, '
        'must be application/json',
      );
      await _respond(
        request,
        HttpStatus.unsupportedMediaType,
        _rpcError(-32002, 'Content-Type must be application/json'),
      );
      return;
    }
    // Request-body size cap (2026-08-14, "Review round 1 fixes" finding
    // 5b): count bytes WHILE STREAMING and stop reading as soon as the cap
    // is exceeded, rather than buffering the full body first and checking
    // its size afterwards — a client sending an unbounded body must not be
    // able to make this daemon hold an unbounded amount of memory even
    // transiently. `await for ... break` cancels the underlying chunk
    // subscription, so nothing past the cap is ever accumulated.
    final bytesBuilder = BytesBuilder(copy: false);
    var tooLarge = false;
    try {
      await for (final chunk in request) {
        bytesBuilder.add(chunk);
        if (bytesBuilder.length > maxBodyBytes) {
          tooLarge = true;
          break;
        }
      }
    } catch (err) {
      log('[http] failed reading request body: $err');
      await _respond(
        request,
        HttpStatus.badRequest,
        _rpcError(_jsonRpcParseError, 'Parse error'),
      );
      return;
    }
    if (tooLarge) {
      log(
        '[http] request body exceeded the $maxBodyBytes-byte cap '
        '(OBX_MEMORY_HTTP_MAX_BODY_BYTES) — rejecting with 413, did not '
        'buffer the remainder of the body',
      );
      await _respond(
        request,
        HttpStatus.requestEntityTooLarge,
        _rpcError(
          -32600,
          'request body exceeds the $maxBodyBytes-byte limit '
          '(OBX_MEMORY_HTTP_MAX_BODY_BYTES)',
        ),
      );
      return;
    }
    final String body;
    try {
      body = utf8.decode(bytesBuilder.takeBytes());
    } on FormatException catch (err) {
      log('[http] failed decoding request body as UTF-8: $err');
      await _respond(
        request,
        HttpStatus.badRequest,
        _rpcError(_jsonRpcParseError, 'Parse error'),
      );
      return;
    }

    late final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (err) {
      log('[http] malformed JSON body: $err');
      await _respond(
        request,
        HttpStatus.badRequest,
        _rpcError(_jsonRpcParseError, 'Parse error'),
      );
      return;
    }
    if (decoded is! Map) {
      await _respond(
        request,
        HttpStatus.badRequest,
        _rpcError(_jsonRpcInvalidRequest, 'Invalid Request'),
      );
      return;
    }
    final message = decoded.cast<String, Object?>();
    final method = message['method'];
    // A literal `"id": null` is treated the same as an absent `id` — i.e.
    // as a notification, not a request awaiting a reply (2026-08-14 review
    // round 2, N1, the 2026-07-18 HTTP-daemon engineering log (internal),
    // "Review round 2 polish"). This matches the JSON-RPC 2.0 spec, which
    // reserves `id:
    // null` for notifications and states a request id "SHOULD NOT be
    // Null" — so a spec-compliant client never sends `"id": null` on a
    // request expecting a response, and this daemon does not attempt to
    // reply to one that does.
    final hasId = message.containsKey('id') && message['id'] != null;

    if (method == 'initialize') {
      await _handleInitialize(request, body, message);
      return;
    }

    final sessionId = request.headers.value('Mcp-Session-Id');
    if (sessionId == null || sessionId.isEmpty) {
      await _respond(
        request,
        HttpStatus.badRequest,
        _rpcError(
          _jsonRpcInvalidRequest,
          'Mcp-Session-Id header is required for non-initialize requests',
        ),
      );
      return;
    }
    final session = _sessions[sessionId];
    if (session == null) {
      await _respond(request, HttpStatus.notFound, null);
      return;
    }
    session.lastActivity = DateTime.now();
    // Fix 3 (2026-09-07, the 2026-09-07 daemon-auth engineering log
    // (internal)): any POST that reaches an existing session (request OR
    // notification) counts as
    // "used since initialize" — see `_Session.postInitRequestCount` doc.
    // Incremented here, at request START (same point as `lastActivity`
    // above), so a session with a slow request already in flight is never
    // mistaken for "never used" by `_findEvictionCandidate`.
    session.postInitRequestCount++;

    if (method == null) {
      await _respond(
        request,
        HttpStatus.badRequest,
        _rpcError(_jsonRpcInvalidRequest, 'Invalid Request'),
      );
      return;
    }

    if (!hasId) {
      // Notification (e.g. notifications/initialized, notifications/
      // cancelled): forward, no response body expected.
      session.sendNotification(body);
      await _respond(request, HttpStatus.accepted, null);
      return;
    }

    // Request: forward and wait for the matching response, then relay it
    // verbatim as the HTTP response.
    try {
      final response = await session.sendRequest(body, message['id']);
      await _respond(request, HttpStatus.ok, response);
    } on TimeoutException catch (err) {
      log('[http] $err');
      await _respond(
        request,
        HttpStatus.internalServerError,
        _rpcError(-32603, err.message ?? 'request timed out'),
      );
    } on StateError catch (err) {
      // Superseded by a later request reusing the same in-flight id (see
      // _Session.sendRequest, finding 4) — already logged there; respond
      // with the specific reason instead of falling through to
      // _handleRequest's generic "internal error" catch-all.
      log('[http] $err');
      await _respond(
        request,
        HttpStatus.internalServerError,
        _rpcError(-32603, err.message),
      );
    }
  }

  Future<void> _handleInitialize(
    HttpRequest request,
    String rawBody,
    Map<String, Object?> message,
  ) async {
    // Session cap (2026-08-14, "Review round 1 fixes" finding 5a): refuse a
    // new session rather than let an unbounded number of them accumulate —
    // each holds a live RememboxServer instance and duplex channel. Hygiene
    // on top of loopback binding, not a replacement for it (see
    // [defaultMaxSessions] doc). 2026-09-07 (Fix 3, the 2026-09-07
    // daemon-auth engineering log, internal): before rejecting, try to
    // evict the oldest session
    // that has served zero requests since ITS OWN initialize — an
    // attacker's abandoned session or a dead client's — so a burst of
    // never-used sessions cannot lock out a legitimate new client. Only
    // fall back to 503 when no session qualifies.
    if (_sessions.length >= maxSessions) {
      final victimId = _findEvictionCandidate();
      if (victimId != null) {
        await _disposeSession(
          victimId,
          reason:
              'evicted to admit a new session — cap ($maxSessions, '
              'OBX_MEMORY_HTTP_MAX_SESSIONS) reached and this was the '
              'oldest session with 0 requests served since initialize',
        );
      } else {
        log(
          '[http] session cap reached ($maxSessions, '
          'OBX_MEMORY_HTTP_MAX_SESSIONS) and every current session has '
          'real traffic (none evictable) — rejecting new initialize with '
          '503',
        );
        await _respond(
          request,
          HttpStatus.serviceUnavailable,
          _rpcError(
            -32000,
            'server busy: max concurrent sessions ($maxSessions, '
            'OBX_MEMORY_HTTP_MAX_SESSIONS) reached',
          ),
        );
        return;
      }
    }
    final id = message['id'];
    final sessionId = _newSessionId();
    final session = _Session.create(
      id: sessionId,
      service: service,
      log: log,
      serializer: serializer,
    );
    _sessions[sessionId] = session;
    _totalSessions++;
    log('[http] session ${sessionLogHandle(sessionId)} created (initialize)');

    try {
      final response = await session.sendRequest(rawBody, id);
      request.response.headers.set('Mcp-Session-Id', sessionId);
      await _respond(request, HttpStatus.ok, response);
    } on TimeoutException catch (err) {
      log(
        '[http] $err — disposing session ${sessionLogHandle(sessionId)}',
      );
      await _disposeSession(sessionId, reason: 'initialize timed out');
      await _respond(
        request,
        HttpStatus.internalServerError,
        _rpcError(-32603, err.message ?? 'initialize timed out'),
      );
    }
  }

  Future<void> _handleDelete(HttpRequest request) async {
    final sessionId = request.headers.value('Mcp-Session-Id');
    if (sessionId == null || sessionId.isEmpty) {
      await _respond(
        request,
        HttpStatus.badRequest,
        _rpcError(_jsonRpcInvalidRequest, 'Mcp-Session-Id header is required'),
      );
      return;
    }
    if (!_sessions.containsKey(sessionId)) {
      await _respond(request, HttpStatus.notFound, null);
      return;
    }
    await _disposeSession(sessionId, reason: 'client DELETE');
    await _respond(request, HttpStatus.ok, null);
  }

  Future<void> _respond(
    HttpRequest request,
    int status,
    Map<String, Object?>? body,
  ) async {
    request.response.statusCode = status;
    if (body != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
    }
    await request.response.close();
  }
}
