import 'dart:io';

import 'package:excel/excel.dart' as excel;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../data/record_database.dart';
import '../data/transaction_record.dart';
import '../data/reimbursement.dart';

class ReimbursementPage extends StatefulWidget {
  const ReimbursementPage({super.key});

  @override
  State<ReimbursementPage> createState() => _ReimbursementPageState();
}

class _ReimbursementPageState extends State<ReimbursementPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();

  // Data
  List<TransactionRecord> _unreimbursedRecords = [];
  List<TransactionRecord> _reimbursedRecords = [];
  List<TransactionRecord> _allRecords = [];

  // Selection
  final Set<int> _selectedRecordIds = {};
  // 记录每个分组是否展开
  final Map<String, bool> _monthExpandedMap = {};
  final Map<String, String> _baseMaterials = {};
  static const String _materialNoteSplitter = '｜';

  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final unreimbursed = await RecordDatabase.instance
          .fetchUnreimbursedRecords();
      final reimbursed = await RecordDatabase.instance.fetchReimbursedRecords();
      final all = await RecordDatabase.instance.fetchAllExpenseRecords();
      final materials = await RecordDatabase.instance.fetchBaseMaterials();

      setState(() {
        _unreimbursedRecords = unreimbursed;
        _reimbursedRecords = reimbursed;
        _allRecords = all;
        _baseMaterials
          ..clear()
          ..addEntries(materials.map((e) => MapEntry(e.name, e.unit)));
        _isLoading = false;
        // Clear selection on reload
        _selectedRecordIds.clear();
      });
    } catch (e) {
      debugPrint('Error loading reimbursement data: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _onRecordToggle(int id) {
    setState(() {
      if (_selectedRecordIds.contains(id)) {
        _selectedRecordIds.remove(id);
      } else {
        _selectedRecordIds.add(id);
      }
    });
  }

  void _onMonthToggle(List<TransactionRecord> recordsInMonth, bool select) {
    setState(() {
      if (select) {
        for (var r in recordsInMonth) {
          _selectedRecordIds.add(r.id!);
        }
      } else {
        for (var r in recordsInMonth) {
          _selectedRecordIds.remove(r.id);
        }
      }
    });
  }

  void _showReimbursementSheet() {
    if (_selectedRecordIds.isEmpty) return;

    final selectedRecords = _unreimbursedRecords
        .where((r) => _selectedRecordIds.contains(r.id))
        .toList();

    final totalAmount = selectedRecords.fold(0.0, (sum, r) => sum + r.amount);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _ReimbursementBottomSheet(
        totalAmount: totalAmount,
        recordIds: _selectedRecordIds.toList(),
        baseMaterials: Map<String, String>.from(_baseMaterials),
        onCompleted: () {
          Navigator.pop(context);
          _loadData();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('报销管理'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '未报'),
            Tab(text: '已报'),
            Tab(text: '全部'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Fixed Search Bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索：分类、备注、标签、金额',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              onChanged: (value) {
                // TODO: Implement search filter
              },
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildRecordList(
                        _unreimbursedRecords,
                        tabIndex: 0,
                        isSelectionEnabled: true,
                      ),
                      _buildRecordList(
                        _reimbursedRecords,
                        tabIndex: 1,
                      ), // TODO: Group by Reimbursement Bundle instead?
                      _buildRecordList(_allRecords, tabIndex: 2),
                    ],
                  ),
          ),
          if (_selectedRecordIds.isNotEmpty && _tabController.index == 0)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '已选 ${_selectedRecordIds.length} 笔',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        Text(
                          '¥ ${_calculateSelectedTotal().toStringAsFixed(2)}',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _showReimbursementSheet,
                      child: const Text('去报销'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  double _calculateSelectedTotal() {
    return _unreimbursedRecords
        .where((r) => _selectedRecordIds.contains(r.id))
        .fold(0.0, (sum, r) => sum + r.amount);
  }

  Widget _buildRecordList(
    List<TransactionRecord> records, {
    required int tabIndex,
    bool isSelectionEnabled = false,
  }) {
    if (records.isEmpty) {
      return const Center(child: Text('暂无数据'));
    }

    final colorScheme = Theme.of(context).colorScheme;
    // Group by Month
    final Map<String, List<TransactionRecord>> grouped = {};
    for (var record in records) {
      final key = DateFormat('yyyy年MM月').format(record.date);
      if (!grouped.containsKey(key)) {
        grouped[key] = [];
      }
      grouped[key]!.add(record);
    }

    final keys = grouped.keys.toList()
      ..sort((a, b) => _monthKeyToDate(b).compareTo(_monthKeyToDate(a)));

    return ListView.builder(
      itemCount: keys.length,
      padding: const EdgeInsets.only(bottom: 80),
      itemBuilder: (context, index) {
        final monthKey = keys[index];
        final monthRecords = grouped[monthKey]!;
        final totalAmount = monthRecords.fold(0.0, (sum, r) => sum + r.amount);
        final isExpanded = _isMonthExpanded(tabIndex, monthKey);

        // Check if all selected in this month
        final allSelected =
            isSelectionEnabled &&
            monthRecords.every((r) => _selectedRecordIds.contains(r.id));

        // Check if some selected (for visual feedback, though Checkbox usually only supports tristate or bool)
        // We'll just use simple logic: if all selected -> true, else false.

        return Column(
          children: [
            // Month Header
            InkWell(
              onTap: () {
                _toggleMonthExpanded(tabIndex, monthKey);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    if (isSelectionEnabled)
                      Checkbox(
                        value: allSelected,
                        onChanged: (val) {
                          _onMonthToggle(monthRecords, val ?? false);
                        },
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            monthKey,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            '共${monthRecords.length}笔，累计${totalAmount.toStringAsFixed(2)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${totalAmount.toStringAsFixed(2)}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                      ),
                      onPressed: () {
                        _toggleMonthExpanded(tabIndex, monthKey);
                      },
                    ),
                  ],
                ),
              ),
            ),
            // Items
            if (isExpanded)
              ...monthRecords.map((record) {
                final isSelected = _selectedRecordIds.contains(record.id);
                return Padding(
                  padding: const EdgeInsets.only(left: 18),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: colorScheme.outlineVariant,
                          width: 2,
                        ),
                      ),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.only(
                        left: 16,
                        right: 16,
                      ),
                      leading: isSelectionEnabled
                          ? Checkbox(
                              value: isSelected,
                              onChanged: (val) => _onRecordToggle(record.id!),
                            )
                          : null,
                      title: Text(record.category),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(DateFormat('MM-dd').format(record.date)),
                          Text(
                            _buildRecordDetail(record),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                      trailing: Text(
                        record.amount.toStringAsFixed(2),
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      onTap: isSelectionEnabled
                          ? () => _onRecordToggle(record.id!)
                          : null,
                    ),
                  ),
                );
              }),
          ],
        );
      },
    );
  }

  DateTime _monthKeyToDate(String key) {
    return DateFormat('yyyy年MM月').parse(key);
  }

  bool _isMonthExpanded(int tabIndex, String monthKey) {
    final mapKey = '$tabIndex-$monthKey';
    return _monthExpandedMap[mapKey] ?? true;
  }

  void _toggleMonthExpanded(int tabIndex, String monthKey) {
    final mapKey = '$tabIndex-$monthKey';
    setState(() {
      final current = _monthExpandedMap[mapKey] ?? true;
      _monthExpandedMap[mapKey] = !current;
    });
  }

  String _buildRecordDetail(TransactionRecord record) {
    if (record.category == '课程材料') {
      final note = (record.note ?? '').trim();
      if (note.isEmpty) {
        return '材料：未填写';
      }
      final index = note.indexOf(_materialNoteSplitter);
      final name = index == -1 ? note : note.substring(0, index).trim();
      final quantity = index == -1
          ? ''
          : note.substring(index + _materialNoteSplitter.length).trim();
      if (name.isEmpty) {
        return '材料：未填写';
      }
      if (quantity.isEmpty) {
        return '材料：$name';
      }
      final unit = _baseMaterials[name];
      final unitText = unit == null || unit.isEmpty ? '' : unit;
      return '材料：$name  数量：$quantity$unitText';
    }
    final note = (record.note ?? '').trim();
    if (note.isEmpty) {
      return '备注：无';
    }
    return '备注：$note';
  }
}

class _ReimbursementBottomSheet extends StatefulWidget {
  final double totalAmount;
  final List<int> recordIds;
  final Map<String, String> baseMaterials;
  final VoidCallback onCompleted;

  const _ReimbursementBottomSheet({
    required this.totalAmount,
    required this.recordIds,
    required this.baseMaterials,
    required this.onCompleted,
  });

  @override
  State<_ReimbursementBottomSheet> createState() =>
      _ReimbursementBottomSheetState();
}

class _ReimbursementBottomSheetState extends State<_ReimbursementBottomSheet> {
  late DateTime _selectedDate;
  final TextEditingController _noteController = TextEditingController();
  static const String _materialNoteSplitter = '｜';

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    try {
      final reimbursement = Reimbursement(
        totalAmount: widget.totalAmount,
        date: _selectedDate,
        note: _noteController.text,
        createdAt: DateTime.now(),
      );

      await RecordDatabase.instance.createReimbursement(
        reimbursement,
        widget.recordIds,
      );

      final records = await RecordDatabase.instance.fetchRecordsByIds(
        widget.recordIds,
      );
      await _exportAndShare(records);

      if (mounted) {
        widget.onCompleted();
      }
    } catch (e) {
      debugPrint('Error creating reimbursement: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('报销失败: $e')));
      }
    }
  }

  Future<void> _exportAndShare(List<TransactionRecord> records) async {
    try {
      final filePath = await _saveAsXlsx(records);
      if (Platform.isAndroid) {
        final file = XFile(
          filePath,
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        );
        await SharePlus.instance.share(ShareParams(files: [file]));
        return;
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导出到 $filePath')));
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('导出失败，请重试')));
    }
  }

  Future<String> _saveAsXlsx(List<TransactionRecord> records) async {
    final headers = [
      '序号',
      '日期',
      '收支类型',
      '账目金额',
      '账目备注',
      '分类',
      '材料名称',
      '数量',
      '单位',
    ];
    final expenseRecords = records
        .where((record) => record.type == 'expense')
        .toList();
    final workbook = excel.Excel.createExcel();
    final sheet = workbook['Sheet1'];
    sheet.appendRow(headers);
    for (var i = 0; i < expenseRecords.length; i++) {
      final record = expenseRecords[i];
      final note = (record.note ?? '').trim();
      final material = _parseExportMaterialFields(
        category: record.category,
        note: note,
      );
      sheet.appendRow([
        i + 1,
        DateFormat('yyyy-MM-dd').format(record.date),
        '支出',
        record.amount,
        note,
        record.category,
        material.name,
        material.quantity,
        material.unit,
      ]);
    }
    final directory = await _exportDirectory();
    final fileName = '报销清单_${_formatDateTime(DateTime.now())}.xlsx';
    final exportFile = File(p.join(directory.path, fileName));
    final bytes = workbook.save();
    if (bytes == null) {
      throw Exception('导出失败');
    }
    await exportFile.writeAsBytes(bytes, flush: true);
    return exportFile.path;
  }

  Future<Directory> _exportDirectory() async {
    if (Platform.isAndroid) {
      return getTemporaryDirectory();
    }
    return getApplicationDocumentsDirectory();
  }

  _ExportMaterialFields _parseExportMaterialFields({
    required String category,
    required String note,
  }) {
    if (category != '课程材料') {
      return const _ExportMaterialFields();
    }
    final trimmedNote = note.trim();
    if (trimmedNote.isEmpty) {
      return const _ExportMaterialFields();
    }
    final splitIndex = trimmedNote.indexOf(_materialNoteSplitter);
    final materialName = splitIndex == -1
        ? trimmedNote
        : trimmedNote.substring(0, splitIndex).trim();
    if (materialName.isEmpty) {
      return const _ExportMaterialFields();
    }
    final quantity = splitIndex == -1
        ? ''
        : trimmedNote
              .substring(splitIndex + _materialNoteSplitter.length)
              .trim();
    final unit = widget.baseMaterials[materialName] ?? '';
    return _ExportMaterialFields(
      name: materialName,
      quantity: quantity,
      unit: unit,
    );
  }

  String _formatDateTime(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    final second = date.second.toString().padLeft(2, '0');
    return '$year$month$day'
        '_$hour$minute$second';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '确认报销',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ListTile(
              title: const Text('报销金额'),
              trailing: Text(
                widget.totalAmount.toStringAsFixed(2),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              title: const Text('报销日期'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(DateFormat('yyyy-MM-dd').format(_selectedDate)),
                  const Icon(Icons.chevron_right),
                ],
              ),
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _selectedDate,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now(),
                );
                if (date != null) {
                  setState(() => _selectedDate = date);
                }
              },
            ),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(
                labelText: '备注',
                hintText: '请输入备注信息',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text('完成报销'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
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
