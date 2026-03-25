import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/record_database.dart';
import '../data/transaction_record.dart';

// 打开记账表单底部弹窗
Future<bool?> showRecordFormSheet(
  BuildContext context, {
  required int billId,
  required int defaultAccountId,
  TransactionRecord? record,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (bottomSheetContext) {
      return RecordFormSheet(
        billId: billId,
        defaultAccountId: defaultAccountId,
        record: record,
      );
    },
  );
}

// 记账录入表单
class RecordFormSheet extends StatefulWidget {
  const RecordFormSheet({
    super.key,
    required this.billId,
    required this.defaultAccountId,
    this.record,
  });

  final TransactionRecord? record;
  final int billId;
  final int defaultAccountId;

  @override
  State<RecordFormSheet> createState() => _RecordFormSheetState();
}

class _RecordFormSheetState extends State<RecordFormSheet> {
  // 记账类型与金额输入状态
  static const String _prefKeyLongcatApiKey = 'longcat_api_key';
  static const String _defaultLongcatApiKey =
      'ak_1DQ2Mp2d77AD7nr5H840Y4xT2VD5D';
  late String _type;
  late String _amountText;
  late String _leftValue;
  String _rightValue = '';
  String? _operator;
  // 基础信息与账户选择
  late DateTime _date;
  String? _category;
  List<Account> _accounts = [];
  bool _loadingAccounts = true;
  int? _accountId;
  late TextEditingController _noteController;
  late TextEditingController _materialNameController;
  late TextEditingController _materialQuantityController;
  bool _smartAccounting = true;
  bool _saving = false;
  static const String _materialNoteSplitter = '｜';

  // 支出分类
  static const List<_CategoryItem> _expenseCategories = [
    _CategoryItem('课程材料', Icons.menu_book_rounded),
    _CategoryItem('劳务费', Icons.engineering_rounded),
    _CategoryItem('餐饮费', Icons.restaurant_rounded),
    _CategoryItem('快递费', Icons.local_shipping_rounded),
    _CategoryItem('办公费', Icons.article_rounded),
    _CategoryItem('其他', Icons.grid_view_rounded),
  ];

  // 收入分类
  static const List<_CategoryItem> _incomeCategories = [
    _CategoryItem('备用金', Icons.account_balance_wallet_rounded),
    _CategoryItem('退款', Icons.keyboard_return_rounded),
    _CategoryItem('其他', Icons.grid_view_rounded),
  ];

  @override
  void initState() {
    super.initState();
    // 初始化表单默认值
    final record = widget.record;
    _type = record?.type ?? 'expense';
    _leftValue = record == null ? '0' : _formatAmountInput(record.amount);
    _rightValue = '';
    _operator = null;
    _amountText = _leftValue;
    _date = record?.date ?? DateTime.now();
    _category =
        record?.category ??
        (_type == 'expense'
            ? _expenseCategories.first.name
            : _incomeCategories.first.name);
    _accountId = record?.accountId ?? widget.defaultAccountId;
    final noteText = record?.note ?? '';
    final materialNote = _splitMaterialNote(noteText);
    final initialQuantity = record?.quantity;
    final quantityText = initialQuantity == null
        ? (materialNote['quantity'] ?? '')
        : _formatAmountInput(initialQuantity);
    _noteController = TextEditingController(
      text: _category == '课程材料' ? (materialNote['name'] ?? '') : noteText,
    );
    _materialNameController = TextEditingController(
      text: materialNote['name'] ?? '',
    );
    _materialQuantityController = TextEditingController(text: quantityText);
    _loadAccounts();
  }

  @override
  void dispose() {
    _noteController.dispose();
    _materialNameController.dispose();
    _materialQuantityController.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    // 加载账户列表并修正默认账户
    setState(() {
      _loadingAccounts = true;
    });
    try {
      final accounts = await RecordDatabase.instance.fetchAccounts();
      final currentId = _accountId;
      var nextId = currentId;
      if (nextId == null || !accounts.any((item) => item.id == nextId)) {
        final defaultAccount = accounts.isEmpty
            ? null
            : accounts.firstWhere(
                (item) => item.isDefault,
                orElse: () => accounts.first,
              );
        nextId = defaultAccount?.id ?? widget.defaultAccountId;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _accounts = accounts;
        _accountId = nextId;
        _loadingAccounts = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingAccounts = false;
      });
      _showMessage('账户加载失败，请重试');
    }
  }

  String _formatAmountInput(double amount) {
    // 金额显示去除无意义的 0
    final rounded = amount.toStringAsFixed(2);
    if (rounded.endsWith('.00')) {
      return rounded.substring(0, rounded.length - 3);
    }
    if (rounded.endsWith('0')) {
      return rounded.substring(0, rounded.length - 1);
    }
    return rounded;
  }

  Map<String, String> _splitMaterialNote(String note) {
    final trimmed = note.trim();
    if (trimmed.isEmpty) {
      return {'name': '', 'quantity': ''};
    }
    final index = trimmed.indexOf(_materialNoteSplitter);
    if (index == -1) {
      return {'name': trimmed, 'quantity': ''};
    }
    final name = trimmed.substring(0, index).trim();
    final quantity = trimmed
        .substring(index + _materialNoteSplitter.length)
        .trim();
    return {'name': name, 'quantity': quantity};
  }

  String _buildMaterialNote(String name, String quantity) {
    final trimmedName = name.trim();
    final trimmedQuantity = quantity.trim();
    if (trimmedQuantity.isEmpty) {
      return trimmedName;
    }
    return '$trimmedName$_materialNoteSplitter$trimmedQuantity';
  }

  bool get _isMaterialCategory => _category == '课程材料';

  void _handleKey(String value) {
    // 键盘输入统一入口
    setState(() {
      if (value == '⌫') {
        _handleBackspace();
        _amountText = _buildDisplayText();
        return;
      }

      if (value == '+' || value == '-') {
        _handleOperator(value);
        _amountText = _buildDisplayText();
        return;
      }

      if (value == '.') {
        _handleDecimal();
        _amountText = _buildDisplayText();
        return;
      }

      _handleDigit(value);
      _amountText = _buildDisplayText();
    });
  }

  void _handleBackspace() {
    // 处理退格键
    if (_operator == null) {
      _leftValue = _removeLastChar(_leftValue);
    } else if (_rightValue.isNotEmpty) {
      _rightValue = _removeLastChar(_rightValue);
    } else {
      _operator = null;
    }
    if (_leftValue.isEmpty) {
      _leftValue = '0';
    }
  }

  void _handleOperator(String operator) {
    // 处理加减运算符
    if (_operator == null) {
      _operator = operator;
      return;
    }
    final result = _computeResult();
    _leftValue = _formatAmountInput(result);
    _rightValue = '';
    _operator = operator;
  }

  void _handleDecimal() {
    // 处理小数点
    if (_operator == null) {
      if (_leftValue.contains('.')) {
        return;
      }
      _leftValue = _leftValue.isEmpty ? '0.' : '$_leftValue.';
    } else {
      if (_rightValue.contains('.')) {
        return;
      }
      _rightValue = _rightValue.isEmpty ? '0.' : '$_rightValue.';
    }
  }

  void _handleDigit(String digit) {
    // 处理数字输入
    if (_operator == null) {
      _leftValue = _appendDigit(_leftValue, digit);
    } else {
      _rightValue = _appendDigit(_rightValue, digit);
    }
  }

  String _appendDigit(String current, String digit) {
    // 控制最大位数与小数位数
    final next = current == '0' ? digit : '$current$digit';
    if (next.contains('.')) {
      final parts = next.split('.');
      if (parts.length > 1 && parts[1].length > 2) {
        return current;
      }
    }
    if (next.length > 12) {
      return current;
    }
    return next;
  }

  String _removeLastChar(String value) {
    // 删除末尾字符并处理小数点
    if (value.isEmpty || value.length == 1) {
      return '';
    }
    final shortened = value.substring(0, value.length - 1);
    if (shortened.endsWith('.')) {
      return shortened.substring(0, shortened.length - 1);
    }
    return shortened;
  }

  String _buildDisplayText() {
    // 构建金额显示文本
    if (_operator == null) {
      return _leftValue;
    }
    if (_rightValue.isEmpty) {
      return '$_leftValue$_operator';
    }
    return '$_leftValue$_operator$_rightValue';
  }

  double _computeResult() {
    // 计算表达式结果
    final left = double.tryParse(_leftValue) ?? 0;
    final right = _rightValue.isEmpty ? 0 : double.tryParse(_rightValue) ?? 0;
    if (_operator == '+') {
      return left + right;
    }
    if (_operator == '-') {
      return left - right;
    }
    return left;
  }

  double _currentAmount() {
    // 获取当前应保存的金额
    if (_operator == null) {
      return double.tryParse(_leftValue) ?? 0;
    }
    return _computeResult();
  }

  Future<void> _pickDate() async {
    // 选择日期
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _date = DateTime(picked.year, picked.month, picked.day);
    });
  }

  Future<String?> _resolveMaterialName(String inputName) async {
    final materials = await RecordDatabase.instance.fetchBaseMaterials();
    final names = materials.map((item) => item.name).toList();
    if (_smartAccounting) {
      final candidates = await _fetchSmartCandidates(inputName, names);
      if (candidates.isEmpty) {
        _showMessage('未找到相似材料，请确认是否新增');
        final created = await _confirmCreateMaterial(inputName);
        return created ? inputName : null;
      }
      final result = await _showMaterialOptions(
        '智能记账推荐',
        candidates,
        inputName: inputName,
      );
      if (result == inputName) {
        final created = await _confirmCreateMaterial(inputName);
        return created ? inputName : null;
      }
      return result;
    }
    final candidates = _localMatchCandidates(inputName, names).take(3).toList();
    if (candidates.isEmpty) {
      _showMessage('未找到相似材料，请确认是否新增');
      final created = await _confirmCreateMaterial(inputName);
      return created ? inputName : null;
    }
    final result = await _showMaterialOptions(
      '相似材料选择',
      candidates,
      inputName: inputName,
    );
    if (result == inputName) {
      final created = await _confirmCreateMaterial(inputName);
      return created ? inputName : null;
    }
    return result;
  }

  Future<List<String>> _fetchSmartCandidates(
    String inputName,
    List<String> baseNames,
  ) async {
    final apiKeyFromDefine = const String.fromEnvironment('LONGCAT_API_KEY');
    final storedKey = await _loadLongcatApiKey();
    final apiKey = apiKeyFromDefine.isNotEmpty
        ? apiKeyFromDefine
        : (Platform.environment['LONGCAT_API_KEY'] ??
              (storedKey.isNotEmpty ? storedKey : _defaultLongcatApiKey));
    if (apiKey.trim().isEmpty) {
      _showMessage('未配置智能记账密钥，已使用本地匹配');
      return _localMatchCandidates(inputName, baseNames).take(3).toList();
    }
    final prompt =
        '''
你是材料匹配助手，请从材料列表中找出与用户备注最相近的材料名称。
要求：
1. 仅返回 JSON 数组，数组元素为材料名称字符串。
2. 只能从材料列表中选择，不可编造。
3. 返回数量最多 5 个。
材料列表：${baseNames.join('、')}
用户备注：$inputName
''';
    final payload = {
      'model': 'LongCat-Flash-Chat',
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
      'temperature': 0.2,
      'stream': false,
    };

    // 打印发送给大模型的请求 payload
    debugPrint('--- AI Request Payload ---');
    debugPrint(jsonEncode(payload));

    final client = HttpClient();
    try {
      final uri = Uri.parse(
        'https://api.longcat.chat/openai/v1/chat/completions',
      );
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', 'Bearer $apiKey');
      request.add(utf8.encode(jsonEncode(payload)));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      // 打印大模型的原始返回结果
      debugPrint('--- AI Response Body ---');
      debugPrint(body);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _localMatchCandidates(inputName, baseNames).take(3).toList();
      }
      final data = jsonDecode(body);
      String? content;
      if (data is Map<String, dynamic>) {
        final choices = data['choices'];
        if (choices is List && choices.isNotEmpty) {
          final first = choices.first;
          if (first is Map<String, dynamic>) {
            final message = first['message'];
            if (message is Map<String, dynamic>) {
              final value = message['content'];
              if (value is String) {
                content = value;
              }
            }
          }
        }
      }
      if (content == null) {
        return _localMatchCandidates(inputName, baseNames).take(3).toList();
      }
      final extracted = _extractJsonArray(content);
      if (extracted == null) {
        return _localMatchCandidates(inputName, baseNames).take(3).toList();
      }
      final rawList = jsonDecode(extracted);
      if (rawList is! List) {
        return _localMatchCandidates(inputName, baseNames).take(3).toList();
      }
      final baseLower = baseNames.map((e) => e.toLowerCase()).toSet();
      final options = <String>[];
      for (final item in rawList) {
        if (item is! String) {
          continue;
        }
        final trimmed = item.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        if (!baseLower.contains(trimmed.toLowerCase())) {
          continue;
        }
        if (!options.contains(trimmed)) {
          options.add(trimmed);
        }
        if (options.length >= 5) {
          break;
        }
      }
      return options;
    } catch (_) {
      return _localMatchCandidates(inputName, baseNames).take(3).toList();
    } finally {
      client.close();
    }
  }

  String? _extractJsonArray(String content) {
    final trimmed = content.trim();
    final start = trimmed.indexOf('[');
    final end = trimmed.lastIndexOf(']');
    if (start == -1 || end == -1 || end <= start) {
      return null;
    }
    return trimmed.substring(start, end + 1);
  }

  Future<String> _loadLongcatApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_prefKeyLongcatApiKey)?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  List<String> _localMatchCandidates(String inputName, List<String> baseNames) {
    final keyword = inputName.trim().toLowerCase();
    if (keyword.isEmpty) {
      return [];
    }
    final scored = <Map<String, Object>>[];
    for (final name in baseNames) {
      final lower = name.toLowerCase();
      var score = 0;
      if (lower == keyword) {
        score += 1000;
      }
      if (lower.contains(keyword)) {
        score += 500;
      }
      if (keyword.contains(lower)) {
        score += 300;
      }
      var common = 0;
      for (final char in keyword.split('')) {
        if (lower.contains(char)) {
          common += 1;
        }
      }
      score += common;
      if (score > 0) {
        scored.add({'name': name, 'score': score});
      }
    }
    scored.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
    return scored.map((item) => item['name'] as String).toList();
  }

  Future<String?> _showMaterialOptions(
    String title,
    List<String> options, {
    String? inputName,
  }) {
    if (options.isEmpty) {
      return Future.value(null);
    }
    return showDialog<String>(
      context: context,
      builder: (context) {
        String? selected = options.first;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: options.map((item) {
                    return RadioListTile<String>(
                      title: Text(item),
                      value: item,
                      groupValue: selected,
                      onChanged: (value) {
                        setState(() {
                          selected = value;
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              actions: [
                if (inputName != null)
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(inputName),
                    child: const Text('直接新增'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(selected),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<bool> _confirmCreateMaterial(String name) async {
    final unitController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('新增基础材料'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(alignment: Alignment.centerLeft, child: Text('材料名称：$name')),
              const SizedBox(height: 12),
              TextField(
                controller: unitController,
                decoration: const InputDecoration(
                  hintText: '请输入单位',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final unit = unitController.text.trim();
                if (unit.isEmpty) {
                  _showMessage('请输入单位');
                  return;
                }
                Navigator.of(context).pop(unit);
              },
              child: const Text('新增'),
            ),
          ],
        );
      },
    );
    final unit = result?.trim();
    if (unit == null || unit.isEmpty) {
      return false;
    }
    try {
      await RecordDatabase.instance.insertBaseMaterial(
        BaseMaterial(name: name, unit: unit),
      );
      _showMessage('已新增基础材料');
      return true;
    } catch (_) {
      _showMessage('新增失败，请重试');
      return false;
    }
  }

  Future<void> _save({required bool keepOpen}) async {
    // 保存记账记录
    if (_saving) {
      return;
    }
    final amount = _currentAmount();
    if (amount <= 0) {
      _showMessage('请输入有效金额');
      return;
    }
    if (_category == null || _category!.isEmpty) {
      _showMessage('请选择分类');
      return;
    }
    if (_accountId == null) {
      _showMessage('请选择账户');
      return;
    }
    setState(() {
      _saving = true;
    });
    try {
      String? note;
      double? quantity;
      String? invMaterialName;
      double? invQuantity;
      String? invUnit;

      if (_isMaterialCategory) {
        final materialName = _materialNameController.text.trim();
        final quantityText = _materialQuantityController.text.trim();
        if (materialName.isEmpty) {
          _showMessage('请输入材料名称');
          setState(() {
            _saving = false;
          });
          return;
        }
        if (quantityText.isEmpty) {
          _showMessage('请输入数量');
          setState(() {
            _saving = false;
          });
          return;
        }
        final qtyValue = double.tryParse(quantityText);
        if (qtyValue == null || qtyValue <= 0) {
          _showMessage('数量必须大于0');
          setState(() {
            _saving = false;
          });
          return;
        }
        final matched = await RecordDatabase.instance.fetchBaseMaterialByName(
          materialName,
        );
        var finalName = materialName;
        if (matched == null) {
          final resolved = await _resolveMaterialName(materialName);
          if (resolved == null || resolved.trim().isEmpty) {
            setState(() {
              _saving = false;
            });
            return;
          }
          finalName = resolved.trim();
          _materialNameController.text = finalName;
        }

        // 获取单位
        final baseMat = await RecordDatabase.instance.fetchBaseMaterialByName(
          finalName,
        );
        if (baseMat != null) {
          invUnit = baseMat.unit;
        }

        invMaterialName = finalName;
        invQuantity = qtyValue;
        quantity = qtyValue;
        note = _buildMaterialNote(finalName, quantityText);
      } else {
        final rawNote = _noteController.text.trim();
        final rawQuantity = _materialQuantityController.text.trim();
        if (rawQuantity.isNotEmpty) {
          final qtyValue = double.tryParse(rawQuantity);
          if (qtyValue == null || qtyValue <= 0) {
            _showMessage('数量必须大于0');
            setState(() {
              _saving = false;
            });
            return;
          }
          quantity = qtyValue;
        }
        note = rawNote.isEmpty ? null : rawNote;
      }
      final record = TransactionRecord(
        id: widget.record?.id,
        billId: widget.record?.billId ?? widget.billId,
        accountId: _accountId!,
        type: _type,
        amount: amount,
        category: _category!,
        date: _date,
        note: note,
        quantity: quantity,
      );

      int recordId;
      if (widget.record == null) {
        recordId = await RecordDatabase.instance.insertRecord(record);
      } else {
        await RecordDatabase.instance.updateRecord(record);
        recordId = widget.record!.id!;
        // 更新时先清理旧的库存记录
        await RecordDatabase.instance.deleteInventoryByRecordId(recordId);
      }

      // 写入库存记录
      if (invMaterialName != null && invQuantity != null) {
        await RecordDatabase.instance.insertInventoryRecord(
          materialName: invMaterialName,
          quantity: invQuantity,
          unit: invUnit,
          recordId: recordId,
        );
      }

      if (!mounted) {
        return;
      }
      if (keepOpen) {
        _showTopToast('保存成功');
        setState(() {
          _leftValue = '0';
          _rightValue = '';
          _operator = null;
          _amountText = _leftValue;
          _noteController.clear();
          _materialNameController.clear();
          _materialQuantityController.clear();
          _saving = false;
        });
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      debugPrint('保存失败，错误：$error');
      _showMessage('保存失败，请重试');
      setState(() {
        _saving = false;
      });
    }
  }

  void _showMessage(String message) {
    // 统一提示入口
    _showTopToast(message);
  }

  void _showTopToast(String message) {
    // 顶部浮层提示
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      return;
    }
    final entry = OverlayEntry(
      builder: (context) {
        return Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: SafeArea(
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF2B2B2B),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 2), () {
      entry.remove();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 构建表单界面
    final categories = _type == 'expense'
        ? _expenseCategories
        : _incomeCategories;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Container(
        padding: EdgeInsets.only(bottom: bottom),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'expense', label: Text('支出')),
                          ButtonSegment(value: 'income', label: Text('收入')),
                        ],
                        selected: {_type},
                        onSelectionChanged: (value) {
                          setState(() {
                            final previousCategory = _category;
                            _type = value.first;
                            _category = _type == 'expense'
                                ? _expenseCategories.first.name
                                : _incomeCategories.first.name;
                            if (_category == '课程材料' &&
                                _materialNameController.text.trim().isEmpty) {
                              _materialNameController.text = _noteController
                                  .text
                                  .trim();
                            } else if (previousCategory == '课程材料' &&
                                _category != '课程材料' &&
                                _noteController.text.trim().isEmpty) {
                              _noteController.text = _materialNameController
                                  .text
                                  .trim();
                            }
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildAccountSection(),
                const SizedBox(height: 16),
                Text('分类', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: categories.map((item) {
                    final selected = item.name == _category;
                    return ChoiceChip(
                      label: Text(item.name),
                      avatar: Icon(
                        item.icon,
                        size: 18,
                        color: selected ? null : const Color(0xFF666666),
                      ),
                      selected: selected,
                      onSelected: (_) {
                        setState(() {
                          final previousCategory = _category;
                          _category = item.name;
                          if (_category == '课程材料' &&
                              _materialNameController.text.trim().isEmpty) {
                            _materialNameController.text = _noteController.text
                                .trim();
                          } else if (previousCategory == '课程材料' &&
                              _category != '课程材料' &&
                              _noteController.text.trim().isEmpty) {
                            _noteController.text = _materialNameController.text
                                .trim();
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text('日期', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    TextButton(
                      onPressed: _pickDate,
                      child: Text(_formatDate(_date)),
                    ),
                  ],
                ),
                if (_isMaterialCategory) ...[
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _materialNameController,
                          decoration: const InputDecoration(
                            hintText: '备注',
                            border: OutlineInputBorder(),
                            counterText: '',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _materialQuantityController,
                          decoration: const InputDecoration(
                            hintText: '数量',
                            border: OutlineInputBorder(),
                            counterText: '',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Checkbox(
                        value: _smartAccounting,
                        onChanged: (value) {
                          setState(() {
                            _smartAccounting = value ?? true;
                          });
                        },
                      ),
                      const Text('智能记账'),
                    ],
                  ),
                ] else ...[
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _noteController,
                          decoration: const InputDecoration(
                            hintText: '备注',
                            border: OutlineInputBorder(),
                            counterText: '',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _materialQuantityController,
                          decoration: const InputDecoration(
                            hintText: '数量',
                            border: OutlineInputBorder(),
                            counterText: '',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  _amountText,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _NumberPad(
                  onKeyPressed: _handleKey,
                  onSave: () => _save(keepOpen: false),
                  onSaveAndContinue: () => _save(keepOpen: true),
                  saving: _saving,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAccountSection() {
    // 账户选择区域
    if (_loadingAccounts) {
      return Row(
        children: [
          Text('账户', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 12),
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('账户', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _accounts.map((account) {
            final selected = account.id == _accountId;
            return ChoiceChip(
              label: Text(account.name),
              selected: selected,
              onSelected: (_) {
                setState(() {
                  _accountId = account.id;
                });
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    // 日期格式化
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}

class _NumberPad extends StatelessWidget {
  // 数字键盘组件
  const _NumberPad({
    required this.onKeyPressed,
    required this.onSave,
    required this.onSaveAndContinue,
    required this.saving,
  });

  final ValueChanged<String> onKeyPressed;
  final VoidCallback onSave;
  final VoidCallback onSaveAndContinue;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    // 构建四行数字键盘
    final disabled = saving;
    return Column(
      children: [
        _PadRow(
          children: [
            _PadButton(label: '1', onTap: () => onKeyPressed('1')),
            _PadButton(label: '2', onTap: () => onKeyPressed('2')),
            _PadButton(label: '3', onTap: () => onKeyPressed('3')),
            _PadButton(
              icon: Icons.backspace_outlined,
              onTap: () => onKeyPressed('⌫'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _PadRow(
          children: [
            _PadButton(label: '4', onTap: () => onKeyPressed('4')),
            _PadButton(label: '5', onTap: () => onKeyPressed('5')),
            _PadButton(label: '6', onTap: () => onKeyPressed('6')),
            _PadButton(label: '-', onTap: () => onKeyPressed('-')),
          ],
        ),
        const SizedBox(height: 8),
        _PadRow(
          children: [
            _PadButton(label: '7', onTap: () => onKeyPressed('7')),
            _PadButton(label: '8', onTap: () => onKeyPressed('8')),
            _PadButton(label: '9', onTap: () => onKeyPressed('9')),
            _PadButton(label: '+', onTap: () => onKeyPressed('+')),
          ],
        ),
        const SizedBox(height: 8),
        _PadRow(
          children: [
            _PadButton(label: '再记', onTap: disabled ? null : onSaveAndContinue),
            _PadButton(label: '0', onTap: () => onKeyPressed('0')),
            _PadButton(label: '.', onTap: () => onKeyPressed('.')),
            _PadButton(
              label: disabled ? '保存中' : '保存',
              backgroundColor: const Color(0xFFE35D5D),
              textColor: Colors.white,
              onTap: disabled ? null : onSave,
            ),
          ],
        ),
      ],
    );
  }
}

class _CategoryItem {
  final String name;
  final IconData icon;

  const _CategoryItem(this.name, this.icon);
}

class _PadRow extends StatelessWidget {
  // 数字键盘行布局
  const _PadRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: children[0]),
        const SizedBox(width: 8),
        Expanded(child: children[1]),
        const SizedBox(width: 8),
        Expanded(child: children[2]),
        const SizedBox(width: 8),
        Expanded(child: children[3]),
      ],
    );
  }
}

class _PadButton extends StatelessWidget {
  // 数字键盘按钮
  const _PadButton({
    this.label,
    this.icon,
    required this.onTap,
    this.backgroundColor,
    this.textColor,
  });

  final String? label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? backgroundColor;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    // 构建按钮样式
    final color = backgroundColor ?? const Color(0xFFF1F1F1);
    final contentColor = textColor ?? const Color(0xFF1F1F1F);
    final child = icon != null
        ? Icon(icon, color: contentColor)
        : Text(
            label ?? '',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: contentColor,
            ),
          );
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(height: 52, child: Center(child: child)),
      ),
    );
  }
}
