import 'dart:io';

import 'package:excel/excel.dart' as excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/record_database.dart';
import '../data/transaction_record.dart';

class LineAccountPage extends StatefulWidget {
  const LineAccountPage({super.key, required this.accountId});

  final int accountId;

  @override
  State<LineAccountPage> createState() => _LineAccountPageState();
}

class _LineAccountPageState extends State<LineAccountPage> {
  static const String _materialNoteSplitter = '｜';
  List<TransactionRecord> _allRecords = [];
  List<TransactionRecord> _records = [];
  Map<String, String> _baseMaterials = {};
  bool _loading = true;
  bool _loadingError = false;
  String _keyword = '';
  bool _exporting = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _loadingError = false;
    });
    try {
      final records = await RecordDatabase.instance.fetchRecordsByAccount(
        widget.accountId,
      );
      final materials = await RecordDatabase.instance.fetchBaseMaterials();
      if (!mounted) {
        return;
      }
      setState(() {
        _allRecords = records;
        _baseMaterials = {for (var e in materials) e.name: e.unit};
        _records = _applyKeyword(records, _keyword);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadingError = true;
      });
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      _keyword = value;
      _records = _applyKeyword(_allRecords, _keyword);
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _keyword = '';
      _records = _allRecords;
    });
  }

  List<TransactionRecord> _applyKeyword(
    List<TransactionRecord> source,
    String keyword,
  ) {
    final normalized = keyword.trim().toLowerCase();
    if (normalized.isEmpty) {
      return source;
    }
    return source.where((record) {
      final note = (record.note ?? '').toLowerCase();
      final category = record.category.toLowerCase();
      final amount = record.amount.toString();
      return note.contains(normalized) ||
          category.contains(normalized) ||
          amount.contains(normalized);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(RecordDatabase.lineAccountName),
        actions: [
          TextButton(
            onPressed: _exporting ? null : _exportRecords,
            child: _exporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('导出'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: '搜索备注或分类',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _keyword.trim().isEmpty
                    ? null
                    : IconButton(
                        onPressed: _clearSearch,
                        icon: const Icon(Icons.close),
                      ),
                filled: true,
                fillColor: const Color(0xFFF5F7F7),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  if (_loading)
                    const Center(child: CircularProgressIndicator())
                  else if (_loadingError)
                    _LineAccountEmptyState(
                      message: '加载失败，请下拉重试',
                      onRetry: _loadData,
                    )
                  else if (_records.isEmpty)
                    _LineAccountEmptyState(
                      message: _keyword.trim().isEmpty ? '暂无记录' : '暂无匹配记录',
                      onRetry: _loadData,
                    )
                  else
                    ..._buildGroupedRecords(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildGroupedRecords() {
    final widgets = <Widget>[];
    var bucket = <TransactionRecord>[];
    String? currentDate;
    void flush() {
      final date = currentDate;
      if (date == null || bucket.isEmpty) {
        return;
      }
      widgets.add(_buildDateGroup(date, bucket));
      bucket = <TransactionRecord>[];
    }

    for (final record in _records) {
      final dateKey = _formatDate(record.date);
      currentDate ??= dateKey;
      if (dateKey != currentDate) {
        flush();
        currentDate = dateKey;
      }
      bucket.add(record);
    }
    flush();
    return widgets;
  }

  Widget _buildDateGroup(String date, List<TransactionRecord> items) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    date,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ...items.asMap().entries.map(
            (entry) => _buildRecordItem(
              entry.value,
              showDivider: entry.key != items.length - 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordItem(
    TransactionRecord record, {
    required bool showDivider,
  }) {
    final isMarked = _isMaterialInBaseList(record);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: showDivider
            ? const Border(bottom: BorderSide(color: Color(0xFFE6E6E6)))
            : null,
      ),
      child: Row(
        children: [
          if (isMarked)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.verified, size: 16, color: Color(0xFF1B7F5A)),
            ),
          Expanded(
            child: Text(
              _buildRecordTitle(record),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            _formatAmount(record),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: record.type == 'income'
                  ? const Color(0xFF1B7F5A)
                  : const Color(0xFFB5473B),
            ),
          ),
        ],
      ),
    );
  }

  bool _isMaterialInBaseList(TransactionRecord record) {
    if (record.category != '课程材料' || record.note == null) return false;
    final parts = record.note!.split(_materialNoteSplitter);
    final materialName = parts.isNotEmpty ? parts[0].trim() : '';
    return _baseMaterials.containsKey(materialName);
  }

  String _buildRecordTitle(TransactionRecord record) {
    final note = record.note?.trim();
    if (note == null || note.isEmpty) {
      return record.category;
    }
    if (record.category == '课程材料') {
      final parts = note.split(_materialNoteSplitter);
      if (parts.isNotEmpty) {
        final name = parts[0].trim();
        if (_baseMaterials.containsKey(name)) {
          final unit = _baseMaterials[name];
          if (parts.length > 1) {
            final quantity = parts[1].trim();
            return '$name · $quantity$unit';
          }
          return '$name · $unit';
        }
      }
    }
    final preview = note.length > 6 ? note.substring(0, 6) : note;
    return '${record.category} · $preview';
  }

  String _formatAmount(TransactionRecord record) {
    final amount = record.amount.toStringAsFixed(2);
    final sign = record.type == 'income' ? '+' : '-';
    return '$sign$amount';
  }

  String _formatDate(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  Future<void> _exportRecords() async {
    if (_records.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无可导出记录')));
      return;
    }
    setState(() {
      _exporting = true;
    });
    try {
      final workbook = excel.Excel.createExcel();
      final sheet = workbook['Sheet1'];
      sheet.appendRow(['日期', '类型', '分类', '标题', '金额', '备注']);
      for (final record in _records) {
        sheet.appendRow([
          _formatDate(record.date),
          record.type == 'income' ? '收入' : '支出',
          record.category,
          _buildRecordTitle(record),
          _formatAmount(record),
          record.note ?? '',
        ]);
      }
      final bytes = workbook.encode()!;
      if (Platform.isWindows) {
        final fileName =
            '公账材料记录_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '请选择保存位置',
          fileName: fileName,
          allowedExtensions: ['xlsx'],
          type: FileType.custom,
        );
        if (outputFile != null) {
          final file = File(outputFile);
          await file.writeAsBytes(bytes);
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('导出成功')));
          }
        }
      } else {
        final directory = await getApplicationDocumentsDirectory();
        final filePath = p.join(
          directory.path,
          '公账材料记录_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx',
        );
        final file = File(filePath);
        await file.writeAsBytes(bytes);
        await Share.shareXFiles([XFile(filePath)], text: '公账材料记录');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导出失败，请重试')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
        });
      }
    }
  }
}

class _LineAccountEmptyState extends StatelessWidget {
  const _LineAccountEmptyState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined, size: 40, color: Colors.grey.shade500),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 10),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
