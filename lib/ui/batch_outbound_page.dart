import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/record_database.dart';

class BatchOutboundPage extends StatefulWidget {
  const BatchOutboundPage({super.key});

  @override
  State<BatchOutboundPage> createState() => _BatchOutboundPageState();
}

class _BatchOutboundPageState extends State<BatchOutboundPage> {
  List<InventoryOutBatch> _batches = [];
  bool _isLoading = true;
  bool _isImporting = false;
  String? _pendingFileName;
  List<_PreviewItem> _previewItems = [];

  @override
  void initState() {
    super.initState();
    _loadBatches();
  }

  Future<void> _loadBatches() async {
    setState(() => _isLoading = true);
    try {
      final list = await RecordDatabase.instance.fetchOutBatches();
      setState(() {
        _batches = list;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading batches: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _pickAndPreviewFile() async {
    setState(() {
      _isImporting = true;
      _previewItems = [];
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        setState(() {
          _isImporting = false;
          _pendingFileName = null;
        });
        return;
      }
      final file = result.files.single;
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (bytes == null) {
        _showMessage('读取文件失败');
        setState(() => _isImporting = false);
        return;
      }
      final workbook = Excel.decodeBytes(bytes);
      Sheet? sheet = workbook.tables['Sheet1'];
      sheet ??= workbook.tables.isEmpty ? null : workbook.tables.values.first;
      if (sheet == null || sheet.rows.isEmpty) {
        _showMessage('未读取到数据');
        setState(() => _isImporting = false);
        return;
      }
      final headerRow = sheet.rows.first;
      final headerIndex = <String, int>{};
      for (var i = 0; i < headerRow.length; i++) {
        final title = _cellString(headerRow, i);
        if (title.isNotEmpty) {
          headerIndex[title] = i;
        }
      }
      final nameIndex = headerIndex['材料名称'];
      final quantityIndex = headerIndex['出库数量'] ?? headerIndex['数量'];
      if (nameIndex == null || quantityIndex == null) {
        _showMessage('模板缺少材料名称或出库数量列');
        setState(() => _isImporting = false);
        return;
      }
      final noteIndex = headerIndex['出库备注'] ?? headerIndex['备注'];
      final dateIndex = headerIndex['出库日期'] ?? headerIndex['日期'];
      final baseMaterials = await RecordDatabase.instance.fetchBaseMaterials();
      final materialMap = {
        for (final item in baseMaterials) item.name: item.unit,
      };
      final previewItems = <_PreviewItem>[];
      final missingNames = <String>{};
      for (var i = 1; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        final name = _cellString(row, nameIndex);
        if (name.isEmpty) {
          continue;
        }
        if (!materialMap.containsKey(name)) {
          missingNames.add(name);
          previewItems.add(_PreviewItem(
            materialName: name,
            quantity: 0,
            unit: '',
            note: '',
            date: null,
            isValid: false,
            error: '材料不存在',
          ));
          continue;
        }
        final quantity = _cellDouble(row, quantityIndex);
        if (quantity == null || quantity <= 0) {
          continue;
        }
        final note = noteIndex == null ? '' : _cellString(row, noteIndex);
        final date = dateIndex == null ? null : _cellDate(row, dateIndex);
        previewItems.add(_PreviewItem(
          materialName: name,
          quantity: quantity,
          unit: materialMap[name] ?? '',
          note: note,
          date: date,
          isValid: true,
        ));
      }
      if (missingNames.isNotEmpty) {
        _showMessage('以下材料不在基础材料中：${missingNames.join('、')}');
      }
      if (previewItems.where((e) => e.isValid).isEmpty) {
        _showMessage('没有可导入的有效数据');
        setState(() {
          _isImporting = false;
          _pendingFileName = null;
        });
        return;
      }
      setState(() {
        _pendingFileName = file.name;
        _previewItems = previewItems;
        _isImporting = false;
      });
    } catch (e) {
      debugPrint('预览失败: $e');
      _showMessage('预览失败，请重试');
      setState(() => _isImporting = false);
    }
  }

  Future<void> _executeBatchOutbound() async {
    if (_previewItems.isEmpty || _pendingFileName == null) {
      return;
    }
    final validItems = _previewItems.where((e) => e.isValid).toList();
    if (validItems.isEmpty) {
      _showMessage('没有有效数据可出库');
      return;
    }
    setState(() => _isImporting = true);
    try {
      final summaryList = await RecordDatabase.instance.fetchInventorySummary();
      final remainingMap = {
        for (final item in summaryList)
          item.materialName: item.remainingQuantity,
      };
      final outByName = <String, double>{};
      for (final item in validItems) {
        outByName[item.materialName] =
            (outByName[item.materialName] ?? 0) + item.quantity;
      }
      final insufficientDetails = <String>[];
      outByName.forEach((name, quantity) {
        final remaining = remainingMap[name] ?? 0;
        if (remaining < quantity) {
          insufficientDetails.add(
            '$name：现有${remaining.toStringAsFixed(2)}，需出库${quantity.toStringAsFixed(2)}',
          );
        }
      });
      if (insufficientDetails.isNotEmpty) {
        final confirmed = await _showConfirmDialog(
          '库存不足',
          '${insufficientDetails.join('\n')}\n库存不足，是否仍然出库？',
        );
        if (!confirmed) {
          setState(() => _isImporting = false);
          return;
        }
      }
      final batchId = await RecordDatabase.instance.insertOutBatch(
        sourceFileName: _pendingFileName,
      );
      var inserted = 0;
      for (final item in validItems) {
        await RecordDatabase.instance.insertOutRecord(
          materialName: item.materialName,
          quantity: item.quantity,
          unit: item.unit,
          note: item.note.isEmpty ? null : item.note,
          outDate: item.date ?? DateTime.now(),
          batchId: batchId,
        );
        inserted += 1;
      }
      setState(() {
        _previewItems = [];
        _pendingFileName = null;
        _isImporting = false;
      });
      _showMessage('批量出库成功：$inserted 条记录');
      _loadBatches();
    } catch (e) {
      debugPrint('批量出库失败: $e');
      _showMessage('批量出库失败，请重试');
      setState(() => _isImporting = false);
    }
  }

  Future<void> _undoBatch(InventoryOutBatch batch) async {
    final confirmed = await _showInputConfirmDialog(
      batch: batch,
      requiredText: '我确定要撤销出库',
    );
    if (!confirmed) {
      return;
    }
    try {
      final deleted = await RecordDatabase.instance.deleteOutBatch(batch.id!);
      if (deleted > 0) {
        _showMessage('已撤销批次，删除 $deleted 条记录');
        _loadBatches();
      } else {
        _showMessage('撤销失败，批次不存在');
      }
    } catch (e) {
      debugPrint('撤销批次失败: $e');
      _showMessage('撤销失败，请重试');
    }
  }

  Future<bool> _showInputConfirmDialog({
    required InventoryOutBatch batch,
    required String requiredText,
  }) async {
    if (!mounted) return false;
    final controller = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('撤销出库批次'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '批次时间：${_formatDateTime(batch.createdAt)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                Text(
                  '出库记录数：${batch.itemCount ?? 0} 条',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                if (batch.sourceFileName != null)
                  Text(
                    '源文件：${batch.sourceFileName}',
                    style: const TextStyle(fontSize: 12, color: Colors.black45),
                  ),
                const SizedBox(height: 16),
                Text(
                  '此操作将删除该批次的所有出库记录，无法恢复。',
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Text(
                  '请输入 "$requiredText" 以确认撤销：',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: requiredText,
                    border: const OutlineInputBorder(),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  onChanged: (value) {
                    // 实时验证输入
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final input = controller.text.trim();
                if (input == requiredText) {
                  Navigator.of(context).pop(true);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('请输入正确的确认文字：$requiredText')),
                  );
                }
              },
              child: const Text('确认撤销'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result ?? false;
  }

  Future<void> _showBatchDetails(InventoryOutBatch batch) async {
    if (batch.id == null) return;
    final records = await RecordDatabase.instance.fetchOutRecordsByBatch(batch.id!);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('批次详情｜${_formatDateTime(batch.createdAt)}'),
          content: SizedBox(
            width: 400,
            height: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (batch.sourceFileName != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('源文件：${batch.sourceFileName}',
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                if (batch.note != null && batch.note!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('备注：${batch.note}',
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                const Divider(),
                Expanded(
                  child: records.isEmpty
                      ? const Center(child: Text('无出库记录'))
                      : ListView.builder(
                          itemCount: records.length,
                          itemBuilder: (context, index) {
                            final record = records[index];
                            return ListTile(
                              dense: true,
                              title: Text(record.materialName),
                              subtitle: Text(
                                '${record.quantity}${record.unit ?? ''}',
                                style: const TextStyle(color: Colors.red),
                              ),
                              trailing: Text(
                                DateFormat('yyyy-MM-dd').format(
                                  DateTime.parse(record.createdAt),
                                ),
                                style: const TextStyle(fontSize: 12, color: Colors.black45),
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

  String _cellString(List<Data?> row, int index) {
    if (index < 0 || index >= row.length) {
      return '';
    }
    final value = row[index]?.value;
    if (value == null) {
      return '';
    }
    return value.toString().trim();
  }

  double? _cellDouble(List<Data?> row, int index) {
    if (index < 0 || index >= row.length) {
      return null;
    }
    final value = row[index]?.value;
    if (value is num) {
      return value.toDouble();
    }
    if (value == null) {
      return null;
    }
    return double.tryParse(value.toString().trim());
  }

  DateTime? _cellDate(List<Data?> row, int index) {
    if (index < 0 || index >= row.length) {
      return null;
    }
    final value = row[index]?.value;
    if (value is DateTime) {
      return value;
    }
    if (value == null) {
      return null;
    }
    final text = value.toString().trim();
    if (text.isEmpty) {
      return null;
    }
    if (text.contains('/')) {
      final parts = text.split('/');
      if (parts.length >= 3) {
        final year = int.tryParse(parts[0].trim());
        final month = int.tryParse(parts[1].trim());
        final day = int.tryParse(parts[2].trim());
        if (year != null && month != null && day != null) {
          return DateTime(year, month, day);
        }
      }
    }
    return DateTime.tryParse(text);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _showConfirmDialog(String title, String message) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
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
        );
      },
    );
    return result ?? false;
  }

  String _formatDateTime(String isoString) {
    final date = DateTime.parse(isoString);
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(date);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('批量出库管理'),
      ),
      body: Column(
        children: [
          // 预览区域
          if (_pendingFileName != null || _previewItems.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                border: Border(
                  bottom: BorderSide(color: Colors.black12),
                ),
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
                        onPressed: _isImporting ? null : () {
                          setState(() {
                            _previewItems = [];
                            _pendingFileName = null;
                          });
                        },
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: _isImporting ? null : _executeBatchOutbound,
                        child: _isImporting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('执行出库'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '有效记录：${_previewItems.where((e) => e.isValid).length} 条',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  if (_previewItems.where((e) => !e.isValid).isNotEmpty)
                    Text(
                      '无效记录：${_previewItems.where((e) => !e.isValid).length} 条',
                      style: const TextStyle(fontSize: 12, color: Colors.red),
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 150,
                    child: ListView.builder(
                      itemCount: _previewItems.length,
                      itemBuilder: (context, index) {
                        final item = _previewItems[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            item.isValid ? Icons.check_circle : Icons.error,
                            color: item.isValid ? Colors.green : Colors.red,
                            size: 20,
                          ),
                          title: Text(item.materialName),
                          subtitle: item.isValid
                              ? Text('${item.quantity}${item.unit}')
                              : Text(item.error ?? '无效', style: const TextStyle(color: Colors.red)),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          // 操作按钮
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isImporting ? null : _pickAndPreviewFile,
                    icon: _isImporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.file_upload),
                    label: const Text('导入出库模板'),
                  ),
                ),
              ],
            ),
          ),
          // 历史批次列表
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text(
                  '历史出库批次',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '共 ${_batches.length} 个批次',
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
                          '暂无历史出库批次',
                          style: TextStyle(color: Colors.black45),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _batches.length,
                        itemBuilder: (context, index) {
                          final batch = _batches[index];
                          return _buildBatchItem(batch);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchItem(InventoryOutBatch batch) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatDateTime(batch.createdAt),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '出库记录：${batch.itemCount ?? 0} 条',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  if (batch.sourceFileName != null)
                    Text(
                      '源文件：${batch.sourceFileName}',
                      style: const TextStyle(fontSize: 12, color: Colors.black45),
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => _showBatchDetails(batch),
              child: const Text('详情'),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () => _undoBatch(batch),
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.errorContainer,
              ),
              child: const Text('撤销'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewItem {
  _PreviewItem({
    required this.materialName,
    required this.quantity,
    required this.unit,
    required this.note,
    required this.date,
    required this.isValid,
    this.error,
  });

  final String materialName;
  final double quantity;
  final String unit;
  final String note;
  final DateTime? date;
  final bool isValid;
  final String? error;
}