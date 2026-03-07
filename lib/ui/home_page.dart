import 'dart:io';
import 'package:excel/excel.dart' as excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/record_database.dart';
import '../data/transaction_record.dart';
import 'extension_menu.dart';
import 'record_form_sheet.dart';

// 首页：记账列表、管理入口与导入导出
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  // 持久化键值
  static const String _prefKeyBillId = 'selected_bill_id';
  static const String _prefKeyAccountId = 'selected_account_id';
  static const String _prefKeyLongcatApiKey = 'longcat_api_key';
  static const String _defaultLongcatApiKey = 'ak_1DQ2Mp2d77AD7nr5H840Y4xT2VD5D';

  // 列表数据与账户余额
  List<TransactionRecord> _records = [];
  List<Bill> _bills = [];
  List<Account> _accounts = [];
  Map<int, double> _accountBalances = {};
  // 列表加载状态
  bool _loading = true;
  bool _loadingError = false;
  bool _loadingBills = true;
  bool _loadingAccounts = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  // 搜索与分页缓存
  String _keyword = '';
  final List<String> _loadedDateKeys = [];
  Map<String, String> _baseMaterials = {}; // 基础材料缓存 (name -> unit)
  static const String _materialNoteSplitter = '｜';

  // 当前选择状态
  int? _currentBillId;
  int? _defaultAccountId;
  int? _currentAccountId;
  int? _editingBillId;
  int? _editingAccountId;
  String _longcatApiKey = _defaultLongcatApiKey;
  // UI 控制器
  late TabController _tabController;
  int _currentTabIndex = 0;
  final ScrollController _recordScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  bool _showFab = true;
  OverlayEntry? _exitToastEntry;
  DateTime? _lastPressedAt;

  @override
  void initState() {
    super.initState();
    final _ = _openImportDialog;
    // 初始化双 Tab 控制器
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_currentTabIndex != _tabController.index) {
        setState(() {
          _currentTabIndex = _tabController.index;
        });
      }
    });
    _recordScrollController.addListener(_handleScroll);
    // 初始化默认账本与账户
    _initDefaults();
  }

  // 启动时确保默认账本与账户可用，并恢复上次选择
  Future<void> _initDefaults() async {
    try {
      await RecordDatabase.instance.ensureDefaultBillAndAccount();
      await _loadPreferences();
    } catch (error) {
      debugPrint('初始化默认账本与账户失败：$error');
    }
    if (!mounted) {
      return;
    }
    _loadBills();
    _loadAccounts();
    _loadBaseMaterials();
  }

  // 加载基础材料列表
  Future<void> _loadBaseMaterials() async {
    try {
      final materials = await RecordDatabase.instance.fetchBaseMaterials();
      if (!mounted) return;
      setState(() {
        _baseMaterials = {for (var e in materials) e.name: e.unit};
      });
    } catch (e) {
      debugPrint('加载基础材料失败: $e');
    }
  }

  Future<void> _loadRecords() async {
    final billId = _currentBillId;
    if (billId == null) {
      return;
    }
    // 重置加载状态
    setState(() {
      _loading = true;
      _loadingError = false;
      _loadingMore = false;
      _hasMore = true;
      _loadedDateKeys.clear();
    });
    try {
      final keyword = _keyword.trim();
      // 搜索模式直接查询全部匹配记录
      if (keyword.isNotEmpty) {
        final records = await RecordDatabase.instance.fetchRecordsByKeyword(
          billId: billId,
          keyword: keyword,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _records = records;
          _hasMore = false;
          _loading = false;
        });
        return;
      }
      await _loadRecentDays(limit: 3, append: false);
      if (!mounted) {
        return;
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadingError = true;
      });
    }
  }

  Future<void> _loadRecentDays({
    required int limit,
    required bool append,
  }) async {
    final billId = _currentBillId;
    if (billId == null) {
      return;
    }
    // 分批获取最近有记录的日期
    final beforeDate =
        append && _loadedDateKeys.isNotEmpty ? _loadedDateKeys.last : null;
    final dates = await RecordDatabase.instance.fetchRecentRecordDates(
      billId: billId,
      beforeDate: beforeDate,
      limit: limit,
    );
    if (!mounted) {
      return;
    }
    if (dates.isEmpty) {
      setState(() {
        if (!append) {
          _records = [];
        }
        _hasMore = false;
        _loading = false;
        _loadingMore = false;
      });
      return;
    }
    final records = await RecordDatabase.instance.fetchRecordsByDates(
      billId: billId,
      dateKeys: dates,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      if (append) {
        _records = [..._records, ...records];
      } else {
        _records = records;
      }
      _loadedDateKeys.addAll(dates);
      _hasMore = dates.length == limit;
      _loading = false;
      _loadingMore = false;
    });
  }

  void _handleScroll() {
    // 根据滚动方向显示/隐藏底部按钮
    if (_recordScrollController.position.userScrollDirection ==
        ScrollDirection.reverse) {
      if (_showFab) {
        setState(() {
          _showFab = false;
        });
      }
    } else if (_recordScrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      if (!_showFab) {
        setState(() {
          _showFab = true;
        });
      }
    }

    if (_loadingMore || _loading || !_hasMore) {
      return;
    }
    if (_keyword.trim().isNotEmpty) {
      return;
    }
    // 接近底部时加载更多
    final position = _recordScrollController.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  // 加载更多日期分组
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) {
      return;
    }
    setState(() {
      _loadingMore = true;
    });
    try {
      await _loadRecentDays(limit: 2, append: true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingMore = false;
      });
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      _keyword = value;
    });
    // 搜索变化后重新加载数据
    _loadRecords();
  }

  // 清空搜索并恢复列表
  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _keyword = '';
    });
    _loadRecords();
  }

  Future<void> _loadBills() async {
    // 切换账本列表时刷新选择状态
    setState(() {
      _loadingBills = true;
    });
    try {
      final bills = await RecordDatabase.instance.fetchBills();
      final fallbackId = RecordDatabase.instance.defaultBillId;
      final currentId = _currentBillId ?? fallbackId;
      final currentExists = bills.any((bill) => bill.id == currentId);
      final defaultBill = bills.isEmpty
          ? null
          : bills.firstWhere(
              (bill) => bill.isDefault,
              orElse: () => bills.first,
            );
      final nextBillId =
          currentExists ? currentId : defaultBill?.id ?? fallbackId;
      if (!mounted) {
        return;
      }
      if (_currentBillId != nextBillId) {
        _saveSelectedBill(nextBillId);
      }
      setState(() {
        _bills = bills;
        _currentBillId = nextBillId;
        _loadingBills = false;
        _editingBillId = null;
      });
      _loadRecords();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingBills = false;
      });
      _showMessage('账本加载失败，请重试');
    }
  }

  // 加载账户与余额信息
  Future<void> _loadAccounts() async {
    setState(() {
      _loadingAccounts = true;
    });
    try {
      final accounts = await RecordDatabase.instance.fetchAccounts();
      final balances = await RecordDatabase.instance.fetchAccountBalances();
      final fallbackId = RecordDatabase.instance.defaultAccountId;
      final currentId = _currentAccountId;
      final currentExists = accounts.any((account) => account.id == currentId);
      if (!mounted) {
        return;
      }
      final nextAccountId = currentExists ? currentId : fallbackId;
      if (_currentAccountId != nextAccountId && nextAccountId != null) {
        _saveSelectedAccount(nextAccountId);
      }
      setState(() {
        _accounts = accounts;
        _accountBalances = balances;
        _defaultAccountId = fallbackId;
        _currentAccountId = nextAccountId;
        _loadingAccounts = false;
        _editingAccountId = null;
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

  // 打开记账表单
  Future<void> _openForm({TransactionRecord? record}) async {
    await showRecordFormSheet(
      context,
      billId: record?.billId ??
          _currentBillId ??
          RecordDatabase.instance.defaultBillId,
      defaultAccountId: record?.accountId ??
          _currentAccountId ??
          _defaultAccountId ??
          RecordDatabase.instance.defaultAccountId,
      record: record,
    );
    _loadRecords();
    _loadAccounts();
    _loadBaseMaterials();
  }

  Future<void> _deleteRecord(TransactionRecord record) async {
    try {
      await RecordDatabase.instance.deleteRecord(record.id!);
      if (!mounted) {
        return;
      }
      // 删除后刷新记录与余额
      _loadRecords();
      _loadAccounts();
      _showMessage('已删除');
    } catch (error) {
      _showMessage('删除失败，请重试');
    }
  }

  // 删除前二次确认
  Future<bool> _confirmDelete(TransactionRecord record) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除账本'),
          content: Text('确定删除 ${record.category} 这条记录吗？'),
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

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // 切换当前账本并刷新记录
  Future<void> _selectBill(Bill bill) async {
    if (_currentBillId == bill.id) {
      return;
    }
    setState(() {
      _currentBillId = bill.id;
    });
    if (bill.id != null) {
      _saveSelectedBill(bill.id!);
    }
    _loadRecords();
  }

  Future<void> _showBillSelectionDialog() async {
    // 底部弹窗选择账本
    final selected = await showModalBottomSheet<Bill>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '切换账本',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _bills.length,
                itemBuilder: (context, index) {
                  final bill = _bills[index];
                  final isSelected = bill.id == _currentBillId;
                  return ListTile(
                    leading: Icon(
                      Icons.book,
                      color: isSelected ? Theme.of(context).primaryColor : null,
                    ),
                    title: Text(
                      bill.name,
                      style: TextStyle(
                        color: isSelected ? Theme.of(context).primaryColor : null,
                        fontWeight: isSelected ? FontWeight.bold : null,
                      ),
                    ),
                    trailing: isSelected ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.of(context).pop(bill),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
    if (selected != null) {
      _selectBill(selected);
    }
  }

  Future<void> _createBill() async {
    // 新增账本对话框
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('新增账本'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '请输入账本名称',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                controller.text.trim(),
              ),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    final name = result?.trim();
    if (name == null || name.isEmpty) {
      return;
    }
    try {
      final newId = await RecordDatabase.instance.insertBill(name);
      if (!mounted) {
        return;
      }
      setState(() {
        _currentBillId = newId;
      });
      _saveSelectedBill(newId);
      _loadBills();
      _showMessage('账本已新增');
    } catch (error) {
      _showMessage('新增失败，请重试');
    }
  }

  Future<void> _editBill(Bill bill) async {
    // 修改账本名称
    final billId = bill.id;
    if (billId == null) {
      return;
    }
    final controller = TextEditingController(text: bill.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('修改账本'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '请输入账本名称',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                controller.text.trim(),
              ),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    final name = result?.trim();
    if (name == null || name.isEmpty || name == bill.name) {
      return;
    }
    try {
      await RecordDatabase.instance.updateBillName(billId, name);
      if (!mounted) {
        return;
      }
      _loadBills();
      _showMessage('账本已修改');
    } catch (error) {
      _showMessage('修改失败，请重试');
    }
  }

  Future<void> _confirmDeleteBill(Bill bill) async {
    // 删除账本时提示记录数量
    final billId = bill.id;
    if (billId == null || billId == RecordDatabase.instance.defaultBillId) {
      return;
    }
    int recordCount = 0;
    try {
      recordCount = await RecordDatabase.instance.countRecordsByBill(billId);
    } catch (error) {
      _showMessage('获取记录失败，请重试');
      return;
    }
    if (!mounted) {
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除账本'),
          content: Text(
            recordCount == 0
                ? '确定删除 ${bill.name} 吗？'
                : '账本下还有 $recordCount 条记录，是否删除或迁移到默认账本？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop('cancel'),
              child: const Text('取消'),
            ),
            if (recordCount > 0)
              TextButton(
                onPressed: () => Navigator.of(context).pop('migrate'),
                child: const Text('迁移到默认账本'),
              ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop('delete'),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (action == null || action == 'cancel') {
      return;
    }
    if (!mounted) {
      return;
    }
    if (action == 'delete' && recordCount > 0) {
      final controller = TextEditingController();
      final confirmText = await showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('确认删除'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '请输入“确认删除”',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(
                  controller.text.trim(),
                ),
                child: const Text('删除'),
              ),
            ],
          );
        },
      );
      if (!mounted) {
        return;
      }
      if (confirmText != '确认删除') {
        if (confirmText != null && confirmText.isNotEmpty) {
          _showMessage('请输入确认删除');
        }
        return;
      }
    }
    try {
      if (action == 'migrate') {
        await RecordDatabase.instance.migrateBillRecordsToDefault(billId);
        await RecordDatabase.instance.deleteBill(billId);
      } else if (recordCount > 0) {
        await RecordDatabase.instance.deleteBillWithRecords(billId);
      } else {
        await RecordDatabase.instance.deleteBill(billId);
      }
      if (!mounted) {
        return;
      }
      if (_currentBillId == billId) {
        _currentBillId = RecordDatabase.instance.defaultBillId;
        _saveSelectedBill(RecordDatabase.instance.defaultBillId);
      }
      _loadBills();
      _showMessage('账本已删除');
    } catch (error) {
      _showMessage('删除失败，请重试');
    }
  }

  Future<void> _createAccount() async {
    // 新增账户对话框
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('新增账户'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '请输入账户名称',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                controller.text.trim(),
              ),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    final name = result?.trim();
    if (name == null || name.isEmpty) {
      return;
    }
    try {
      await RecordDatabase.instance.insertAccount(name);
      if (!mounted) {
        return;
      }
      _loadAccounts();
      _showMessage('账户已新增');
    } catch (error) {
      _showMessage('新增失败，请重试');
    }
  }

  Future<void> _editAccount(Account account) async {
    // 修改账户名称
    final accountId = account.id;
    if (accountId == null) {
      return;
    }
    final controller = TextEditingController(text: account.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('修改账户'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '请输入账户名称',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                controller.text.trim(),
              ),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    final name = result?.trim();
    if (name == null || name.isEmpty || name == account.name) {
      return;
    }
    try {
      await RecordDatabase.instance.updateAccountName(accountId, name);
      if (!mounted) {
        return;
      }
      _loadAccounts();
      _showMessage('账户已修改');
    } catch (error) {
      _showMessage('修改失败，请重试');
    }
  }

  Future<void> _selectAccount(Account account) async {
    // 切换当前账户，仅影响筛选与记账默认值
    if (account.id == null || account.id == _currentAccountId) {
      return;
    }
    setState(() {
      _currentAccountId = account.id;
    });
    _saveSelectedAccount(account.id!);
  }

  Future<void> _confirmDeleteAccount(Account account) async {
    // 删除账户并清理记录
    if (account.id == _defaultAccountId) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除账户'),
          content: Text('确定删除 ${account.name} 吗？'),
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
    if (confirmed != true) {
      return;
    }
    try {
      await RecordDatabase.instance.deleteAccount(account.id!);
      if (!mounted) {
        return;
      }
      _loadAccounts();
      _showMessage('账户已删除');
    } catch (error) {
      _showMessage('删除失败，请重试');
    }
  }

  String _currentBillName() {
    // 当前账本显示名称
    final id = _currentBillId;
    for (final bill in _bills) {
      if (bill.id == id) {
        return bill.name;
      }
    }
    return '默认账本';
  }

  Future<void> _loadPreferences() async {
    // 从本地偏好恢复选择状态
    try {
      final prefs = await SharedPreferences.getInstance();
      final billId = prefs.getInt(_prefKeyBillId);
      final accountId = prefs.getInt(_prefKeyAccountId);
      final apiKey = prefs.getString(_prefKeyLongcatApiKey);
      if (mounted) {
        setState(() {
          if (billId != null) _currentBillId = billId;
          if (accountId != null) _currentAccountId = accountId;
          if (apiKey != null && apiKey.trim().isNotEmpty) {
            _longcatApiKey = apiKey.trim();
          } else {
            _longcatApiKey = _defaultLongcatApiKey;
          }
        });
      }
    } catch (e) {
      debugPrint('加载偏好设置失败: $e');
    }
  }

  Future<void> _saveSelectedBill(int id) async {
    // 持久化账本选择
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefKeyBillId, id);
    } catch (e) {
      debugPrint('保存账本选择失败: $e');
    }
  }

  Future<void> _saveSelectedAccount(int id) async {
    // 持久化账户选择
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefKeyAccountId, id);
    } catch (e) {
      debugPrint('保存账户选择失败: $e');
    }
  }

  Future<void> _saveLongcatApiKey(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyLongcatApiKey, value);
    } catch (e) {
      debugPrint('保存模型密钥失败: $e');
    }
  }

  String _maskApiKey(String value) {
    final trimmed = value.trim();
    if (trimmed.length <= 8) {
      return '已配置';
    }
    final prefix = trimmed.substring(0, 4);
    final suffix = trimmed.substring(trimmed.length - 4);
    return '$prefix****$suffix';
  }

  Future<void> _editLongcatApiKey() async {
    final controller = TextEditingController(text: _longcatApiKey);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('配置 LongCat AK'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: '请输入 LongCat AK',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    final trimmed = result?.trim();
    if (trimmed == null) {
      return;
    }
    final nextValue =
        trimmed.isEmpty ? _defaultLongcatApiKey : trimmed;
    setState(() {
      _longcatApiKey = nextValue;
    });
    await _saveLongcatApiKey(nextValue);
    _showMessage('已保存');
  }

  @override
  void dispose() {
    _exitToastEntry?.remove();
    _exitToastEntry = null;
    _tabController.dispose();
    _recordScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _showExitToast() {
    if (_exitToastEntry != null) {
      return;
    }
    final entry = OverlayEntry(
      builder: (context) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '再按一次退出',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(entry);
    _exitToastEntry = entry;
    Future.delayed(const Duration(seconds: 3), () {
      if (_exitToastEntry == entry) {
        _exitToastEntry?.remove();
        _exitToastEntry = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 主界面结构
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastPressedAt == null ||
            now.difference(_lastPressedAt!) > const Duration(seconds: 3)) {
          _lastPressedAt = now;
          _showExitToast();
        } else {
          await SystemNavigator.pop();
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('记账'),
            const SizedBox(width: 12),
            InkWell(
              onTap: _showBillSelectionDialog,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _currentBillName(),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSecondaryContainer,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '记账'),
            Tab(text: '管理'),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const ExtensionMenuPage(),
                ),
              ).then((_) => _loadBaseMaterials());
            },
            icon: const Icon(Icons.apps),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    hintText: '搜索备注或分类',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _keyword.trim().isEmpty
                        ? null
                        : IconButton(
                            onPressed: _clearSearch,
                            icon: const Icon(Icons.close),
                          ),
                    filled: true,
                    fillColor: const Color(0xFFF5F7F7),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _loadRecords,
                  child: ListView(
                    controller: _recordScrollController,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
                    children: [
                      if (_loading)
                        const Center(child: CircularProgressIndicator())
                      else if (_loadingError)
                        _EmptyState(
                          message: '加载失败，请下拉重试',
                          onRetry: _loadRecords,
                        )
                      else if (_records.isEmpty)
                        _EmptyState(
                          message: '暂无记录，点 + 记一笔',
                          onRetry: _loadRecords,
                        )
                      else
                        ..._buildGroupedRecords(),
                      if (_loadingMore)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          _buildManagementTab(),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _currentTabIndex == 0
          ? AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: _showFab ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_showFab,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      FloatingActionButton(
                        heroTag: 'scrollToTop',
                        onPressed: () {
                          _recordScrollController.animateTo(
                            0,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                          );
                        },
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        child: const Icon(Icons.arrow_upward),
                      ),
                      const Spacer(),
                      FloatingActionButton.extended(
                        heroTag: 'addRecord',
                        onPressed: () => _openForm(),
                        label: const Text('记一笔'),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : null,
      ),
    );
  }

  Widget _buildManagementTab() {
    // 管理页：账本、账户、备份恢复、导入导出与格式化
    if (_loadingBills || _loadingAccounts) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '账本管理',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: _createBill,
              icon: const Icon(Icons.add),
              label: const Text('新增'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_bills.isEmpty)
          _EmptyState(
            message: '暂无账本',
            onRetry: _loadBills,
          )
        else
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: List.generate(_bills.length, (index) {
                final bill = _bills[index];
                final isSelected = bill.id == _currentBillId;
                final isEditing = bill.id == _editingBillId;
                return InkWell(
                  onTap: isEditing ? null : () => _selectBill(bill),
                  onLongPress: () {
                    setState(() {
                      _editingBillId = bill.id;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      border: index == _bills.length - 1
                          ? null
                          : const Border(
                              bottom: BorderSide(color: Color(0xFFE6E6E6)),
                            ),
                    ),
                    child: Row(
                      children: isEditing
                          ? [
                              Expanded(
                                child: FilledButton(
                                  onPressed: () {
                                    setState(() {
                                      _editingBillId = null;
                                    });
                                    _editBill(bill);
                                  },
                                  child: const Text('修改'),
                                ),
                              ),
                              if (!bill.isDefault) ...[
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () {
                                      setState(() {
                                        _editingBillId = null;
                                      });
                                      _confirmDeleteBill(bill);
                                    },
                                    child: const Text('删除'),
                                  ),
                                ),
                              ],
                            ]
                          : [
                              Icon(
                                isSelected
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                                color: isSelected
                                    ? const Color(0xFF1B7F5A)
                                    : Colors.black54,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(bill.name),
                                    if (bill.isDefault)
                                      Text(
                                        '默认账本',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium
                                            ?.copyWith(color: Colors.black54),
                                      ),
                                  ],
                                ),
                              ),
                              if (isSelected)
                                const Icon(
                                  Icons.check_circle,
                                  color: Color(0xFF1B7F5A),
                                ),
                            ],
                    ),
                  ),
                );
              }),
            ),
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                '账户管理',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: _createAccount,
              icon: const Icon(Icons.add),
              label: const Text('新增'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_accounts.isEmpty)
          _EmptyState(
            message: '暂无账户',
            onRetry: _loadAccounts,
          )
        else
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: List.generate(_accounts.length, (index) {
                final account = _accounts[index];
                final isDefault = account.id == _defaultAccountId;
                final isSelected = account.id == _currentAccountId;
                final isEditing = account.id == _editingAccountId;
                final balance = _accountBalances[account.id ?? 0] ?? 0;
                return InkWell(
                  onTap: isEditing ? null : () => _selectAccount(account),
                  onLongPress: () {
                    setState(() {
                      _editingAccountId = account.id;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      border: index == _accounts.length - 1
                          ? null
                          : const Border(
                              bottom: BorderSide(color: Color(0xFFE6E6E6)),
                            ),
                    ),
                    child: Row(
                      children: isEditing
                          ? [
                              Expanded(
                                child: FilledButton(
                                  onPressed: () {
                                    setState(() {
                                      _editingAccountId = null;
                                    });
                                    _editAccount(account);
                                  },
                                  child: const Text('修改'),
                                ),
                              ),
                              if (!isDefault) ...[
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () {
                                      setState(() {
                                        _editingAccountId = null;
                                      });
                                      _confirmDeleteAccount(account);
                                    },
                                    child: const Text('删除'),
                                  ),
                                ),
                              ],
                            ]
                          : [
                              Icon(
                                isSelected
                                    ? Icons.check_circle
                                    : Icons.radio_button_off,
                                color: isSelected
                                    ? const Color(0xFF1B7F5A)
                                    : Colors.black54,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(account.name),
                                    if (isDefault)
                                      Text(
                                        '默认账户',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium
                                            ?.copyWith(color: Colors.black54),
                                      ),
                                  ],
                                ),
                              ),
                              Text(
                                _formatPlainAmount(balance),
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: balance >= 0
                                      ? const Color(0xFF1B7F5A)
                                      : const Color(0xFFB5473B),
                                ),
                              ),
                            ],
                    ),
                  ),
                );
              }),
            ),
          ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                '数据备份与恢复',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.backup, color: Color(0xFF1B7F5A)),
                title: const Text('立即备份'),
                subtitle: const Text('创建当前数据的快照'),
                onTap: _backupData,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.restore, color: Color(0xFFB5473B)),
                title: const Text('恢复数据'),
                subtitle: const Text('从快照或外部文件恢复'),
                onTap: _showRestoreDialog,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                '大模型配置',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.smart_toy_outlined),
                title: const Text('LongCat AK'),
                subtitle: Text('当前：${_maskApiKey(_longcatApiKey)}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _editLongcatApiKey,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                '账单数据导出',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: _openExportDialog,
              icon: const Icon(Icons.file_download),
              label: const Text('导出'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '支持按开始日期、结束日期、账本与账户筛选，默认导出全部',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                '危险区域',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: const Color(0xFFB5473B),
                    ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 0,
          color: const Color(0xFFFEECEB),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ListTile(
            leading: const Icon(Icons.delete_forever, color: Color(0xFFB5473B)),
            title: const Text(
              '数据格式化',
              style: TextStyle(color: Color(0xFFB5473B)),
            ),
            subtitle: const Text(
              '清空所有记账数据（自动备份）',
              style: TextStyle(color: Color(0xFFB5473B)),
            ),
            onTap: _showFormatDialog,
          ),
        ),
      ],
    );
  }

  Future<void> _showFormatDialog() async {
    // 数据格式化确认弹窗
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('数据格式化'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '此操作将清空所有记账数据（records表），但会保留账本与账户设置。\n\n'
                '为了安全起见，系统将在清空前自动创建一个备份。\n\n'
                '请输入以下文字确认操作：',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              const SelectableText(
                '我确认要将数据清空',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFB5473B),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: '请输入确认文本',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB5473B),
              ),
              onPressed: () {
                if (controller.text.trim() == '我确认要将数据清空') {
                  Navigator.of(context).pop(true);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('输入文本不匹配')),
                  );
                }
              },
              child: const Text('确认清空'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await _executeFormat();
    }
  }

  Future<void> _executeFormat() async {
    // 执行格式化：备份 + 清空 + 刷新
    // 显示加载对话框
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return const Center(child: CircularProgressIndicator());
      },
    );

    try {
      // 1. 执行自动备份
      final backupPath = await RecordDatabase.instance.backup();
      debugPrint('格式化前自动备份完成：$backupPath');

      // 2. 清空数据
      await RecordDatabase.instance.clearAllRecords();
      debugPrint('数据已清空');

      if (!mounted) return;
      // 关闭加载对话框
      Navigator.of(context).pop();

      // 3. 刷新界面
      _loadRecords();
      _loadAccounts(); // 余额会变动
      
      _showMessage('数据已格式化，自动备份已创建');
    } catch (e) {
      if (!mounted) return;
      // 关闭加载对话框
      Navigator.of(context).pop();
      _showMessage('操作失败: $e');
    }
  }

  Future<void> _backupData() async {
    // 立即创建备份并提示导出
    try {
      final path = await RecordDatabase.instance.backup();
      if (!mounted) {
        return;
      }
      _showMessage('备份成功');
      // 可以在这里询问是否要立即导出到外部
      final shouldExport = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('备份已创建'),
            content: const Text('建议将备份文件导出到微信或云盘，防止卸载丢失。\n是否立即导出？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('稍后'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('立即导出'),
              ),
            ],
          );
        },
      );
      if (shouldExport == true) {
        final xFiles = [XFile(path)];
        await SharePlus.instance.share(
          ShareParams(files: xFiles, text: 'FinFlow 数据备份'),
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showMessage('备份失败: $e');
    }
  }

  Future<void> _showRestoreDialog() async {
    // 从本地快照或外部文件恢复
    final backups = await RecordDatabase.instance.getBackups();
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '恢复数据',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _restoreFromExternalFile();
                        },
                        icon: const Icon(Icons.file_open),
                        label: const Text('从外部文件导入'),
                      ),
                    ],
                  ),
                ),
                if (backups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('暂无本地快照，请先备份或从外部导入'),
                  ),
                if (backups.isNotEmpty)
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: backups.length,
                      itemBuilder: (context, index) {
                        final file = backups[index];
                        final name = p.basename(file.path);
                        // 提取时间戳并格式化
                        String displayTime = name;
                        try {
                          final timestamp = name.split('_')[2].split('.')[0];
                          if (timestamp.length >= 14) {
                             final year = timestamp.substring(0, 4);
                             final month = timestamp.substring(4, 6);
                             final day = timestamp.substring(6, 8);
                             final hour = timestamp.substring(9, 11);
                             final minute = timestamp.substring(11, 13);
                             final second = timestamp.substring(13, 15);
                             displayTime = '$year-$month-$day $hour:$minute:$second';
                          }
                        } catch (_) {}

                        return ListTile(
                          leading: const Icon(Icons.history),
                          title: Text(displayTime),
                          subtitle: Text(
                            '${(file.lengthSync() / 1024).toStringAsFixed(1)} KB',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                               IconButton(
                                icon: const Icon(Icons.share, size: 20),
                                onPressed: () {
                                  SharePlus.instance.share(
                                    ShareParams(files: [XFile(file.path)]),
                                  );
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.restore, color: Color(0xFFB5473B)),
                                onPressed: () {
                                  Navigator.pop(context);
                                  _confirmRestore(file.path);
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      '注意：卸载 App 前请务必执行“导出”，否则数据将丢失！',
                      style: TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 16),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _restoreFromExternalFile() async {
    // 选择外部 .db 文件进行恢复
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        if (!path.endsWith('.db')) {
             _showMessage('请选择正确的 .db 备份文件');
             return;
        }
        await _confirmRestore(path);
      }
    } catch (e) {
      _showMessage('选择文件失败: $e');
    }
  }

  Future<void> _confirmRestore(String path) async {
    // 恢复前确认提示
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('确认恢复？'),
          content: const Text('恢复操作将覆盖当前所有数据，且不可撤销。\n建议恢复前先执行一次备份。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确定恢复'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      try {
        await RecordDatabase.instance.restore(path);
        if (!mounted) return;
        _showMessage('数据恢复成功');
        // 刷新页面数据
        _loadBills();
        _loadAccounts();
        _loadRecords();
      } catch (e) {
        if (!mounted) return;
        _showMessage('恢复失败: $e');
      }
    }
  }

  List<Widget> _buildGroupedRecords() {
    // 按日期分组渲染记账记录
    final widgets = <Widget>[];
    var bucket = <TransactionRecord>[];
    String? currentDate;
    void flush() {
      final date = currentDate;
      if (date == null || bucket.isEmpty) {
        return;
      }
      widgets.add(_buildDateGroup(date, bucket));
      bucket = <TransactionRecord>[];
    }

    for (final record in _records) {
      final dateKey = _formatDate(record.date);
      currentDate ??= dateKey;
      if (dateKey != currentDate) {
        flush();
        currentDate = dateKey;
      }
      bucket.add(record);
    }
    flush();
    return widgets;
  }

  Widget _buildDateGroup(String date, List<TransactionRecord> items) {
    // 日期分组卡片
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    date,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ...items.asMap().entries.map(
                (entry) => _buildRecordItem(
                  entry.value,
                  showDivider: entry.key != items.length - 1,
                ),
              ),
        ],
      ),
    );
  }

  bool _isMaterialInBaseList(TransactionRecord record) {
    if (record.category != '课程材料' || record.note == null) return false;
    final parts = record.note!.split(_materialNoteSplitter);
    final materialName = parts.isNotEmpty ? parts[0].trim() : '';
    return _baseMaterials.containsKey(materialName);
  }

  Widget _buildRecordItem(
    TransactionRecord record, {
    required bool showDivider,
  }) {
    // 单条记录展示
    final isMarked = _isMaterialInBaseList(record);
    return InkWell(
        onTap: () => _openForm(record: record),
        onLongPress: () async {
          final confirmed = await _confirmDelete(record);
          if (confirmed) {
            _deleteRecord(record);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: showDivider
                ? const Border(
                    bottom: BorderSide(color: Color(0xFFE6E6E6)),
                  )
                : null,
          ),
          child: Row(
            children: [
              if (isMarked)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: const Icon(
                    Icons.verified,
                    size: 16,
                    color: Color(0xFF1B7F5A),
                  ),
                ),
              Expanded(
                child: Text(
                  _buildRecordTitle(record),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _formatAmount(record),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: record.type == 'income'
                      ? const Color(0xFF1B7F5A)
                      : const Color(0xFFB5473B),
                ),
              ),
            ],
          ),
        ),
      );
  }

  String _buildRecordTitle(TransactionRecord record) {
    // 标题展示：分类 + 备注前缀
    final note = record.note?.trim();
    if (note == null || note.isEmpty) {
      return record.category;
    }

    // 课程材料特殊处理：如果匹配基础材料，显示单位
    if (record.category == '课程材料') {
      final parts = note.split(_materialNoteSplitter);
      if (parts.isNotEmpty) {
        final name = parts[0].trim();
        // 匹配到基础材料
        if (_baseMaterials.containsKey(name)) {
          final unit = _baseMaterials[name];
          // 如果有数量
          if (parts.length > 1) {
            final quantity = parts[1].trim();
            return '$name · $quantity$unit';
          }
          // 只有名称
          return '$name · $unit';
        }
      }
    }

    final preview = note.length > 6 ? note.substring(0, 6) : note;
    return '${record.category} · $preview';
  }

  String _formatAmount(TransactionRecord record) {
    // 金额显示加正负号
    final amount = record.amount.toStringAsFixed(2);
    final sign = record.type == 'income' ? '+' : '-';
    return '$sign$amount';
  }

  String _formatPlainAmount(double amount) {
    // 余额显示格式化
    return amount.toStringAsFixed(2);
  }

  String _formatDate(DateTime date) {
    // 日期格式化
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  Future<void> _openImportDialog() async {
    // 打开导入对话框
    final defaultBillId = RecordDatabase.instance.defaultBillId;
    final defaultAccountId =
        _defaultAccountId ?? RecordDatabase.instance.defaultAccountId;
    debugPrint('导入对话框打开');
    final result = await showDialog<_ImportSelection>(
      context: context,
      builder: (context) {
        return _ImportDialog(
          bills: _bills,
          accounts: _accounts,
          defaultBillId: defaultBillId,
          defaultAccountId: defaultAccountId,
        );
      },
    );
    if (!mounted) {
      return;
    }
    if (result == null) {
      return;
    }
    try {
      final count = await _importFromXlsx(result);
      if (!mounted) {
        return;
      }
      _loadRecords();
      _loadAccounts();
      _showMessage('已导入 $count 条记录');
    } catch (error, stack) {
      debugPrint('导入流程出现异常：$error');
      debugPrint('异常堆栈：$stack');
      if (!mounted) {
        return;
      }
      _showMessage('导入失败，请重试');
    }
  }

  Future<void> _openExportDialog() async {
    // 打开导出筛选弹窗
    DateTime? start;
    DateTime? end;
    int? billId;
    int? accountId;
    debugPrint('导出对话框打开');
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return _ExportDialog(
          bills: _bills,
          accounts: _accounts,
          onChanged: (s, e, b, a) {
            start = s;
            end = e;
            billId = b;
            accountId = a;
            debugPrint(
                '导出参数已选择 start=$start end=$end billId=$billId accountId=$accountId');
          },
        );
      },
    );
    if (!mounted) {
      return;
    }
    if (result != true) {
      return;
    }
    try {
      debugPrint('开始执行数据导出');
      final rows = await RecordDatabase.instance.fetchExportRows(
        startDate: start,
        endDate: end,
        billId: billId,
        accountId: accountId,
      );
      debugPrint('待导出行数=${rows.length}');
      final filePath = await _saveAsXlsx(rows);
      debugPrint('xlsx 文件已生成：$filePath');
      final shared = await _shareExportFile(filePath);
      debugPrint(shared ? '已尝试分享文件' : '当前平台不进行分享');
      if (!mounted) {
        return;
      }
      _showMessage(shared ? '已导出并唤起分享' : '已导出到 $filePath');
    } catch (error, stack) {
      debugPrint('导出流程出现异常：$error');
      debugPrint('异常堆栈：$stack');
      if (!mounted) {
        return;
      }
      _showMessage('导出失败，请重试');
    }
  }

  Future<String> _saveAsXlsx(List<Map<String, Object?>> rows) async {
    // 将导出数据写入 xlsx 文件
    final headers = [
      '序号',
      '日期',
      '账本名称',
      '账户名称',
      '收支类型',
      '账目金额',
      '账目备注',
      '分类',
      '材料名称',
      '数量',
      '单位',
    ];
    final workbook = excel.Excel.createExcel();
    final sheet = workbook['Sheet1'];
    debugPrint('工作簿与默认 Sheet1 已创建');
    sheet.appendRow(headers);
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final rawDate = r['date'] as String?;
      final parsedDate = rawDate == null ? null : DateTime.tryParse(rawDate);
      final date = parsedDate == null ? (rawDate ?? '') : _formatDate(parsedDate);
      final book = r['book_name'] as String? ?? '默认账本';
      final account = r['account_name'] as String? ?? '默认账户';
      final type = r['type'] as String? ?? '';
      final amount = (r['amount'] as num?)?.toDouble() ?? 0;
      final note = r['note'] as String? ?? '';
      final category = r['category'] as String? ?? '';
      final material = _parseExportMaterialFields(
        category: category,
        note: note,
      );
      sheet.appendRow([
        i + 1,
        date,
        book,
        account,
        type == 'income' ? '收入' : '支出',
        amount,
        note,
        category,
        material.name,
        material.quantity,
        material.unit,
      ]);
    }
    debugPrint('数据写入工作表完成，准备保存为文件');
    final directory = await _exportDirectory();
    final fileName = '数据导出_${_formatDateTime(DateTime.now())}.xlsx';
    final exportFile = File(p.join(directory.path, fileName));
    final bytes = workbook.save();
    if (bytes == null) {
      debugPrint('生成字节失败：bytes 为 null');
      throw Exception('导出失败');
    }
    debugPrint('生成字节长度=${bytes.length}');
    await exportFile.writeAsBytes(bytes, flush: true);
    debugPrint('文件写入完成：${exportFile.path}');
    return exportFile.path;
  }

  Future<Directory> _exportDirectory() async {
    // 根据平台选择导出目录
    if (Platform.isAndroid) {
      final dir = await getTemporaryDirectory();
      debugPrint('Android 临时目录：${dir.path}');
      return dir;
    }
    final dir = await getApplicationDocumentsDirectory();
    debugPrint('Windows 文档目录：${dir.path}');
    return dir;
  }

  Future<bool> _shareExportFile(String filePath) async {
    // Android 分享导出文件
    if (!Platform.isAndroid) {
      debugPrint('非 Android 平台，跳过分享逻辑');
      return false;
    }
    try {
      final file = XFile(
        filePath,
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      await SharePlus.instance.share(
        ShareParams(files: [file]),
      );
      debugPrint('Android 分享面板已唤起');
      return true;
    } catch (_) {
      debugPrint('唤起分享时发生异常，忽略继续');
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
    return '$year$month$day' '_$hour$minute$second';
  }

  Future<int> _importFromXlsx(_ImportSelection selection) async {
    // 从 xlsx 解析并导入记账记录
    debugPrint(
        '开始导入文件：${selection.fileName} billId=${selection.billId} accountId=${selection.accountId}');
    final workbook = excel.Excel.decodeBytes(selection.bytes);
    excel.Sheet? sheet = workbook.tables['Sheet1'];
    sheet ??= workbook.tables.isEmpty ? null : workbook.tables.values.first;
    if (sheet == null) {
      throw Exception('未找到可导入的工作表');
    }
    final rows = sheet.rows;
    if (rows.isEmpty) {
      return 0;
    }
    var startIndex = 0;
    if (_isHeaderRow(rows.first)) {
      startIndex = 1;
    }
    final records = <TransactionRecord>[];
    for (var i = startIndex; i < rows.length; i++) {
      final row = rows[i];
      if (_rowIsEmpty(row)) {
        continue;
      }
      final date = _dateFromCell(row, 1);
      final typeText = _stringFromCell(_cellAt(row, 4));
      final amount = _doubleFromCell(row, 5);
      final noteText = _stringFromCell(_cellAt(row, 6));
      final categoryText = _stringFromCell(_cellAt(row, 7));
      final type = _normalizeType(typeText);
      if (date == null || amount == null || type == null) {
        debugPrint('跳过无效行：index=$i date=$date type=$typeText amount=$amount');
        continue;
      }
      records.add(
        TransactionRecord(
          billId: selection.billId,
          accountId: selection.accountId,
          type: type,
          amount: amount,
          category: categoryText.isEmpty ? '未分类' : categoryText,
          date: date,
          note: noteText.isEmpty ? null : noteText,
        ),
      );
    }
    debugPrint('解析完成，待写入记录数=${records.length}');
    await RecordDatabase.instance.insertRecords(records);
    return records.length;
  }

  bool _isHeaderRow(List<excel.Data?> row) {
    // 判断是否为表头行
    return _stringFromCell(_cellAt(row, 0)) == '序号' &&
        _stringFromCell(_cellAt(row, 1)) == '日期';
  }

  bool _rowIsEmpty(List<excel.Data?> row) {
    // 判断行是否为空
    for (final cell in row) {
      if (_stringFromCell(cell).isNotEmpty) {
        return false;
      }
    }
    return true;
  }

  excel.Data? _cellAt(List<excel.Data?> row, int index) {
    // 读取指定索引的单元格
    if (index < 0 || index >= row.length) {
      return null;
    }
    return row[index];
  }

  String _stringFromCell(excel.Data? cell) {
    // 读取单元格字符串内容
    final value = cell?.value;
    if (value == null) {
      return '';
    }
    return value.toString().trim();
  }

  double? _doubleFromCell(List<excel.Data?> row, int index) {
    // 读取单元格数值内容
    final value = _cellAt(row, index)?.value;
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  DateTime? _dateFromCell(List<excel.Data?> row, int index) {
    // 读取单元格日期内容
    final value = _cellAt(row, index)?.value;
    if (value is DateTime) {
      return value;
    }
    if (value is String) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  String? _normalizeType(String input) {
    // 统一收支类型格式
    if (input == '收入' || input.toLowerCase() == 'income') {
      return 'income';
    }
    if (input == '支出' || input.toLowerCase() == 'expense') {
      return 'expense';
    }
    return null;
  }

  _ExportMaterialFields _parseExportMaterialFields({
    required String category,
    required String note,
  }) {
    if (category != '课程材料') {
      return const _ExportMaterialFields();
    }
    final trimmedNote = note.trim();
    if (trimmedNote.isEmpty) {
      return const _ExportMaterialFields();
    }
    final splitIndex = trimmedNote.indexOf(_materialNoteSplitter);
    final materialName = splitIndex == -1
        ? trimmedNote
        : trimmedNote.substring(0, splitIndex).trim();
    if (materialName.isEmpty) {
      return const _ExportMaterialFields();
    }
    final quantity = splitIndex == -1
        ? ''
        : trimmedNote.substring(splitIndex + _materialNoteSplitter.length).trim();
    final unit = _baseMaterials[materialName] ?? '';
    return _ExportMaterialFields(
      name: materialName,
      quantity: quantity,
      unit: unit,
    );
  }

}

class _ExportMaterialFields {
  const _ExportMaterialFields({
    this.name = '',
    this.quantity = '',
    this.unit = '',
  });

  final String name;
  final String quantity;
  final String unit;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({
    required this.bills,
    required this.accounts,
    required this.onChanged,
  });

  final List<Bill> bills;
  final List<Account> accounts;
  final void Function(
    DateTime?,
    DateTime?,
    int?,
    int?,
  ) onChanged;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  DateTime? _startDate;
  DateTime? _endDate;
  int? _billId;
  int? _accountId;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('数据导出'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pickStartDate(context),
                    child: Text(_startDate == null
                        ? '开始日期'
                        : _formatDate(_startDate!)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pickEndDate(context),
                    child: Text(_endDate == null
                        ? '结束日期'
                        : _formatDate(_endDate!)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '账本选择',
                border: OutlineInputBorder(),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int?>(
                  value: _billId,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('全部账本'),
                    ),
                    ...widget.bills.map(
                      (bill) => DropdownMenuItem<int?>(
                        value: bill.id,
                        child: Text(bill.name),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _billId = value;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '账户选择',
                border: OutlineInputBorder(),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int?>(
                  value: _accountId,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('全部账户'),
                    ),
                    ...widget.accounts.map(
                      (account) => DropdownMenuItem<int?>(
                        value: account.id,
                        child: Text(account.name),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _accountId = value;
                    });
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            widget.onChanged(
              _startDate,
              _endDate,
              _billId,
              _accountId,
            );
            Navigator.of(context).pop(true);
          },
          child: const Text('导出'),
        ),
      ],
    );
  }

  Future<void> _pickStartDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _startDate = DateTime(picked.year, picked.month, picked.day);
      if (_endDate != null && _endDate!.isBefore(_startDate!)) {
        _endDate = _startDate;
      }
    });
  }

  Future<void> _pickEndDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _endDate = DateTime(picked.year, picked.month, picked.day);
      if (_startDate != null && _endDate!.isBefore(_startDate!)) {
        _startDate = _endDate;
      }
    });
  }

  String _formatDate(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}

class _ImportSelection {
  _ImportSelection({
    required this.fileName,
    required this.bytes,
    required this.billId,
    required this.accountId,
  });

  final String fileName;
  final Uint8List bytes;
  final int billId;
  final int accountId;
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({
    required this.bills,
    required this.accounts,
    required this.defaultBillId,
    required this.defaultAccountId,
  });

  final List<Bill> bills;
  final List<Account> accounts;
  final int defaultBillId;
  final int defaultAccountId;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  int? _billId;
  int? _accountId;
  String? _fileName;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _billId = widget.defaultBillId;
    _accountId = widget.defaultAccountId;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('数据导入'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '账本选择',
                border: OutlineInputBorder(),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _billId,
                  isExpanded: true,
                  items: widget.bills
                      .map((bill) => DropdownMenuItem<int>(
                            value: bill.id!,
                            child: Text(bill.name),
                          ))
                      .toList(),
                  onChanged: (value) {
                    setState(() => _billId = value);
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '账户选择',
                border: OutlineInputBorder(),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _accountId,
                  isExpanded: true,
                  items: widget.accounts
                      .map((a) => DropdownMenuItem<int>(
                            value: a.id!,
                            child: Text(a.name),
                          ))
                      .toList(),
                  onChanged: (value) {
                    setState(() => _accountId = value);
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickFile,
                    icon: const Icon(Icons.attach_file),
                    label: Text(_fileName ?? '选择 .xlsx 文件'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _bytes == null || _billId == null || _accountId == null
              ? null
              : () {
                  Navigator.of(context).pop(
                    _ImportSelection(
                      fileName: _fileName!,
                      bytes: _bytes!,
                      billId: _billId!,
                      accountId: _accountId!,
                    ),
                  );
                },
          child: const Text('开始导入'),
        ),
      ],
    );
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      withData: true,
    );
    final files = result?.files ?? [];
    if (files.isEmpty) {
      return;
    }
    final file = files.first;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) {
      return;
    }
    setState(() {
      _fileName = file.name;
      _bytes = bytes;
    });
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      alignment: Alignment.center,
      child: Column(
        children: [
          Text(
            message,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onRetry,
            child: const Text('刷新'),
          ),
        ],
      ),
    );
  }
}
