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

class MaterialInventoryPage extends StatefulWidget {
  const MaterialInventoryPage({super.key});

  @override
  State<MaterialInventoryPage> createState() => _MaterialInventoryPageState();
}

class _MaterialInventoryPageState extends State<MaterialInventoryPage> {
  final TextEditingController _searchController = TextEditingController();
  List<InventorySummary> _inventoryList = [];
  bool _isLoading = true;
  bool _isExporting = false;
  bool _isImporting = false;
  bool _isTemplateExporting = false;

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
    setState(() => _isLoading = true);
    try {
      final list = await RecordDatabase.instance.fetchInventorySummary(
        keyword: _searchController.text,
      );
      setState(() {
        _inventoryList = list;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading inventory: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _exportInventory() async {
    if (_inventoryList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可导出的数据')),
      );
      return;
    }

    setState(() {
      _isExporting = true;
    });

    try {
      final excelFile = Excel.createExcel();
      final sheet = excelFile['Sheet1'];

      // 表头
      sheet.appendRow([
        '材料名称',
        '单位',
        '已购数量',
        '出库数量',
        '剩余数量',
        '总金额',
        '单价',
      ]);

      for (final item in _inventoryList) {
        final unitPrice = item.purchasedQuantity != 0
            ? item.totalAmount / item.purchasedQuantity
            : 0.0;
        sheet.appendRow([
          item.materialName,
          item.unit ?? '',
          item.purchasedQuantity,
          item.outQuantity,
          item.remainingQuantity,
          item.totalAmount,
          double.parse(unitPrice.toStringAsFixed(2)),
        ]);
      }

      // 保存文件
      final directory = await getApplicationDocumentsDirectory();
      final filePath = p.join(directory.path, '库存汇总_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx');
      final file = File(filePath);
      await file.writeAsBytes(excelFile.encode()!);

      // 分享文件
      await Share.shareXFiles([XFile(filePath)], text: '库存汇总');

    } catch (e) {
      debugPrint('导出失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导出失败，请重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  Future<void> _exportOutTemplate() async {
    setState(() {
      _isTemplateExporting = true;
    });
    try {
      final workbook = Excel.createExcel();
      final sheet = workbook['Sheet1'];
      sheet.appendRow(['材料名称', '出库数量', '出库日期', '出库备注']);
      final materials = await RecordDatabase.instance.fetchBaseMaterials();
      for (final item in materials) {
        sheet.appendRow([item.name, '', '', '']);
      }
      final directory = await getApplicationDocumentsDirectory();
      final filePath =
          p.join(directory.path, '批量出库模板_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx');
      final file = File(filePath);
      await file.writeAsBytes(workbook.encode()!);
      await Share.shareXFiles([XFile(filePath)], text: '批量出库模板');
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

  @override
  Widget build(BuildContext context) {
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
          '材料库存查询',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        actions: [
          TextButton(
            onPressed: _isImporting ? null : _importOutStock,
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
                : const Text('批量出库'),
          ),
          TextButton(
            onPressed: _isTemplateExporting ? null : _exportOutTemplate,
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
                : const Text('导出批量出库模板'),
          ),
          TextButton(
            onPressed: _isExporting ? null : _exportInventory,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: _isExporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Text('导出库存'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: '搜索材料名称',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                prefixIcon: Icon(Icons.search, color: Colors.white.withOpacity(0.5)),
                filled: true,
                fillColor: const Color(0xFF2B2B2B),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onChanged: (value) => _loadData(),
            ),
          ),
          // 表头
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF2B2B2B),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    '序号',
                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    '材料名称',
                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    '已购数量',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    '出库数量',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    '剩余数量',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    '总金额',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    '单价',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                  ),
                ),
                const SizedBox(width: 56),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _inventoryList.isEmpty
                    ? Center(
                        child: Text(
                          '暂无库存记录',
                          style: TextStyle(color: Colors.white.withOpacity(0.5)),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        itemCount: _inventoryList.length,
                        separatorBuilder: (context, index) => const Divider(color: Color(0xFF333333), height: 1),
                        itemBuilder: (context, index) {
                          final item = _inventoryList[index];
                          return _buildInventoryItem(index + 1, item);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryItem(int index, InventorySummary item) {
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => InventoryDetailsPage(materialName: item.materialName),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: Text(
                '$index',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
            Expanded(
              flex: 4,
              child: Text(
                item.materialName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: _buildQuantityCell(
                item.purchasedQuantity,
                item.unit,
                color: Colors.white,
              ),
            ),
            Expanded(
              flex: 3,
              child: _buildQuantityCell(
                item.outQuantity,
                item.unit,
                color: Colors.white,
              ),
            ),
            Expanded(
              flex: 3,
              child: _buildQuantityCell(
                item.remainingQuantity,
                item.unit,
                color: item.remainingQuantity < 0
                    ? const Color(0xFFE57373)
                    : Colors.white,
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                item.totalAmount.toStringAsFixed(2),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Color(0xFF4CAF50),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                (item.purchasedQuantity == 0
                        ? 0
                        : item.totalAmount / item.purchasedQuantity)
                    .toStringAsFixed(2),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => _showOutStockSheet(item),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
              ),
              child: const Text('出库'),
            ),
            Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.3), size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildQuantityCell(double value, String? unit,
      {Color? color, bool bold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          value.toStringAsFixed(2),
          style: TextStyle(
            color: color ?? Colors.white,
            fontSize: 14,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        if (unit != null)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              unit,
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _importOutStock() async {
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
      final quantityIndex = headerIndex['出库数量'] ?? headerIndex['数量'];
      if (nameIndex == null || quantityIndex == null) {
        _showMessage('模板缺少材料名称或出库数量列');
        return;
      }
      final noteIndex = headerIndex['出库备注'] ?? headerIndex['备注'];
      final dateIndex = headerIndex['出库日期'] ?? headerIndex['日期'];
      final baseMaterials = await RecordDatabase.instance.fetchBaseMaterials();
      final materialMap = {
        for (final item in baseMaterials) item.name: item.unit,
      };
      final detailList = <Map<String, Object?>>[];
      final missingNames = <String>{};
      for (var i = 1; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        final name = _cellString(row, nameIndex);
        if (name.isEmpty) {
          continue;
        }
        if (!materialMap.containsKey(name)) {
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
        await _showBlockDialog(
          '导入失败',
          '以下材料不在基础材料中：${missingNames.join('、')}',
        );
        return;
      }
      if (detailList.isEmpty) {
        _showMessage('没有可导入的数据');
        return;
      }
      final summaryList = await RecordDatabase.instance.fetchInventorySummary();
      final remainingMap = {
        for (final item in summaryList) item.materialName: item.remainingQuantity,
      };
      final outByName = <String, double>{};
      for (final detail in detailList) {
        final name = detail['name'] as String;
        final quantity = detail['quantity'] as double;
        outByName[name] = (outByName[name] ?? 0) + quantity;
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
          return;
        }
      }
      var inserted = 0;
      for (final detail in detailList) {
        final name = detail['name'] as String;
        final quantity = detail['quantity'] as double;
        final note = detail['note'] as String;
        final date = detail['date'] as DateTime? ?? DateTime.now();
        await RecordDatabase.instance.insertOutRecord(
          materialName: name,
          quantity: quantity,
          unit: materialMap[name],
          note: note.isEmpty ? null : note,
          outDate: date,
        );
        inserted += 1;
      }
      _showMessage('导入完成：成功 $inserted 条');
      _loadData();
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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

  Future<bool> _showConfirmDialog(String title, String message) async {
    if (!mounted) {
      return false;
    }
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
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _showOutStockSheet(InventorySummary item) async {
    final quantityController = TextEditingController();
    final noteController = TextEditingController();
    DateTime selectedDate = DateTime.now();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '材料出库',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    item.materialName,
                    style:
                        TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: quantityController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '出库数量',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
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
                    controller: noteController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '出库备注（可选）',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
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
                          DateFormat('yyyy-MM-dd').format(selectedDate),
                          style: TextStyle(color: Colors.white.withOpacity(0.7)),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: selectedDate,
                            firstDate: DateTime(2000),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) {
                            setModalState(() {
                              selectedDate = picked;
                            });
                          }
                        },
                        child: const Text('选择日期'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () async {
                            final quantity =
                                double.tryParse(quantityController.text.trim());
                            if (quantity == null || quantity <= 0) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('请输入有效的出库数量')),
                              );
                              return;
                            }
                            // 单笔出库库存不足时给出确认提示
                            if (item.remainingQuantity < quantity) {
                              final unitText = item.unit == null ? '' : item.unit!;
                              final confirmed = await _showConfirmDialog(
                                '库存不足',
                                '${item.materialName}：现有${item.remainingQuantity.toStringAsFixed(2)}$unitText，'
                                '需出库${quantity.toStringAsFixed(2)}$unitText\n库存不足，是否仍然出库？',
                              );
                              if (!confirmed) {
                                return;
                              }
                            }
                            await RecordDatabase.instance.insertOutRecord(
                              materialName: item.materialName,
                              quantity: quantity,
                              unit: item.unit,
                              note: noteController.text.trim().isEmpty
                                  ? null
                                  : noteController.text.trim(),
                              outDate: selectedDate,
                            );
                            if (mounted) {
                              Navigator.pop(context);
                              _loadData();
                            }
                          },
                          child: const Text('确认出库'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );
    quantityController.dispose();
    noteController.dispose();
  }
}

class InventoryDetailsPage extends StatefulWidget {
  final String materialName;

  const InventoryDetailsPage({super.key, required this.materialName});

  @override
  State<InventoryDetailsPage> createState() => _InventoryDetailsPageState();
}

class _InventoryDetailsPageState extends State<InventoryDetailsPage> {
  List<InventoryDetailRecord> _records = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    setState(() => _isLoading = true);
    try {
      final list = await RecordDatabase.instance.fetchInventoryDetails(widget.materialName);
      setState(() {
        _records = list;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading details: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.materialName,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
      ),
      body: Column(
        children: [
           // 明细表头
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFF2B2B2B),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    '时间',
                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '数量',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '金额',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '单价',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _records.isEmpty
                    ? Center(
                        child: Text(
                          '无记录',
                          style: TextStyle(color: Colors.white.withOpacity(0.5)),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _records.length,
                        separatorBuilder: (context, index) => const Divider(color: Color(0xFF333333), height: 1),
                        itemBuilder: (context, index) {
                          final record = _records[index];
                          return _buildDetailItem(record);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailItem(InventoryDetailRecord record) {
    final date = DateTime.parse(record.createdAt);
    final dateStr = DateFormat('yyyy-MM-dd HH:mm').format(date);
    final isOutbound = record.isOutbound;
    final amount = record.amount;
    final unitPrice =
        record.quantity != 0 && amount != null ? amount / record.quantity : null;
    final note = (record.note ?? '').trim();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: InkWell(
        onLongPress: record.isOutbound ? () => _showEditOutRecord(record) : null,
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    dateStr,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 14,
                    ),
                  ),
                  // 出入库备注展示
                  if (note.isNotEmpty)
                    Text(
                      '${isOutbound ? '出库' : '入库'}备注：$note',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    '${isOutbound ? '-' : '+'}${record.quantity}',
                    style: TextStyle(
                      color: isOutbound
                          ? const Color(0xFFE57373)
                          : const Color(0xFF4CAF50),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (record.unit != null) ...[
                    const SizedBox(width: 2),
                    Text(
                      record.unit!,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                amount == null ? '-' : amount.toStringAsFixed(2),
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: amount == null
                      ? Colors.white.withOpacity(0.4)
                      : Colors.white,
                  fontSize: 14,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                unitPrice == null ? '-' : unitPrice.toStringAsFixed(2),
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: unitPrice == null
                      ? Colors.white.withOpacity(0.4)
                      : Colors.white,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditOutRecord(InventoryDetailRecord record) async {
    final quantityController =
        TextEditingController(text: record.quantity.toString());
    final noteController = TextEditingController(text: record.note ?? '');
    DateTime selectedDate = DateTime.parse(record.createdAt);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '编辑出库记录',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: quantityController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '出库数量',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
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
                    controller: noteController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '出库备注（可选）',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
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
                          DateFormat('yyyy-MM-dd').format(selectedDate),
                          style: TextStyle(color: Colors.white.withOpacity(0.7)),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: selectedDate,
                            firstDate: DateTime(2000),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) {
                            setModalState(() {
                              selectedDate = picked;
                            });
                          }
                        },
                        child: const Text('选择日期'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            await RecordDatabase.instance.deleteOutRecord(record.id);
                            if (mounted) {
                              Navigator.pop(context);
                              _loadDetails();
                            }
                          },
                          child: const Text('删除'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () async {
                            final quantity =
                                double.tryParse(quantityController.text.trim());
                            if (quantity == null || quantity <= 0) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('请输入有效的出库数量')),
                              );
                              return;
                            }
                            await RecordDatabase.instance.updateOutRecord(
                              id: record.id,
                              quantity: quantity,
                              unit: record.unit,
                              note: noteController.text.trim().isEmpty
                                  ? null
                                  : noteController.text.trim(),
                              outDate: selectedDate,
                            );
                            if (mounted) {
                              Navigator.pop(context);
                              _loadDetails();
                            }
                          },
                          child: const Text('保存'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );
    quantityController.dispose();
    noteController.dispose();
  }
}
