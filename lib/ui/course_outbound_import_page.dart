import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
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
  static const String _historyPrefsKey = 'course_export_history';
  final Map<String, TextEditingController> _studentControllers = {};
  final Map<String, TextEditingController> _teacherControllers = {};
  final List<_ExportHistoryItem> _historyRecords = [];
  Uint8List? _sourceBytes;
  String? _sourceFileName;
  bool _calculating = false;
  List<String> _grades = [];

  @override
  void initState() {
    super.initState();
    _loadHistoryRecords();
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
    final sourceRowQuantities = <int, double>{};

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
      sourceRowQuantities[i] = finalQty;
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
        final basisQuantity = outboundCategory == '按组'
            ? eachGroupQty
            : outboundQty;
        final multiplierValue = outboundCategory == '按组'
            ? groupCount
            : (peopleCounts[grade]![role] ?? 0).toDouble();
        // 课程详情Sheet需要保留不同计算口径，避免按人/按组混合后无法审计。
        if (!costItem.materialDetails.any(
          (d) =>
              d.materialName == materialName &&
              d.role == role &&
              d.outboundCategory == outboundCategory &&
              _isSameDouble(d.basisQuantity, basisQuantity) &&
              _isSameDouble(d.multiplierValue, multiplierValue),
        )) {
          costItem.materialDetails.add(
            _CourseMaterialDetail(
              materialName: materialName,
              unitPrice: 0,
              quantity: finalQty,
              minimumQuantity: _minimumCostQuantity(
                role: role,
                outboundCategory: outboundCategory,
                actualQuantity: finalQty,
                eachGroupQty: eachGroupQty,
              ),
              role: role,
              outboundCategory: outboundCategory,
              basisQuantity: basisQuantity,
              multiplierValue: multiplierValue,
            ),
          );
        } else {
          final existingDetail = costItem.materialDetails.firstWhere(
            (d) =>
                d.materialName == materialName &&
                d.role == role &&
                d.outboundCategory == outboundCategory &&
                _isSameDouble(d.basisQuantity, basisQuantity) &&
                _isSameDouble(d.multiplierValue, multiplierValue),
          );
          existingDetail.quantity += finalQty;
          existingDetail.minimumQuantity += _minimumCostQuantity(
            role: role,
            outboundCategory: outboundCategory,
            actualQuantity: finalQty,
            eachGroupQty: eachGroupQty,
          );
        }
      }
    }

    // 获取材料单价并更新课程成本数据
    _appendDebug('开始获取材料单价');
    final unitPriceByMaterial = await _fetchAndApplyUnitPrices(courseCostMap);

    // 暂不排序，在写入成本计算Sheet时按材料总价排序
    final courseCosts = courseCostMap.values.toList();

    final sourceRows = rows
        .map(
          (row) =>
              row.map((cell) => _cellExportValue(cell)).toList(growable: true),
        )
        .toList(growable: true);
    final materialPriceRows = _buildMaterialPriceRows(
      sourceRows: sourceRows,
      columnIndex: index,
      sourceRowQuantities: sourceRowQuantities,
      unitPriceByMaterial: unitPriceByMaterial,
      peopleCounts: peopleCounts,
    );
    _appendDebug(
      '聚合完成: 原始行=${sourceRows.length}，课程成本数据=${courseCosts.length}条',
    );
    return _AggregateResult(
      aggregate: aggregate,
      sourceRows: sourceRows,
      materialPriceRows: materialPriceRows,
      grades: grades,
      courseCosts: courseCosts,
    );
  }

  // 从数据库获取材料单价并更新课程成本数据
  Future<Map<String, double>> _fetchAndApplyUnitPrices(
    Map<String, _CourseCostItem> courseCostMap,
  ) async {
    final unitPriceCache = <String, double>{};
    try {
      final inventorySummary = await RecordDatabase.instance
          .fetchInventorySummary();
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
        costItem.teacherMinimumCost = 0;
        for (final detail in costItem.materialDetails) {
          final unitPrice = unitPriceCache[detail.materialName] ?? 0.0;
          detail.unitPrice = unitPrice;
          final materialCost = detail.quantity * unitPrice;
          final minimumCost = detail.minimumQuantity * unitPrice;
          if (detail.role == '老师') {
            totalTeacherCost += materialCost;
            costItem.teacherMinimumCost += minimumCost;
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
    return unitPriceCache;
  }

  double _minimumCostQuantity({
    required String role,
    required String outboundCategory,
    required double actualQuantity,
    required double eachGroupQty,
  }) {
    if (role != '老师') {
      return actualQuantity;
    }
    if (outboundCategory == '按组') {
      return eachGroupQty;
    }
    return actualQuantity;
  }

  List<List<dynamic>> _buildMaterialPriceRows({
    required List<List<dynamic>> sourceRows,
    required Map<String, int> columnIndex,
    required Map<int, double> sourceRowQuantities,
    required Map<String, double> unitPriceByMaterial,
    required Map<String, Map<String, int>> peopleCounts,
  }) {
    final materialNameIndex = columnIndex['材料名称'];
    final outboundQtyIndex = columnIndex['出库数量'];
    if (materialNameIndex == null || outboundQtyIndex == null) {
      return sourceRows.map((row) => List<dynamic>.from(row)).toList();
    }

    final result = <List<dynamic>>[];
    for (var i = 0; i < sourceRows.length; i++) {
      // 跳过业务字段全为空的数据行
      if (i > 0) {
        final src = sourceRows[i];
        bool allEmpty(int idx) =>
            idx >= src.length || _valueText(src[idx]).isEmpty;
        if (allEmpty(2) &&
            allEmpty(3) &&
            allEmpty(4) &&
            allEmpty(5) &&
            allEmpty(6) &&
            allEmpty(7)) {
          continue;
        }
      }
      final row = List<dynamic>.from(sourceRows[i], growable: true);
      String? qtyDesc;
      if (i == 0) {
        // 表头：在出库数量后插入材料单价和计算支撑字段
        _insertSheetCell(row, outboundQtyIndex, '材料单价');
        _insertSheetCell(row, outboundQtyIndex + 2, '学生人数');
        _insertSheetCell(row, outboundQtyIndex + 3, '老师人数');
        _insertSheetCell(row, outboundQtyIndex + 4, '按组每组出库数量');
        _insertSheetCell(row, outboundQtyIndex + 5, '每组学生人数');
        _insertSheetCell(row, outboundQtyIndex + 6, '组数');
        _insertSheetCell(row, outboundQtyIndex + 7, '材料总数');
        _insertSheetCell(row, outboundQtyIndex + 8, '总价');
        // 重命名源数据列
        row[5] = '按人每人出库数量';
      } else {
        final materialName = _valueText(
          _rowValueAt(sourceRows[i], materialNameIndex),
        );
        final rawUnitPrice = unitPriceByMaterial[materialName] ?? 0.0;
        final unitPrice = _roundToSigFigs(rawUnitPrice, 4);
        final finalQty = sourceRowQuantities[i] ?? 0.0;

        // 从源数据行读取支撑字段
        final gradeIndex = columnIndex['年级']!;
        final outboundCategoryIndex = columnIndex['出库类别']!;
        final eachGroupQtyIndex = columnIndex['每组数量']!;
        final eachGroupStudentIndex = columnIndex['每组学生人数']!;

        final grade = _valueText(_rowValueAt(sourceRows[i], gradeIndex));
        final role = _valueText(_rowValueAt(sourceRows[i], 5));
        final outboundCategory = _valueText(
          _rowValueAt(sourceRows[i], outboundCategoryIndex),
        );
        final eachGroupQty = _valueText(
          _rowValueAt(sourceRows[i], eachGroupQtyIndex),
        );
        final eachGroupStudent = _valueText(
          _rowValueAt(sourceRows[i], eachGroupStudentIndex),
        );

        // 计算人数和组数
        final gradePeople = peopleCounts[grade];
        final isByGroup = outboundCategory == '按组';
        String groupCountStr = '';
        if (isByGroup) {
          final studentCount = gradePeople != null
              ? (gradePeople['学生'] ?? 0)
              : 0;
          final eachGroupStudentNum = double.tryParse(eachGroupStudent) ?? 1;
          final double gc = eachGroupStudentNum > 0
              ? math
                    .max(1, (studentCount / eachGroupStudentNum).ceil())
                    .toDouble()
              : 0.0;
          groupCountStr = _formatFixed2(gc);
        }

        _insertSheetCell(row, outboundQtyIndex, unitPrice);
        _insertSheetCell(
          row,
          outboundQtyIndex + 2,
          isByGroup ? 0 : (gradePeople?['学生'] ?? 0),
        );
        _insertSheetCell(
          row,
          outboundQtyIndex + 3,
          isByGroup ? 0 : (gradePeople?['老师'] ?? 0),
        );
        _insertSheetCell(
          row,
          outboundQtyIndex + 4,
          isByGroup ? (double.tryParse(eachGroupQty) ?? 0) : 0,
        );
        _insertSheetCell(
          row,
          outboundQtyIndex + 5,
          isByGroup ? (double.tryParse(eachGroupStudent) ?? 0) : 0,
        );
        _insertSheetCell(
          row,
          outboundQtyIndex + 6,
          isByGroup ? (double.tryParse(groupCountStr) ?? 0) : 0,
        );
        _insertSheetCell(row, outboundQtyIndex + 7, finalQty);
        _insertSheetCell(row, outboundQtyIndex + 8, 0.0); // 占位，排序后更新公式
        // 说明列：材料总数计算方式
        final outboundQtyVal = _valueText(
          _rowValueAt(sourceRows[i], outboundQtyIndex),
        );
        final rolePeople = gradePeople?[role] ?? 0;
        qtyDesc = isByGroup
            ? '按组每组出库数量×组数=$eachGroupQty×$groupCountStr=${_formatFixed2(finalQty)}'
            : '按人每人出库数量×人数=$outboundQtyVal×$rolePeople=${_formatFixed2(finalQty)}';
      }
      // 移除源数据重复列：每组学生人数(17)、每组数量(16)
      if (row.length > 17) {
        row.removeAt(17);
        row.removeAt(16);
      }
      // 说明列（Q列）
      row.add(qtyDesc ?? '材料总数说明');
      result.add(row);
    }
    // 排序：跳过表头，对数据行排序
    final header = result.first;
    final dataRows = result.sublist(1);
    dataRows.sort((a, b) {
      final courseA = _valueText(a.length > 2 ? a[2] : null);
      final courseB = _valueText(b.length > 2 ? b[2] : null);
      // 公共材料、包装材料固定排最后
      const bottomCourses = {'公共材料', '包装材料'};
      final aBottom = bottomCourses.contains(courseA);
      final bBottom = bottomCourses.contains(courseB);
      if (aBottom != bBottom) return aBottom ? 1 : -1;
      // 课程名称排序：数字开头排前面
      final aNum = _courseSortKey(courseA);
      final bNum = _courseSortKey(courseB);
      if (aNum != bNum) return aNum.compareTo(bNum);
      final cmp = courseA.compareTo(courseB);
      if (cmp != 0) return cmp;
      // 第二排序字段：学生在前，老师在后
      final roleA = _valueText(a.length > 13 ? a[13] : null);
      final roleB = _valueText(b.length > 13 ? b[13] : null);
      const roleOrder = {'学生': 0, '老师': 1};
      return (roleOrder[roleA] ?? 2).compareTo(roleOrder[roleB] ?? 2);
    });
    // 排序后重排序号和公式行号
    for (var j = 0; j < dataRows.length; j++) {
      final row = dataRows[j];
      row[0] = j + 1; // 重排序号
      final excelRow = j + 2; // Excel行号（表头第1行，数据从第2行开始）
      row[12] = excel.Formula.custom('=E$excelRow*L$excelRow'); // 总价公式
    }
    return [header, ...dataRows];
  }

  Object? _rowValueAt(List<dynamic> row, int index) {
    if (index < 0 || index >= row.length) {
      return null;
    }
    return row[index];
  }

  double _roundToSigFigs(double value, int sigFigs) {
    if (value == 0) return 0;
    final d = (math.log(value.abs()) / math.ln10).ceil();
    final shift = sigFigs - d;
    final factor = math.pow(10, shift);
    return (value * factor).round() / factor;
  }

  bool _isSameDouble(double a, double b) {
    return (a - b).abs() < 0.000001;
  }

  int _courseSortKey(String name) {
    if (name.isEmpty) return 2;
    final first = name.substring(0, 1);
    if (RegExp(r'[0-9]').hasMatch(first)) return 0;
    if ('一二三四五六七八九十百千万'.contains(first)) return 0;
    return 1;
  }

  void _insertSheetCell(List<dynamic> row, int index, dynamic value) {
    while (row.length < index) {
      row.add('');
    }
    row.insert(index, value);
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
    final inventorySummary = await RecordDatabase.instance
        .fetchInventorySummary();
    final inventoryQuantityMap = <String, double>{
      for (final item in inventorySummary)
        item.materialName: item.remainingQuantity,
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

    // 成本计算Sheet：按年级-课程汇总成本，按材料总价从高到低排序
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
        '每生成本\n（材料总价/学生人数）',
        '老师材料最小值\n（1组人）',
        '最高材料占比',
        '最大成本项',
      ],
    );
    // 按材料总价从高到低排序
    final sortedCosts = aggregate.courseCosts.toList()
      ..sort((a, b) {
        final aTotal = a.teacherCost + a.studentCost;
        final bTotal = b.teacherCost + b.studentCost;
        return bTotal.compareTo(aTotal);
      });
    for (var i = 0; i < sortedCosts.length; i++) {
      final costItem = sortedCosts[i];
      final totalCost = costItem.teacherCost + costItem.studentCost;
      final studentCount = peopleCounts[costItem.grade]!['学生'] ?? 0;
      final teacherCount = peopleCounts[costItem.grade]!['老师'] ?? 0;
      final costPerStudent = studentCount > 0 ? totalCost / studentCount : 0.0;
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
      _appendSheetRow(
        sheet: costSheet,
        stage: '成本计算-数据',
        rowIndex: i + 1,
        row: [
          i + 1,
          costItem.grade,
          costItem.courseName,
          _formatFixed2(costItem.teacherCost),
          _formatFixed2(costItem.studentCost),
          _formatFixed2(totalCost),
          studentCount,
          teacherCount,
          _formatFixed2(costPerStudent),
          _formatFixed2(costItem.teacherMinimumCost),
          '${_formatFixed2(highestRatio * 100)}%',
          highestCostMaterial,
        ],
      );
    }

    // 材料单价Sheet
    final materialPriceSheet = workbook['材料单价'];
    for (var i = 0; i < aggregate.materialPriceRows.length; i++) {
      _appendSheetRow(
        sheet: materialPriceSheet,
        row: aggregate.materialPriceRows[i],
        stage: '材料单价',
        rowIndex: i + 1,
      );
    }

    // 课程详情Sheet：为每个课程创建材料成本明细
    final courseDetailSheetNames = <String, String>{}; // courseKey -> sheetName
    final usedSheetNames = <String>{};
    for (var i = 0; i < sortedCosts.length; i++) {
      final costItem = sortedCosts[i];
      final courseKey = '${costItem.grade}_${costItem.courseName}';
      // 生成唯一Sheet名
      var rawName = courseKey;
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
      courseDetailSheetNames[courseKey] = sheetName;

      final detailSheet = workbook[sheetName];
      final studentCount = peopleCounts[costItem.grade]!['学生'] ?? 0;
      final teacherCount = peopleCounts[costItem.grade]!['老师'] ?? 0;
      final totalCost = costItem.teacherCost + costItem.studentCost;
      final costPerStudent = studentCount > 0 ? totalCost / studentCount : 0.0;
      final sortedDetails = costItem.materialDetails.toList()
        ..sort((a, b) {
          final amountCompare = b.amount.compareTo(a.amount);
          if (amountCompare != 0) {
            return amountCompare;
          }
          const roleOrder = {'学生': 0, '老师': 1};
          final roleCompare = (roleOrder[a.role] ?? 9).compareTo(
            roleOrder[b.role] ?? 9,
          );
          if (roleCompare != 0) {
            return roleCompare;
          }
          final nameCompare = a.materialName.compareTo(b.materialName);
          if (nameCompare != 0) {
            return nameCompare;
          }
          return a.outboundCategory.compareTo(b.outboundCategory);
        });

      _appendSheetRow(
        sheet: detailSheet,
        stage: '$sheetName-返回',
        row: ['← 返回成本计算'],
      );
      _appendSheetRow(
        sheet: detailSheet,
        stage: '$sheetName-标题',
        row: ['课程成本审核清单', '', '', '', '', '', '', ''],
      );
      _appendSheetRow(
        sheet: detailSheet,
        stage: '$sheetName-基础信息',
        row: [
          '年级',
          costItem.grade,
          '',
          '课程名称',
          costItem.courseName,
          '',
          '',
          '',
        ],
      );
      _appendSheetRow(
        sheet: detailSheet,
        stage: '$sheetName-基础信息',
        row: ['学生人数', studentCount, '', '老师人数', teacherCount, '', '', ''],
      );
      _appendSheetRow(
        sheet: detailSheet,
        stage: '$sheetName-汇总',
        row: [
          '学生材料总价',
          _formatFixed2(costItem.studentCost),
          '',
          '老师材料总价',
          _formatFixed2(costItem.teacherCost),
          '',
          '',
          '',
        ],
      );
      _appendSheetRow(
        sheet: detailSheet,
        stage: '$sheetName-汇总',
        row: [
          '材料总价',
          _formatFixed2(totalCost),
          '',
          '每生成本',
          _formatFixed2(costPerStudent),
          '',
          '',
          '',
        ],
      );
      _appendSheetRow(
        sheet: detailSheet,
        stage: '$sheetName-汇总',
        row: [
          '老师材料最小值（1组人）',
          '',
          '',
          '',
          _formatFixed2(costItem.teacherMinimumCost),
          '',
          '',
          '',
        ],
      );
      _appendSheetRow(sheet: detailSheet, stage: '$sheetName-空行', row: []);
      _appendSheetRow(
        sheet: detailSheet,
        stage: '$sheetName-口径标题',
        row: ['成本计算口径', '', '', '', '', '', '', ''],
      );
      for (final note in _buildCourseCostAuditNotes(studentCount)) {
        _appendSheetRow(
          sheet: detailSheet,
          stage: '$sheetName-口径说明',
          row: [note, '', '', '', '', '', '', ''],
        );
      }
      _appendSheetRow(sheet: detailSheet, stage: '$sheetName-空行', row: []);
      _appendSheetRow(
        sheet: detailSheet,
        stage: '$sheetName-表头',
        row: ['序号', '材料名称', '角色', '计量方式', '单价', '数量', '金额', '计算说明'],
      );

      var seq = 0;
      for (final detail in sortedDetails) {
        seq++;
        _appendSheetRow(
          sheet: detailSheet,
          stage: '$sheetName-数据',
          rowIndex: seq,
          row: [
            seq,
            detail.materialName,
            detail.role,
            detail.outboundCategory,
            _formatFixed2(detail.unitPrice),
            _formatFixed2(detail.quantity),
            _formatFixed2(detail.amount),
            _buildCourseCostDetailDescription(detail),
          ],
        );
      }

      _appendSheetRow(
        sheet: detailSheet,
        stage: '$sheetName-合计',
        row: ['', '合计', '', '', '', '', _formatFixed2(totalCost), ''],
      );

      // 设置列宽
      detailSheet.setColWidth(0, 10.0);
      detailSheet.setColWidth(1, 28.0);
      detailSheet.setColWidth(2, 10.0);
      detailSheet.setColWidth(3, 10.0);
      detailSheet.setColWidth(4, 12.0);
      detailSheet.setColWidth(5, 12.0);
      detailSheet.setColWidth(6, 12.0);
      detailSheet.setColWidth(7, 44.0);
    }

    _appendDebug('开始应用表格样式');
    _beautifyWorkbook(
      workbook,
      skipSheets: courseDetailSheetNames.values.toSet(),
    );
    _applyHyperlinkStyles(workbook, courseDetailSheetNames, sortedCosts);
    _appendDebug('开始保存xlsx文件');
    final bytes = workbook.save();
    if (bytes == null) {
      throw Exception('导出失败');
    }
    final frozenBytes = _freezeHeaderRows(bytes);
    final hyperBytes = _injectHyperlinks(
      frozenBytes,
      courseDetailSheetNames,
      sortedCosts,
    );
    final directory = await _exportDirectory();
    final fileName = '课程出库导出_${_formatDateTime(DateTime.now())}.xlsx';
    final exportFile = File(p.join(directory.path, fileName));
    await exportFile.writeAsBytes(hyperBytes, flush: true);
    _appendDebug('xlsx写入完成: ${exportFile.path}');
    return exportFile.path;
  }

  dynamic _formatNumber(double value) {
    if (value % 1 == 0) {
      return value.toInt();
    }
    return double.parse(value.toStringAsFixed(2));
  }

  String _formatFixed2(double value) {
    return value.toStringAsFixed(2);
  }

  List<String> _buildCourseCostAuditNotes(int studentCount) {
    final costPerStudentDesc = studentCount > 0
        ? '每生成本 = 材料总价 / 学生人数'
        : '每生成本 = 学生人数为0时按0展示';
    return [
      '1. 学生材料总价 = 所有“学生”材料行金额之和',
      '2. 老师材料总价 = 所有“老师”材料行金额之和',
      '3. 材料总价 = 学生材料总价 + 老师材料总价；$costPerStudentDesc',
      '4. 老师材料最小值（1组人）= 老师按人材料按实际人数计算，老师按组材料仅按1组计算',
    ];
  }

  String _buildCourseCostDetailDescription(_CourseMaterialDetail detail) {
    final quantityPart = detail.outboundCategory == '按组'
        ? '按组：每组${_formatFixed2(detail.basisQuantity)} × ${_formatFixed2(detail.multiplierValue)}组 = ${_formatFixed2(detail.quantity)}'
        : '按人：每人${_formatFixed2(detail.basisQuantity)} × ${_formatFixed2(detail.multiplierValue)}人 = ${_formatFixed2(detail.quantity)}';
    final amountPart =
        '金额：${_formatFixed2(detail.quantity)} × ${_formatFixed2(detail.unitPrice)} = ${_formatFixed2(detail.amount)}';
    return '$quantityPart；$amountPart';
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

  void _applyHyperlinkStyles(
    excel.Excel workbook,
    Map<String, String> courseDetailSheetNames,
    List<_CourseCostItem> sortedCosts,
  ) {
    final border = excel.Border(
      borderStyle: excel.BorderStyle.Thin,
      borderColorHex: '#FF666666',
    );
    final costLinkStyle = excel.CellStyle(
      fontColorHex: '#FF0563C1',
      underline: excel.Underline.Single,
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    final detailLinkStyle = excel.CellStyle(
      bold: true,
      fontColorHex: '#FF0563C1',
      underline: excel.Underline.Single,
      backgroundColorHex: '#FFF4F8FC',
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
    final titleStyle = excel.CellStyle(
      bold: true,
      fontColorHex: '#FFFFFFFF',
      backgroundColorHex: '#FF1F4E78',
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    final infoLabelStyle = excel.CellStyle(
      bold: true,
      backgroundColorHex: '#FFEAF2F8',
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    final infoValueStyle = excel.CellStyle(
      bold: true,
      backgroundColorHex: '#FFFFFFFF',
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    final noteHeaderStyle = excel.CellStyle(
      bold: true,
      backgroundColorHex: '#FFD9EAF7',
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    final noteStyle = excel.CellStyle(
      backgroundColorHex: '#FFF8FBFE',
      textWrapping: excel.TextWrapping.WrapText,
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    final tableHeaderStyle = excel.CellStyle(
      bold: true,
      fontColorHex: '#FFFFFFFF',
      backgroundColorHex: '#FF4F81BD',
      textWrapping: excel.TextWrapping.WrapText,
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );
    final totalStyle = excel.CellStyle(
      bold: true,
      backgroundColorHex: '#FFFFF2CC',
      leftBorder: border,
      rightBorder: border,
      topBorder: border,
      bottomBorder: border,
    );

    final costSheet = workbook.tables['成本计算'];
    if (costSheet != null) {
      for (var i = 0; i < sortedCosts.length; i++) {
        final cell = costSheet.cell(
          excel.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: i + 1),
        );
        cell.cellStyle = costLinkStyle;
      }
    }

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

    for (final entry in courseDetailSheetNames.entries) {
      final sheetName = entry.value;
      final ds = workbook.tables[sheetName];
      if (ds == null) {
        continue;
      }
      final costItem = sortedCosts.firstWhere(
        (c) => '${c.grade}_${c.courseName}' == entry.key,
      );
      const noteCount = 4;
      const titleRow = 1;
      const infoStartRow = 2;
      const summarySingleRow = 6;
      const noteHeaderRow = 8;
      const noteStartRow = 9;
      const tableHeaderRow = 14;
      const dataStartRow = 15;
      final totalRow = dataStartRow + costItem.materialDetails.length;

      ds.merge(
        excel.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
        excel.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 0),
        customValue: '← 返回成本计算',
      );
      ds.merge(
        excel.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: titleRow),
        excel.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: titleRow),
        customValue: '课程成本审核清单',
      );
      for (final rowIndex in [
        infoStartRow,
        infoStartRow + 1,
        infoStartRow + 2,
        infoStartRow + 3,
      ]) {
        ds.merge(
          excel.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowIndex),
          excel.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: rowIndex),
        );
        ds.merge(
          excel.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: rowIndex),
          excel.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: rowIndex),
        );
      }
      ds.merge(
        excel.CellIndex.indexByColumnRow(
          columnIndex: 0,
          rowIndex: summarySingleRow,
        ),
        excel.CellIndex.indexByColumnRow(
          columnIndex: 3,
          rowIndex: summarySingleRow,
        ),
      );
      ds.merge(
        excel.CellIndex.indexByColumnRow(
          columnIndex: 4,
          rowIndex: summarySingleRow,
        ),
        excel.CellIndex.indexByColumnRow(
          columnIndex: 7,
          rowIndex: summarySingleRow,
        ),
      );
      ds.merge(
        excel.CellIndex.indexByColumnRow(
          columnIndex: 0,
          rowIndex: noteHeaderRow,
        ),
        excel.CellIndex.indexByColumnRow(
          columnIndex: 7,
          rowIndex: noteHeaderRow,
        ),
        customValue: '成本计算口径',
      );
      for (
        var rowIndex = noteStartRow;
        rowIndex < noteStartRow + noteCount;
        rowIndex++
      ) {
        ds.merge(
          excel.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIndex),
          excel.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: rowIndex),
        );
      }
      ds.merge(
        excel.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: totalRow),
        excel.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: totalRow),
      );

      setRowStyle(ds, 0, 8, normalStyle);
      setStyle(ds, 0, 0, detailLinkStyle);
      setStyle(ds, 0, titleRow, titleStyle);
      for (final rowIndex in [
        infoStartRow,
        infoStartRow + 1,
        infoStartRow + 2,
        infoStartRow + 3,
      ]) {
        setStyle(ds, 0, rowIndex, infoLabelStyle);
        setStyle(ds, 1, rowIndex, infoValueStyle);
        setStyle(ds, 3, rowIndex, infoLabelStyle);
        setStyle(ds, 4, rowIndex, infoValueStyle);
      }
      setStyle(ds, 0, summarySingleRow, infoLabelStyle);
      setStyle(ds, 4, summarySingleRow, infoValueStyle);
      setRowStyle(ds, 7, 8, normalStyle);
      setStyle(ds, 0, noteHeaderRow, noteHeaderStyle);
      for (
        var rowIndex = noteStartRow;
        rowIndex < noteStartRow + noteCount;
        rowIndex++
      ) {
        setStyle(ds, 0, rowIndex, noteStyle);
      }
      setRowStyle(ds, 13, 8, normalStyle);
      setRowStyle(ds, tableHeaderRow, 8, tableHeaderStyle);
      for (var rowIndex = dataStartRow; rowIndex < totalRow; rowIndex++) {
        setRowStyle(ds, rowIndex, 8, normalStyle);
      }
      setRowStyle(ds, totalRow, 8, totalStyle);

      ds.setColWidth(0, 12.0);
      ds.setColWidth(1, 28.0);
      ds.setColWidth(2, 10.0);
      ds.setColWidth(3, 12.0);
      ds.setColWidth(4, 14.0);
      ds.setColWidth(5, 12.0);
      ds.setColWidth(6, 14.0);
      ds.setColWidth(7, 52.0);
    }
  }

  void _beautifyWorkbook(excel.Excel workbook, {Set<String>? skipSheets}) {
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
      textWrapping: excel.TextWrapping.WrapText,
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
      if (skipSheets != null && skipSheets.contains(sheetName)) {
        _autoFitSheetColumns(sheet);
        continue;
      }
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
    final remainingInventoryColumns = <int>{};
    final zeroUnitPriceColumns = <int>{};
    for (var col = 0; col < sheet.maxCols; col++) {
      final headerCell = sheet.cell(
        excel.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0),
      );
      final headerText = _valueText(headerCell.value);
      if (sheetName == '材料单价' &&
          (headerText == '材料单价' ||
              headerText == '材料总数' ||
              headerText == '总价')) {
        highlightColumns.add(col);
      }
      if (sheetName != '材料单价' &&
          (headerText.contains('出库数量') || headerText == '材料总数')) {
        highlightColumns.add(col);
      }
      if (sheetName == '材料单价' && headerText == '材料单价') {
        zeroUnitPriceColumns.add(col);
      }
      if (headerText == '出库后库存数量') {
        remainingInventoryColumns.add(col);
      }
    }
    final nonPositiveInventoryStyle = excel.CellStyle(
      fontColorHex: '#FF8B0000',
      backgroundColorHex: '#FFFDE9D9',
      bold: true,
      leftBorder: normalStyle.leftBorder,
      rightBorder: normalStyle.rightBorder,
      topBorder: normalStyle.topBorder,
      bottomBorder: normalStyle.bottomBorder,
    );
    final zeroUnitPriceStyle = excel.CellStyle(
      backgroundColorHex: '#FFF4CCCC',
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
        if (remainingInventoryColumns.contains(col)) {
          final numericValue = num.tryParse(_valueText(cell.value));
          if (numericValue != null && numericValue <= 0) {
            cell.cellStyle = nonPositiveInventoryStyle;
            continue;
          }
        }
        if (zeroUnitPriceColumns.contains(col)) {
          final numericValue = num.tryParse(_valueText(cell.value));
          if (numericValue != null && numericValue == 0) {
            cell.cellStyle = zeroUnitPriceStyle;
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

  List<int> _injectHyperlinks(
    List<int> xlsxBytes,
    Map<String, String> courseDetailSheetNames,
    List<_CourseCostItem> sortedCosts,
  ) {
    try {
      final archive = ZipDecoder().decodeBytes(xlsxBytes);
      // 1. 解析 workbook.xml 获取 sheetName → rId
      final sheetRIds = <String, String>{};
      final sheetFileMap =
          <String, String>{}; // sheetName → xl/worksheets/sheetN.xml
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

      _appendDebug('超链接: sheetRIds=$sheetRIds');
      _appendDebug('超链接: sheetFileMap=$sheetFileMap');

      // 2. 找到成本计算sheet文件
      final costSheetFile = sheetFileMap['成本计算'];
      if (costSheetFile == null) {
        _appendDebug('超链接: 未找到成本计算sheet，跳过');
        return xlsxBytes;
      }

      // 3. 准备超链接数据
      final costHyperlinks = <Map<String, String>>[];
      for (var i = 0; i < sortedCosts.length; i++) {
        final costItem = sortedCosts[i];
        final courseKey = '${costItem.grade}_${costItem.courseName}';
        final detailSheetName = courseDetailSheetNames[courseKey];
        if (detailSheetName == null) continue;
        costHyperlinks.add({
          'ref': 'C${i + 2}',
          'location': "'$detailSheetName'!A1",
        });
      }

      final detailHyperlinks = <String, List<Map<String, String>>>{};
      for (final sheetName in courseDetailSheetNames.values) {
        detailHyperlinks[sheetName] = [
          {'ref': 'A1', 'location': "'成本计算'!A1"},
        ];
      }

      _appendDebug(
        '超链接: costHyperlinks=${costHyperlinks.length}条, detailSheets=${detailHyperlinks.length}个',
      );

      // 4. 构建新archive，注入内部超链接（仅用location属性，不需要rels）
      final newArchive = Archive();

      for (final file in archive.files) {
        if (!file.isFile) {
          newArchive.addFile(file);
          continue;
        }

        var content = file.content as List<int>;
        final name = file.name;
        var modified = false;

        // 成本计算sheet注入超链接
        if (name == costSheetFile) {
          final xml = utf8.decode(content);
          final updated = _injectHyperlinksIntoSheet(xml, costHyperlinks);
          content = utf8.encode(updated);
          modified = true;
          _appendDebug('超链接: 注入成本计算sheet $name');
        }

        // 详情sheet注入超链接
        for (final entry in detailHyperlinks.entries) {
          final detailFile = sheetFileMap[entry.key];
          if (detailFile != null && name == detailFile) {
            final xml = utf8.decode(content);
            final updated = _injectHyperlinksIntoSheet(xml, entry.value);
            content = utf8.encode(updated);
            modified = true;
            _appendDebug('超链接: 注入详情sheet $name');
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
        _appendDebug('超链接: ZipEncoder返回null');
        return xlsxBytes;
      }
      _appendDebug('超链接: 编码完成, ${result.length}字节');
      return result;
    } catch (e) {
      _appendDebug('超链接注入失败: $e');
      return xlsxBytes;
    }
  }

  String _injectHyperlinksIntoSheet(
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

  Future<void> _loadHistoryRecords() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_historyPrefsKey);
      debugPrint('加载历史记录: key=$_historyPrefsKey, 数据长度=${jsonStr?.length ?? 0}');
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final List<dynamic> jsonList = jsonDecode(jsonStr);
        debugPrint('解析到 ${jsonList.length} 条历史记录');
        _historyRecords.clear();
        for (final json in jsonList) {
          _historyRecords.add(_ExportHistoryItem.fromJson(json));
        }
        _historyRecords.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        if (mounted) {
          setState(() {});
        }
      }
    } catch (e) {
      debugPrint('加载历史记录失败: $e');
    }
  }

  Future<void> _saveHistoryRecords() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _historyRecords.map((item) => item.toJson()).toList();
      final jsonStr = jsonEncode(jsonList);
      await prefs.setString(_historyPrefsKey, jsonStr);
      debugPrint(
        '保存历史记录成功: ${_historyRecords.length} 条, 数据长度=${jsonStr.length}',
      );
    } catch (e) {
      debugPrint('保存历史记录失败: $e');
    }
  }

  void _addHistoryRecord(_ExportHistoryItem item) {
    _historyRecords.add(item);
    _historyRecords.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (_historyRecords.length > 3) {
      _historyRecords.removeRange(3, _historyRecords.length);
    }
    _saveHistoryRecords();
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

  Map<String, dynamic> toJson() {
    return {
      'createdAt': createdAt.toIso8601String(),
      'filePath': filePath,
      'fileName': fileName,
      'sourceFileName': sourceFileName,
      'peopleCounts': peopleCounts,
    };
  }

  factory _ExportHistoryItem.fromJson(Map<String, dynamic> json) {
    final peopleCountsMap = <String, Map<String, int>>{};
    final rawPeopleCounts = json['peopleCounts'] as Map<String, dynamic>;
    for (final entry in rawPeopleCounts.entries) {
      final gradeMap = <String, int>{};
      final rawGradeMap = entry.value as Map<String, dynamic>;
      for (final gradeEntry in rawGradeMap.entries) {
        gradeMap[gradeEntry.key] = gradeEntry.value as int;
      }
      peopleCountsMap[entry.key] = gradeMap;
    }

    return _ExportHistoryItem(
      createdAt: DateTime.parse(json['createdAt'] as String),
      filePath: json['filePath'] as String,
      fileName: json['fileName'] as String,
      sourceFileName: json['sourceFileName'] as String,
      peopleCounts: peopleCountsMap,
    );
  }
}

class _AggregateResult {
  const _AggregateResult({
    required this.aggregate,
    required this.sourceRows,
    required this.materialPriceRows,
    required this.grades,
    required this.courseCosts,
  });

  final Map<String, Map<_MaterialKey, _AggregateItem>> aggregate;
  final List<List<dynamic>> sourceRows;
  final List<List<dynamic>> materialPriceRows;
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
    required this.minimumQuantity,
    required this.role,
    required this.outboundCategory,
    required this.basisQuantity,
    required this.multiplierValue,
  });

  final String materialName;
  double unitPrice; // 材料单价
  double quantity; // 使用数量
  double minimumQuantity; // 最小口径数量
  final String role; // 学生/老师
  final String outboundCategory; // 按人/按组
  final double basisQuantity; // 按人时为每人数量，按组时为每组数量
  final double multiplierValue; // 按人时为人数，按组时为组数

  double get amount => quantity * unitPrice;
}

// 课程成本汇总项：记录每个年级-课程组合的成本信息
class _CourseCostItem {
  _CourseCostItem({required this.grade, required this.courseName});

  final String grade;
  final String courseName;
  double teacherCost = 0; // 老师材料总价
  double studentCost = 0; // 学生材料总价
  double teacherMinimumCost = 0; // 老师材料最小值
  final List<_CourseMaterialDetail> materialDetails = []; // 材料明细列表
}
