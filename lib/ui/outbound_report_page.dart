import 'dart:io';

import 'package:excel/excel.dart' as excel;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/record_database.dart';

// 出库报表：按日期区间导出出库材料记录
class OutboundReportPage extends StatefulWidget {
  const OutboundReportPage({super.key});

  @override
  State<OutboundReportPage> createState() => _OutboundReportPageState();
}

class _OutboundReportPageState extends State<OutboundReportPage> {
  DateTime? _startDate;
  DateTime? _endDate;
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('出库报表')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '根据开始日期和结束日期框定出库日期，导出区间内（包含起止日期）的所有出库材料记录，默认按出库日期升序排列。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pickStartDate(context),
                  child: Text(
                    _startDate == null ? '开始日期' : _formatDate(_startDate!),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pickEndDate(context),
                  child: Text(
                    _endDate == null ? '结束日期' : _formatDate(_endDate!),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download_outlined),
            label: Text(_exporting ? '导出中…' : '导出'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickStartDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _startDate = DateTime(picked.year, picked.month, picked.day);
      if (_endDate != null && _endDate!.isBefore(_startDate!)) {
        _endDate = _startDate;
      }
    });
  }

  Future<void> _pickEndDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _endDate = DateTime(picked.year, picked.month, picked.day);
      if (_startDate != null && _endDate!.isBefore(_startDate!)) {
        _startDate = _endDate;
      }
    });
  }

  Future<void> _export() async {
    if (_startDate == null || _endDate == null) {
      _showMessage('请先选择开始日期和结束日期');
      return;
    }
    setState(() {
      _exporting = true;
    });
    try {
      final records = await RecordDatabase.instance.fetchOutRecordsForReport(
        startDate: _startDate,
        endDate: _endDate,
      );
      if (records.isEmpty) {
        _showMessage('所选日期区间内暂无出库记录');
        return;
      }
      final filePath = await _saveAsXlsx(records);
      final shared = await _shareExportFile(filePath);
      if (!mounted) {
        return;
      }
      _showMessage(
        shared
            ? '已导出${records.length}条出库记录并唤起分享'
            : '已导出${records.length}条出库记录到 $filePath',
      );
    } catch (error) {
      debugPrint('出库报表导出异常：$error');
      _showMessage('导出失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
        });
      }
    }
  }

  Future<String> _saveAsXlsx(List<InventoryOutRecord> records) async {
    // 单价口径与课程出库导出一致：入库总金额 / 入库总数
    final summaryList = await RecordDatabase.instance.fetchInventorySummary();
    final unitPriceMap = <String, double>{};
    for (final item in summaryList) {
      final unitPrice = item.purchasedQuantity > 0
          ? item.totalAmount / item.purchasedQuantity
          : 0.0;
      unitPriceMap[item.materialName] = unitPrice;
    }

    final workbook = excel.Excel.createExcel();
    final sheet = workbook['Sheet1'];
    sheet.appendRow(['序号', '材料名称', '出库数量', '材料单价', '总金额', '出库日期']);
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      final unitPrice =
          (unitPriceMap[record.materialName] ?? 0.0).toDouble();
      final parsedDate = DateTime.tryParse(record.createdAt);
      sheet.appendRow([
        i + 1,
        record.materialName,
        record.quantity,
        double.parse(unitPrice.toStringAsFixed(4)),
        double.parse((record.quantity * unitPrice).toStringAsFixed(2)),
        parsedDate == null ? record.createdAt : _formatDate(parsedDate),
      ]);
    }
    _beautifySheet(sheet);

    final directory = await _exportDirectory();
    final fileName =
        '出库报表_${_formatDate(_startDate!)}-${_formatDate(_endDate!)}'
        '_${_formatDateTime(DateTime.now())}.xlsx';
    final exportFile = File(p.join(directory.path, fileName));
    final bytes = workbook.save();
    if (bytes == null) {
      throw Exception('导出失败');
    }
    await exportFile.writeAsBytes(bytes, flush: true);
    debugPrint('出库报表已生成：${exportFile.path}（${records.length}条）');
    return exportFile.path;
  }

  void _beautifySheet(excel.Sheet sheet) {
    if (sheet.maxRows <= 0 || sheet.maxCols <= 0) {
      return;
    }
    final border = excel.Border(
      borderStyle: excel.BorderStyle.Thin,
      borderColorHex: '#FFD9D9D9',
    );
    final headerStyle = excel.CellStyle(
      bold: true,
      fontColorHex: '#FF1F2937',
      backgroundColorHex: '#FFEAF4F2',
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
      horizontalAlign: excel.HorizontalAlign.Center,
      verticalAlign: excel.VerticalAlign.Center,
    );
    final oddStyle = excel.CellStyle(
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
      horizontalAlign: excel.HorizontalAlign.Left,
      verticalAlign: excel.VerticalAlign.Center,
    );
    final evenStyle = excel.CellStyle(
      backgroundColorHex: '#FFF9FCFB',
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
      horizontalAlign: excel.HorizontalAlign.Left,
      verticalAlign: excel.VerticalAlign.Center,
    );
    for (var row = 0; row < sheet.maxRows; row++) {
      for (var col = 0; col < sheet.maxCols; col++) {
        final cell = sheet.cell(
          excel.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row),
        );
        if (row == 0) {
          cell.cellStyle = headerStyle;
        } else {
          cell.cellStyle = row.isEven ? evenStyle : oddStyle;
        }
      }
    }
    for (var col = 0; col < sheet.maxCols; col++) {
      var maxWidth = 0;
      for (var row = 0; row < sheet.maxRows; row++) {
        final cell = sheet.cell(
          excel.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row),
        );
        final width = _textDisplayWidth(_excelCellText(cell.value));
        if (width > maxWidth) {
          maxWidth = width;
        }
      }
      sheet.setColWidth(col, (maxWidth + 2).toDouble().clamp(10, 40));
    }
  }

  int _textDisplayWidth(String text) {
    if (text.isEmpty) {
      return 0;
    }
    var total = 0;
    for (final rune in text.runes) {
      total += rune <= 0x7F ? 1 : 2;
    }
    return total;
  }

  String _excelCellText(Object? value) {
    if (value == null) {
      return '';
    }
    try {
      final dynamic raw = value;
      final inner = raw.value;
      if (inner != null) {
        return inner.toString().trim();
      }
    } catch (_) {}
    return value.toString().trim();
  }

  Future<Directory> _exportDirectory() async {
    // 根据平台选择导出目录
    if (Platform.isAndroid) {
      return getTemporaryDirectory();
    }
    return getApplicationDocumentsDirectory();
  }

  Future<bool> _shareExportFile(String filePath) async {
    // Android 分享导出文件
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final file = XFile(
        filePath,
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      await SharePlus.instance.share(ShareParams(files: [file]));
      return true;
    } catch (_) {
      debugPrint('唤起分享时发生异常，忽略继续');
      return false;
    }
  }

  String _formatDate(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  String _formatDateTime(DateTime date) {
    // 生成文件名时间戳
    final datePart = _formatDate(date).replaceAll('-', '');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    final second = date.second.toString().padLeft(2, '0');
    return '${datePart}_$hour$minute$second';
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
