import 'dart:async';

import 'package:flutter/foundation.dart';

/// Kind of a startup timeline event — drives the tag in the dumped trace.
enum StartupTraceKind { db, tx, fs, provider, job, ui }

/// One timed span or point event in the chronological startup timeline.
///
/// [startMs] / [endMs] are milliseconds since [StartupTrace.init] (the app
/// launch epoch), so the trace reads as a `+x.xxs` offset. [durMs] is the
/// measured span; for a point [instant] event start == end (durMs == 0).
class StartupEvent {
  final String op;
  final StartupTraceKind kind;
  final int startMs;
  final int endMs;
  final int rows;
  final String? caller;
  final String? detail;

  /// For a DB span: the last DB op that COMPLETED before this one started
  /// (answers "what was running immediately before").
  final String? prevOp;

  /// For a slow DB span: the other DB ops that were still open while this one
  /// ran (answers "what was it concurrent with").
  final List<String> concurrent;

  const StartupEvent({
    required this.op,
    required this.kind,
    required this.startMs,
    required this.endMs,
    this.rows = 0,
    this.caller,
    this.detail,
    this.prevOp,
    this.concurrent = const [],
  });

  int get durMs => endMs - startMs;
  bool get isInstant => endMs == startMs;
}

/// In-flight span handle returned by [StartupTrace.begin].
class _TraceToken {
  final int id;
  final String op;
  final StartupTraceKind kind;
  final int startMs;
  final String? caller;
  final String? prevOp;
  bool live;
  _TraceToken({
    required this.id,
    required this.op,
    required this.kind,
    required this.startMs,
    required this.live,
    this.caller,
    this.prevOp,
  });
}

/// A CHRONOLOGICAL startup timeline recorder — the diagnostic counterpart to
/// [SyncTelemetry]. Where SyncTelemetry keeps per-op AGGREGATES (count / avg /
/// max), this keeps an ordered log of every startup operation with its start,
/// end, duration and (for slow DB spans) its caller and what else was running —
/// exactly what is needed to pin a transient early-launch UI freeze to a
/// specific operation.
///
/// PURELY OBSERVATIONAL: it never changes sync, reads, writes, listeners,
/// providers or startup sequencing. It records only inside the launch window
/// ([recordWindow]); outside it every method short-circuits on a boolean, so
/// the steady-state cost is a single `isActive` check at each call site.
///
/// Usage: call [init] as the FIRST line of `main()`, then wrap operations with
/// [begin] / [end] (timed spans) or [instant] (point events). The trace is
/// auto-dumped to the console via [dump] at [dumpAt]; it can also be dumped on
/// demand at any time.
class StartupTrace {
  StartupTrace._();

  static final StartupTrace instance = StartupTrace._();

  /// Any op slower than this is flagged `SLOW` in the trace.
  static const int slowOpMs = 50;

  /// A DB op slower than this additionally records its caller and the other
  /// DB ops it overlapped (the >80ms attribution the diagnosis asked for).
  static const int dbAttributionMs = 80;

  /// The instrumented launch window. Recording stops after this so the
  /// steady-state hot paths are untouched. Set a little past 15s so the
  /// jobs scheduled at the 15s boundary are still captured.
  static const Duration recordWindow = Duration(seconds: 17);

  /// When the trace is auto-printed to the console.
  static const Duration dumpAt = Duration(seconds: 15);

  /// Hard cap so a pathological notify storm can't grow the buffer unbounded.
  static const int maxEvents = 5000;

  final Stopwatch _clock = Stopwatch();
  DateTime _wallStart = DateTime.now();
  bool _active = false;
  Timer? _dumpTimer;
  Timer? _stopTimer;

  final List<StartupEvent> _events = <StartupEvent>[];
  final List<_TraceToken> _open = <_TraceToken>[];
  final Set<String> _seenKeys = <String>{};
  int _seq = 0;
  int _notifyCount = 0;

  String? _lastDbOp;

  /// Handle used when recording is inactive (id < 0 → [end] is a no-op).
  static final _TraceToken _inactive = _TraceToken(
    id: -1,
    op: '',
    kind: StartupTraceKind.job,
    startMs: 0,
    live: false,
  );

  bool get isActive => _active;

  int _elapsed() => _clock.isRunning ? _clock.elapsedMilliseconds : 0;

  /// Arm the recorder. Call as the first statement of `main()`.
  void init() {
    if (_active) return;
    _wallStart = DateTime.now();
    _clock
      ..reset()
      ..start();
    _active = true;
    instant('process start (main)', StartupTraceKind.job);
    _dumpTimer = Timer(dumpAt, () => dump(log: true));
    _stopTimer = Timer(recordWindow, () {
      _active = false;
      _open.clear();
    });
  }

  /// Cancel the recorder and its timers (tests / early shutdown). No-op on the
  /// production path; kept so the timers can be torn down deterministically.
  void dispose() {
    _dumpTimer?.cancel();
    _stopTimer?.cancel();
    _active = false;
  }

  /// Start a timed span. Pair every [begin] with exactly one [end].
  _TraceToken begin(
    String op, {
    StartupTraceKind kind = StartupTraceKind.db,
    String? caller,
  }) {
    if (!_active) return _inactive;
    final isDb = kind == StartupTraceKind.db || kind == StartupTraceKind.tx;
    final tok = _TraceToken(
      id: _seq++,
      op: op,
      kind: kind,
      startMs: _elapsed(),
      caller: caller,
      live: true,
      // Snapshot the last DB op AS OF THIS START, not as of end.
      prevOp: isDb ? _lastDbOp : null,
    );
    _open.add(tok);
    return tok;
  }

  /// Close a span started by [begin]. Records duration, and for a slow DB span
  /// the caller plus the other DB ops still open (concurrent).
  void end(
    _TraceToken tok, {
    int rows = 0,
    String? detail,
  }) {
    if (!_active || tok.id < 0 || !tok.live) return;
    tok.live = false;
    _open.remove(tok);
    final endMs = _elapsed();
    final durMs = endMs - tok.startMs;
    final isDb = tok.kind == StartupTraceKind.db || tok.kind == StartupTraceKind.tx;
    List<String> concurrent = const [];
    if (isDb && durMs >= dbAttributionMs) {
      concurrent = _open
          .where(
            (o) =>
                (o.kind == StartupTraceKind.db || o.kind == StartupTraceKind.tx) &&
                o.startMs <= endMs,
          )
          .map((o) => '${o.op}(opened +${_s(o.startMs)}s)')
          .toList();
    }
    _add(
      StartupEvent(
        op: tok.op,
        kind: tok.kind,
        startMs: tok.startMs,
        endMs: endMs,
        rows: rows,
        caller: tok.caller,
        detail: detail,
        prevOp: tok.prevOp,
        concurrent: concurrent,
      ),
    );
    if (isDb) _lastDbOp = tok.op;
  }

  /// Record a point event (no duration): a listener attach, a first snapshot,
  /// a scheduled-job fire, etc.
  void instant(
    String op,
    StartupTraceKind kind, {
    String? detail,
    int rows = 0,
  }) {
    if (!_active) return;
    final now = _elapsed();
    _add(
      StartupEvent(
        op: op,
        kind: kind,
        startMs: now,
        endMs: now,
        rows: rows,
        detail: detail,
      ),
    );
  }

  /// True only the FIRST time [key] is seen — for marking a listener's initial
  /// (full-result-set) snapshot apart from later deltas. Uses its own set so it
  /// never disturbs the SyncTelemetry first-emission bookkeeping.
  bool isFirstForKey(String key) => _seenKeys.add(key);

  /// Count a provider notification. Kept as a lightweight counter (not one
  /// event each) so a rebuild storm can't flood the timeline; [dump] reports
  /// the total.
  void notify() {
    if (_active) _notifyCount++;
  }

  void _add(StartupEvent ev) {
    if (_events.length >= maxEvents) return;
    _events.add(ev);
  }

  static String _s(int ms) => (ms / 1000).toStringAsFixed(2);

  /// Assemble the chronological trace. [log] prints it to the console
  /// (logcat on device). Safe to call any time; the buffer is retained until
  /// the window closes.
  String dump({bool log = false}) {
    final events = [..._events]
      ..sort((a, b) {
        final c = a.startMs.compareTo(b.startMs);
        return c != 0 ? c : a.endMs.compareTo(b.endMs);
      });

    final sb = StringBuffer();
    sb.writeln('');
    sb.writeln('═══════════════ STARTUP TRACE ═══════════════');
    sb.writeln(
      'wall=${_wallStart.toIso8601String()}  '
      'events=${events.length}  notifyListeners=$_notifyCount',
    );
    sb.writeln('─────────────── timeline ───────────────');
    for (final e in events) {
      sb.write('+${_s(e.startMs)}s  [${e.kind.name}]  ${e.op}');
      if (e.isInstant) {
        if (e.rows > 0) sb.write('  rows=${e.rows}');
      } else {
        sb.write('  ${e.durMs}ms');
        if (e.rows > 0) sb.write('  rows=${e.rows}');
        final flags = <String>[];
        if (e.durMs >= slowOpMs) flags.add('SLOW>${slowOpMs}ms');
        if (e.caller != null) flags.add('caller=${e.caller}');
        if (e.prevOp != null) flags.add('prev=${e.prevOp}');
        if (e.concurrent.isNotEmpty) flags.add('concurrent=${e.concurrent.join(' & ')}');
        if (flags.isNotEmpty) sb.write('  (${flags.join(', ')})');
      }
      if (e.detail != null) sb.write('  ${e.detail}');
      sb.writeln();
    }

    // Slowest spans + the >80ms DB attributions, pulled out for a quick read.
    final slow = events.where((e) => !e.isInstant && e.durMs >= slowOpMs).toList()
      ..sort((a, b) => b.durMs.compareTo(a.durMs));
    sb.writeln('─────────────── slow ops (>=${slowOpMs}ms) ───────────────');
    if (slow.isEmpty) {
      sb.writeln('(none)');
    } else {
      for (final e in slow.take(25)) {
        sb.writeln(
          '+${_s(e.startMs)}s  ${e.op}  ${e.durMs}ms'
          '${e.rows > 0 ? '  rows=${e.rows}' : ''}'
          '${e.caller != null ? '  caller=${e.caller}' : ''}'
          '${e.prevOp != null ? '  prev=${e.prevOp}' : ''}'
          '${e.concurrent.isNotEmpty ? '  concurrent=${e.concurrent.join(' & ')}' : ''}',
        );
      }
    }
    sb.writeln('════════════════ END TRACE ════════════════');

    final out = sb.toString();
    if (log) debugPrint(out);
    return out;
  }
}
