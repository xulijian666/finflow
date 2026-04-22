import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/record_database.dart';

class CourseOutboundImportPage extends StatefulWidget {
  const CourseOutboundImportPage({super.key});

  @override
  State<CourseOutboundImportPage> createState() =>
      _CourseOutboundImportPageState();
}

class _CourseOutboundImportPageState extends State<CourseOutboundImportPage> {
  static const List<String> _requiredColumns = [
    '序号',
    '年级',
    '课程名称',
    '材料名称',
    '出库数量',
    '角色',
    '材料类型',
    '出库类别',
    '每组数量',
    '每组学生人数',
  ];
  final Map<String, TextEditingController> _studentControllers = {};
  final Map<String, TextEditingController> _teacherControllers = {};
  final List<_ExportHistoryItem> _historyRecords = [];
  Uint8List? _sourceBytes;
  String? _sourceFileName;
  bool _calculating = false;
  List<String> _grades = [];

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
    try {
      final grades = _extractGrades(bytes);
      if (grades.isEmpty) {
        _showMessage('源数据未识别到年级');
        return;
      }
      _appendDebug('已导入文件: ${file.name}, 年级=${grades.join("、")}');
      setState(() {
        _sourceBytes = bytes;
        _sourceFileName = file.name;
        _grades = grades;
        _syncPeopleControllers(grades);
      });
    } catch (error) {
      final message = error.toString().replaceFirst('Exception: ', '');
      _appendDebug('解析源文件失败: $message');
      _showMessage('解析源文件失败：$message');
    }
  }

  List<String> _extractGrades(Uint8List sourceBytes) {
    final workbook = excel.Excel.decodeBytes(sourceBytes);
    final sourceSheet = _findSourceSheet(workbook);
    final rows = sourceSheet.rows;
    final headerValues = rows.first.map(_cellText).toList();
    final gradeIndex = headerValues.indexOf('年级');
    if (gradeIndex < 0) {
      throw Exception('表头缺少“年级”');
    }
    final seen = <String>{};
    final grades = <String>[];
    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      final grade = _cellText(_cellAt(row, gradeIndex));
      if (grade.isEmpty || seen.contains(grade)) {
        continue;
      }
      seen.add(grade);
      grades.add(grade);
    }
    return grades;
  }

  void _syncPeopleControllers(List<String> grades) {
    final gradeSet = grades.toSet();
    final studentRemove = _studentControllers.keys
        .where((grade) => !gradeSet.contains(grade))
        .toList();
    for (final grade in studentRemove) {
      _studentControllers.remove(grade)?.dispose();
    }
    final teacherRemove = _teacherControllers.keys
        .where((grade) => !gradeSet.contains(grade))
        .toList();
    for (final grade in teacherRemove) {
      _teacherControllers.remove(grade)?.dispose();
    }
    for (final grade in grades) {
      _studentControllers.putIfAbsent(grade, () => TextEditingController());
      _teacherControllers.putIfAbsent(grade, () => TextEditingController());
    }
  }

  Future<void> _calculateAndExport() async {
    if (_sourceBytes == null || _calculating || _grades.isEmpty) {
      return;
    }
    final peopleCounts = await _collectPeopleCounts();
    if (peopleCounts == null) {
      return;
    }
    _appendDebug('开始计算导出: 文件=${_sourceFileName ?? "未知"}, 人数=$peopleCounts');
    setState(() {
      _calculating = true;
    });
    try {
      final aggregateResult = await _readAndAggregate(
        _sourceBytes!,
        peopleCounts,
      );
      final filePath = await _writeResult(
        aggregate: aggregateResult,
        peopleCounts: peopleCounts,
      );
      final shared = await _shareExportFile(filePath);
      if (!mounted) {
        return;
      }
      final recordedAt = DateTime.now();
      final snapshot = {
        for (final entry in peopleCounts.entries)
          entry.key: {
            '学生': entry.value['学生'] ?? 0,
            '老师': entry.value['老师'] ?? 0,
          },
      };
      setState(() {
        _addHistoryRecord(
          _ExportHistoryItem(
            createdAt: recordedAt,
            filePath: filePath,
            fileName: p.basename(filePath),
            sourceFileName: _sourceFileName ?? '未知',
            peopleCounts: snapshot,
          ),
        );
      });
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

  Future<Map<String, Map<String, int>>?> _collectPeopleCounts() async {
    if (_grades.isEmpty) {
      _showMessage('请先导入源数据');
      return null;
    }
    final result = <String, Map<String, int>>{};
    final missingFields = <String>[];
    for (final grade in _grades) {
      final studentText = _studentControllers[grade]!.text.trim();
      final teacherText = _teacherControllers[grade]!.text.trim();
      final student = studentText.isEmpty ? 0 : int.tryParse(studentText);
      final teacher = teacherText.isEmpty ? 0 : int.tryParse(teacherText);
      if (student == null || student < 0) {
        _showMessage('$grade 学生人数请输入非负整数');
        return null;
      }
      if (teacher == null || teacher < 0) {
        _showMessage('$grade 老师人数请输入非负整数');
        return null;
      }
      if (studentText.isEmpty) {
        missingFields.add('$grade-学生人数');
      }
      if (teacherText.isEmpty) {
        missingFields.add('$grade-老师人数');
      }
      result[grade] = {'学生': student, '老师': teacher};
    }
    if (missingFields.isNotEmpty) {
      final continueExport = await _confirmContinueWithMissingFields(
        missingFields,
      );
      if (!continueExport) {
        _appendDebug('用户取消导出，未填写项：${missingFields.join('、')}');
        return null;
      }
      _appendDebug('未填写项按0处理：${missingFields.join('、')}');
    }
    return result;
  }

  Future<bool> _confirmContinueWithMissingFields(
    List<String> missingFields,
  ) async {
    if (!mounted) {
      return false;
    }
    final detail = missingFields.join('、');
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('存在未填写人数'),
          content: Text('以下输入框未填写：$detail。\n继续导出将按 0 处理，是否继续？'),
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

  Future<_AggregateResult> _readAndAggregate(
    Uint8List sourceBytes,
    Map<String, Map<String, int>> peopleCounts,
  ) async {
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
    final grades = peopleCounts.keys.toList();
    final aggregate = <String, Map<_MaterialKey, _AggregateItem>>{
      for (final grade in grades) grade: <_MaterialKey, _AggregateItem>{},
    };
    // 课程成本数据：按(年级,课程)分组记录材料使用情况
    final courseCostMap = <String, _CourseCostItem>{};

    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      final grade = _cellText(_cellAt(row, index['年级']!));
      if (!peopleCounts.containsKey(grade)) {
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
      final outboundCategoryRaw = _cellText(_cellAt(row, index['出库类别']!));
      final outboundCategory = outboundCategoryRaw == '按组' ? '按组' : '按人';
      final eachGroupQty = _cellNumber(_cellAt(row, index['每组数量']!));
      final eachGroupStudent = _cellNumber(_cellAt(row, index['每组学生人数']!));
      double groupCount = 0;
      double finalQty;
      if (outboundCategory == '按组') {
        if (eachGroupStudent <= 0) {
          throw Exception('第${i + 1}行“每组学生人数”必须大于0');
        }
        if (eachGroupQty <= 0) {
          continue;
        }
        final studentCount = (peopleCounts[grade]!['学生'] ?? 0).toDouble();
        if (studentCount <= 0) {
          continue;
        }
        groupCount = math
            .max(1, (studentCount / eachGroupStudent).ceil())
            .toDouble();
        finalQty = groupCount * eachGroupQty;
      } else {
        final people = peopleCounts[grade]![role] ?? 0;
        finalQty = outboundQty * people;
      }
      if (finalQty <= 0) {
        continue;
      }
      final key = _MaterialKey(
        materialName: materialName,
        materialType: materialType,
        outboundCategory: outboundCategory,
        eachGroupQty: eachGroupQty,
        eachGroupStudent: eachGroupStudent,
      );
      final gradeBucket = aggregate[grade]!;
      final item = gradeBucket.putIfAbsent(
        key,
        () => _AggregateItem(
          outboundCategory: outboundCategory,
          eachGroupQty: eachGroupQty,
          eachGroupStudent: eachGroupStudent,
          groupCount: groupCount,
        ),
      );
      if (outboundCategory == '按组' && groupCount > item.groupCount) {
        item.groupCount = groupCount;
      }
      if (role == '老师') {
        item.teacherQty += finalQty;
      } else {
        item.studentQty += finalQty;
      }
      if (courseName.isNotEmpty) {
        item.courses.add(courseName);
      }
      // 记录课程成本数据（用于成本计算Sheet）
      if (courseName.isNotEmpty) {
        final costKey = '$grade|$courseName';
        final costItem = courseCostMap.putIfAbsent(
          costKey,
          () => _CourseCostItem(grade: grade, courseName: courseName),
        );
        // 累加材料数量
        if (!costItem.materialDetails.any(
          (d) => d.materialName == materialName && d.role == role,
        )) {
          costItem.materialDetails.add(
            _CourseMaterialDetail(
              materialName: materialName,
              unitPrice: 0,
              quantity: finalQty,
              role: role,
            ),
          );
        } else {
          final existingDetail = costItem.materialDetails.firstWhere(
            (d) => d.materialName == materialName && d.role == role,
          );
          existingDetail.quantity += finalQty;
        }
      }
    }

    // 获取材料单价并更新课程成本数据
    _appendDebug('开始获取材料单价');
    await _fetchAndApplyUnitPrices(courseCostMap);

    // 暂不排序，在写入成本计算Sheet时按每生成本排序
    final courseCosts = courseCostMap.values.toList();

    final sourceRows = rows
        .map(
          (row) =>
              row.map((cell) => _cellExportValue(cell)).toList(growable: true),
        )
        .toList(growable: true);
    _appendDebug(
      '聚合完成: 原始行=${sourceRows.length}，课程成本数据=${courseCosts.length}条',
    );
    return _AggregateResult(
      aggregate: aggregate,
      sourceRows: sourceRows,
      grades: grades,
      courseCosts: courseCosts,
    );
  }

  // 从数据库获取材料单价并更新课程成本数据
  Future<void> _fetchAndApplyUnitPrices(
    Map<String, _CourseCostItem> courseCostMap,
  ) async {
    try {
      final inventorySummary = await RecordDatabase.instance
          .fetchInventorySummary();
      final unitPriceCache = <String, double>{};
      for (final item in inventorySummary) {
        final unitPrice = item.purchasedQuantity > 0
            ? item.totalAmount / item.purchasedQuantity
            : 0.0;
        unitPriceCache[item.materialName] = unitPrice;
        _appendDebug('材料单价: ${item.materialName} = $unitPrice');
      }
      // 更新课程成本数据中的单价并计算总价
      for (final costItem in courseCostMap.values) {
        double totalTeacherCost = 0;
        double totalStudentCost = 0;
        for (final detail in costItem.materialDetails) {
          final unitPrice = unitPriceCache[detail.materialName] ?? 0.0;
          detail.unitPrice = unitPrice;
          final materialCost = detail.quantity * unitPrice;
          if (detail.role == '老师') {
            totalTeacherCost += materialCost;
          } else {
            totalStudentCost += materialCost;
          }
        }
        costItem.teacherCost = totalTeacherCost;
        costItem.studentCost = totalStudentCost;
        _appendDebug(
          '课程成本: ${costItem.grade}-${costItem.courseName}, '
          '老师=$totalTeacherCost, 学生=$totalStudentCost',
        );
      }
    } catch (e) {
      _appendDebug('获取材料单价失败: $e，将使用0单价');
    }
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
    for (final grade in aggregate.grades) {
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
          '出库类别',
          '每组数量',
          '每组学生人数',
          '组数',
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
        final isByGroup = item.outboundCategory == '按组';
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
            item.outboundCategory,
            isByGroup ? _formatNumber(item.eachGroupQty) : '',
            isByGroup ? _formatNumber(item.eachGroupStudent) : '',
            isByGroup ? _formatNumber(item.groupCount) : '',
            courses.join('，'),
          ],
        );
      }
    }
    final summarySheet = workbook['出库汇总'];
    final inventorySummary = await RecordDatabase.instance.fetchInventorySummary();
    final inventoryQuantityMap = <String, double>{
      for (final item in inventorySummary) item.materialName: item.remainingQuantity,
    };
    _appendSheetRow(
      sheet: summarySheet,
      stage: '出库汇总-表头',
      row: [
        '序号',
        '材料名称',
        '当前库存数量',
        '出库总数量',
        '出库后库存数量',
        ...aggregate.grades.map((grade) => '$grade数量'),
      ],
    );
    final summaryData = <String, Map<String, double>>{};
    for (final grade in aggregate.grades) {
      final gradeData = aggregate.aggregate[grade] ?? {};
      for (final entry in gradeData.entries) {
        final material = entry.key.materialName;
        final totalQty = entry.value.teacherQty + entry.value.studentQty;
        final gradeMap = summaryData.putIfAbsent(
          material,
          () => {for (final g in aggregate.grades) g: 0},
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
      final gradeValues = aggregate.grades
          .map((grade) => row.value[grade] ?? 0)
          .toList();
      final total = gradeValues.fold<double>(0, (sum, item) => sum + item);
      // 根据材料名称回填当前库存，并计算出库后的剩余库存
      final currentInventory = inventoryQuantityMap[row.key] ?? 0;
      final remainingInventory = currentInventory - total;
      _appendSheetRow(
        sheet: summarySheet,
        stage: '出库汇总-数据',
        rowIndex: i + 1,
        row: [
          i + 1,
          row.key,
          _formatNumber(currentInventory),
          _formatNumber(total),
          _formatNumber(remainingInventory),
          ...gradeValues.map((value) => _formatNumber(value)),
        ],
      );
    }

    // 成本计算Sheet：按年级-课程汇总成本，按每生成本从高到低排序
    final costSheet = workbook['成本计算'];
    _appendSheetRow(
      sheet: costSheet,
      stage: '成本计算-表头',
      row: [
        '序号',
        '年级',
        '课程名称',
        '老师材料总价',
        '学生材料总价',
        '材料总价',
        '学生人数',
        '老师人数',
        '每生成本',
        '师均成本',
        '人均成本',
        '生师比',
        '最高材料占比',
        '集中度指数',
        '最大成本项',
        '健康度评分',
        '健康度评语',
        '备注（材料名称:单价）',
      ],
    );
    // 按每生成本从高到低排序
    final sortedCosts = aggregate.courseCosts.toList()
      ..sort((a, b) {
        final aTotal = a.teacherCost + a.studentCost;
        final bTotal = b.teacherCost + b.studentCost;
        final aStudentCount = peopleCounts[a.grade]!['学生'] ?? 0;
        final bStudentCount = peopleCounts[b.grade]!['学生'] ?? 0;
        final aCostPerStudent = aStudentCount > 0
            ? aTotal / aStudentCount
            : 0.0;
        final bCostPerStudent = bStudentCount > 0
            ? bTotal / bStudentCount
            : 0.0;
        return bCostPerStudent.compareTo(aCostPerStudent);
      });
    for (var i = 0; i < sortedCosts.length; i++) {
      final costItem = sortedCosts[i];
      final totalCost = costItem.teacherCost + costItem.studentCost;
      final studentCount = peopleCounts[costItem.grade]!['学生'] ?? 0;
      final teacherCount = peopleCounts[costItem.grade]!['老师'] ?? 0;
      final costPerStudent = studentCount > 0 ? totalCost / studentCount : 0.0;
      final costPerTeacher = teacherCount > 0 ? totalCost / teacherCount : 0.0;
      final totalPeople = studentCount + teacherCount;
      final costPerPerson = totalPeople > 0 ? totalCost / totalPeople : 0.0;
      final studentTeacherRatio = teacherCount > 0
          ? studentCount / teacherCount
          : 0.0;
      // 计算成本结构分析指标
      final materialCosts = <String, double>{};
      for (final detail in costItem.materialDetails) {
        final cost = detail.quantity * detail.unitPrice;
        materialCosts[detail.materialName] =
            (materialCosts[detail.materialName] ?? 0) + cost;
      }
      // 最高材料占比
      double highestRatio = 0.0;
      String highestCostMaterial = '';
      if (totalCost > 0) {
        for (final entry in materialCosts.entries) {
          final ratio = entry.value / totalCost;
          if (ratio > highestRatio) {
            highestRatio = ratio;
            highestCostMaterial = entry.key;
          }
        }
      }
      // 集中度指数（HHI）：各材料占比的平方和，接近1表示高度集中
      double hhi = 0.0;
      if (totalCost > 0) {
        for (final cost in materialCosts.values) {
          final ratio = cost / totalCost;
          hhi += ratio * ratio;
        }
      }
      // 健康度评分（基于集中度和最高占比）
      String healthScore = '';
      String healthComment = '';
      if (highestRatio >= 0.7 || hhi >= 0.6) {
        healthScore = '❌ 差';
        healthComment = '成本高度集中于${highestCostMaterial}，需重点优化';
      } else if (highestRatio >= 0.5 || hhi >= 0.4) {
        healthScore = '⚠️ 中';
        healthComment = '成本集中度偏高，${highestCostMaterial}可优化';
      } else if (highestRatio >= 0.3 || hhi >= 0.25) {
        healthScore = '✅ 良';
        healthComment = '成本结构合理，可小幅优化';
      } else {
        healthScore = '⭐ 优';
        healthComment = '成本分散均匀，结构健康';
      }
      // 生成材料明细备注
      final materialNotes = costItem.materialDetails
          .map((d) => '${d.materialName}:${_formatNumber(d.unitPrice)}')
          .toSet()
          .join('，');
      _appendSheetRow(
        sheet: costSheet,
        stage: '成本计算-数据',
        rowIndex: i + 1,
        row: [
          i + 1,
          costItem.grade,
          costItem.courseName,
          _formatNumber(costItem.teacherCost),
          _formatNumber(costItem.studentCost),
          _formatNumber(totalCost),
          studentCount,
          teacherCount,
          _formatNumber(costPerStudent),
          _formatNumber(costPerTeacher),
          _formatNumber(costPerPerson),
          _formatNumber(studentTeacherRatio),
          '${_formatNumber(highestRatio * 100)}%',
          _formatNumber(hhi),
          highestCostMaterial,
          healthScore,
          healthComment,
          materialNotes,
        ],
      );
    }

    _appendDebug('开始应用表格样式');
    _beautifyWorkbook(workbook);
    _appendDebug('开始保存xlsx文件');
    final bytes = workbook.save();
    if (bytes == null) {
      throw Exception('导出失败');
    }
    final frozenBytes = _freezeHeaderRows(bytes);
    final directory = await _exportDirectory();
    final fileName = '课程出库导出_${_formatDateTime(DateTime.now())}.xlsx';
    final exportFile = File(p.join(directory.path, fileName));
    await exportFile.writeAsBytes(frozenBytes, flush: true);
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

  void _beautifyWorkbook(excel.Excel workbook) {
    final border = excel.Border(
      borderStyle: excel.BorderStyle.Thin,
      borderColorHex: '#FF666666',
    );
    final normalStyle = excel.CellStyle(
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
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
    final highlightStyle = excel.CellStyle(
      backgroundColorHex: '#FFFFF2CC',
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    for (final entry in workbook.tables.entries) {
      final sheetName = entry.key;
      final sheet = entry.value;
      _applySheetStyles(
        sheet: sheet,
        normalStyle: normalStyle,
        headerStyle: headerStyle,
        highlightStyle: highlightStyle,
        sheetName: sheetName,
      );
      _autoFitSheetColumns(sheet);
    }
  }

  void _applySheetStyles({
    required excel.Sheet sheet,
    required excel.CellStyle normalStyle,
    required excel.CellStyle headerStyle,
    required excel.CellStyle highlightStyle,
    required String sheetName,
  }) {
    if (sheet.maxRows <= 0 || sheet.maxCols <= 0) {
      return;
    }
    final highlightColumns = <int>{};
    final healthScoreColumns = <int>{};
    final remainingInventoryColumns = <int>{};
    for (var col = 0; col < sheet.maxCols; col++) {
      final headerCell = sheet.cell(
        excel.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0),
      );
      final headerText = _valueText(headerCell.value);
      if (headerText.contains('出库数量')) {
        highlightColumns.add(col);
      }
      if (headerText.contains('健康度评分')) {
        healthScoreColumns.add(col);
      }
      if (headerText == '出库后库存数量') {
        remainingInventoryColumns.add(col);
      }
    }
    // 健康度颜色样式
    final healthBadStyle = excel.CellStyle(
      fontColorHex: '#FF8B0000',
      bold: true,
    );
    final healthMidStyle = excel.CellStyle(
      fontColorHex: '#FF996600',
      bold: true,
    );
    final healthGoodStyle = excel.CellStyle(
      fontColorHex: '#FF2E7D32',
      bold: true,
    );
    final healthExcellentStyle = excel.CellStyle(
      fontColorHex: '#FF1B5E20',
      bold: true,
    );
    final nonPositiveInventoryStyle = excel.CellStyle(
      fontColorHex: '#FF8B0000',
      backgroundColorHex: '#FFFDE9D9',
      bold: true,
      leftBorder: normalStyle.leftBorder,
      rightBorder: normalStyle.rightBorder,
      topBorder: normalStyle.topBorder,
      bottomBorder: normalStyle.bottomBorder,
    );

    for (var row = 0; row < sheet.maxRows; row++) {
      for (var col = 0; col < sheet.maxCols; col++) {
        final cell = sheet.cell(
          excel.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row),
        );
        if (row == 0) {
          cell.cellStyle = headerStyle;
          continue;
        }
        // 成本计算Sheet的健康度评分列特殊处理
        if (healthScoreColumns.contains(col)) {
          final cellText = _valueText(cell.value) ?? '';
          if (cellText.contains('差')) {
            cell.cellStyle = healthBadStyle;
          } else if (cellText.contains('中')) {
            cell.cellStyle = healthMidStyle;
          } else if (cellText.contains('良')) {
            cell.cellStyle = healthGoodStyle;
          } else if (cellText.contains('优')) {
            cell.cellStyle = healthExcellentStyle;
          } else {
            cell.cellStyle = normalStyle;
          }
          continue;
        }
        if (remainingInventoryColumns.contains(col)) {
          final numericValue = num.tryParse(_valueText(cell.value));
          if (numericValue != null && numericValue <= 0) {
            cell.cellStyle = nonPositiveInventoryStyle;
            continue;
          }
        }
        cell.cellStyle = highlightColumns.contains(col)
            ? highlightStyle
            : normalStyle;
      }
    }
  }

  void _autoFitSheetColumns(excel.Sheet sheet) {
    if (sheet.maxRows <= 0 || sheet.maxCols <= 0) {
      return;
    }
    for (var col = 0; col < sheet.maxCols; col++) {
      var maxWidth = 0;
      for (var row = 0; row < sheet.maxRows; row++) {
        final cell = sheet.cell(
          excel.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row),
        );
        final width = _textDisplayWidth(_valueText(cell.value));
        if (width > maxWidth) {
          maxWidth = width;
        }
      }
      final targetWidth = (maxWidth + 2).toDouble().clamp(10, 60).toDouble();
      sheet.setColWidth(col, targetWidth);
    }
  }

  int _textDisplayWidth(String text) {
    if (text.isEmpty) {
      return 0;
    }
    var total = 0;
    for (final rune in text.runes) {
      total += rune <= 0x7F ? 1 : 2;
    }
    return total;
  }

  List<int> _freezeHeaderRows(List<int> xlsxBytes) {
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
      final updated = _injectFrozenPane(xml);
      if (updated == xml) {
        continue;
      }
      final updatedBytes = utf8.encode(updated);
      final replaced = ArchiveFile(file.name, updatedBytes.length, updatedBytes)
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

  String _injectFrozenPane(String xml) {
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

  void _appendDebug(String message) {
    final now = DateTime.now();
    final line =
        '[${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}] $message';
    debugPrint(line);
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

  void _addHistoryRecord(_ExportHistoryItem item) {
    _historyRecords.add(item);
    _historyRecords.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (_historyRecords.length > 3) {
      _historyRecords.removeRange(3, _historyRecords.length);
    }
  }

  String _formatHistoryDateTime(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute';
  }

  Future<void> _showHistoryDetail(_ExportHistoryItem item) async {
    if (!mounted) {
      return;
    }
    final grades = item.peopleCounts.keys.toList()..sort();
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('录入人数｜${_formatHistoryDateTime(item.createdAt)}'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('源文件：${item.sourceFileName}'),
                  const SizedBox(height: 8),
                  ...grades.map((grade) {
                    final count = item.peopleCounts[grade]!;
                    final student = count['学生'] ?? 0;
                    final teacher = count['老师'] ?? 0;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('$grade：学生 $student，老师 $teacher'),
                    );
                  }),
                ],
              ),
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

  Future<void> _downloadHistoryFile(_ExportHistoryItem item) async {
    final file = File(item.filePath);
    if (!await file.exists()) {
      if (mounted) {
        _showMessage('文件不存在：${item.fileName}');
      }
      return;
    }
    final shared = await _shareExportFile(item.filePath);
    if (!mounted) {
      return;
    }
    _showMessage(shared ? '已唤起下载分享：${item.fileName}' : '文件路径：${item.filePath}');
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
      appBar: AppBar(title: const Text('课程出库导出')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '先导入源数据，系统自动识别年级后，再输入各年级学生与老师人数，点击计算后导出结果。',
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
          if (_grades.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '识别到年级：${_grades.join('、')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          ..._grades.map(
            (grade) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(width: 88, child: Text(grade)),
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
          if (_grades.isEmpty)
            Text(
              '导入后将按源数据中的年级动态生成人数输入项',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _sourceBytes == null || _calculating || _grades.isEmpty
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
                  const Text(
                    '历史导出记录',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  if (_historyRecords.isEmpty)
                    Text(
                      '暂无历史导出记录',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else
                    Column(
                      children: _historyRecords.map((item) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _formatHistoryDateTime(item.createdAt),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      item.fileName,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              TextButton(
                                onPressed: () => _showHistoryDetail(item),
                                child: const Text('查看'),
                              ),
                              FilledButton.tonal(
                                onPressed: () => _downloadHistoryFile(item),
                                child: const Text('下载'),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
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

class _ExportHistoryItem {
  const _ExportHistoryItem({
    required this.createdAt,
    required this.filePath,
    required this.fileName,
    required this.sourceFileName,
    required this.peopleCounts,
  });

  final DateTime createdAt;
  final String filePath;
  final String fileName;
  final String sourceFileName;
  final Map<String, Map<String, int>> peopleCounts;
}

class _AggregateResult {
  const _AggregateResult({
    required this.aggregate,
    required this.sourceRows,
    required this.grades,
    required this.courseCosts,
  });

  final Map<String, Map<_MaterialKey, _AggregateItem>> aggregate;
  final List<List<dynamic>> sourceRows;
  final List<String> grades;
  final List<_CourseCostItem> courseCosts; // 课程成本数据
}

class _MaterialKey {
  const _MaterialKey({
    required this.materialName,
    required this.materialType,
    required this.outboundCategory,
    required this.eachGroupQty,
    required this.eachGroupStudent,
  });

  final String materialName;
  final String materialType;
  final String outboundCategory;
  final double eachGroupQty;
  final double eachGroupStudent;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is _MaterialKey &&
        other.materialName == materialName &&
        other.materialType == materialType &&
        other.outboundCategory == outboundCategory &&
        other.eachGroupQty == eachGroupQty &&
        other.eachGroupStudent == eachGroupStudent;
  }

  @override
  int get hashCode => Object.hash(
    materialName,
    materialType,
    outboundCategory,
    eachGroupQty,
    eachGroupStudent,
  );
}

class _AggregateItem {
  _AggregateItem({
    required this.outboundCategory,
    required this.eachGroupQty,
    required this.eachGroupStudent,
    required this.groupCount,
  });

  double teacherQty = 0;
  double studentQty = 0;
  final Set<String> courses = {};
  final String outboundCategory;
  final double eachGroupQty;
  final double eachGroupStudent;
  double groupCount;
}

// 课程成本明细项：记录每种材料在特定课程中的使用情况
class _CourseMaterialDetail {
  _CourseMaterialDetail({
    required this.materialName,
    required this.unitPrice,
    required this.quantity,
    required this.role,
  });

  final String materialName;
  double unitPrice; // 材料单价
  double quantity; // 使用数量
  final String role; // 学生/老师
}

// 课程成本汇总项：记录每个年级-课程组合的成本信息
class _CourseCostItem {
  _CourseCostItem({required this.grade, required this.courseName});

  final String grade;
  final String courseName;
  double teacherCost = 0; // 老师材料总价
  double studentCost = 0; // 学生材料总价
  final List<_CourseMaterialDetail> materialDetails = []; // 材料明细列表
}
