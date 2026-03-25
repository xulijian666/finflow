import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/record_database.dart';
import '../data/transaction_record.dart';

class MaterialInventoryInitPage extends StatefulWidget {
  const MaterialInventoryInitPage({super.key});

  @override
  State<MaterialInventoryInitPage> createState() =>
      _MaterialInventoryInitPageState();
}

class _MaterialInventoryInitPageState extends State<MaterialInventoryInitPage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  List<BaseMaterial> _baseMaterials = [];
  List<InventoryInitRecord> _initRecords = [];
  Map<String, String> _materialUnitMap = {};
  bool _loading = true;
  bool _initRecordsLoading = true;
  bool _isSubmitting = false;
  bool _isImporting = false;
  bool _isTemplateExporting = false;
  DateTime _selectedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadBaseMaterials();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    _noteController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadBaseMaterials() async {
    setState(() => _loading = true);
    try {
      final list = await RecordDatabase.instance.fetchBaseMaterials();
      setState(() {
        _baseMaterials = list;
        _materialUnitMap = {for (final item in list) item.name: item.unit};
        _loading = false;
      });
      await _loadInitRecords();
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadInitRecords() async {
    if (mounted) {
      setState(() {
        _initRecordsLoading = true;
      });
    }
    try {
      final list = await RecordDatabase.instance.fetchInitRecords();
      if (!mounted) {
        return;
      }
      setState(() {
        _initRecords = list;
        _initRecordsLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _initRecordsLoading = false;
      });
    }
  }

  Future<void> _submitManualInit() async {
    if (_isSubmitting) {
      return;
    }
    final name = _nameController.text.trim();
    final quantity = double.tryParse(_quantityController.text.trim());
    if (name.isEmpty) {
      _showMessage('请输入材料名称');
      return;
    }
    if (!_materialUnitMap.containsKey(name)) {
      _showMessage('材料名称不在基础材料中，不允许初始化');
      return;
    }
    if (quantity == null || quantity <= 0) {
      _showMessage('请输入有效的初始化数量');
      return;
    }
    setState(() {
      _isSubmitting = true;
    });
    try {
      await RecordDatabase.instance.insertInitRecord(
        materialName: name,
        quantity: quantity,
        unit: _materialUnitMap[name],
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
        initDate: _selectedDate,
      );
      _showMessage('初始化成功');
      _quantityController.clear();
      _noteController.clear();
      await _loadInitRecords();
    } catch (_) {
      _showMessage('初始化失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _importInitByExcel() async {
    if (_isImporting) {
      return;
    }
    setState(() {
      _isImporting = true;
    });
    try {
      final bytes = await _pickImportFile();
      if (bytes == null) {
        return;
      }
      final workbook = Excel.decodeBytes(bytes);
      Sheet? sheet = workbook.tables['Sheet1'];
      sheet ??= workbook.tables.isEmpty ? null : workbook.tables.values.first;
      if (sheet == null || sheet.rows.isEmpty) {
        _showMessage('未读取到数据');
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
      final quantityIndex = headerIndex['初始化数量'] ?? headerIndex['数量'];
      if (nameIndex == null || quantityIndex == null) {
        _showMessage('模板缺少材料名称或初始化数量列');
        return;
      }
      final noteIndex = headerIndex['初始化备注'] ?? headerIndex['备注'];
      final dateIndex = headerIndex['初始化日期'] ?? headerIndex['日期'];
      final detailList = <Map<String, Object?>>[];
      final missingNames = <String>{};
      for (var i = 1; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        final name = _cellString(row, nameIndex);
        if (name.isEmpty) {
          continue;
        }
        if (!_materialUnitMap.containsKey(name)) {
          missingNames.add(name);
          continue;
        }
        final quantity = _cellDouble(row, quantityIndex);
        if (quantity == null || quantity <= 0) {
          continue;
        }
        final note = noteIndex == null ? '' : _cellString(row, noteIndex);
        final date = dateIndex == null ? null : _cellDate(row, dateIndex);
        detailList.add({
          'name': name,
          'quantity': quantity,
          'note': note,
          'date': date,
        });
      }
      if (missingNames.isNotEmpty) {
        await _showBlockDialog('导入失败', '以下材料不在基础材料中：${missingNames.join('、')}');
        return;
      }
      if (detailList.isEmpty) {
        _showMessage('没有可导入的数据');
        return;
      }
      var inserted = 0;
      for (final detail in detailList) {
        final name = detail['name'] as String;
        final quantity = detail['quantity'] as double;
        final note = detail['note'] as String;
        final date = detail['date'] as DateTime? ?? DateTime.now();
        await RecordDatabase.instance.insertInitRecord(
          materialName: name,
          quantity: quantity,
          unit: _materialUnitMap[name],
          note: note.isEmpty ? null : note,
          initDate: date,
        );
        inserted += 1;
      }
      _showMessage('导入完成：成功 $inserted 条');
      await _loadInitRecords();
    } catch (_) {
      _showMessage('导入失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
        });
      }
    }
  }

  Future<void> _exportImportTemplate() async {
    if (_isTemplateExporting) {
      return;
    }
    setState(() {
      _isTemplateExporting = true;
    });
    try {
      final workbook = Excel.createExcel();
      final sheet = workbook['Sheet1'];
      sheet.appendRow(['材料名称', '初始化数量', '初始化日期', '初始化备注']);
      for (final item in _baseMaterials) {
        sheet.appendRow([item.name, '', '', '']);
      }
      final bytes = workbook.encode()!;
      if (Platform.isWindows) {
        final fileName =
            '库存初始化模板_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '请选择保存位置',
          fileName: fileName,
          allowedExtensions: ['xlsx'],
          type: FileType.custom,
        );
        if (outputFile != null) {
          final file = File(outputFile);
          await file.writeAsBytes(bytes);
          _showMessage('导出成功');
        }
      } else {
        final directory = await getApplicationDocumentsDirectory();
        final filePath = p.join(
          directory.path,
          '库存初始化模板_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx',
        );
        final file = File(filePath);
        await file.writeAsBytes(bytes);
        await Share.shareXFiles([XFile(filePath)], text: '库存初始化模板');
      }
    } catch (_) {
      _showMessage('模板导出失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _isTemplateExporting = false;
        });
      }
    }
  }

  Future<Uint8List?> _pickImportFile() async {
    final selection = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      withData: true,
    );
    if (selection == null || selection.files.isEmpty) {
      return null;
    }
    final file = selection.files.single;
    if (file.bytes != null) {
      return file.bytes;
    }
    final path = file.path;
    if (path == null) {
      return null;
    }
    return File(path).readAsBytes();
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
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showBlockDialog(String title, String message) async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteInitRecord(InventoryInitRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除初始化记录'),
          content: Text(
            '确定删除 ${record.materialName} 的初始化记录（数量：${_formatCompactNumber(record.quantity)}）吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    await RecordDatabase.instance.deleteInitRecord(record.id!);
    _showMessage('已删除初始化记录');
    await _loadInitRecords();
  }

  String _formatCompactNumber(double value) {
    if (value % 1 == 0) {
      return value.toInt().toString();
    }
    return value
        .toStringAsFixed(6)
        .replaceAll(RegExp(r'0*$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }

  @override
  Widget build(BuildContext context) {
    final matchedMaterials = _baseMaterials.where((item) {
      final keyword = _searchController.text.trim();
      if (keyword.isEmpty) {
        return true;
      }
      return item.name.contains(keyword);
    }).toList();
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '材料库存初始化',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        actions: [
          TextButton(
            onPressed: _isImporting ? null : _importInitByExcel,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: _isImporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Text('批量导入'),
          ),
          TextButton(
            onPressed: _isTemplateExporting ? null : _exportImportTemplate,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: _isTemplateExporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Text('导出模板'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '材料名称（必须存在于基础材料）',
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF2B2B2B),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _quantityController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '初始化数量',
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF2B2B2B),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _noteController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '初始化备注（可选）',
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF2B2B2B),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          DateFormat('yyyy-MM-dd').format(_selectedDate),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _selectedDate,
                            firstDate: DateTime(2000),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) {
                            setState(() {
                              _selectedDate = picked;
                            });
                          }
                        },
                        child: const Text('选择日期'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isSubmitting ? null : _submitManualInit,
                      child: _isSubmitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('手动新增初始化库存'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    '初始化记录（可删除）',
                    style: TextStyle(color: Colors.white.withOpacity(0.9)),
                  ),
                  const SizedBox(height: 8),
                  if (_initRecordsLoading)
                    const Center(child: CircularProgressIndicator())
                  else if (_initRecords.isEmpty)
                    Text(
                      '暂无初始化记录',
                      style: TextStyle(color: Colors.white.withOpacity(0.5)),
                    )
                  else
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF2B2B2B),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < _initRecords.length; i++)
                            ListTile(
                              dense: true,
                              title: Text(
                                _initRecords[i].materialName,
                                style: const TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                '${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.parse(_initRecords[i].createdAt))}'
                                '${(_initRecords[i].note ?? '').trim().isEmpty ? '' : '\n备注：${_initRecords[i].note!.trim()}'}',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.6),
                                ),
                              ),
                              isThreeLine: (_initRecords[i].note ?? '')
                                  .trim()
                                  .isNotEmpty,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '+${_formatCompactNumber(_initRecords[i].quantity)}${_initRecords[i].unit ?? ''}',
                                    style: const TextStyle(
                                      color: Color(0xFF4CAF50),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () =>
                                        _deleteInitRecord(_initRecords[i]),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Color(0xFFE57373),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '搜索基础材料',
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                      ),
                      prefixIcon: Icon(
                        Icons.search,
                        color: Colors.white.withOpacity(0.5),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF2B2B2B),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '基础材料（${matchedMaterials.length}/${_baseMaterials.length}）',
                    style: TextStyle(color: Colors.white.withOpacity(0.7)),
                  ),
                  const SizedBox(height: 8),
                  if (matchedMaterials.isEmpty)
                    Text(
                      '无匹配材料',
                      style: TextStyle(color: Colors.white.withOpacity(0.5)),
                    )
                  else
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF2B2B2B),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < matchedMaterials.length; i++)
                            ListTile(
                              dense: true,
                              title: Text(
                                matchedMaterials[i].name,
                                style: const TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                '单位：${matchedMaterials[i].unit}',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.6),
                                ),
                              ),
                              onTap: () {
                                setState(() {
                                  _nameController.text =
                                      matchedMaterials[i].name;
                                });
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
