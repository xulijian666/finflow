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

class MaterialInventoryInitPage extends StatefulWidget {
  const MaterialInventoryInitPage({super.key});

  @override
  State<MaterialInventoryInitPage> createState() =>
      _MaterialInventoryInitPageState();
}

class _MaterialInventoryInitPageState extends State<MaterialInventoryInitPage> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<InventoryInitMaterialRow> _rows = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  static const int _pageSize = 50;
  String _keyword = '';
  bool _isImporting = false;
  bool _isTemplateExporting = false;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initPage();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initPage() async {
    try {
      // 先归并历史重复初始化记录，再补齐基础材料缺省初始化项
      await RecordDatabase.instance.ensureInitOneToOne();
      await RecordDatabase.instance.syncInitRecordsWithBaseMaterials();
      await _loadRows(showLoading: true, reset: true);
    } catch (_) {
      _showMessage('初始化数据加载失败，请重试');
    }
  }

  Future<void> _loadRows({
    required bool showLoading,
    required bool reset,
  }) async {
    if (reset) {
      _offset = 0;
      _hasMore = true;
      _loadingMore = false;
    }
    if (showLoading) {
      setState(() {
        _loading = true;
      });
    } else if (!reset) {
      setState(() {
        _loadingMore = true;
      });
    }
    try {
      final list = await RecordDatabase.instance.fetchInitMaterialRows(
        keyword: _keyword,
        limit: _pageSize,
        offset: _offset,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        if (reset) {
          _rows = list;
        } else {
          _rows.addAll(list);
        }
        _offset += list.length;
        _hasMore = list.length == _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
      _showMessage('加载失败，请重试');
    }
  }

  void _onScroll() {
    if (_loading || _loadingMore || !_hasMore) {
      return;
    }
    if (_scrollController.position.extentAfter < 200) {
      _loadRows(showLoading: false, reset: false);
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      _keyword = value.trim();
    });
    _loadRows(showLoading: false, reset: true);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _keyword = '';
    });
    _loadRows(showLoading: false, reset: true);
  }

  Future<void> _editQuantity(InventoryInitMaterialRow row) async {
    final controller = TextEditingController(
      text: _formatCompactNumber(row.quantity),
    );
    final value = await showDialog<double>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('修改初始化数量'),
          content: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              hintText: '${row.materialName} 初始化数量',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final parsed = double.tryParse(controller.text.trim());
                Navigator.of(context).pop(parsed);
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (value == null || value < 0) {
      if (value != null && value < 0) {
        _showMessage('初始化数量不能小于0');
      }
      return;
    }
    try {
      await RecordDatabase.instance.upsertInitQuantity(
        materialName: row.materialName,
        unit: row.unit,
        quantity: value,
      );
      _showMessage('已更新');
      await _loadRows(showLoading: false, reset: true);
    } catch (_) {
      _showMessage('更新失败，请重试');
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
      final materialList = await RecordDatabase.instance.fetchBaseMaterials();
      final materialUnitMap = {
        for (final item in materialList) item.name.trim(): item.unit,
      };
      final missingNames = <String>{};
      final overwriteMap = <String, double>{};
      for (var i = 1; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        final name = _cellString(row, nameIndex);
        if (name.isEmpty) {
          continue;
        }
        if (!materialUnitMap.containsKey(name)) {
          missingNames.add(name);
          continue;
        }
        final quantity = _cellDouble(row, quantityIndex);
        overwriteMap[name] = quantity == null || quantity < 0 ? 0 : quantity;
      }
      if (missingNames.isNotEmpty) {
        await _showBlockDialog('导入失败', '以下材料不在基础材料中：${missingNames.join('、')}');
        return;
      }
      if (overwriteMap.isEmpty) {
        _showMessage('没有可导入的数据');
        return;
      }
      final rows = overwriteMap.entries
          .map(
            (entry) => InventoryInitMaterialRow(
              materialName: entry.key,
              unit: materialUnitMap[entry.key] ?? '',
              quantity: entry.value,
            ),
          )
          .toList();
      await RecordDatabase.instance.importInitQuantitiesOverwrite(rows);
      _showMessage('导入完成：覆盖 ${rows.length} 条');
      await _loadRows(showLoading: false, reset: true);
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

  Future<void> _downloadImportTemplate() async {
    if (_isTemplateExporting) {
      return;
    }
    setState(() {
      _isTemplateExporting = true;
    });
    try {
      final list = await RecordDatabase.instance.fetchInitMaterialRows();
      final workbook = Excel.createExcel();
      final sheet = workbook['Sheet1'];
      sheet.appendRow(['材料名称', '单位', '初始化数量']);
      for (final item in list) {
        sheet.appendRow([
          item.materialName,
          item.unit,
          _formatCompactNumber(item.quantity),
        ]);
      }
      final bytes = workbook.encode()!;
      if (Platform.isWindows) {
        final fileName =
            '库存初始化导入模板_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
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
          '库存初始化导入模板_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx',
        );
        final file = File(filePath);
        await file.writeAsBytes(bytes);
        await Share.shareXFiles([XFile(filePath)], text: '库存初始化导入模板');
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

  Future<void> _exportInitData() async {
    if (_isExporting) {
      return;
    }
    setState(() {
      _isExporting = true;
    });
    try {
      final list = await RecordDatabase.instance.fetchInitMaterialRows();
      final filtered = list.where((e) => e.quantity > 0).toList();
      if (filtered.isEmpty) {
        _showMessage('暂无初始化数量大于0的数据');
        return;
      }
      final workbook = Excel.createExcel();
      final sheet = workbook['Sheet1'];
      sheet.appendRow(['材料名称', '单位', '初始化数量']);
      for (final item in filtered) {
        sheet.appendRow([
          item.materialName,
          item.unit,
          _formatCompactNumber(item.quantity),
        ]);
      }
      final bytes = workbook.encode()!;
      if (Platform.isWindows) {
        final fileName =
            '库存初始化导出_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
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
          '库存初始化导出_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx',
        );
        final file = File(filePath);
        await file.writeAsBytes(bytes);
        await Share.shareXFiles([XFile(filePath)], text: '库存初始化导出');
      }
    } catch (_) {
      _showMessage('导出失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
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
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('材料库存初始化'),
        actions: [
          TextButton(
            onPressed: _isImporting ? null : _importInitByExcel,
            style: TextButton.styleFrom(foregroundColor: colorScheme.primary),
            child: _isImporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  )
                : const Text('批量导入'),
          ),
          TextButton(
            onPressed: _isTemplateExporting ? null : _downloadImportTemplate,
            style: TextButton.styleFrom(foregroundColor: colorScheme.primary),
            child: _isTemplateExporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  )
                : const Text('导入模板下载'),
          ),
          TextButton(
            onPressed: _isExporting ? null : _exportInitData,
            style: TextButton.styleFrom(foregroundColor: colorScheme.primary),
            child: _isExporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  )
                : const Text('导出'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: '搜索材料名称',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _keyword.isEmpty
                    ? null
                    : IconButton(
                        onPressed: _clearSearch,
                        icon: const Icon(Icons.close),
                      ),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Expanded(flex: 4, child: Text('材料名称')),
                  Expanded(flex: 2, child: Text('单位')),
                  Expanded(flex: 2, child: Text('初始化数量')),
                  SizedBox(width: 56),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _rows.isEmpty
                  ? const Center(child: Text('暂无材料数据'))
                  : ListView.separated(
                      controller: _scrollController,
                      itemCount: _rows.length + (_loadingMore ? 1 : 0),
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        if (index >= _rows.length) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final row = _rows[index];
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.surface,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 4,
                                child: Text(
                                  row.materialName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  row.unit,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(_formatCompactNumber(row.quantity)),
                              ),
                              SizedBox(
                                width: 56,
                                child: TextButton(
                                  onPressed: () => _editQuantity(row),
                                  child: const Text('修改'),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
