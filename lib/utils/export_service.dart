import 'dart:io';
import 'package:flutter/material.dart';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

/// Export format options
enum ExportFormat { csv, excel, pdf }

/// Shared export utility for both Task and Sales modules.
/// Exports the currently filtered/visible list to CSV, Excel, or PDF.
class ExportService {
  /// Export a list of records to the specified format.
  /// [headers] - Column headers
  /// [rows] - List of rows, each row is a list of cell values
  /// [title] - Title for the document (used in PDF/Excel)
  /// [filterLabel] - Active filter description (used in filename)
  static Future<void> export({
    required List<String> headers,
    required List<List<String>> rows,
    required String title,
    required String filterLabel,
    required ExportFormat format,
  }) async {
    if (rows.isEmpty) return;

    final dateFormat = DateFormat('yyyy-MM-dd');
    final dateStr = dateFormat.format(DateTime.now());
    final safeFilter = filterLabel.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final baseName = '${title}_$safeFilter$dateStr';

    switch (format) {
      case ExportFormat.csv:
        await _exportCsv(headers, rows, '$baseName.csv');
        break;
      case ExportFormat.excel:
        await _exportExcel(headers, rows, title, '$baseName.xlsx');
        break;
      case ExportFormat.pdf:
        await _exportPdf(headers, rows, title, '$baseName.pdf');
        break;
    }
  }

  /// Show a format selection dialog and export
  static Future<void> showExportDialog({
    required dynamic context,
    required List<String> headers,
    required List<List<String>> rows,
    required String title,
    required String filterLabel,
  }) async {
    final result = await showDialog<ExportFormat>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Export'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${rows.length} items to export',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _buildFormatOption(
              ctx,
              'CSV',
              Icons.table_chart,
              'Spreadsheet compatible',
              ExportFormat.csv,
            ),
            _buildFormatOption(
              ctx,
              'Excel',
              Icons.grid_on,
              'Formatted with styles',
              ExportFormat.excel,
            ),
            _buildFormatOption(
              ctx,
              'PDF',
              Icons.picture_as_pdf,
              'Print-ready document',
              ExportFormat.pdf,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (result != null && context.mounted) {
      // Show loading indicator
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 16),
              Text('Exporting ${result.name.toUpperCase()}...'),
            ],
          ),
          duration: const Duration(seconds: 3),
        ),
      );

      await export(
        headers: headers,
        rows: rows,
        title: title,
        filterLabel: filterLabel,
        format: result,
      );

      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${result.name.toUpperCase()} exported successfully'),
            backgroundColor: const Color(0xFF2F9E44),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  static Widget _buildFormatOption(
    BuildContext context,
    String label,
    IconData icon,
    String subtitle,
    ExportFormat format,
  ) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 24, color: const Color(0xFF1971C2)),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      onTap: () => Navigator.pop(context, format),
    );
  }

  // ── CSV Export ──────────────────────────────────────────────────────────

  static Future<void> _exportCsv(
    List<String> headers,
    List<List<String>> rows,
    String fileName,
  ) async {
    final allRows = [headers, ...rows];
    final csvString = const ListToCsvConverter().convert(allRows);

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(csvString);

    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  // ── Excel Export ────────────────────────────────────────────────────────

  static Future<void> _exportExcel(
    List<String> headers,
    List<List<String>> rows,
    String title,
    String fileName,
  ) async {
    final excel = Excel.createExcel();
    final sheetName = 'Sheet1';

    // Rename default sheet
    excel.rename(excel.getDefaultSheet()!, sheetName);
    final sheet = excel[sheetName];

    // Header style
    final headerStyle = CellStyle(bold: true);

    // Write headers
    for (var i = 0; i < headers.length; i++) {
      final cell = CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0);
      sheet.cell(cell).value = TextCellValue(headers[i]);
      sheet.cell(cell).cellStyle = headerStyle;
    }

    // Write data rows
    for (var rowIdx = 0; rowIdx < rows.length; rowIdx++) {
      for (var colIdx = 0; colIdx < rows[rowIdx].length; colIdx++) {
        final cell = CellIndex.indexByColumnRow(
          columnIndex: colIdx,
          rowIndex: rowIdx + 1,
        );
        final value = rows[rowIdx][colIdx];
        // Try to parse as number
        final numValue = double.tryParse(value);
        if (numValue != null) {
          sheet.cell(cell).value = DoubleCellValue(numValue);
        } else {
          sheet.cell(cell).value = TextCellValue(value);
        }
      }
    }

    // Auto-fit column widths (approximate)
    for (var i = 0; i < headers.length; i++) {
      final maxLen = _maxColumnLength(headers, rows, i);
      sheet.setColumnWidth(i, (maxLen * 1.2 + 2).clamp(8, 40));
    }

    // Save
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await excel.save(fileName: file.path);

    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  static int _maxColumnLength(
    List<String> headers,
    List<List<String>> rows,
    int colIndex,
  ) {
    int maxLen = headers[colIndex].length;
    for (final row in rows) {
      if (colIndex < row.length) {
        maxLen = maxLen > row[colIndex].length ? maxLen : row[colIndex].length;
      }
    }
    return maxLen;
  }

  // ── PDF Export ──────────────────────────────────────────────────────────

  static Future<void> _exportPdf(
    List<String> headers,
    List<List<String>> rows,
    String title,
    String fileName,
  ) async {
    final pdf = pw.Document();
    final dateFormat = DateFormat('dd MMM yyyy, hh:mm a');

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              title,
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Generated: ${dateFormat.format(DateTime.now())} | ${rows.length} items',
              style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
            ),
            pw.SizedBox(height: 8),
            pw.Divider(thickness: 1),
            pw.SizedBox(height: 8),
          ],
        ),
        build: (context) => [
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: rows,
            headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 9,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: PdfColors.blue800),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellAlignment: pw.Alignment.centerLeft,
            cellPadding: const pw.EdgeInsets.all(4),
            oddRowDecoration: pw.BoxDecoration(color: PdfColors.grey50),
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            headerCellDecoration: pw.BoxDecoration(color: PdfColors.blue800),
          ),
        ],
      ),
    );

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(await pdf.save());

    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }
}
