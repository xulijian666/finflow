import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import 'transaction_record.dart';

class RecordDatabase {
  RecordDatabase._internal();

  static final RecordDatabase instance = RecordDatabase._internal();
  static const String _dbName = 'finflow.db';
  static const String _assetDbPath = 'assets/finflow.db';
  static const String _tableName = 'records';
  static const String _billTableName = 'bills';
  static const String _accountTableName = 'accounts';
  static const int _defaultBillId = 1;
  static const String _defaultBillName = '默认账本';
  static const int _defaultAccountId = 1;
  static const String _defaultAccountName = '默认账户';

  sqflite.Database? _database;

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

  Future<int> insertRecord(TransactionRecord record) async {
    final db = await database;
    return db.insert(_tableName, record.toMap());
  }

  Future<int> updateRecord(TransactionRecord record) async {
    final db = await database;
    return db.update(
      _tableName,
      record.toMap(),
      where: 'id = ?',
      whereArgs: [record.id],
    );
  }

  Future<int> deleteRecord(int id) async {
    final db = await database;
    return db.delete(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

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

  Future<List<Bill>> fetchBills() async {
    final db = await database;
    final maps = await db.query(
      _billTableName,
      orderBy: 'is_default DESC, id ASC',
    );
    return maps.map(Bill.fromMap).toList();
  }

  Future<int> insertBill(String name) async {
    final db = await database;
    return db.insert(_billTableName, {
      'name': name,
      'is_default': 0,
    });
  }

  Future<int> updateBillName(int id, String name) async {
    final db = await database;
    return db.update(
      _billTableName,
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

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

  Future<int> insertAccount(String name) async {
    final db = await database;
    return db.insert(_accountTableName, {
      'name': name,
      'is_default': 0,
    });
  }

  Future<int> updateAccountName(int id, String name) async {
    final db = await database;
    return db.update(
      _accountTableName,
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

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

  int get defaultBillId => _defaultBillId;
  int get defaultAccountId => _defaultAccountId;
}
