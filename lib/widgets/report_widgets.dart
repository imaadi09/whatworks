import 'package:flutter/material.dart';
import '../utils/constants.dart';

/// Reusable UI pieces for the Reports/Analytics screens.
/// Kept dependency-free (Material only) and theme-agnostic: callers pass an
/// [accent] colour so both the Task (green) and Sales (blue) modules can reuse
/// the same widgets.

/// A single KPI metric tile: a large value with a caption underneath.
class ReportStatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;
  final IconData? icon;

  const ReportStatCard({
    super.key,
    required this.label,
    required this.value,
    required this.accent,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withOpacity(0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: accent),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.secondaryText,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// A card wrapper for one report block: title header with an optional export
/// button, followed by the report body ([children]).
class ReportSection extends StatelessWidget {
  final String title;
  final Color accent;
  final VoidCallback? onExport;
  final List<Widget> children;

  const ReportSection({
    super.key,
    required this.title,
    required this.accent,
    this.onExport,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryText,
                  ),
                ),
              ),
              if (onExport != null)
                InkWell(
                  onTap: onExport,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.download_outlined,
                      size: 20,
                      color: accent,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

/// A wrap of [ReportStatCard] tiles.
class ReportStatRow extends StatelessWidget {
  final List<ReportStatCard> cards;

  const ReportStatRow({super.key, required this.cards});

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: cards);
  }
}

/// A lightweight breakdown table: a styled header row + data rows.
/// [flex] optionally weights the columns (defaults to equal weighting).
/// [onRowTap] makes rows tappable (row index) for the interactive reports.
class ReportBreakdownTable extends StatelessWidget {
  final List<String> headers;
  final List<List<String>> rows;
  final Color accent;
  final List<int>? flex;
  final void Function(int rowIndex)? onRowTap;

  const ReportBreakdownTable({
    super.key,
    required this.headers,
    required this.rows,
    required this.accent,
    this.flex,
    this.onRowTap,
  });

  List<int> get _weights => flex ?? List<int>.filled(headers.length, 1);

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No data',
          style: TextStyle(fontSize: 13, color: AppTheme.lightText),
        ),
      );
    }

    return Column(
      children: [
        // Header row
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          decoration: BoxDecoration(
            color: accent.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: List.generate(headers.length, (i) {
              return Expanded(
                flex: _weights[i],
                child: Text(
                  headers[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                  textAlign: i == 0 ? TextAlign.start : TextAlign.center,
                ),
              );
            }),
          ),
        ),
        // Data rows
        ...List.generate(rows.length, (ri) {
          final r = rows[ri];
          final row = Padding(
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
            child: Row(
              children: List.generate(headers.length, (i) {
                final value = i < r.length ? r[i] : '';
                return Expanded(
                  flex: _weights[i],
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.primaryText,
                      fontWeight: i == 0 ? FontWeight.w500 : FontWeight.normal,
                    ),
                    textAlign: i == 0 ? TextAlign.start : TextAlign.center,
                  ),
                );
              }),
            ),
          );
          final tap = onRowTap;
          if (tap == null) return row;
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => tap(ri),
            child: row,
          );
        }),
      ],
    );
  }
}
