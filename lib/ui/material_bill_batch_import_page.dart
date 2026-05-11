import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/record_database.dart';
import '../data/transaction_record.dart';

class MaterialBillBatchImportPage extends StatefulWidget {
  const MaterialBillBatchImportPage({super.key});

  @override
  State<MaterialBillBatchImportPage> createState() =>
      _MaterialBillBatchImportPageState();
}

class _MaterialBillBatchImportPageState
    extends State<MaterialBillBatchImportPage> {
  List<MaterialBillImportBatch> _batches = [];
  List<Bill> _bills = [];
  List<Account> _accounts = [];
  bool _isLoading = true;
  bool _isWorking = false;
  String? _pendingFileName;
  _ImportDraft? _pendingDraft;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final batches = await RecordDatabase.instance
          .fetchMaterialBillImportBatches();
      final bills = await RecordDatabase.instance.fetchBills();
      final accounts = await RecordDatabase.instance.fetchAccounts();
      if (!mounted) return;
      setState(() {
        _batches = batches;
        _bills = bills;
        _accounts = accounts;
        _isLoading = false;
      });
    } catch (error) {
      debugPrint('加载批量材料账单数据失败: $error');
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showMessage('加载失败，请重试');
    }
  }

  Future<void> _downloadTemplate() async {
    if (_isWorking) return;
    final options = await _showTemplateOptionsDialog();
    if (options == null) {
      return;
    }
    setState(() => _isWorking = true);
    try {
      final workbook = Excel.createExcel();
      final sheet = workbook['Sheet1'];
      final dateText = DateFormat('yyyy-MM-dd').format(options.recordDate);
      sheet.appendRow(['批量材料账单导入模板', '', '']);
      sheet.appendRow(['账本', options.bill.name]);
      sheet.appendRow(['账户', options.account.name]);
      sheet.appendRow(['日期', dateText]);
      sheet.appendRow(['导入备注', options.note]);
      sheet.appendRow(['填写说明：只填写下方三列；材料名称必须已在基础材料中维护；数量和总价必须大于0。', '', '']);
      sheet.appendRow(['材料名称', '数量', '总价']);
      for (var i = 0; i < 20; i++) {
        sheet.appendRow(['', '', '']);
      }
      _styleTemplateSheet(sheet);
      sheet.setColWidth(0, 28);
      sheet.setColWidth(1, 16);
      sheet.setColWidth(2, 16);
      final bytes = workbook.encode()!;
      final fileName =
          '批量材料账单导入模板_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
      if (Platform.isWindows) {
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '请选择保存位置',
          fileName: fileName,
          allowedExtensions: ['xlsx'],
          type: FileType.custom,
        );
        if (outputFile != null) {
          await File(outputFile).writeAsBytes(bytes);
          _showMessage('模板已下载');
        }
      } else {
        final directory = await getApplicationDocumentsDirectory();
        final filePath = p.join(directory.path, fileName);
        await File(filePath).writeAsBytes(bytes);
        await SharePlus.instance.share(
          ShareParams(files: [XFile(filePath)], text: '批量材料账单导入模板'),
        );
      }
    } catch (error) {
      debugPrint('下载批量材料账单模板失败: $error');
      _showMessage('模板下载失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _isWorking = false);
      }
    }
  }

  Future<_TemplateOptions?> _showTemplateOptionsDialog() async {
    if (_bills.isEmpty || _accounts.isEmpty) {
      _showMessage('请先维护账本和账户');
      return null;
    }
    var selectedBill = _bills.firstWhere(
      (item) => item.isDefault,
      orElse: () => _bills.first,
    );
    var selectedAccount = _accounts.firstWhere(
      (item) => item.isDefault,
      orElse: () => _accounts.first,
    );
    var selectedDate = DateTime.now();
    final noteController = TextEditingController();
    final result = await showDialog<_TemplateOptions>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('下载导入模板'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      initialValue: selectedBill.id,
                      decoration: const InputDecoration(labelText: '账本'),
                      items: _bills
                          .map(
                            (bill) => DropdownMenuItem<int>(
                              value: bill.id,
                              child: Text(bill.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        final next = _bills.firstWhere(
                          (item) => item.id == value,
                          orElse: () => selectedBill,
                        );
                        setDialogState(() => selectedBill = next);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: selectedAccount.id,
                      decoration: const InputDecoration(labelText: '账户'),
                      items: _accounts
                          .map(
                            (account) => DropdownMenuItem<int>(
                              value: account.id,
                              child: Text(account.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        final next = _accounts.firstWhere(
                          (item) => item.id == value,
                          orElse: () => selectedAccount,
                        );
                        setDialogState(() => selectedAccount = next);
                      },
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('日期'),
                      subtitle: Text(
                        DateFormat('yyyy-MM-dd').format(selectedDate),
                      ),
                      trailing: const Icon(Icons.calendar_month_outlined),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: selectedDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setDialogState(() => selectedDate = picked);
                        }
                      },
                    ),
                    TextField(
                      controller: noteController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: '备注',
                        hintText: '仅用于导入历史详情',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(context).pop(
                      _TemplateOptions(
                        bill: selectedBill,
                        account: selectedAccount,
                        recordDate: selectedDate,
                        note: noteController.text.trim(),
                      ),
                    );
                  },
                  child: const Text('下载'),
                ),
              ],
            );
          },
        );
      },
    );
    noteController.dispose();
    return result;
  }

  void _styleTemplateSheet(Sheet sheet) {
    final titleStyle = CellStyle(
      bold: true,
      fontSize: 16,
      fontColorHex: '#FFFFFFFF',
      backgroundColorHex: '#FF2F5597',
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
    );
    final labelStyle = CellStyle(
      bold: true,
      fontColorHex: '#FF1F4E78',
      backgroundColorHex: '#FFD9EAF7',
      horizontalAlign: HorizontalAlign.Center,
    );
    final valueStyle = CellStyle(backgroundColorHex: '#FFF7FBFF');
    final instructionStyle = CellStyle(
      fontColorHex: '#FF7F6000',
      backgroundColorHex: '#FFFFF2CC',
      textWrapping: TextWrapping.WrapText,
    );
    final headerStyle = CellStyle(
      bold: true,
      fontColorHex: '#FFFFFFFF',
      backgroundColorHex: '#FF70AD47',
      horizontalAlign: HorizontalAlign.Center,
    );
    final inputStyle = CellStyle(backgroundColorHex: '#FFFFFDF2');

    sheet.merge(
      CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
      CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: 0),
      customValue: '批量材料账单导入模板',
    );
    sheet.merge(
      CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 5),
      CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: 5),
      customValue: '填写说明：只填写下方三列；材料名称必须已在基础材料中维护；数量和总价必须大于0。',
    );
    _setCellStyle(sheet, 0, 0, titleStyle);
    for (var row = 1; row <= 4; row++) {
      _setCellStyle(sheet, row, 0, labelStyle);
      _setCellStyle(sheet, row, 1, valueStyle);
      _setCellStyle(sheet, row, 2, valueStyle);
    }
    _setCellStyle(sheet, 5, 0, instructionStyle);
    for (var col = 0; col < 3; col++) {
      _setCellStyle(sheet, 6, col, headerStyle);
    }
    for (var row = 7; row < sheet.maxRows; row++) {
      for (var col = 0; col < 3; col++) {
        _setCellStyle(sheet, row, col, inputStyle);
      }
    }
  }

  void _setCellStyle(Sheet sheet, int row, int col, CellStyle style) {
    sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
            .cellStyle =
        style;
  }

  Future<void> _pickAndPreviewFile() async {
    if (_isWorking) return;
    setState(() {
      _isWorking = true;
      _pendingFileName = null;
      _pendingDraft = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        if (mounted) setState(() => _isWorking = false);
        return;
      }
      final file = result.files.single;
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (bytes == null) {
        _showMessage('读取文件失败');
        if (mounted) setState(() => _isWorking = false);
        return;
      }
      final draft = await _parseImportFile(bytes, file.name);
      if (draft == null) {
        if (mounted) setState(() => _isWorking = false);
        return;
      }
      setState(() {
        _pendingFileName = file.name;
        _pendingDraft = draft;
        _isWorking = false;
      });
    } catch (error) {
      debugPrint('预览批量材料账单失败: $error');
      _showMessage('预览失败，请检查模板内容');
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Future<_ImportDraft?> _parseImportFile(
    Uint8List bytes,
    String fileName,
  ) async {
    final workbook = Excel.decodeBytes(bytes);
    Sheet? sheet = workbook.tables['Sheet1'];
    sheet ??= workbook.tables.isEmpty ? null : workbook.tables.values.first;
    if (sheet == null || sheet.rows.isEmpty) {
      _showMessage('未读取到数据');
      return null;
    }
    final metadata = _readTopMetadata(sheet);
    final headerRowIndex = _findDetailHeaderRow(sheet);
    if (headerRowIndex == null) {
      _showMessage('模板缺少材料名称、数量或总价列');
      return null;
    }
    final header = <String, int>{};
    final headerRow = sheet.rows[headerRowIndex];
    for (var i = 0; i < headerRow.length; i++) {
      final title = _cellString(headerRow, i);
      if (title.isNotEmpty) {
        header[title] = i;
      }
    }
    final nameIndex = header['材料名称'];
    final quantityIndex = header['数量'];
    final amountIndex = header['总价'];
    if (nameIndex == null || quantityIndex == null || amountIndex == null) {
      _showMessage('模板缺少材料名称、数量或总价列');
      return null;
    }

    final materials = await RecordDatabase.instance.fetchBaseMaterials();
    final materialMap = {for (final item in materials) item.name: item.unit};
    final initQuantityMap = {
      for (final item in materials) item.name: item.initQuantity,
    };
    final missingNames = <String>{};
    final entries = <MaterialBillImportItem>[];

    for (var i = headerRowIndex + 1; i < sheet.rows.length; i++) {
      final row = sheet.rows[i];
      final materialName = _cellString(row, nameIndex);
      if (materialName.isEmpty) {
        continue;
      }
      if (!materialMap.containsKey(materialName)) {
        missingNames.add(materialName);
        continue;
      }
      final quantity = _cellDouble(row, quantityIndex);
      final amount = _cellDouble(row, amountIndex);
      if (quantity == null || quantity <= 0 || amount == null || amount <= 0) {
        continue;
      }
      entries.add(
        MaterialBillImportItem(
          materialName: materialName,
          quantity: quantity,
          totalAmount: amount,
          unit: materialMap[materialName],
        ),
      );
    }

    if (missingNames.isNotEmpty) {
      await _showBlockDialog(
        '导入失败',
        '以下材料不在基础材料中：${missingNames.join('、')}\n请先维护基础材料后再导入。',
      );
      return null;
    }
    if (entries.isEmpty) {
      _showMessage('没有可导入的有效数据');
      return null;
    }

    final resolved = _resolveMetadata(metadata);
    if (resolved == null) {
      _showMessage('模板中的账本、账户或日期无效，请重新下载模板');
      return null;
    }
    final importedQuantityMap = <String, double>{};
    for (final item in entries) {
      importedQuantityMap[item.materialName] =
          (importedQuantityMap[item.materialName] ?? 0) + item.quantity;
    }
    final importedNames = importedQuantityMap.keys.toSet();
    final initClearItems =
        importedNames
            .map(
              (name) => _InitClearItem(
                materialName: name,
                importedQuantity: importedQuantityMap[name] ?? 0,
                initQuantity: initQuantityMap[name] ?? 0,
              ),
            )
            .where((item) => item.initQuantity > 0)
            .toList()
          ..sort((a, b) => a.materialName.compareTo(b.materialName));
    return _ImportDraft(
      bill: resolved.bill,
      account: resolved.account,
      recordDate: resolved.recordDate,
      note: resolved.note,
      sourceFileName: fileName,
      items: entries,
      initClearItems: initClearItems,
    );
  }

  int? _findDetailHeaderRow(Sheet sheet) {
    for (var rowIndex = 0; rowIndex < sheet.rows.length; rowIndex++) {
      final row = sheet.rows[rowIndex];
      final titles = <String>{};
      for (var col = 0; col < row.length; col++) {
        final title = _cellString(row, col);
        if (title.isNotEmpty) {
          titles.add(title);
        }
      }
      if (titles.contains('材料名称') &&
          titles.contains('数量') &&
          titles.contains('总价')) {
        return rowIndex;
      }
    }
    return null;
  }

  _ImportMetadata? _readTopMetadata(Sheet sheet) {
    String valueAfterLabel(String label) {
      for (final row in sheet.rows) {
        for (var col = 0; col < row.length; col++) {
          if (_cellString(row, col) == label) {
            return _cellString(row, col + 1);
          }
        }
      }
      return '';
    }

    final billName = valueAfterLabel('账本');
    final accountName = valueAfterLabel('账户');
    final dateText = valueAfterLabel('日期');
    final note = valueAfterLabel('导入备注');
    final date = DateTime.tryParse(dateText);
    if (billName.isEmpty &&
        accountName.isEmpty &&
        date == null &&
        note.isEmpty) {
      return null;
    }
    return _ImportMetadata(
      billName: billName,
      accountName: accountName,
      recordDate: date,
      note: note,
    );
  }

  _ResolvedMetadata? _resolveMetadata(_ImportMetadata? metadata) {
    if (_bills.isEmpty || _accounts.isEmpty) {
      return null;
    }
    final bill = _findBillByName(metadata?.billName);
    final account = _findAccountByName(metadata?.accountName);
    final resolvedBill =
        bill ??
        _bills.firstWhere((item) => item.isDefault, orElse: () => _bills.first);
    final resolvedAccount =
        account ??
        _accounts.firstWhere(
          (item) => item.isDefault,
          orElse: () => _accounts.first,
        );
    final date = metadata?.recordDate ?? DateTime.now();
    return _ResolvedMetadata(
      bill: resolvedBill,
      account: resolvedAccount,
      recordDate: DateTime(date.year, date.month, date.day),
      note: metadata?.note ?? '',
    );
  }

  Bill? _findBillByName(String? name) {
    final target = (name ?? '').trim();
    if (target.isEmpty) return null;
    for (final bill in _bills) {
      if (bill.name == target) return bill;
    }
    return null;
  }

  Account? _findAccountByName(String? name) {
    final target = (name ?? '').trim();
    if (target.isEmpty) return null;
    for (final account in _accounts) {
      if (account.name == target) return account;
    }
    return null;
  }

  Future<void> _executeImport() async {
    final draft = _pendingDraft;
    if (draft == null || _isWorking) {
      return;
    }
    setState(() => _isWorking = true);
    try {
      final result = await RecordDatabase.instance.importMaterialBillBatch(
        billId: draft.bill.id!,
        accountId: draft.account.id!,
        billName: draft.bill.name,
        accountName: draft.account.name,
        recordDate: draft.recordDate,
        items: draft.items,
        note: draft.note.isEmpty ? null : draft.note,
        sourceFileName: draft.sourceFileName,
      );
      setState(() {
        _pendingDraft = null;
        _pendingFileName = null;
        _isWorking = false;
      });
      _showImportSuccessMessage(
        itemCount: draft.items.length,
        batchId: result.batchId,
        clearedInitMaterialNames: result.clearedInitMaterialNames,
      );
      _loadData();
    } catch (error) {
      debugPrint('批量材料账单导入失败: $error');
      _showMessage('导入失败，请重试');
      if (mounted) setState(() => _isWorking = false);
    }
  }

  void _showImportSuccessMessage({
    required int itemCount,
    required int batchId,
    required List<String> clearedInitMaterialNames,
  }) {
    if (clearedInitMaterialNames.isEmpty) {
      _showMessage('导入成功：$itemCount 条，批次 $batchId。请添加一笔同金额收入用于平账。');
      return;
    }
    final namesText = clearedInitMaterialNames.length <= 5
        ? clearedInitMaterialNames.join('、')
        : '${clearedInitMaterialNames.take(5).join('、')} 等 ${clearedInitMaterialNames.length} 个材料';
    _showMessage(
      '导入成功：$itemCount 条，批次 $batchId。已将 $namesText 的初始化数量置为0。请添加一笔同金额收入用于平账。建议后续都使用批量导入材料账单维护历史数据，不要再用初始化。',
    );
  }

  Future<void> _undoBatch(MaterialBillImportBatch batch) async {
    if (batch.id == null) return;
    final isLatest = await RecordDatabase.instance
        .isLatestMaterialBillImportBatch(batch.id!);
    if (!isLatest) {
      _showMessage('只能撤销最近一次导入');
      return;
    }
    final confirmed = await _showConfirmDialog(
      '撤销导入',
      '此操作将删除该批次生成的账单和库存入库记录，且只能撤销最近一次导入。是否继续？',
    );
    if (!confirmed) return;
    try {
      final deleted = await RecordDatabase.instance
          .deleteLatestMaterialBillImportBatch(batch.id!);
      if (deleted > 0) {
        _showMessage('已撤销最近一次导入');
        _loadData();
      } else {
        _showMessage('撤销失败，只能撤销最近一次导入');
      }
    } catch (error) {
      debugPrint('撤销批量材料账单失败: $error');
      _showMessage('撤销失败，请重试');
    }
  }

  Future<void> _showBatchDetails(MaterialBillImportBatch batch) async {
    if (batch.id == null) return;
    final items = await RecordDatabase.instance
        .fetchMaterialBillImportItemsByBatch(batch.id!);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('导入详情｜${_formatDateTime(batch.createdAt)}'),
          content: SizedBox(
            width: 460,
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('账本：${batch.billName}'),
                Text('账户：${batch.accountName}'),
                Text('日期：${_formatDate(batch.recordDate)}'),
                if ((batch.sourceFileName ?? '').isNotEmpty)
                  Text('源文件：${batch.sourceFileName}'),
                if ((batch.note ?? '').isNotEmpty) Text('备注：${batch.note}'),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return ListTile(
                        dense: true,
                        title: Text(item.materialName),
                        subtitle: Text(
                          '${_formatCompactNumber(item.quantity)}${item.unit ?? ''}',
                        ),
                        trailing: Text(
                          '¥${item.totalAmount.toStringAsFixed(2)}',
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  String _cellString(List<Data?> row, int? index) {
    if (index == null || index < 0 || index >= row.length) {
      return '';
    }
    final value = row[index]?.value;
    if (value == null) return '';
    return value.toString().trim();
  }

  double? _cellDouble(List<Data?> row, int? index) {
    if (index == null || index < 0 || index >= row.length) {
      return null;
    }
    final value = row[index]?.value;
    if (value is num) return value.toDouble();
    if (value == null) return null;
    return double.tryParse(value.toString().trim());
  }

  Future<void> _showBlockDialog(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<bool> _showConfirmDialog(String title, String message) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDateTime(String isoString) {
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.parse(isoString));
  }

  String _formatDate(String isoString) {
    return DateFormat('yyyy-MM-dd').format(DateTime.parse(isoString));
  }

  String _formatCompactNumber(double value) {
    final rounded = value.toStringAsFixed(2);
    if (rounded.endsWith('.00')) {
      return rounded.substring(0, rounded.length - 3);
    }
    if (rounded.endsWith('0')) {
      return rounded.substring(0, rounded.length - 1);
    }
    return rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('批量导入材料账单')),
      body: Column(
        children: [
          if (_pendingDraft != null) _buildPreviewPanel(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isWorking ? null : _downloadTemplate,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('下载模板'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isWorking ? null : _pickAndPreviewFile,
                    icon: _isWorking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.upload_file_outlined),
                    label: const Text('导入'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text(
                  '导入历史',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '共 ${_batches.length} 次',
                  style: const TextStyle(fontSize: 12, color: Colors.black45),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _batches.isEmpty
                ? const Center(
                    child: Text(
                      '暂无导入历史',
                      style: TextStyle(color: Colors.black45),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _batches.length,
                    itemBuilder: (context, index) {
                      return _buildBatchItem(_batches[index], index == 0);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewPanel() {
    final draft = _pendingDraft!;
    final total = draft.items.fold<double>(
      0,
      (sum, item) => sum + item.totalAmount,
    );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: const Border(bottom: BorderSide(color: Colors.black12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '预览：$_pendingFileName',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: _isWorking
                    ? null
                    : () => setState(() {
                        _pendingDraft = null;
                        _pendingFileName = null;
                      }),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _isWorking ? null : _executeImport,
                child: const Text('确认导入'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${draft.bill.name} · ${draft.account.name} · ${DateFormat('yyyy-MM-dd').format(draft.recordDate)} · ${draft.items.length} 条 · ¥${total.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          _buildInitClearPreview(draft),
          const SizedBox(height: 8),
          SizedBox(
            height: 128,
            child: ListView.builder(
              itemCount: draft.items.length,
              itemBuilder: (context, index) {
                final item = draft.items[index];
                return ListTile(
                  dense: true,
                  title: Text(item.materialName),
                  subtitle: Text(
                    '${_formatCompactNumber(item.quantity)}${item.unit ?? ''}',
                  ),
                  trailing: Text('¥${item.totalAmount.toStringAsFixed(2)}'),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInitClearPreview(_ImportDraft draft) {
    if (draft.initClearItems.isEmpty) {
      return const Text(
        '本次导入不会清零任何材料初始化数量。',
        style: TextStyle(fontSize: 12, color: Colors.black54),
      );
    }
    final totalInitQuantity = draft.initClearItems.fold<double>(
      0,
      (sum, item) => sum + item.initQuantity,
    );
    final totalImportedQuantity = draft.initClearItems.fold<double>(
      0,
      (sum, item) => sum + (item.importedQuantity ?? 0),
    );
    final totalAmount = draft.items.fold<double>(
      0,
      (sum, item) => sum + item.totalAmount,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF2CC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD6B656)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '确认：本次导入总金额 ¥${totalAmount.toStringAsFixed(2)}。将清零 ${draft.initClearItems.length} 个材料的初始化数量；这些材料导入数量合计 ${_formatCompactNumber(totalImportedQuantity)}，初始化数量合计 ${_formatCompactNumber(totalInitQuantity)}，差异 ${_formatCompactNumber(totalImportedQuantity - totalInitQuantity)}。',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF7F6000),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 72,
            child: ListView.builder(
              itemCount: draft.initClearItems.length,
              itemBuilder: (context, index) {
                final item = draft.initClearItems[index];
                final importedQuantity = item.importedQuantity ?? 0;
                return Text(
                  '${item.materialName}：导入 ${_formatCompactNumber(importedQuantity)} / 初始化 ${_formatCompactNumber(item.initQuantity)} / 差异 ${_formatCompactNumber(importedQuantity - item.initQuantity)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '请核对导入数量、初始化数量和清零数量，没问题后点击“确认导入”。导入后会产生对应支出，请再添加一笔同金额收入用于平账。建议后续都使用批量导入材料账单维护历史数据，不要再用初始化。',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchItem(MaterialBillImportBatch batch, bool isLatest) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () => _showBatchDetails(batch),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatDateTime(batch.createdAt),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${batch.billName} · ${batch.accountName} · ${batch.itemCount ?? 0} 条 · ¥${(batch.totalAmount ?? 0).toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                    if ((batch.note ?? '').isNotEmpty)
                      Text(
                        '备注：${batch.note}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black45,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
            TextButton(
              onPressed: () => _showBatchDetails(batch),
              child: const Text('详情'),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: isLatest ? () => _undoBatch(batch) : null,
              style: FilledButton.styleFrom(
                backgroundColor: isLatest ? colorScheme.errorContainer : null,
              ),
              child: const Text('撤销'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TemplateOptions {
  _TemplateOptions({
    required this.bill,
    required this.account,
    required this.recordDate,
    required this.note,
  });

  final Bill bill;
  final Account account;
  final DateTime recordDate;
  final String note;
}

class _ImportMetadata {
  _ImportMetadata({
    required this.billName,
    required this.accountName,
    this.recordDate,
    required this.note,
  });

  final String billName;
  final String accountName;
  final DateTime? recordDate;
  final String note;
}

class _ResolvedMetadata {
  _ResolvedMetadata({
    required this.bill,
    required this.account,
    required this.recordDate,
    required this.note,
  });

  final Bill bill;
  final Account account;
  final DateTime recordDate;
  final String note;
}

class _InitClearItem {
  _InitClearItem({
    required this.materialName,
    required this.importedQuantity,
    required this.initQuantity,
  });

  final String materialName;
  final double? importedQuantity;
  final double initQuantity;
}

class _ImportDraft {
  _ImportDraft({
    required this.bill,
    required this.account,
    required this.recordDate,
    required this.note,
    required this.sourceFileName,
    required this.items,
    required this.initClearItems,
  });

  final Bill bill;
  final Account account;
  final DateTime recordDate;
  final String note;
  final String sourceFileName;
  final List<MaterialBillImportItem> items;
  final List<_InitClearItem> initClearItems;
}
