/// Deterministic in-memory [Embedder] for tests: no network, no Ollama.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:remembox/src/embedder.dart';

/// Deterministic fake: vectors derive from a SHA-256 of the text, unless a
/// vector was explicitly registered for that text (which lets tests control
/// exact similarities).
class FakeEmbedder implements Embedder {
  @override
  final String modelId;
  @override
  final int dims;

  /// Number of dims actually emitted (defaults to [dims]); tests set this
  /// differently to provoke the dimension-mismatch error path.
  final int emitDims;

  final Map<String, List<double>> _registered = {};

  /// Embed calls observed (for asserting embedding happened / was skipped).
  final List<String> calls = [];

  /// When set, every embed throws — simulates Ollama being down.
  EmbedderException? failWith;

  /// Optional artificial delay before returning, via [Future.delayed] (a
  /// REAL event-loop yield, unlike a bare `async` function with no I/O).
  /// Used to reproduce FIX-1's tool-interleaving race in tests: the
  /// production [OllamaEmbedder] awaits real HTTP I/O, which yields the
  /// event loop mid-`remember()` — a plain `async` fake that never
  /// truly suspends does NOT reproduce that race, so tests that need to
  /// exercise it opt in with this delay.
  ///
  /// Only applied to the FIRST [embed] call (i.e. the one `remember()`
  /// makes) so a subsequent `recall()` call's embed resolves immediately —
  /// this reliably wins the race against the delayed call's continuation
  /// (two equal delays would instead preserve program order via the timer
  /// queue and never reproduce the interleaving).
  final Duration embedDelay;

  /// 2026-09-01 (Store-Gate, the 2026-09-01 store-gate engineering log
  /// (internal), WP6): fired synchronously on every [embed] call, BEFORE
  /// the delay/failure/
  /// vector logic below. The store-gate contract requires embedding to run
  /// UNLOCKED — a regression that moved an `embed()` call back inside a
  /// `gate.withStore(...)` lending would otherwise pass every functional
  /// test (the vectors would still be correct) while silently reintroducing
  /// the exact per-request latency/serialization hazard WP4 exists to
  /// remove. Tests assert against this hook (typically checking
  /// `StoreGate.debugLendingOpen == false`) rather than any behavior visible
  /// through the returned vector, so this class of regression is caught
  /// even though it produces no wrong ANSWER, only a wrong SHAPE.
  void Function()? onEmbed;

  int _embedCallCount = 0;

  FakeEmbedder({
    this.modelId = 'fake-embedder',
    this.dims = 768,
    int? emitDims,
    this.embedDelay = Duration.zero,
    this.onEmbed,
  }) : emitDims = emitDims ?? dims;

  /// Registers an exact (normalized) vector for [text].
  void register(String text, List<double> vector) {
    _registered[text] = normalize(vector);
  }

  /// A unit vector in the plane of axes 0/1 at [degrees] from axis 0 —
  /// cosine similarity between two such vectors is cos(delta degrees).
  List<double> planeVector(double degrees, {int? length}) {
    final radians = degrees * math.pi / 180.0;
    final v = List<double>.filled(length ?? emitDims, 0.0);
    v[0] = math.cos(radians);
    v[1] = math.sin(radians);
    return v;
  }

  static List<double> normalize(List<double> v) {
    final norm = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
    if (norm == 0) return v;
    return [for (final x in v) x / norm];
  }

  @override
  Future<List<double>> embed(String text) async {
    onEmbed?.call();
    calls.add(text);
    _embedCallCount++;
    if (embedDelay > Duration.zero && _embedCallCount == 1) {
      await Future.delayed(embedDelay);
    }
    final failure = failWith;
    if (failure != null) throw failure;
    final registered = _registered[text];
    if (registered != null) return registered;
    // Hash-derived pseudo-random unit vector, stable per text.
    final digest = sha256.convert(utf8.encode(text)).bytes;
    final v = List<double>.generate(
      emitDims,
      (i) => (digest[(i * 7) % digest.length] / 255.0) - 0.5,
    );
    return normalize(v);
  }
}
