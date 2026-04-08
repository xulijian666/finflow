import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart' as excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/record_database.dart';
import '../data/transaction_record.dart';

class ProjectMaterialRelationPage extends StatefulWidget {
  const ProjectMaterialRelationPage({super.key});

  @override
  State<ProjectMaterialRelationPage> createState() =>
      _ProjectMaterialRelationPageState();
}

class _ProjectMaterialRelationPageState extends State<ProjectMaterialRelationPage> {
  static const List<_SearchOption> _searchOptions = [
    _SearchOption(key: 'all', label: '全部'),
    _SearchOption(key: 'project', label: '项目'),
    _SearchOption(key: 'grade', label: '年级'),
    _SearchOption(key: 'course', label: '课程'),
    _SearchOption(key: 'material', label: '材料'),
  ];

  List<ProjectMaterialRelation> _rows = [];
  bool _loading = true;
  bool _importing = false;
  bool _exporting = false;
  String _keyword = '';
  String _searchField = 'all';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadRows(showLoading: true);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadRows({required bool showLoading}) async {
    if (showLoading) {
      setState(() {
        _loading = true;
      });
    }
    try {
      final list = await RecordDatabase.instance.fetchProjectMaterialRelations(
        keyword: _keyword,
        searchField: _searchField,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _rows = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
      });
      _showMessage('加载失败，请重试');
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      _keyword = value.trim();
    });
    _loadRows(showLoading: false);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _keyword = '';
    });
    _loadRows(showLoading: false);
  }

  Future<void> _importRows() async {
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
      final parsed = _parseRows(bytes);
      if (parsed.isEmpty) {
        _showMessage('未识别到可导入的数据');
        return;
      }
      final materialNames = parsed.map((e) => e.materialName).toSet();
      final baseMaterials = await RecordDatabase.instance.fetchBaseMaterials();
      final baseNameSet = baseMaterials.map((e) => e.name.trim()).toSet();
      final missing = materialNames
          .where((name) => !baseNameSet.contains(name))
          .toList()
        ..sort();
      if (missing.isNotEmpty) {
        final details = missing.take(20).join('、');
        final suffix = missing.length > 20 ? ' 等${missing.length}项' : '';
        _showMessage('导入失败，以下材料不存在：$details$suffix');
        return;
      }
      await RecordDatabase.instance.importProjectMaterialRelationsByProject(
        parsed,
      );
      if (!mounted) {
        return;
      }
      _showMessage('导入成功，共 ${parsed.length} 条');
      _loadRows(showLoading: false);
    } catch (error) {
      debugPrint('项目材料关系导入失败: $error');
      _showMessage('导入失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
        });
      }
    }
  }

  Future<void> _exportRows() async {
    if (_exporting) {
      return;
    }
    setState(() {
      _exporting = true;
    });
    try {
      final list = await RecordDatabase.instance.fetchProjectMaterialRelations();
      if (list.isEmpty) {
        _showMessage('暂无可导出数据');
        return;
      }
      final filePath = await _saveAsXlsx(list);
      final shared = await _shareExportFile(filePath);
      if (!mounted) {
        return;
      }
      _showMessage(shared ? '已导出并唤起分享' : '已导出到 $filePath');
    } catch (error) {
      debugPrint('项目材料关系导出失败: $error');
      _showMessage('导出失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
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

  List<ProjectMaterialRelation> _parseRows(Uint8List bytes) {
    final workbook = excel.Excel.decodeBytes(bytes);
    excel.Sheet? sheet = workbook.tables['Sheet1'];
    sheet ??= workbook.tables.isEmpty ? null : workbook.tables.values.first;
    if (sheet == null) {
      return [];
    }
    final rows = sheet.rows;
    if (rows.isEmpty) {
      return [];
    }
    final header = rows.first.map(_cellText).toList();
    var projectIndex = header.indexOf('项目名称');
    var gradeIndex = header.indexOf('年级名称');
    var courseIndex = header.indexOf('课程名称');
    var materialIndex = header.indexOf('基础材料名称');
    var startIndex = 0;
    if (projectIndex != -1 &&
        gradeIndex != -1 &&
        courseIndex != -1 &&
        materialIndex != -1) {
      startIndex = 1;
    } else {
      projectIndex = 0;
      gradeIndex = 1;
      courseIndex = 2;
      materialIndex = 3;
    }
    final list = <ProjectMaterialRelation>[];
    final unique = <String>{};
    for (var i = startIndex; i < rows.length; i++) {
      final row = rows[i];
      final project = _cellText(_cellAt(row, projectIndex)).trim();
      final grade = _cellText(_cellAt(row, gradeIndex)).trim();
      final course = _cellText(_cellAt(row, courseIndex)).trim();
      final material = _cellText(_cellAt(row, materialIndex)).trim();
      if (project.isEmpty || grade.isEmpty || course.isEmpty || material.isEmpty) {
        continue;
      }
      final key = '$project|$grade|$course|$material';
      if (unique.contains(key)) {
        continue;
      }
      unique.add(key);
      list.add(
        ProjectMaterialRelation(
          projectName: project,
          gradeName: grade,
          courseName: course,
          materialName: material,
        ),
      );
    }
    return list;
  }

  String _cellText(excel.Data? cell) {
    final value = cell?.value;
    return value == null ? '' : value.toString().trim();
  }

  excel.Data? _cellAt(List<excel.Data?> row, int index) {
    if (index < 0 || index >= row.length) {
      return null;
    }
    return row[index];
  }

  Future<String> _saveAsXlsx(List<ProjectMaterialRelation> list) async {
    final workbook = excel.Excel.createExcel();
    final sheet = workbook['Sheet1'];
    sheet.appendRow(['项目名称', '年级名称', '课程名称', '基础材料名称']);
    for (final row in list) {
      sheet.appendRow([
        row.projectName,
        row.gradeName,
        row.courseName,
        row.materialName,
      ]);
    }
    final directory = await _exportDirectory();
    final fileName = '项目材料关系_${_formatDateTime(DateTime.now())}.xlsx';
    final exportFile = File(p.join(directory.path, fileName));
    final bytes = workbook.save();
    if (bytes == null) {
      throw Exception('导出失败');
    }
    await exportFile.writeAsBytes(bytes, flush: true);
    return exportFile.path;
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
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('项目材料关系维护'),
        actions: [
          IconButton(
            onPressed: _importing ? null : _importRows,
            icon: const Icon(Icons.upload_file_outlined),
            tooltip: '导入 xlsx',
          ),
          IconButton(
            onPressed: _exporting ? null : _exportRows,
            icon: const Icon(Icons.ios_share_outlined),
            tooltip: '导出 xlsx',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                SizedBox(
                  width: 112,
                  child: DropdownButtonFormField<String>(
                    initialValue: _searchField,
                    items: _searchOptions
                        .map(
                          (e) => DropdownMenuItem<String>(
                            value: e.key,
                            child: Text(e.label),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _searchField = value;
                      });
                      _loadRows(showLoading: false);
                    },
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: '搜索项目/年级/课程/材料',
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
                ),
              ],
            ),
            const SizedBox(height: 16),
            _ProjectMaterialHeader(colorScheme: colorScheme),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _rows.isEmpty
                  ? _ProjectMaterialEmptyState(keyword: _keyword)
                  : ListView.separated(
                      itemCount: _rows.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        return _ProjectMaterialRow(
                          index: index + 1,
                          row: _rows[index],
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

class _SearchOption {
  const _SearchOption({required this.key, required this.label});

  final String key;
  final String label;
}

class _ProjectMaterialHeader extends StatelessWidget {
  const _ProjectMaterialHeader({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        children: [
          SizedBox(width: 36, child: Text('序号')),
          Expanded(flex: 2, child: Text('项目')),
          Expanded(flex: 2, child: Text('年级')),
          Expanded(flex: 2, child: Text('课程')),
          Expanded(flex: 2, child: Text('材料')),
        ],
      ),
    );
  }
}

class _ProjectMaterialRow extends StatelessWidget {
  const _ProjectMaterialRow({required this.index, required this.row});

  final int index;
  final ProjectMaterialRelation row;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          SizedBox(width: 36, child: Text('$index')),
          Expanded(flex: 2, child: Text(row.projectName, overflow: TextOverflow.ellipsis)),
          Expanded(flex: 2, child: Text(row.gradeName, overflow: TextOverflow.ellipsis)),
          Expanded(flex: 2, child: Text(row.courseName, overflow: TextOverflow.ellipsis)),
          Expanded(flex: 2, child: Text(row.materialName, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

class _ProjectMaterialEmptyState extends StatelessWidget {
  const _ProjectMaterialEmptyState({required this.keyword});

  final String keyword;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        keyword.isEmpty ? '暂无数据，请先导入 xlsx' : '暂无匹配数据',
      ),
    );
  }
}
