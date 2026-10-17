import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/sync_telemetry.dart';
import '../../utils/constants.dart';

/// Developer diagnostics panel — a live, read-only view of the app-local
/// performance/load telemetry ([SyncTelemetry]) gathered at the SHARED SQLite,
/// sync and Firestore layers, so Task, Sales and CRM are reported together.
///
/// Hidden behind the Settings ▸ About version-row 5-tap unlock. It never alters
/// sync/read/write behaviour; it only renders what the recorders observed while
/// "Record telemetry" is on. The panel *polls* the singleton at 1 Hz (recording
/// is push-free), so opening it cannot itself perturb what it measures.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final SyncTelemetry _tel = SyncTelemetry.instance;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 1 Hz repaint. Recording never triggers a rebuild on its own, so this
    // timer is the only thing that refreshes the numbers.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  Color _sev(TelSeverity s) {
    if (s == TelSeverity.crit) return Colors.red.shade600;
    if (s == TelSeverity.warn) return Colors.amber.shade700;
    return Colors.green.shade600;
  }

  String _sevWord(TelSeverity s) {
    if (s == TelSeverity.crit) return 'CRIT';
    if (s == TelSeverity.warn) return 'WARN';
    return 'OK';
  }

  /// Compact integer formatter: 850 -> "850", 12400 -> "12.4k".
  String _n(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return '$v';
  }

  String _fmtTime(DateTime t) {
    String two(int x) => x.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  List<MapEntry<String, ListenerStat>> _sortedListeners() {
    final l = _tel.listeners.entries.toList()
      ..sort((a, b) => b.value.totalDocs.compareTo(a.value.totalDocs));
    return l;
  }

  List<MapEntry<String, OpStat>> _sortedDb() {
    final l = _tel.db.entries.toList()
      ..sort((a, b) => b.value.avgMs.compareTo(a.value.avgMs));
    return l;
  }

  // ── Building blocks ────────────────────────────────────────────────────

  Widget _card(List<Widget> children) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(children: children),
    );
  }

  Widget _section(String title, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.secondaryText,
                letterSpacing: 0.6,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  /// One "label ......... value" metric line.
  Widget _kv(String k, String v, {TelSeverity? sev}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              k,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.secondaryText,
              ),
            ),
          ),
          Text(
            v,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
              color: sev != null ? _sev(sev) : AppTheme.primaryText,
            ),
          ),
        ],
      ),
    );
  }

  /// A titled item with a severity dot and a monospace stats sub-line — used
  /// for the per-listener and per-op tables.
  Widget _item(String title, String stats, TelSeverity sev) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: _sev(sev), shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    color: AppTheme.primaryText,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 2),
            child: Text(
              stats,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: AppTheme.secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(TelSeverity sev, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _sev(sev).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _sev(sev)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: _sev(sev),
        ),
      ),
    );
  }

  Widget _controlsCard() {
    return _card([
      SwitchListTile(
        title: const Text('Record telemetry', style: TextStyle(fontSize: 15)),
        subtitle: const Text(
          'Measure SQLite, sync and Firestore load',
          style: TextStyle(fontSize: 12),
        ),
        value: _tel.enabled,
        activeThumbColor: AppTheme.primaryGreen,
        onChanged: (v) async {
          await _tel.setEnabled(v);
          if (mounted) setState(() {});
        },
      ),
      const Divider(height: 1),
      SwitchListTile(
        title: const Text('Floating badge', style: TextStyle(fontSize: 15)),
        subtitle: const Text(
          'Glance overlay on every screen (needs recording on)',
          style: TextStyle(fontSize: 12),
        ),
        value: _tel.badgeVisible,
        activeThumbColor: AppTheme.primaryGreen,
        onChanged: (v) async {
          await _tel.setBadgeVisible(v);
          if (mounted) setState(() {});
        },
      ),
      const Divider(height: 1),
      ListTile(
        leading: const Icon(Icons.restart_alt, color: AppTheme.headerGreen),
        title: const Text('Reset counters', style: TextStyle(fontSize: 15)),
        subtitle: Text(
          'Uptime ${_tel.elapsedSeconds}s · since ${_fmtTime(_tel.startedAt)}',
          style: const TextStyle(fontSize: 12),
        ),
        onTap: () {
          _tel.reset();
          setState(() {});
        },
      ),
    ]);
  }

  Widget _notice(String msg) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Text(
        msg,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13, color: AppTheme.secondaryText),
      ),
    );
  }

  // ── Screen ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final worst = _tel.worstSeverity();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          if (_tel.enabled)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: _pill(worst, _sevWord(worst))),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SizedBox(height: 12),
          _controlsCard(),
          if (!_tel.enabled)
            _notice(
              'Recording is off. Turn on "Record telemetry", then use the app '
              'normally — open chats, switch tabs, send messages. Counts stay '
              'at zero while recording is off, so the overhead in normal use '
              'is nil.',
            )
          else ...[
            _section(
              'Firestore load',
              trailing: _pill(_tel.severityActiveListeners,
                  '${_tel.activeListeners} live'),
            ),
            _card([
              _kv('Active listeners', '${_tel.activeListeners}',
                  sev: _tel.severityActiveListeners),
              _kv('Total reads (docs)', _n(_tel.fsReads)),
              _kv('Writes (docs)', _n(_tel.fsWrites)),
              _kv('Reads / min', _tel.readsPerMin.toStringAsFixed(0)),
              _kv('Writes / min', _tel.writesPerMin.toStringAsFixed(0),
                  sev: _tel.severityWriteRate),
            ]),
            if (_tel.listeners.isNotEmpty) ...[
              _section('Listeners  ·  attach = one full read'),
              _card([
                for (final e in _sortedListeners())
                  _item(
                    e.key,
                    'attach ${e.value.attaches} · emit ${e.value.emissions} · '
                        'init ${_n(e.value.initialDocs)} · '
                        'delta ${_n(e.value.deltaDocs)} · '
                        'maxInit ${_n(e.value.maxInitialDocs)}',
                    _tel.severityListener(e.value),
                  ),
              ]),
            ],
            _section('SQLite ops'),
            _card(
              _tel.db.isEmpty
                  ? [
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No measured queries yet.',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.secondaryText,
                          ),
                        ),
                      ),
                    ]
                  : [
                      for (final e in _sortedDb())
                        _item(
                          e.key,
                          'count ${e.value.count} · avg ${e.value.avgMs}ms · '
                              'max ${e.value.maxMs}ms · '
                              'rows ${e.value.lastRows}/max ${e.value.maxRows}',
                          _tel.severityDb(e.key),
                        ),
                    ],
            ),
            _section('Provider / sync churn'),
            _card([
              _kv('Reload invoked', '${_tel.reloadInvoked}'),
              _kv('Reload executed', '${_tel.reloadExecuted}'),
              _kv('Reload coalesced', '${_tel.reloadCoalesced}'),
              _kv('Reloads / min', _tel.reloadsPerMin.toStringAsFixed(0),
                  sev: _tel.severityReloadRate),
              _kv('Notifies', '${_tel.notifyCount}'),
              _kv('Notifies / min', _tel.notifiesPerMin.toStringAsFixed(0),
                  sev: _tel.severityNotifyRate),
              _kv('Change-set patches (rows)', '${_tel.changeSetPatch}'),
              _kv('Change-set full reloads', '${_tel.changeSetFullReload}'),
            ]),
          ],
        ],
      ),
    );
  }
}
