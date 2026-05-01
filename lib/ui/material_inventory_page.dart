import 'dart:io';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/record_database.dart';
import 'batch_outbound_page.dart';

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
      list.sort((a, b) => a.remainingQuantity.compareTo(b.remainingQuantity));
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

  Future<void> _navigateToBatchOutbound() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const BatchOutboundPage(),
      ),
    );
    _loadData();
  }

  Future<void> _exportInventory() async {
    if (_inventoryList.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有可导出的数据')));
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
        '初始化数量',
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
          item.initializedQuantity,
          item.outQuantity,
          item.remainingQuantity,
          item.totalAmount,
          double.parse(unitPrice.toStringAsFixed(2)),
        ]);
      }

      final bytes = excelFile.encode()!;
      if (Platform.isWindows) {
        final fileName =
            '库存汇总_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
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
        // 保存文件
        final directory = await getApplicationDocumentsDirectory();
        final filePath = p.join(
          directory.path,
          '库存汇总_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx',
        );
        final file = File(filePath);
        await file.writeAsBytes(bytes);

        // 分享文件
        await Share.shareXFiles([XFile(filePath)], text: '库存汇总');
      }
    } catch (e) {
      debugPrint('导出失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导出失败，请重试')));
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
      final bytes = workbook.encode()!;
      if (Platform.isWindows) {
        final fileName =
            '批量出库模板_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
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
          '批量出库模板_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx',
        );
        final file = File(filePath);
        await file.writeAsBytes(bytes);
        await Share.shareXFiles([XFile(filePath)], text: '批量出库模板');
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('材料库存查询'),
        actions: [
          TextButton(
            onPressed: _navigateToBatchOutbound,
            style: TextButton.styleFrom(foregroundColor: colorScheme.primary),
            child: const Text('批量出库'),
          ),
          TextButton(
            onPressed: _isTemplateExporting ? null : _exportOutTemplate,
            style: TextButton.styleFrom(foregroundColor: colorScheme.primary),
            child: _isTemplateExporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('导出批量出库模板'),
          ),
          TextButton(
            onPressed: _isExporting ? null : _exportInventory,
            style: TextButton.styleFrom(foregroundColor: colorScheme.primary),
            child: _isExporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
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
              decoration: InputDecoration(
                hintText: '搜索材料名称',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
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
            color: colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    '序号',
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: 11,
                    ),
                  ),
                ),
                Expanded(
                  flex: 5,
                  child: Text(
                    '名称',
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: 11,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '已购',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: 11,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '出库',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: 11,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '剩余',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: 11,
                    ),
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
                      style: const TextStyle(color: Colors.black45),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: _inventoryList.length,
                    separatorBuilder: (context, index) =>
                        const Divider(color: Color(0xFFE6E6E6), height: 1),
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
    final colorScheme = Theme.of(context).colorScheme;
    final remainingColor = item.remainingQuantity < 0
        ? const Color(0xFFE57373)
        : item.remainingQuantity < item.purchasedQuantity * 0.1
        ? const Color(0xFF4CAF50)
        : Colors.black87;
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) =>
                InventoryDetailsPage(materialName: item.materialName),
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
                style: const TextStyle(color: Colors.black87, fontSize: 12),
              ),
            ),
            Expanded(
              flex: 5,
              child: Text(
                item.materialName,
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: _buildQuantityCell(item.purchasedQuantity),
            ),
            Expanded(
              flex: 2,
              child: _buildQuantityCell(item.outQuantity),
            ),
            Expanded(
              flex: 2,
              child: _buildQuantityCell(
                item.remainingQuantity,
                color: remainingColor,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => _showOutStockSheet(item),
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
              ),
              child: const Text('出库', style: TextStyle(fontSize: 12)),
            ),
            Icon(
              Icons.chevron_right,
              color: Colors.black26,
              size: 14,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuantityCell(double value, {Color? color, bool bold = false}) {
    return Align(
      alignment: Alignment.centerRight,
      child: Text(
        _formatCompactNumber(value),
        style: TextStyle(
          color: color ?? Colors.black87,
          fontSize: 12,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  String _formatCompactNumber(double value) {
    if (value % 1 == 0) {
      return value.toInt().toString();
    }
    return value
        .toStringAsFixed(6)
        .replaceAll(RegExp(r"0*$"), "")
        .replaceAll(RegExp(r"\.$"), "");
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
      backgroundColor: Colors.white,
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
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    item.materialName,
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: quantityController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      hintText: '出库数量',
                      filled: true,
                      fillColor: const Color(0xFFF5F7F7),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteController,
                    decoration: InputDecoration(
                      hintText: '出库备注（可选）',
                      filled: true,
                      fillColor: const Color(0xFFF5F7F7),
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
                          style: const TextStyle(color: Colors.black54),
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
                            final quantity = double.tryParse(
                              quantityController.text.trim(),
                            );
                            if (quantity == null || quantity <= 0) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('请输入有效的出库数量')),
                              );
                              return;
                            }
                            // 单笔出库库存不足时给出确认提示
                            if (item.remainingQuantity < quantity) {
                              final unitText = item.unit == null
                                  ? ''
                                  : item.unit!;
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
      final list = await RecordDatabase.instance.fetchInventoryDetails(
        widget.materialName,
      );
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
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.materialName),
      ),
      body: Column(
        children: [
          // 明细表头
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    '时间',
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: 12,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '数量',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: 12,
                    ),
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
                      style: const TextStyle(color: Colors.black45),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _records.length,
                    separatorBuilder: (context, index) =>
                        const Divider(color: Color(0xFFE6E6E6), height: 1),
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
    final note = (record.note ?? '').trim();
    final recordTypeLabel = record.isInitialization
        ? '初始化'
        : isOutbound
        ? '出库'
        : '入库';
    final notePrefix = record.isInitialization
        ? '初始化备注'
        : isOutbound
        ? '出库备注'
        : '入库备注';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: InkWell(
        onLongPress: record.isOutbound
            ? () => _showEditOutRecord(record)
            : null,
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
                      color: Colors.black54,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    recordTypeLabel,
                    style: TextStyle(
                      color: record.isInitialization
                          ? const Color(0xFF64B5F6)
                          : isOutbound
                          ? const Color(0xFFE57373)
                          : const Color(0xFF4CAF50),
                      fontSize: 12,
                    ),
                  ),
                  // 出入库备注展示
                  if (note.isNotEmpty)
                    Text(
                      '$notePrefix：$note',
                      style: TextStyle(
                        color: Colors.black45,
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
                        color: Colors.black45,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditOutRecord(InventoryDetailRecord record) async {
    final quantityController = TextEditingController(
      text: record.quantity.toString(),
    );
    final noteController = TextEditingController(text: record.note ?? '');
    DateTime selectedDate = DateTime.parse(record.createdAt);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
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
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: quantityController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      hintText: '出库数量',
                      filled: true,
                      fillColor: const Color(0xFFF5F7F7),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteController,
                    decoration: InputDecoration(
                      hintText: '出库备注（可选）',
                      filled: true,
                      fillColor: const Color(0xFFF5F7F7),
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
                          style: const TextStyle(color: Colors.black54),
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
                            await RecordDatabase.instance.deleteOutRecord(
                              record.id,
                            );
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
                            final quantity = double.tryParse(
                              quantityController.text.trim(),
                            );
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
