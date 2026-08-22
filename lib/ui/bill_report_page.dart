import 'dart:io';

import 'package:excel/excel.dart' as excel;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/record_database.dart';
import '../data/transaction_record.dart';

// 账单报表：按日期/账本/账户筛选后导出账单
class BillReportPage extends StatefulWidget {
  const BillReportPage({super.key});

  @override
  State<BillReportPage> createState() => _BillReportPageState();
}

class _BillReportPageState extends State<BillReportPage> {
  static const String _materialNoteSplitter = '｜';

  DateTime? _startDate;
  DateTime? _endDate;
  int? _billId;
  int? _accountId;
  bool _exporting = false;
  List<Bill> _bills = [];
  List<Account> _accounts = [];
  Map<String, String> _baseMaterials = {}; // 基础材料缓存 (name -> unit)

  @override
  void initState() {
    super.initState();
    _loadFilterOptions();
  }

  Future<void> _loadFilterOptions() async {
    try {
      final bills = await RecordDatabase.instance.fetchBills();
      final accounts = await RecordDatabase.instance.fetchAccounts();
      final materials = await RecordDatabase.instance.fetchBaseMaterials();
      if (!mounted) {
        return;
      }
      setState(() {
        _bills = bills;
        _accounts = accounts;
        _baseMaterials = {for (var e in materials) e.name: e.unit};
      });
    } catch (error) {
      debugPrint('账单报表筛选条件加载失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('账单报表')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '根据开始日期、结束日期、账本和账户筛选账单，导出满足条件的账单记录（日期不选视为不限，含起止日期）。',
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
          const SizedBox(height: 12),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: '账本选择',
              border: OutlineInputBorder(),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int?>(
                value: _billId,
                isExpanded: true,
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('全部账本'),
                  ),
                  ..._bills.map(
                    (bill) => DropdownMenuItem<int?>(
                      value: bill.id,
                      child: Text(bill.name),
                    ),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    _billId = value;
                  });
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: '账户选择',
              border: OutlineInputBorder(),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int?>(
                value: _accountId,
                isExpanded: true,
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('全部账户'),
                  ),
                  ..._accounts.map(
                    (account) => DropdownMenuItem<int?>(
                      value: account.id,
                      child: Text(account.name),
                    ),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    _accountId = value;
                  });
                },
              ),
            ),
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
    setState(() {
      _exporting = true;
    });
    try {
      final rows = await RecordDatabase.instance.fetchExportRows(
        startDate: _startDate,
        endDate: _endDate,
        billId: _billId,
        accountId: _accountId,
      );
      if (rows.isEmpty) {
        _showMessage('当前筛选条件下暂无账单记录');
        return;
      }
      final filePath = await _saveAsXlsx(rows);
      final shared = await _shareExportFile(filePath);
      if (!mounted) {
        return;
      }
      _showMessage(
        shared
            ? '已导出${rows.length}条账单并唤起分享'
            : '已导出${rows.length}条账单到 $filePath',
      );
    } catch (error) {
      debugPrint('账单报表导出异常：$error');
      _showMessage('导出失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
        });
      }
    }
  }

  Future<String> _saveAsXlsx(List<Map<String, Object?>> rows) async {
    final headers = [
      '序号',
      '日期',
      '账本名称',
      '账户名称',
      '收支类型',
      '账目金额',
      '账目备注',
      '分类',
      '材料名称',
      '数量',
      '单位',
      '归属项目',
      '归属年级',
      '跨项目重复材料',
      '跨年级重复材料',
    ];
    final workbook = excel.Excel.createExcel();
    final sheet = workbook['Sheet1'];
    final relationRows = await RecordDatabase.instance
        .fetchProjectMaterialRelations();
    final relationMap = <String, _MaterialRelationMeta>{};
    for (final row in relationRows) {
      final key = row.materialName.trim();
      if (key.isEmpty) {
        continue;
      }
      final current =
          relationMap[key] ??
          _MaterialRelationMeta(projects: <String>{}, grades: <String>{});
      current.projects.add(row.projectName.trim());
      current.grades.add(row.gradeName.trim());
      relationMap[key] = current;
    }
    sheet.appendRow(headers);
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final rawDate = r['date'] as String?;
      final parsedDate = rawDate == null ? null : DateTime.tryParse(rawDate);
      final date = parsedDate == null
          ? (rawDate ?? '')
          : _formatDate(parsedDate);
      final book = r['book_name'] as String? ?? '默认账本';
      final account = r['account_name'] as String? ?? '默认账户';
      final type = r['type'] as String? ?? '';
      final amount = (r['amount'] as num?)?.toDouble() ?? 0;
      final note = r['note'] as String? ?? '';
      final category = r['category'] as String? ?? '';
      final quantity = (r['quantity'] as num?)?.toDouble();
      final material = _parseExportMaterialFields(
        category: category,
        note: note,
        recordQuantity: quantity,
      );
      final relation = relationMap[material.name.trim()];
      final projects = relation == null
          ? <String>[]
          : (relation.projects.where((e) => e.isNotEmpty).toList()..sort());
      final grades = relation == null
          ? <String>[]
          : (relation.grades.where((e) => e.isNotEmpty).toList()..sort());
      sheet.appendRow([
        i + 1,
        date,
        book,
        account,
        type == 'income' ? '收入' : '支出',
        amount,
        note,
        category,
        material.name,
        material.quantity,
        material.unit,
        projects.join('、'),
        grades.join('、'),
        relation == null ? '' : (projects.length > 1 ? '是' : '否'),
        relation == null ? '' : (grades.length > 1 ? '是' : '否'),
      ]);
    }
    _beautifySheet(sheet);
    final directory = await _exportDirectory();
    final fileName = '账单报表_${_formatDateTime(DateTime.now())}.xlsx';
    final exportFile = File(p.join(directory.path, fileName));
    final bytes = workbook.save();
    if (bytes == null) {
      throw Exception('导出失败');
    }
    await exportFile.writeAsBytes(bytes, flush: true);
    debugPrint('账单报表已生成：${exportFile.path}（${rows.length}条）');
    return exportFile.path;
  }

  _ExportMaterialFields _parseExportMaterialFields({
    required String category,
    required String note,
    required double? recordQuantity,
  }) {
    final quantityText = _formatExportQuantity(recordQuantity);
    if (category != '课程材料') {
      return _ExportMaterialFields(quantity: quantityText);
    }
    final trimmedNote = note.trim();
    if (trimmedNote.isEmpty) {
      return _ExportMaterialFields(quantity: quantityText);
    }
    final splitIndex = trimmedNote.indexOf(_materialNoteSplitter);
    final materialName = splitIndex == -1
        ? trimmedNote
        : trimmedNote.substring(0, splitIndex).trim();
    if (materialName.isEmpty) {
      return _ExportMaterialFields(quantity: quantityText);
    }
    final parsedQuantity = splitIndex == -1
        ? ''
        : trimmedNote
              .substring(splitIndex + _materialNoteSplitter.length)
              .trim();
    final unit = _baseMaterials[materialName] ?? '';
    return _ExportMaterialFields(
      name: materialName,
      quantity: quantityText.isEmpty ? parsedQuantity : quantityText,
      unit: unit,
    );
  }

  String _formatExportQuantity(double? quantity) {
    if (quantity == null || quantity <= 0) {
      return '';
    }
    final value = quantity.toStringAsFixed(6);
    return value.replaceFirst(RegExp(r'\.?0+$'), '');
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

class _ExportMaterialFields {
  const _ExportMaterialFields({
    this.name = '',
    this.quantity = '',
    this.unit = '',
  });

  final String name;
  final String quantity;
  final String unit;
}

class _MaterialRelationMeta {
  _MaterialRelationMeta({required this.projects, required this.grades});

  final Set<String> projects;
  final Set<String> grades;
}
