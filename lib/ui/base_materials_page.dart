import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:excel/excel.dart' as excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/record_database.dart';
import '../data/transaction_record.dart';

// 基础材料管理页面，提供增删查改与导出分享
class BaseMaterialsPage extends StatefulWidget {
  const BaseMaterialsPage({super.key});

  @override
  State<BaseMaterialsPage> createState() => _BaseMaterialsPageState();
}

class _BaseMaterialsPageState extends State<BaseMaterialsPage> {
  List<BaseMaterial> _materials = [];
  bool _loading = true;
  bool _exporting = false;
  bool _importing = false;
  String _keyword = '';
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  static const int _pageSize = 50;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadMaterials(showLoading: true, reset: true);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMaterials({
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
      final list = await RecordDatabase.instance.fetchBaseMaterials(
        keyword: _keyword,
        limit: _pageSize,
        offset: _offset,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        if (reset) {
          _materials = list;
        } else {
          _materials.addAll(list);
        }
        _hasMore = list.length == _pageSize;
        _offset += list.length;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
      _showMessage('加载基础材料失败，请重试');
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      _keyword = value.trim();
    });
    _loadMaterials(showLoading: false, reset: true);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _keyword = '';
    });
    _loadMaterials(showLoading: false, reset: true);
  }

  void _onScroll() {
    if (_loading || _loadingMore || !_hasMore) {
      return;
    }
    if (_scrollController.position.extentAfter < 200) {
      _loadMaterials(showLoading: false, reset: false);
    }
  }

  Future<void> _openForm({BaseMaterial? material}) async {
    final result = await showModalBottomSheet<_BaseMaterialFormResult>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return _BaseMaterialFormSheet(material: material);
      },
    );
    if (result == null) {
      return;
    }
    if (material == null) {
      await _createMaterial(result);
    } else {
      await _updateMaterial(material, result);
    }
  }

  Future<void> _createMaterial(_BaseMaterialFormResult result) async {
    try {
      await RecordDatabase.instance.insertBaseMaterial(
        BaseMaterial(name: result.name, unit: result.unit),
      );
      if (!mounted) {
        return;
      }
      _showMessage('已新增基础材料');
      _loadMaterials(showLoading: false, reset: true);
    } catch (error) {
      _showMessage('新增失败，请重试');
    }
  }

  Future<void> _updateMaterial(
    BaseMaterial material,
    _BaseMaterialFormResult result,
  ) async {
    try {
      final oldName = material.name.trim();
      final newName = result.name.trim();
      final nameChanged = oldName != newName;
      if (nameChanged) {
        final existed = await RecordDatabase.instance.fetchBaseMaterialByName(
          newName,
        );
        if (existed != null && existed.id != material.id) {
          _showMessage('材料名称已存在，请使用其他名称');
          return;
        }
        final affectedCount = await RecordDatabase.instance
            .countCourseMaterialRecordsByName(oldName);
        final confirmed = await _confirmRenameSync(
          oldName: oldName,
          newName: newName,
          affectedCount: affectedCount,
        );
        if (!confirmed) {
          return;
        }
        final changed = await RecordDatabase.instance.renameBaseMaterialAndSync(
          materialId: material.id!,
          oldName: oldName,
          newName: newName,
          unit: result.unit,
        );
        if (!mounted) {
          return;
        }
        final inventoryChanged =
            (changed['inventoryIn'] ?? 0) +
            (changed['inventoryInit'] ?? 0) +
            (changed['inventoryOut'] ?? 0);
        _showMessage(
          '已更新基础材料，账单同步${changed['records'] ?? 0}条，库存同步$inventoryChanged条',
        );
        _loadMaterials(showLoading: false, reset: true);
        return;
      }
      final updated = BaseMaterial(
        id: material.id,
        name: newName,
        unit: result.unit,
      );
      await RecordDatabase.instance.updateBaseMaterial(updated);
      if (!mounted) {
        return;
      }
      _showMessage('已更新基础材料');
      _loadMaterials(showLoading: false, reset: true);
    } catch (error) {
      _showMessage('更新失败，请重试');
    }
  }

  Future<bool> _confirmRenameSync({
    required String oldName,
    required String newName,
    required int affectedCount,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('同步变更确认'),
          content: Text(
            '将材料名称从“$oldName”改为“$newName”后，'
            '关联的课程材料账单名称将同步变更（预计 $affectedCount 条），'
            '材料库存中的入库/初始化/出库记录名称也会同步变更。是否继续？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('继续'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _deleteMaterial(BaseMaterial material) async {
    final confirmed = await _confirmDelete(material);
    if (!confirmed) {
      return;
    }
    try {
      await RecordDatabase.instance.deleteBaseMaterial(material.id!);
      if (!mounted) {
        return;
      }
      _showMessage('已删除基础材料');
      _loadMaterials(showLoading: false, reset: true);
    } catch (error) {
      _showMessage('删除失败，请重试');
    }
  }

  Future<bool> _confirmDelete(BaseMaterial material) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除基础材料'),
          content: Text('确定删除 ${material.name} 吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _exportMaterials() async {
    if (_exporting) {
      return;
    }
    setState(() {
      _exporting = true;
    });
    try {
      final list = await RecordDatabase.instance.fetchBaseMaterials();
      final filePath = await _saveAsXlsx(list);
      final shared = await _shareExportFile(filePath);
      if (!mounted) {
        return;
      }
      _showMessage(shared ? '已导出并唤起分享' : '已导出到 $filePath');
    } catch (error) {
      _showMessage('导出失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
        });
      }
    }
  }

  Future<void> _exportPurchaseRecords() async {
    if (_exporting) {
      return;
    }
    setState(() {
      _exporting = true;
    });
    try {
      final summaryList = await RecordDatabase.instance
          .fetchInventorySummary();
      final purchaseMaterials = summaryList
          .where((item) => item.purchasedQuantity > 0)
          .toList();
      if (purchaseMaterials.isEmpty) {
        _showMessage('暂无记账入库记录');
        return;
      }
      final filePath = await _savePurchaseXlsx(purchaseMaterials);
      final shared = await _shareExportFile(filePath);
      if (!mounted) {
        return;
      }
      _showMessage(shared ? '已导出并唤起分享' : '已导出到 $filePath');
    } catch (error) {
      _showMessage('导出失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
        });
      }
    }
  }

  Future<String> _savePurchaseXlsx(List<InventorySummary> list) async {
    final workbook = excel.Excel.createExcel();
    const mainSheetName = 'Sheet1';
    final mainSheet = workbook[mainSheetName];
    workbook.setDefaultSheet(mainSheetName);

    _appendPurchaseSheetRow(
      sheet: mainSheet,
      row: ['序号', '材料名称', '入库总数', '金额之和', '单价'],
    );

    final detailSheetNames = <String, String>{};
    final detailSheetLayouts = <String, _PurchaseDetailLayout>{};
    final usedSheetNames = <String>{};

    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      final unitPrice = item.purchasedQuantity > 0
          ? item.totalAmount / item.purchasedQuantity
          : 0.0;
      _appendPurchaseSheetRow(
        sheet: mainSheet,
        row: [
          i + 1,
          item.materialName,
          _formatPurchaseNumber(item.purchasedQuantity),
          _formatPurchaseFixed2(item.totalAmount),
          _formatPurchaseFixed2(unitPrice),
        ],
      );

      var rawName = item.materialName;
      rawName = rawName.replaceAll(RegExp(r'[\\/*?\[\]：:———–]'), '_');
      if (rawName.length > 31) rawName = rawName.substring(0, 31);
      var sheetName = rawName;
      var suffix = 2;
      while (usedSheetNames.contains(sheetName)) {
        final maxBase = 31 - '_$suffix'.length;
        sheetName =
            '${rawName.substring(0, maxBase.clamp(0, rawName.length))}_$suffix';
        suffix++;
      }
      usedSheetNames.add(sheetName);
      detailSheetNames[item.materialName] = sheetName;

      final detailRecords = await RecordDatabase.instance
          .fetchPurchaseRecords(item.materialName);
      final detailSheet = workbook[sheetName];
      final layout = _buildPurchaseDetailSheet(
        sheet: detailSheet,
        sheetName: sheetName,
        materialName: item.materialName,
        unit: item.unit,
        records: detailRecords,
      );
      detailSheetLayouts[item.materialName] = layout;
    }

    _applyPurchaseStyles(
      workbook: workbook,
      mainSheetName: mainSheetName,
      detailSheetNames: detailSheetNames,
      detailSheetLayouts: detailSheetLayouts,
      list: list,
    );

    final bytes = workbook.save();
    if (bytes == null) {
      throw Exception('导出失败');
    }
    final frozenBytes = _freezePurchaseHeaderRows(bytes);
    final hyperBytes = _injectPurchaseHyperlinks(
      frozenBytes,
      detailSheetNames,
      list,
    );
    final directory = await _exportDirectory();
    final fileName = '材料记账导出_${_formatDateTime(DateTime.now())}.xlsx';
    final exportFile = File(p.join(directory.path, fileName));
    await exportFile.writeAsBytes(hyperBytes, flush: true);
    return exportFile.path;
  }

  _PurchaseDetailLayout _buildPurchaseDetailSheet({
    required excel.Sheet sheet,
    required String sheetName,
    required String materialName,
    required String? unit,
    required List<InventoryDetailRecord> records,
  }) {
    _appendPurchaseSheetRow(
      sheet: sheet,
      row: ['← 返回目录'],
    );
    _appendPurchaseSheetRow(
      sheet: sheet,
      row: ['材料入库明细', '', '', '', ''],
    );
    _appendPurchaseSheetRow(
      sheet: sheet,
      row: ['材料名称', materialName, '单位', unit ?? '', ''],
    );
    _appendPurchaseSheetRow(sheet: sheet, row: []);
    _appendPurchaseSheetRow(
      sheet: sheet,
      row: ['材料名称', '金额', '数量', '购买日期', '当次单价'],
    );

    final headerRow = 4;
    final dataRows = <int>[];
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      final amount = record.amount ?? 0.0;
      final unitPrice = record.quantity > 0 ? amount / record.quantity : 0.0;
      final dateStr = record.createdAt.length >= 10
          ? record.createdAt.substring(0, 10)
          : record.createdAt;
      dataRows.add(sheet.maxRows);
      _appendPurchaseSheetRow(
        sheet: sheet,
        row: [
          record.materialName,
          _formatPurchaseFixed2(amount),
          _formatPurchaseFixed2(record.quantity),
          dateStr,
          _formatPurchaseFixed2(unitPrice),
        ],
      );
    }

    final totalAmount = records.fold<double>(
      0,
      (sum, r) => sum + (r.amount ?? 0),
    );
    final totalQty = records.fold<double>(0, (sum, r) => sum + r.quantity);
    final avgUnitPrice = totalQty > 0 ? totalAmount / totalQty : 0.0;
    final summaryRow = sheet.maxRows;
    _appendPurchaseSheetRow(
      sheet: sheet,
      row: ['汇总', _formatPurchaseFixed2(totalAmount), _formatPurchaseFixed2(totalQty), '', _formatPurchaseFixed2(avgUnitPrice)],
    );

    sheet.setColWidth(0, 32.0);
    sheet.setColWidth(1, 14.0);
    sheet.setColWidth(2, 14.0);
    sheet.setColWidth(3, 16.0);
    sheet.setColWidth(4, 14.0);

    return _PurchaseDetailLayout(
      backRow: 0,
      titleRow: 1,
      infoRow: 2,
      headerRow: headerRow,
      dataRows: dataRows,
      summaryRow: summaryRow,
    );
  }

  void _appendPurchaseSheetRow({
    required excel.Sheet sheet,
    required List<dynamic> row,
  }) {
    sheet.appendRow(List<dynamic>.from(row, growable: true));
  }

  dynamic _formatPurchaseNumber(double value) {
    if (value % 1 == 0) {
      return value.toInt();
    }
    return double.parse(value.toStringAsFixed(2));
  }

  String _formatPurchaseFixed2(double value) {
    return value.toStringAsFixed(2);
  }

  void _applyPurchaseStyles({
    required excel.Excel workbook,
    required String mainSheetName,
    required Map<String, String> detailSheetNames,
    required Map<String, _PurchaseDetailLayout> detailSheetLayouts,
    required List<InventorySummary> list,
  }) {
    final border = excel.Border(
      borderStyle: excel.BorderStyle.Thin,
      borderColorHex: '#FF666666',
    );
    final headerStyle = excel.CellStyle(
      bold: true,
      fontColorHex: '#FFFFFFFF',
      backgroundColorHex: '#FF4F81BD',
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    final normalStyle = excel.CellStyle(
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    final linkStyle = excel.CellStyle(
      fontColorHex: '#FF0563C1',
      underline: excel.Underline.Single,
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    final titleStyle = excel.CellStyle(
      fontColorHex: '#FF1F1F1F',
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    final sectionTitleStyle = excel.CellStyle(
      fontColorHex: '#FF1F1F1F',
      backgroundColorHex: '#FFDCE6F1',
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );

    void setStyle(excel.Sheet s, int col, int row, excel.CellStyle style) {
      s
              .cell(
                excel.CellIndex.indexByColumnRow(
                  columnIndex: col,
                  rowIndex: row,
                ),
              )
              .cellStyle =
          style;
    }

    void setRowStyle(
      excel.Sheet s,
      int row,
      int colCount,
      excel.CellStyle style,
    ) {
      for (var c = 0; c < colCount; c++) {
        setStyle(s, c, row, style);
      }
    }

    // 主Sheet样式
    final mainSheet = workbook.tables[mainSheetName];
    if (mainSheet != null) {
      setRowStyle(mainSheet, 0, 5, headerStyle);
      for (var i = 0; i < list.length; i++) {
        final rowIndex = i + 1;
        setRowStyle(mainSheet, rowIndex, 5, normalStyle);
        setStyle(mainSheet, 1, rowIndex, linkStyle);
      }
    }

    // 详情Sheet样式
    for (final entry in detailSheetNames.entries) {
      final ds = workbook.tables[entry.value];
      final layout = detailSheetLayouts[entry.key];
      if (ds == null || layout == null) {
        continue;
      }
      setRowStyle(ds, layout.backRow, 5, normalStyle);
      setStyle(ds, 0, layout.backRow, linkStyle);
      setRowStyle(ds, layout.titleRow, 5, titleStyle);
      setRowStyle(ds, layout.infoRow, 5, sectionTitleStyle);
      setRowStyle(ds, 3, 5, normalStyle);
      setRowStyle(ds, layout.headerRow, 5, headerStyle);
      for (final row in layout.dataRows) {
        setRowStyle(ds, row, 5, normalStyle);
      }
      setRowStyle(ds, layout.summaryRow, 5, sectionTitleStyle);
    }

    _autoFitPurchaseSheets(workbook);
  }

  void _autoFitPurchaseSheets(excel.Excel workbook) {
    for (final sheet in workbook.tables.values) {
      if (sheet.maxRows <= 0 || sheet.maxCols <= 0) {
        continue;
      }
      for (var col = 0; col < sheet.maxCols; col++) {
        var maxWidth = 0;
        for (var row = 0; row < sheet.maxRows; row++) {
          final cell = sheet.cell(
            excel.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row),
          );
          final width = _textPurchaseDisplayWidth(cell.value?.toString() ?? '');
          if (width > maxWidth) {
            maxWidth = width;
          }
        }
        final targetWidth = (maxWidth + 2).toDouble().clamp(10, 60).toDouble();
        sheet.setColWidth(col, targetWidth);
      }
    }
  }

  int _textPurchaseDisplayWidth(String text) {
    if (text.isEmpty) {
      return 0;
    }
    var total = 0;
    for (final rune in text.runes) {
      total += rune <= 0x7F ? 1 : 2;
    }
    return total;
  }

  List<int> _freezePurchaseHeaderRows(List<int> xlsxBytes) {
    final archive = ZipDecoder().decodeBytes(xlsxBytes);
    for (var i = 0; i < archive.length; i++) {
      final file = archive[i];
      if (!file.isFile) {
        continue;
      }
      if (!file.name.startsWith('xl/worksheets/sheet') ||
          !file.name.endsWith('.xml')) {
        continue;
      }
      final xml = utf8.decode(file.content);
      final updated = _injectPurchaseFrozenPane(xml);
      if (updated == xml) {
        continue;
      }
      final updatedBytes = utf8.encode(updated);
      final replaced = ArchiveFile(
        file.name,
        updatedBytes.length,
        updatedBytes,
      )
        ..mode = file.mode
        ..ownerId = file.ownerId
        ..groupId = file.groupId
        ..lastModTime = file.lastModTime
        ..comment = file.comment
        ..crc32 = file.crc32
        ..compress = file.compress
        ..isFile = file.isFile;
      archive[i] = replaced;
    }
    return ZipEncoder().encode(archive) ?? xlsxBytes;
  }

  String _injectPurchaseFrozenPane(String xml) {
    if (xml.contains('state="frozen"') || xml.contains('<pane ')) {
      return xml;
    }
    const pane =
        '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>';
    final selfClosing = RegExp(r'<sheetView([^>]*)/>');
    final selfMatch = selfClosing.firstMatch(xml);
    if (selfMatch != null) {
      final attrs = selfMatch.group(1) ?? '';
      return xml.replaceFirst(
        selfClosing,
        '<sheetView$attrs>$pane</sheetView>',
      );
    }
    final opening = RegExp(r'<sheetView([^>]*)>');
    final openMatch = opening.firstMatch(xml);
    if (openMatch == null) {
      return xml;
    }
    final index = openMatch.end;
    return '${xml.substring(0, index)}$pane${xml.substring(index)}';
  }

  List<int> _injectPurchaseHyperlinks(
    List<int> xlsxBytes,
    Map<String, String> detailSheetNames,
    List<InventorySummary> list,
  ) {
    try {
      final archive = ZipDecoder().decodeBytes(xlsxBytes);
      final sheetRIds = <String, String>{};
      final sheetFileMap = <String, String>{};
      for (final file in archive.files) {
        if (!file.isFile) continue;
        if (file.name == 'xl/workbook.xml') {
          final xml = utf8.decode(file.content as List<int>);
          final sheetPattern = RegExp(
            r'<sheet\s[^>]*?name="([^"]+)"[^>]*?r:id="([^"]+)"',
          );
          for (final m in sheetPattern.allMatches(xml)) {
            sheetRIds[m.group(1)!] = m.group(2)!;
          }
        }
        if (file.name == 'xl/_rels/workbook.xml.rels') {
          final xml = utf8.decode(file.content as List<int>);
          final relPattern = RegExp(
            r'<Relationship\s[^>]*?Id="([^"]+)"[^>]*?Target="([^"]+)"',
          );
          for (final m in relPattern.allMatches(xml)) {
            final rId = m.group(1)!;
            final target = m.group(2)!;
            for (final entry in sheetRIds.entries) {
              if (entry.value == rId) {
                sheetFileMap[entry.key] = 'xl/$target';
                break;
              }
            }
          }
        }
      }

      final mainSheetFile = sheetFileMap['Sheet1'];
      if (mainSheetFile == null) {
        return xlsxBytes;
      }

      final mainHyperlinks = <Map<String, String>>[];
      for (var i = 0; i < list.length; i++) {
        final materialName = list[i].materialName;
        final detailSheetName = detailSheetNames[materialName];
        if (detailSheetName == null) continue;
        mainHyperlinks.add({
          'ref': 'B${i + 2}',
          'location': "'$detailSheetName'!A1",
        });
      }

      final detailHyperlinks = <String, List<Map<String, String>>>{};
      for (final sheetName in detailSheetNames.values) {
        detailHyperlinks[sheetName] = [
          {'ref': 'A1', 'location': "'Sheet1'!A1"},
        ];
      }

      final newArchive = Archive();
      for (final file in archive.files) {
        if (!file.isFile) {
          newArchive.addFile(file);
          continue;
        }

        var content = file.content as List<int>;
        final name = file.name;
        var modified = false;

        if (name == mainSheetFile) {
          final xml = utf8.decode(content);
          final updated = _injectPurchaseHyperlinksIntoSheet(
            xml,
            mainHyperlinks,
          );
          content = utf8.encode(updated);
          modified = true;
        }

        for (final entry in detailHyperlinks.entries) {
          final detailFile = sheetFileMap[entry.key];
          if (detailFile != null && name == detailFile) {
            final xml = utf8.decode(content);
            final updated = _injectPurchaseHyperlinksIntoSheet(
              xml,
              entry.value,
            );
            content = utf8.encode(updated);
            modified = true;
          }
        }

        if (modified) {
          final newFile = ArchiveFile(name, content.length, content)
            ..compress = true;
          newArchive.addFile(newFile);
        } else {
          newArchive.addFile(file);
        }
      }

      final result = ZipEncoder().encode(newArchive);
      if (result == null) {
        return xlsxBytes;
      }
      return result;
    } catch (e) {
      return xlsxBytes;
    }
  }

  String _injectPurchaseHyperlinksIntoSheet(
    String xml,
    List<Map<String, String>> hyperlinks,
  ) {
    if (hyperlinks.isEmpty) return xml;

    final buffer = StringBuffer('<hyperlinks>');
    for (final h in hyperlinks) {
      final ref = h['ref']!;
      final location = h['location']!;
      buffer.write('<hyperlink ref="$ref" location="$location"/>');
    }
    buffer.write('</hyperlinks>');
    final hlXml = buffer.toString();

    final idx = xml.indexOf('<pageMargins');
    if (idx < 0) {
      final endIdx = xml.lastIndexOf('</worksheet>');
      if (endIdx < 0) return xml;
      return '${xml.substring(0, endIdx)}$hlXml${xml.substring(endIdx)}';
    }
    return '${xml.substring(0, idx)}$hlXml${xml.substring(idx)}';
  }

  Future<void> _importMaterials() async {
    if (_importing) {
      return;
    }
    setState(() {
      _importing = true;
    });
    try {
      final bytes = await _pickImportFile();
      if (bytes == null) {
        return;
      }
      final mode = await _chooseImportMode();
      if (mode == null) {
        return;
      }
      if (mode == _ImportMode.replaceAll) {
        final confirmed = await _confirmReplaceAll();
        if (!confirmed) {
          return;
        }
      }
      final parseResult = _parseMaterialsFromXlsx(bytes);
      if (parseResult.nameToUnits.isEmpty) {
        _showMessage('未识别到可导入的数据');
        return;
      }
      final conflicts = parseResult.conflicts;
      Map<String, String> resolved = {};
      if (conflicts.isNotEmpty) {
        final selection = await _resolveImportConflicts(conflicts);
        if (selection == null) {
          return;
        }
        resolved = selection;
      }
      final list = parseResult.nameToUnits.entries.map((entry) {
        final options = entry.value.toList();
        final unit = resolved[entry.key] ?? options.first;
        return BaseMaterial(name: entry.key, unit: unit);
      }).toList();
      if (list.isEmpty) {
        _showMessage('未识别到可导入的数据');
        return;
      }
      if (mode == _ImportMode.replaceAll) {
        final count = await RecordDatabase.instance.replaceBaseMaterials(list);
        if (!mounted) {
          return;
        }
        _showMessage('已全量覆盖，导入 $count 条');
      } else {
        final result = await RecordDatabase.instance.upsertBaseMaterials(list);
        if (!mounted) {
          return;
        }
        final inserted = result['inserted'] ?? 0;
        final updated = result['updated'] ?? 0;
        _showMessage('导入完成：新增 $inserted 条，更新 $updated 条');
      }
      _loadMaterials(showLoading: false, reset: true);
    } catch (error) {
      _showMessage('导入失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
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

  Future<_ImportMode?> _chooseImportMode() async {
    var replaceAll = false;
    final result = await showDialog<_ImportMode>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('选择导入方式'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('默认增量更新，可勾选全量覆盖'),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    value: replaceAll,
                    onChanged: (value) {
                      setState(() {
                        replaceAll = value ?? false;
                      });
                    },
                    title: const Text('全量覆盖'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(context).pop(
                      replaceAll
                          ? _ImportMode.replaceAll
                          : _ImportMode.increment,
                    );
                  },
                  child: const Text('继续'),
                ),
              ],
            );
          },
        );
      },
    );
    return result;
  }

  Future<bool> _confirmReplaceAll() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('确认全量覆盖'),
          content: const Text('全量覆盖将删除现有基础材料，是否继续？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  _ImportParseResult _parseMaterialsFromXlsx(Uint8List bytes) {
    final workbook = excel.Excel.decodeBytes(bytes);
    excel.Sheet? sheet = workbook.tables['Sheet1'];
    sheet ??= workbook.tables.isEmpty ? null : workbook.tables.values.first;
    if (sheet == null) {
      return const _ImportParseResult(nameToUnits: {});
    }
    final rows = sheet.rows;
    if (rows.isEmpty) {
      return const _ImportParseResult(nameToUnits: {});
    }
    final headerTexts = rows.first.map(_cellText).toList();
    var nameIndex = headerTexts.indexOf('材料名称');
    var unitIndex = headerTexts.indexOf('单位');
    var startIndex = 0;
    if (nameIndex != -1 && unitIndex != -1) {
      startIndex = 1;
    } else {
      if (headerTexts.isNotEmpty && headerTexts.first == '序号') {
        nameIndex = 1;
        unitIndex = 2;
        startIndex = 1;
      } else {
        nameIndex = 0;
        unitIndex = 1;
      }
    }
    final nameToUnits = <String, Set<String>>{};
    for (var i = startIndex; i < rows.length; i++) {
      final row = rows[i];
      final name = _cellText(_cellAt(row, nameIndex)).trim();
      final unit = _cellText(_cellAt(row, unitIndex)).trim();
      if (name.isEmpty || unit.isEmpty) {
        continue;
      }
      final set = nameToUnits.putIfAbsent(name, () => <String>{});
      set.add(unit);
    }
    return _ImportParseResult(nameToUnits: nameToUnits);
  }

  String _cellText(excel.Data? cell) {
    final value = cell?.value;
    return value == null ? '' : value.toString().trim();
  }

  Future<Map<String, String>?> _resolveImportConflicts(
    Map<String, Set<String>> conflicts,
  ) async {
    final selections = <String, String>{};
    for (final entry in conflicts.entries) {
      selections[entry.key] = entry.value.first;
    }
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('处理单位冲突'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: conflicts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final entry = conflicts.entries.elementAt(index);
                    final name = entry.key;
                    final units = entry.value.toList()..sort();
                    final selected = selections[name];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: units.map((unit) {
                            final isSelected = unit == selected;
                            return ChoiceChip(
                              label: Text(unit),
                              selected: isSelected,
                              onSelected: (_) {
                                setState(() {
                                  selections[name] = unit;
                                });
                              },
                            );
                          }).toList(),
                        ),
                      ],
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(Map<String, String>.from(selections)),
                  child: const Text('继续导入'),
                ),
              ],
            );
          },
        );
      },
    );
    return result;
  }

  excel.Data? _cellAt(List<excel.Data?> row, int index) {
    if (index < 0 || index >= row.length) {
      return null;
    }
    return row[index];
  }

  Future<String> _saveAsXlsx(List<BaseMaterial> list) async {
    // 将基础材料数据写入 xlsx 文件
    final headers = ['序号', '材料名称', '单位'];
    final workbook = excel.Excel.createExcel();
    final sheet = workbook['Sheet1'];
    sheet.appendRow(headers);
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      sheet.appendRow([i + 1, item.name, item.unit]);
    }
    final directory = await _exportDirectory();
    final fileName = '基础材料导出_${_formatDateTime(DateTime.now())}.xlsx';
    final exportFile = File(p.join(directory.path, fileName));
    final bytes = workbook.save();
    if (bytes == null) {
      throw Exception('导出失败');
    }
    await exportFile.writeAsBytes(bytes, flush: true);
    return exportFile.path;
  }

  Future<Directory> _exportDirectory() async {
    // 根据平台选择导出目录
    if (Platform.isAndroid) {
      return getTemporaryDirectory();
    }
    return getApplicationDocumentsDirectory();
  }

  Future<bool> _shareExportFile(String filePath) async {
    // Android 端唤起系统分享面板，可选择微信
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
      return false;
    }
  }

  String _formatDateTime(DateTime date) {
    // 生成文件名时间戳
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    final second = date.second.toString().padLeft(2, '0');
    return '$year$month$day'
        '_$hour$minute$second';
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('基础材料'),
        actions: [
          TextButton(
            onPressed: _importing ? null : _importMaterials,
            child: const Text('导入'),
          ),
          TextButton(
            onPressed: _exporting ? null : _exportMaterials,
            child: const Text('导出'),
          ),
          TextButton(
            onPressed: _exporting ? null : _exportPurchaseRecords,
            child: const Text('记账导出'),
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
            _MaterialTableHeader(colorScheme: colorScheme),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _materials.isEmpty
                  ? _EmptyState(keyword: _keyword, onAdd: () => _openForm())
                  : ListView.separated(
                      controller: _scrollController,
                      itemCount: _materials.length + (_loadingMore ? 1 : 0),
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        if (index >= _materials.length) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          );
                        }
                        final material = _materials[index];
                        return _MaterialRow(
                          material: material,
                          onEdit: () => _openForm(material: material),
                          onDelete: () => _deleteMaterial(material),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('新增材料'),
      ),
    );
  }
}

// 空状态展示
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.keyword, required this.onAdd});

  final String keyword;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final title = keyword.isEmpty ? '暂无基础材料' : '未找到匹配材料';
    final subtitle = keyword.isEmpty ? '点击右下角按钮创建或右上角批量导入' : '尝试调整关键词';
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              Icons.inventory_2_outlined,
              color: colorScheme.onPrimaryContainer,
              size: 32,
            ),
          ),
          const SizedBox(height: 12),
          Text(title, style: textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(subtitle, style: textTheme.bodySmall),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('新增材料'),
          ),
        ],
      ),
    );
  }
}

// 基础材料行
class _MaterialRow extends StatelessWidget {
  const _MaterialRow({
    required this.material,
    required this.onEdit,
    required this.onDelete,
  });

  final BaseMaterial material;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onEdit,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  material.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 1,
                child: Text(
                  material.unit,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 88,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      tooltip: '编辑',
                    ),
                    IconButton(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      tooltip: '删除',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MaterialTableHeader extends StatelessWidget {
  const _MaterialTableHeader({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text('材料名称', style: Theme.of(context).textTheme.labelLarge),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 1,
            child: Text('单位', style: Theme.of(context).textTheme.labelLarge),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 88,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text('操作', style: Theme.of(context).textTheme.labelLarge),
            ),
          ),
        ],
      ),
    );
  }
}

enum _ImportMode { increment, replaceAll }

class _ImportParseResult {
  const _ImportParseResult({required this.nameToUnits});

  final Map<String, Set<String>> nameToUnits;

  Map<String, Set<String>> get conflicts {
    final map = <String, Set<String>>{};
    for (final entry in nameToUnits.entries) {
      if (entry.value.length > 1) {
        map[entry.key] = entry.value;
      }
    }
    return map;
  }
}

// 新增/编辑基础材料表单
class _BaseMaterialFormSheet extends StatefulWidget {
  const _BaseMaterialFormSheet({this.material});

  final BaseMaterial? material;

  @override
  State<_BaseMaterialFormSheet> createState() => _BaseMaterialFormSheetState();
}

class _BaseMaterialFormSheetState extends State<_BaseMaterialFormSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _unitController;

  @override
  void initState() {
    super.initState();
    // 初始化表单输入默认值
    _nameController = TextEditingController(text: widget.material?.name ?? '');
    _unitController = TextEditingController(text: widget.material?.unit ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _unitController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final result = _BaseMaterialFormResult(
      name: _nameController.text.trim(),
      unit: _unitController.text.trim(),
    );
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.material != null;
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottomPadding + 20),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  isEditing ? '编辑材料' : '新增材料',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '材料名称',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return '请输入材料名称';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _unitController,
              decoration: const InputDecoration(
                labelText: '计量单位',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return '请输入计量单位';
                }
                return null;
              },
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submit,
                child: Text(isEditing ? '保存修改' : '确认新增'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 表单提交结果
class _BaseMaterialFormResult {
  const _BaseMaterialFormResult({required this.name, required this.unit});

  final String name;
  final String unit;
}

class _PurchaseDetailLayout {
  const _PurchaseDetailLayout({
    required this.backRow,
    required this.titleRow,
    required this.infoRow,
    required this.headerRow,
    required this.dataRows,
    required this.summaryRow,
  });

  final int backRow;
  final int titleRow;
  final int infoRow;
  final int headerRow;
  final List<int> dataRows;
  final int summaryRow;
}
