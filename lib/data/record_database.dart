import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import 'transaction_record.dart';

// 数据库访问单例，封装账本、账户、记账记录的读写与维护
class RecordDatabase {
  RecordDatabase._internal();

  // 全局唯一实例
  static final RecordDatabase instance = RecordDatabase._internal();
  // 数据库文件名与内置资产路径
  static const String _dbName = 'finflow.db'; 
  static const String _assetDbPath = 'assets/finflow.db';
  // 表名常量
  static const String _tableName = 'records';
  static const String _billTableName = 'bills';
  static const String _accountTableName = 'accounts';
  // 默认账本与账户
  static const int _defaultBillId = 1;
  static const String _defaultBillName = '默认账本';
  static const int _defaultAccountId = 1;
  static const String _defaultAccountName = '默认账户';

  // 当前数据库连接缓存
  sqflite.Database? _database;

  // 获取应用目录下数据库文件路径
  Future<String> getDatabasePath() async {
    final directory = await getApplicationDocumentsDirectory();
    return p.join(directory.path, _dbName);
  }

  // 关闭数据库连接并释放缓存
  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  // 创建数据库备份并清理旧备份
  Future<String> backup() async {
    final dbPath = await getDatabasePath();
    final directory = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(directory.path, 'backups'));
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }

    final now = DateTime.now();
    final timestamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final backupPath = p.join(backupDir.path, 'finflow_backup_$timestamp.db');

    // 确保数据库已落盘
    final db = await database;
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
    } catch (_) {}
    
    await File(dbPath).copy(backupPath);
    await _cleanOldBackups(backupDir);
    return backupPath;
  }

  // 仅保留最新的备份文件
  Future<void> _cleanOldBackups(Directory backupDir) async {
    try {
      final entities = await backupDir.list().toList();
      final backups = entities.whereType<File>().where((file) {
        return p.basename(file.path).startsWith('finflow_backup_') &&
            p.basename(file.path).endsWith('.db');
      }).toList();

      if (backups.length > 3) {
        // 按修改时间排序，最旧的在前面
        backups.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
        final toDelete = backups.sublist(0, backups.length - 3);
        for (final file in toDelete) {
          await file.delete();
        }
      }
    } catch (e) {
      print('清理旧备份失败: $e');
    }
  }

  // 获取本地备份列表
  Future<List<File>> getBackups() async {
    final directory = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(directory.path, 'backups'));
    if (!await backupDir.exists()) {
      return [];
    }

    final entities = await backupDir.list().toList();
    final backups = entities.whereType<File>().where((file) {
      return p.basename(file.path).startsWith('finflow_backup_') &&
          p.basename(file.path).endsWith('.db');
    }).toList();

    // 按修改时间倒序排列，最新的在前面
    backups.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return backups;
  }

  // 从指定路径恢复数据库并重新初始化连接
  Future<void> restore(String sourcePath) async {
    await close();
    final dbPath = await getDatabasePath();
    final sourceFile = File(sourcePath);
    if (await sourceFile.exists()) {
       await sourceFile.copy(dbPath);
    } else {
       throw Exception('备份文件不存在');
    }
    // 重新初始化连接
    await database;
  }

  // 获取数据库连接，必要时初始化并补齐表结构
  Future<sqflite.Database> get database async {
    final existing = _database;
    if (existing != null) {
      await _ensureSchema(existing);
      return existing;
    }
    _database = await _initDatabase();
    await _ensureSchema(_database!);
    return _database!;
  }

  // 初始化数据库文件与平台适配
  Future<sqflite.Database> _initDatabase() async {
    final directory = await getApplicationDocumentsDirectory();
    await Directory(directory.path).create(recursive: true);
    final path = p.join(directory.path, _dbName);
    final file = File(path);
    if (!await file.exists()) {
      final data = await rootBundle.load(_assetDbPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await file.writeAsBytes(bytes, flush: true);
    }
    print('SQLite 数据库路径：$path');
    if (Platform.isWindows) {
      ffi.sqfliteFfiInit();
      sqflite.databaseFactory = ffi.databaseFactoryFfi;
    }
    return sqflite.openDatabase(
      path,
      version: 3,
      onCreate: _createDb,
      onUpgrade: _upgradeDb,
    );
  }

  // 初始化创建表结构与默认数据
  Future<void> _createDb(sqflite.Database db, int version) async {
    await db.execute(
      '''
      CREATE TABLE $_billTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        is_default INTEGER NOT NULL DEFAULT 0
      )
      ''',
    );
    await db.insert(
      _billTableName,
      {
        'id': _defaultBillId,
        'name': _defaultBillName,
        'is_default': 1,
      },
    );
    await db.execute(
      '''
      CREATE TABLE $_accountTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        is_default INTEGER NOT NULL DEFAULT 0
      )
      ''',
    );
    await db.insert(
      _accountTableName,
      {
        'id': _defaultAccountId,
        'name': _defaultAccountName,
        'is_default': 1,
      },
    );
    await db.execute(
      '''
      CREATE TABLE $_tableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bill_id INTEGER NOT NULL,
        account_id INTEGER NOT NULL,
        type TEXT NOT NULL,
        amount REAL NOT NULL,
        category TEXT NOT NULL,
        date TEXT NOT NULL,
        note TEXT
      )
      ''',
    );
  }

  // 数据库版本升级与字段迁移
  Future<void> _upgradeDb(
    sqflite.Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        '''
        CREATE TABLE IF NOT EXISTS $_billTableName (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          is_default INTEGER NOT NULL DEFAULT 0
        )
        ''',
      );
      final existing = await db.query(
        _billTableName,
        where: 'id = ?',
        whereArgs: [_defaultBillId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await db.insert(
          _billTableName,
          {
            'id': _defaultBillId,
            'name': _defaultBillName,
            'is_default': 1,
          },
        );
      }
      await db.execute(
        'ALTER TABLE $_tableName ADD COLUMN bill_id INTEGER NOT NULL DEFAULT $_defaultBillId',
      );
      await db.update(
        _tableName,
        {'bill_id': _defaultBillId},
        where: 'bill_id IS NULL',
      );
    }
    if (oldVersion < 3) {
      await db.execute(
        '''
        CREATE TABLE IF NOT EXISTS $_accountTableName (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          is_default INTEGER NOT NULL DEFAULT 0
        )
        ''',
      );
      final existing = await db.query(
        _accountTableName,
        where: 'id = ?',
        whereArgs: [_defaultAccountId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await db.insert(
          _accountTableName,
          {
            'id': _defaultAccountId,
            'name': _defaultAccountName,
            'is_default': 1,
          },
        );
      }
      await db.execute(
        'ALTER TABLE $_tableName ADD COLUMN account_id INTEGER NOT NULL DEFAULT $_defaultAccountId',
      );
      await db.update(
        _tableName,
        {'account_id': _defaultAccountId},
        where: 'account_id IS NULL',
      );
    }
  }

  // 启动时补齐缺失表与缺失字段
  Future<void> _ensureSchema(sqflite.Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final tableNames = tables.map((e) => e['name'] as String).toSet();
    if (!tableNames.contains(_billTableName)) {
      await db.execute(
        '''
        CREATE TABLE $_billTableName (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          is_default INTEGER NOT NULL DEFAULT 0
        )
        ''',
      );
    }
    final defaultBillExists = await db.query(
      _billTableName,
      where: 'id = ?',
      whereArgs: [_defaultBillId],
      limit: 1,
    );
    if (defaultBillExists.isEmpty) {
      await db.insert(
        _billTableName,
        {
          'id': _defaultBillId,
          'name': _defaultBillName,
          'is_default': 1,
        },
      );
    }

    if (!tableNames.contains(_accountTableName)) {
      await db.execute(
        '''
        CREATE TABLE $_accountTableName (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          is_default INTEGER NOT NULL DEFAULT 0
        )
        ''',
      );
    }
    final defaultAccountExists = await db.query(
      _accountTableName,
      where: 'id = ?',
      whereArgs: [_defaultAccountId],
      limit: 1,
    );
    if (defaultAccountExists.isEmpty) {
      await db.insert(
        _accountTableName,
        {
          'id': _defaultAccountId,
          'name': _defaultAccountName,
          'is_default': 1,
        },
      );
    }

    final recordColumns =
        await db.rawQuery("PRAGMA table_info($_tableName)");
    final columnNames =
        recordColumns.map((e) => e['name'] as String).toSet();
    if (!columnNames.contains('bill_id')) {
      await db.execute(
        'ALTER TABLE $_tableName ADD COLUMN bill_id INTEGER NOT NULL DEFAULT $_defaultBillId',
      );
      await db.update(
        _tableName,
        {'bill_id': _defaultBillId},
        where: 'bill_id IS NULL',
      );
    }
    if (!columnNames.contains('account_id')) {
      await db.execute(
        'ALTER TABLE $_tableName ADD COLUMN account_id INTEGER NOT NULL DEFAULT $_defaultAccountId',
      );
      await db.update(
        _tableName,
        {'account_id': _defaultAccountId},
        where: 'account_id IS NULL',
      );
    }
  }

  // 确保默认账本与默认账户存在
  Future<void> ensureDefaultBillAndAccount() async {
    final db = await database;
    final defaultBillExists = await db.query(
      _billTableName,
      where: 'id = ?',
      whereArgs: [_defaultBillId],
      limit: 1,
    );
    if (defaultBillExists.isEmpty) {
      await db.insert(
        _billTableName,
        {
          'id': _defaultBillId,
          'name': _defaultBillName,
          'is_default': 1,
        },
      );
    }
    final defaultAccountExists = await db.query(
      _accountTableName,
      where: 'id = ?',
      whereArgs: [_defaultAccountId],
      limit: 1,
    );
    if (defaultAccountExists.isEmpty) {
      await db.insert(
        _accountTableName,
        {
          'id': _defaultAccountId,
          'name': _defaultAccountName,
          'is_default': 1,
        },
      );
    }
  }

  // 新增记账记录
  Future<int> insertRecord(TransactionRecord record) async {
    final db = await database;
    return db.insert(_tableName, record.toMap());
  }

  // 更新记账记录
  Future<int> updateRecord(TransactionRecord record) async {
    final db = await database;
    return db.update(
      _tableName,
      record.toMap(),
      where: 'id = ?',
      whereArgs: [record.id],
    );
  }

  // 删除指定记录
  Future<int> deleteRecord(int id) async {
    final db = await database;
    return db.delete(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // 获取账本下的全部记录
  Future<List<TransactionRecord>> fetchRecords({required int billId}) async {
    final db = await database;
    final maps = await db.query(
      _tableName,
      where: 'bill_id = ?',
      whereArgs: [billId],
      orderBy: 'date DESC, id DESC',
    );
    return maps.map(TransactionRecord.fromMap).toList();
  }

  // 获取最近有记录的日期列表
  Future<List<String>> fetchRecentRecordDates({
    required int billId,
    String? beforeDate,
    int limit = 3,
  }) async {
    final db = await database;
    final where = <String>['bill_id = ?'];
    final args = <Object?>[billId];
    if (beforeDate != null) {
      where.add("substr(date, 1, 10) < ?");
      args.add(beforeDate);
    }
    final rows = await db.rawQuery(
      '''
      SELECT substr(date, 1, 10) AS day
      FROM $_tableName
      WHERE ${where.join(' AND ')}
      GROUP BY day
      ORDER BY day DESC
      LIMIT ?
      ''',
      [...args, limit],
    );
    return rows.map((row) => row['day'] as String).toList();
  }

  // 按日期集合批量获取记录
  Future<List<TransactionRecord>> fetchRecordsByDates({
    required int billId,
    required List<String> dateKeys,
  }) async {
    if (dateKeys.isEmpty) {
      return [];
    }
    final db = await database;
    final placeholders = List.filled(dateKeys.length, '?').join(',');
    final rows = await db.rawQuery(
      '''
      SELECT *
      FROM $_tableName
      WHERE bill_id = ?
        AND substr(date, 1, 10) IN ($placeholders)
      ORDER BY date DESC, id DESC
      ''',
      [billId, ...dateKeys],
    );
    return rows.map(TransactionRecord.fromMap).toList();
  }

  // 按关键词检索记录
  Future<List<TransactionRecord>> fetchRecordsByKeyword({
    required int billId,
    required String keyword,
  }) async {
    final db = await database;
    final like = '%$keyword%';
    final rows = await db.query(
      _tableName,
      where: 'bill_id = ? AND (note LIKE ? OR category LIKE ?)',
      whereArgs: [billId, like, like],
      orderBy: 'date DESC, id DESC',
    );
    return rows.map(TransactionRecord.fromMap).toList();
  }

  // 构造导出所需的数据行
  Future<List<Map<String, Object?>>> fetchExportRows({
    DateTime? startDate,
    DateTime? endDate,
    int? billId,
    int? accountId,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];
    if (startDate != null) {
      final start = DateTime(startDate.year, startDate.month, startDate.day);
      where.add('r.date >= ?');
      args.add(start.toIso8601String());
    }
    if (endDate != null) {
      final end = DateTime(endDate.year, endDate.month, endDate.day)
          .add(const Duration(days: 1));
      where.add('r.date < ?');
      args.add(end.toIso8601String());
    }
    if (billId != null) {
      where.add('r.bill_id = ?');
      args.add(billId);
    }
    if (accountId != null) {
      where.add('r.account_id = ?');
      args.add(accountId);
    }
    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = await db.rawQuery(
      '''
      SELECT r.date,
             r.type,
             r.amount,
             r.category,
             r.note,
             b.name AS book_name,
             a.name AS account_name
      FROM $_tableName r
      LEFT JOIN $_billTableName b ON r.bill_id = b.id
      LEFT JOIN $_accountTableName a ON r.account_id = a.id
      $whereClause
      ORDER BY r.date DESC, r.id DESC
      ''',
      args,
    );
    return rows;
  }

  // 批量插入记录
  Future<void> insertRecords(List<TransactionRecord> records) async {
    if (records.isEmpty) {
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final record in records) {
        batch.insert(_tableName, record.toMap());
      }
      await batch.commit(noResult: true);
    });
  }

  // 按主键获取单条记录
  Future<TransactionRecord?> fetchRecord(int id) async {
    final db = await database;
    final maps = await db.query(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) {
      return null;
    }
    return TransactionRecord.fromMap(maps.first);
  }

  // 获取账本列表
  Future<List<Bill>> fetchBills() async {
    final db = await database;
    final maps = await db.query(
      _billTableName,
      orderBy: 'is_default DESC, id ASC',
    );
    return maps.map(Bill.fromMap).toList();
  }

  // 新增账本
  Future<int> insertBill(String name) async {
    final db = await database;
    return db.insert(_billTableName, {
      'name': name,
      'is_default': 0,
    });
  }

  // 修改账本名称
  Future<int> updateBillName(int id, String name) async {
    final db = await database;
    return db.update(
      _billTableName,
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // 删除账本（默认账本不可删除）
  Future<int> deleteBill(int id) async {
    if (id == _defaultBillId) {
      return 0;
    }
    final db = await database;
    return db.delete(
      _billTableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // 删除账本并清理对应记录
  Future<int> deleteBillWithRecords(int id) async {
    if (id == _defaultBillId) {
      return 0;
    }
    final db = await database;
    await db.delete(
      _tableName,
      where: 'bill_id = ?',
      whereArgs: [id],
    );
    return db.delete(
      _billTableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // 统计账本记录数量
  Future<int> countRecordsByBill(int billId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM $_tableName WHERE bill_id = ?',
      [billId],
    );
    if (rows.isEmpty) {
      return 0;
    }
    final value = rows.first['total'];
    return value is int ? value : (value as num?)?.toInt() ?? 0;
  }

  // 将账本记录迁移到默认账本
  Future<int> migrateBillRecordsToDefault(int billId) async {
    if (billId == _defaultBillId) {
      return 0;
    }
    final db = await database;
    return db.update(
      _tableName,
      {'bill_id': _defaultBillId},
      where: 'bill_id = ?',
      whereArgs: [billId],
    );
  }

  // 获取账户列表，并在为空时补齐默认账户
  Future<List<Account>> fetchAccounts() async {
    final db = await database;
    final maps = await db.query(
      _accountTableName,
      orderBy: 'id ASC',
    );
    final accounts = maps.map(Account.fromMap).toList();
    if (accounts.isEmpty) {
      await db.insert(
        _accountTableName,
        {
          'id': _defaultAccountId,
          'name': _defaultAccountName,
          'is_default': 1,
        },
      );
      final refreshed = await db.query(
        _accountTableName,
        orderBy: 'is_default DESC, id ASC',
      );
      return refreshed.map(Account.fromMap).toList();
    }
    return accounts;
  }

  // 新增账户
  Future<int> insertAccount(String name) async {
    final db = await database;
    return db.insert(_accountTableName, {
      'name': name,
      'is_default': 0,
    });
  }

  // 修改账户名称
  Future<int> updateAccountName(int id, String name) async {
    final db = await database;
    return db.update(
      _accountTableName,
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // 删除账户并移除关联记录
  Future<int> deleteAccount(int id) async {
    if (id == _defaultAccountId) {
      return 0;
    }
    final db = await database;
    await db.delete(
      _tableName,
      where: 'account_id = ?',
      whereArgs: [id],
    );
    return db.delete(
      _accountTableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // 设置默认账户
  Future<void> setDefaultAccount(int id) async {
    final db = await database;
    await db.update(_accountTableName, {'is_default': 0});
    await db.update(
      _accountTableName,
      {'is_default': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // 统计账户余额（收入为正、支出为负）
  Future<Map<int, double>> fetchAccountBalances() async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT account_id,
             SUM(CASE WHEN type = 'income' THEN amount ELSE -amount END) AS balance
      FROM $_tableName
      GROUP BY account_id
      ''',
    );
    final map = <int, double>{};
    for (final row in rows) {
      final id = row['account_id'] as int?;
      if (id == null) {
        continue;
      }
      final value = row['balance'];
      map[id] = (value is num) ? value.toDouble() : 0;
    }
    return map;
  }

  // 清空所有记账记录
  Future<void> clearAllRecords() async {
    final db = await database;
    await db.delete(_tableName);
  }

  // 默认账本与账户的固定主键
  int get defaultBillId => _defaultBillId;
  int get defaultAccountId => _defaultAccountId;
}
