import 'dart:io';

import 'package:excel/excel.dart' as excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class ZhengdaOutboundExportPage extends StatefulWidget {
  const ZhengdaOutboundExportPage({super.key});

  @override
  State<ZhengdaOutboundExportPage> createState() =>
      _ZhengdaOutboundExportPageState();
}

class _ZhengdaOutboundExportPageState extends State<ZhengdaOutboundExportPage> {
  static const List<String> _gradeOrder = ['一年级', '二年级', '三年级', '四年级', '五年级'];
  static const List<String> _requiredColumns = [
    '序号',
    '年级',
    '课程名称',
    '材料名称',
    '出库数量',
    '角色',
    '材料类型',
  ];
  final Map<String, TextEditingController> _studentControllers = {};
  final Map<String, TextEditingController> _teacherControllers = {};
  final List<String> _debugLogs = [];
  Uint8List? _sourceBytes;
  String? _sourceFileName;
  bool _calculating = false;

  @override
  void initState() {
    super.initState();
    for (final grade in _gradeOrder) {
      _studentControllers[grade] = TextEditingController(text: '0');
      _teacherControllers[grade] = TextEditingController(text: '0');
    }
  }

  @override
  void dispose() {
    for (final controller in _studentControllers.values) {
      controller.dispose();
    }
    for (final controller in _teacherControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _pickSourceFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      _appendDebug('选择文件已取消');
      return;
    }
    final file = result.files.single;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) {
      _appendDebug('读取源文件失败: ${file.name}');
      _showMessage('读取源文件失败');
      return;
    }
    _appendDebug('已导入文件: ${file.name}, 大小: ${bytes.lengthInBytes} bytes');
    setState(() {
      _sourceBytes = bytes;
      _sourceFileName = file.name;
    });
  }

  Future<void> _calculateAndExport() async {
    if (_sourceBytes == null || _calculating) {
      return;
    }
    final peopleCounts = _collectPeopleCounts();
    if (peopleCounts == null) {
      return;
    }
    _appendDebug('开始计算导出: 文件=${_sourceFileName ?? "未知"}, 人数=$peopleCounts');
    setState(() {
      _calculating = true;
    });
    try {
      final aggregateResult = _readAndAggregate(_sourceBytes!, peopleCounts);
      final filePath = await _writeResult(
        aggregate: aggregateResult,
        peopleCounts: peopleCounts,
      );
      final shared = await _shareExportFile(filePath);
      if (!mounted) {
        return;
      }
      _appendDebug('导出完成: $filePath, 分享触发=${shared ? "是" : "否"}');
      _showMessage(shared ? '已导出并唤起分享' : '已导出到 $filePath');
    } catch (error, stackTrace) {
      if (!mounted) {
        return;
      }
      final message = error.toString().replaceFirst('Exception: ', '');
      _appendDebug('计算导出失败: $message');
      _appendDebug(stackTrace.toString());
      _showMessage('计算导出失败：$message');
    } finally {
      if (mounted) {
        setState(() {
          _calculating = false;
        });
      }
    }
  }

  Map<String, Map<String, int>>? _collectPeopleCounts() {
    final result = <String, Map<String, int>>{};
    for (final grade in _gradeOrder) {
      final studentText = _studentControllers[grade]!.text.trim();
      final teacherText = _teacherControllers[grade]!.text.trim();
      final student = int.tryParse(studentText);
      final teacher = int.tryParse(teacherText);
      if (student == null || teacher == null || student < 0 || teacher < 0) {
        _showMessage('$grade 人数请输入非负整数');
        return null;
      }
      result[grade] = {'学生': student, '老师': teacher};
    }
    return result;
  }

  _AggregateResult _readAndAggregate(
    Uint8List sourceBytes,
    Map<String, Map<String, int>> peopleCounts,
  ) {
    _appendDebug('开始解析源数据');
    final workbook = excel.Excel.decodeBytes(sourceBytes);
    final sourceSheet = _findSourceSheet(workbook);
    final rows = sourceSheet.rows;
    _appendDebug('已读取源sheet，行数=${rows.length}');
    final headerValues = rows.first.map(_cellText).toList();
    _appendDebug('源表头: ${headerValues.join(' | ')}');
    final index = {
      for (final name in _requiredColumns) name: headerValues.indexOf(name),
    };
    final aggregate = <String, Map<_MaterialKey, _AggregateItem>>{
      for (final grade in _gradeOrder) grade: <_MaterialKey, _AggregateItem>{},
    };
    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      final grade = _cellText(_cellAt(row, index['年级']!));
      if (!_gradeOrder.contains(grade)) {
        continue;
      }
      final role = _cellText(_cellAt(row, index['角色']!));
      if (role != '学生' && role != '老师') {
        continue;
      }
      final materialName = _cellText(_cellAt(row, index['材料名称']!));
      final materialType = _cellText(_cellAt(row, index['材料类型']!));
      final courseName = _cellText(_cellAt(row, index['课程名称']!));
      final outboundQty = _cellNumber(_cellAt(row, index['出库数量']!));
      final people = peopleCounts[grade]![role] ?? 0;
      final finalQty = outboundQty * people;
      if (finalQty <= 0) {
        continue;
      }
      final key = _MaterialKey(
        materialName: materialName,
        materialType: materialType,
      );
      final gradeBucket = aggregate[grade]!;
      final item = gradeBucket.putIfAbsent(key, () => _AggregateItem());
      if (role == '老师') {
        item.teacherQty += finalQty;
      } else {
        item.studentQty += finalQty;
      }
      if (courseName.isNotEmpty) {
        item.courses.add(courseName);
      }
    }
    final sourceRows = rows
        .map(
          (row) =>
              row.map((cell) => _cellExportValue(cell)).toList(growable: true),
        )
        .toList(growable: true);
    _appendDebug('聚合完成: 原始行=${sourceRows.length}');
    return _AggregateResult(aggregate: aggregate, sourceRows: sourceRows);
  }

  Future<String> _writeResult({
    required _AggregateResult aggregate,
    required Map<String, Map<String, int>> peopleCounts,
  }) async {
    _appendDebug('开始写入导出工作簿');
    final workbook = excel.Excel.createExcel();
    _appendDebug('新工作簿初始sheet: ${workbook.tables.keys.join(', ')}');
    const rawSheetName = 'Sheet1';
    final rawSheet = workbook[rawSheetName];
    final defaultSet = workbook.setDefaultSheet(rawSheetName);
    _appendDebug('已设置默认打开sheet: $rawSheetName, 结果=$defaultSet');
    for (var i = 0; i < aggregate.sourceRows.length; i++) {
      final row = aggregate.sourceRows[i];
      _appendSheetRow(
        sheet: rawSheet,
        row: row,
        stage: 'Sheet1-原始数据',
        rowIndex: i + 1,
      );
    }
    for (final grade in _gradeOrder) {
      final sheet = workbook[grade];
      final teacherCount = peopleCounts[grade]!['老师'] ?? 0;
      final studentCount = peopleCounts[grade]!['学生'] ?? 0;
      _appendSheetRow(
        sheet: sheet,
        stage: '$grade-表头',
        row: [
          '序号',
          '年级',
          '材料名称',
          '老师数量【$teacherCount】',
          '学生数量【$studentCount】',
          '出库数量',
          '材料类型',
          '课程名称',
        ],
      );
      final gradeData = aggregate.aggregate[grade] ?? {};
      final sortedItems = gradeData.entries.toList()
        ..sort((a, b) {
          final aMaterialFirst = a.key.materialType == '普通材料' ? 0 : 1;
          final bMaterialFirst = b.key.materialType == '普通材料' ? 0 : 1;
          if (aMaterialFirst != bMaterialFirst) {
            return aMaterialFirst.compareTo(bMaterialFirst);
          }
          final aTotal = a.value.teacherQty + a.value.studentQty;
          final bTotal = b.value.teacherQty + b.value.studentQty;
          final totalCompare = aTotal.compareTo(bTotal);
          if (totalCompare != 0) {
            return totalCompare;
          }
          final typeCompare = a.key.materialType.compareTo(b.key.materialType);
          if (typeCompare != 0) {
            return typeCompare;
          }
          return a.key.materialName.compareTo(b.key.materialName);
        });
      for (var i = 0; i < sortedItems.length; i++) {
        final entry = sortedItems[i];
        final item = entry.value;
        final courses = item.courses.toList()..sort();
        final totalQty = item.teacherQty + item.studentQty;
        _appendSheetRow(
          sheet: sheet,
          stage: '$grade-数据',
          rowIndex: i + 1,
          row: [
            i + 1,
            grade,
            entry.key.materialName,
            _formatNumber(item.teacherQty),
            _formatNumber(item.studentQty),
            _formatNumber(totalQty),
            entry.key.materialType,
            courses.join('，'),
          ],
        );
      }
    }
    final summarySheet = workbook['出库汇总'];
    _appendSheetRow(
      sheet: summarySheet,
      stage: '出库汇总-表头',
      row: ['序号', '材料名称', '出库总数量', '一年级数量', '二年级数量', '三年级数量', '四年级数量', '五年级数量'],
    );
    final summaryData = <String, Map<String, double>>{};
    for (final grade in _gradeOrder) {
      final gradeData = aggregate.aggregate[grade] ?? {};
      for (final entry in gradeData.entries) {
        final material = entry.key.materialName;
        final totalQty = entry.value.teacherQty + entry.value.studentQty;
        final gradeMap = summaryData.putIfAbsent(
          material,
          () => {for (final g in _gradeOrder) g: 0},
        );
        gradeMap[grade] = (gradeMap[grade] ?? 0) + totalQty;
      }
    }
    final summaryRows = summaryData.entries.toList()
      ..sort((a, b) {
        final totalA = a.value.values.fold<double>(
          0,
          (sum, item) => sum + item,
        );
        final totalB = b.value.values.fold<double>(
          0,
          (sum, item) => sum + item,
        );
        final totalCompare = totalB.compareTo(totalA);
        if (totalCompare != 0) {
          return totalCompare;
        }
        return a.key.compareTo(b.key);
      });
    for (var i = 0; i < summaryRows.length; i++) {
      final row = summaryRows[i];
      final gradeValues = _gradeOrder
          .map((grade) => row.value[grade] ?? 0)
          .toList();
      final total = gradeValues.fold<double>(0, (sum, item) => sum + item);
      _appendSheetRow(
        sheet: summarySheet,
        stage: '出库汇总-数据',
        rowIndex: i + 1,
        row: [
          i + 1,
          row.key,
          _formatNumber(total),
          _formatNumber(gradeValues[0]),
          _formatNumber(gradeValues[1]),
          _formatNumber(gradeValues[2]),
          _formatNumber(gradeValues[3]),
          _formatNumber(gradeValues[4]),
        ],
      );
    }
    _appendDebug('开始保存xlsx文件');
    final bytes = workbook.save();
    if (bytes == null) {
      throw Exception('导出失败');
    }
    final directory = await _exportDirectory();
    final fileName = '正大出库数量汇总_${_formatDateTime(DateTime.now())}.xlsx';
    final exportFile = File(p.join(directory.path, fileName));
    await exportFile.writeAsBytes(bytes, flush: true);
    _appendDebug('xlsx写入完成: ${exportFile.path}');
    return exportFile.path;
  }

  dynamic _formatNumber(double value) {
    if (value % 1 == 0) {
      return value.toInt();
    }
    return double.parse(value.toStringAsFixed(4));
  }

  excel.Data? _cellAt(List<excel.Data?> row, int index) {
    if (index < 0 || index >= row.length) {
      return null;
    }
    return row[index];
  }

  String _cellText(excel.Data? cell) {
    return _valueText(cell?.value);
  }

  double _cellNumber(excel.Data? cell) {
    final value = cell?.value;
    if (value == null) {
      return 0;
    }
    if (value is num) {
      return value.toDouble();
    }
    final text = _valueText(value);
    if (text.isEmpty) {
      return 0;
    }
    return double.tryParse(text) ?? 0;
  }

  excel.Sheet _findSourceSheet(excel.Excel workbook) {
    if (workbook.tables.isEmpty) {
      throw Exception('未找到可读取工作表');
    }
    _appendDebug('工作簿sheet: ${workbook.tables.keys.join(', ')}');
    final preferred = workbook.tables['Sheet1'];
    if (_isValidSourceSheet(preferred)) {
      _appendDebug('命中源sheet: Sheet1');
      return preferred!;
    }
    for (final sheet in workbook.tables.values) {
      if (_isValidSourceSheet(sheet)) {
        _appendDebug(
          '命中源sheet: ${workbook.tables.entries.firstWhere((entry) => identical(entry.value, sheet)).key}',
        );
        return sheet;
      }
    }
    throw Exception('未找到可识别表头，需包含：${_requiredColumns.join('、')}');
  }

  bool _isValidSourceSheet(excel.Sheet? sheet) {
    if (sheet == null) {
      return false;
    }
    final rows = sheet.rows;
    if (rows.isEmpty) {
      return false;
    }
    final headers = rows.first.map(_cellText).toList();
    for (final name in _requiredColumns) {
      if (!headers.contains(name)) {
        return false;
      }
    }
    return true;
  }

  String _valueText(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is String) {
      return value.trim();
    }
    if (value is num || value is bool) {
      return value.toString();
    }
    final raw = value.toString().trim();
    final match = RegExp(r'value:\s*(.+)\)$').firstMatch(raw);
    if (match != null) {
      return match.group(1)?.trim() ?? '';
    }
    return raw;
  }

  void _appendSheetRow({
    required excel.Sheet sheet,
    required List<dynamic> row,
    required String stage,
    int? rowIndex,
  }) {
    final mutable = List<dynamic>.from(row, growable: true);
    try {
      sheet.appendRow(mutable);
    } catch (error, stackTrace) {
      _appendDebug(
        'appendRow失败: 阶段=$stage, 行=${rowIndex ?? 0}, 列数=${mutable.length}, 数据=$mutable',
      );
      _appendDebug('appendRow异常: $error');
      _appendDebug(stackTrace.toString());
      rethrow;
    }
  }

  void _appendDebug(String message) {
    final now = DateTime.now();
    final line =
        '[${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}] $message';
    debugPrint(line);
    if (!mounted) {
      _debugLogs.add(line);
      return;
    }
    setState(() {
      _debugLogs.add(line);
      if (_debugLogs.length > 300) {
        _debugLogs.removeRange(0, _debugLogs.length - 300);
      }
    });
  }

  Future<void> _copyLogs() async {
    final content = _debugLogs.join('\n');
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) {
      return;
    }
    _showMessage('调试日志已复制');
  }

  dynamic _cellExportValue(excel.Data? cell) {
    final value = cell?.value;
    if (value == null) {
      return '';
    }
    if (value is num || value is bool || value is String) {
      return value;
    }
    return _valueText(value);
  }

  Future<Directory> _exportDirectory() async {
    if (Platform.isAndroid) {
      return getTemporaryDirectory();
    }
    return getApplicationDocumentsDirectory();
  }

  Future<bool> _shareExportFile(String filePath) async {
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
    return Scaffold(
      appBar: AppBar(title: const Text('正大出库导出')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '先导入“正大出库清洗.xlsx”，再输入五个年级的学生与老师人数，点击计算后导出结果。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickSourceFile,
            icon: const Icon(Icons.attach_file),
            label: Text(
              _sourceFileName == null ? '导入 xlsx 源数据' : '已导入：$_sourceFileName',
            ),
          ),
          const SizedBox(height: 16),
          ..._gradeOrder.map(
            (grade) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(width: 72, child: Text(grade)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _studentControllers[grade],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '学生人数',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _teacherControllers[grade],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '老师人数',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _sourceBytes == null || _calculating
                ? null
                : _calculateAndExport,
            icon: _calculating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.calculate_outlined),
            label: Text(_calculating ? '计算中...' : '计算并导出'),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '调试日志',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton(
                        onPressed: _debugLogs.isEmpty
                            ? null
                            : () {
                                setState(() {
                                  _debugLogs.clear();
                                });
                              },
                        child: const Text('清空'),
                      ),
                      TextButton(
                        onPressed: _debugLogs.isEmpty ? null : _copyLogs,
                        child: const Text('复制'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(
                      minHeight: 80,
                      maxHeight: 220,
                    ),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _debugLogs.isEmpty ? '暂无日志' : _debugLogs.join('\n'),
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AggregateResult {
  const _AggregateResult({required this.aggregate, required this.sourceRows});

  final Map<String, Map<_MaterialKey, _AggregateItem>> aggregate;
  final List<List<dynamic>> sourceRows;
}

class _MaterialKey {
  const _MaterialKey({required this.materialName, required this.materialType});

  final String materialName;
  final String materialType;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is _MaterialKey &&
        other.materialName == materialName &&
        other.materialType == materialType;
  }

  @override
  int get hashCode => Object.hash(materialName, materialType);
}

class _AggregateItem {
  double teacherQty = 0;
  double studentQty = 0;
  final Set<String> courses = {};
}
