import 'package:flutter/material.dart';

import '../data/record_database.dart';
import '../data/transaction_record.dart';

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
  late String _type;
  late String _amountText;
  late String _leftValue;
  String _rightValue = '';
  String? _operator;
  late DateTime _date;
  String? _category;
  List<Account> _accounts = [];
  bool _loadingAccounts = true;
  int? _accountId;
  late TextEditingController _noteController;
  bool _saving = false;

  static const List<String> _expenseCategories = [
    '课程材料',
    '人员劳务',
    '餐饮与水',
    '物流快递',
    '活动差旅',
    '其他',
  ];

  static const List<String> _incomeCategories = [
    '备用金',
    '退款',
    '其他',
  ];

  @override
  void initState() {
    super.initState();
    final record = widget.record;
    _type = record?.type ?? 'expense';
    _leftValue = record == null ? '0' : _formatAmountInput(record.amount);
    _rightValue = '';
    _operator = null;
    _amountText = _leftValue;
    _date = record?.date ?? DateTime.now();
    _category = record?.category ??
        (_type == 'expense'
            ? _expenseCategories.first
            : _incomeCategories.first);
    _accountId = record?.accountId ?? widget.defaultAccountId;
    _noteController = TextEditingController(text: record?.note ?? '');
    _loadAccounts();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
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
    final rounded = amount.toStringAsFixed(2);
    if (rounded.endsWith('.00')) {
      return rounded.substring(0, rounded.length - 3);
    }
    if (rounded.endsWith('0')) {
      return rounded.substring(0, rounded.length - 1);
    }
    return rounded;
  }

  void _handleKey(String value) {
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
    if (_operator == null) {
      _leftValue = _appendDigit(_leftValue, digit);
    } else {
      _rightValue = _appendDigit(_rightValue, digit);
    }
  }

  String _appendDigit(String current, String digit) {
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
    if (_operator == null) {
      return _leftValue;
    }
    if (_rightValue.isEmpty) {
      return '$_leftValue$_operator';
    }
    return '$_leftValue$_operator$_rightValue';
  }

  double _computeResult() {
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
    if (_operator == null) {
      return double.tryParse(_leftValue) ?? 0;
    }
    return _computeResult();
  }

  Future<void> _pickDate() async {
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

  Future<void> _save({required bool keepOpen}) async {
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
      final record = TransactionRecord(
        id: widget.record?.id,
        billId: widget.record?.billId ?? widget.billId,
        accountId: _accountId!,
        type: _type,
        amount: amount,
        category: _category!,
        date: _date,
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
      );
      if (widget.record == null) {
        await RecordDatabase.instance.insertRecord(record);
      } else {
        await RecordDatabase.instance.updateRecord(record);
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
    _showTopToast(message);
  }

  void _showTopToast(String message) {
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
    final categories =
        _type == 'expense' ? _expenseCategories : _incomeCategories;
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
                          ButtonSegment(
                            value: 'expense',
                            label: Text('支出'),
                          ),
                          ButtonSegment(
                            value: 'income',
                            label: Text('收入'),
                          ),
                        ],
                        selected: {_type},
                        onSelectionChanged: (value) {
                          setState(() {
                            _type = value.first;
                            _category = _type == 'expense'
                                ? _expenseCategories.first
                                : _incomeCategories.first;
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
                Text(
                  '分类',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: categories.map((item) {
                    final selected = item == _category;
                    return ChoiceChip(
                      label: Text(item),
                      selected: selected,
                      onSelected: (_) {
                        setState(() {
                          _category = item;
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      '日期',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _pickDate,
                      child: Text(_formatDate(_date)),
                    ),
                  ],
                ),
                TextField(
                  controller: _noteController,
                  decoration: const InputDecoration(
                    hintText: '',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                ),
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
    if (_loadingAccounts) {
      return Row(
        children: [
          Text(
            '账户',
            style: Theme.of(context).textTheme.titleMedium,
          ),
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
        Text(
          '账户',
          style: Theme.of(context).textTheme.titleMedium,
        ),
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
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}

class _NumberPad extends StatelessWidget {
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
            _PadButton(
              label: '再记',
              onTap: disabled ? null : onSaveAndContinue,
            ),
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

class _PadRow extends StatelessWidget {
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
        child: SizedBox(
          height: 52,
          child: Center(child: child),
        ),
      ),
    );
  }
}
