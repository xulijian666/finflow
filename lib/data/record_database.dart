import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'reimbursement.dart';
import 'transaction_record.dart';

class InventoryRecord {
  InventoryRecord({
    this.id,
    required this.materialName,
    required this.quantity,
    this.unit,
    this.recordId,
    required this.createdAt,
    this.amount,
  });

  final int? id;
  final String materialName;
  final double quantity;
  final String? unit;
  final int? recordId;
  final String createdAt;
  final double? amount;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'material_name': materialName,
      'quantity': quantity,
      'unit': unit,
      'record_id': recordId,
      'created_at': createdAt,
    };
  }

  static InventoryRecord fromMap(Map<String, Object?> map) {
    return InventoryRecord(
      id: map['id'] as int?,
      materialName: map['material_name'] as String,
      quantity: (map['quantity'] as num).toDouble(),
      unit: map['unit'] as String?,
      recordId: map['record_id'] as int?,
      createdAt: map['created_at'] as String,
      amount: (map['amount'] as num?)?.toDouble(),
    );
  }
}

class InventorySummary {
  InventorySummary({
    required this.materialName,
    this.unit,
    required this.purchasedQuantity,
    required this.initializedQuantity,
    required this.outQuantity,
    required this.remainingQuantity,
    required this.totalAmount,
  });

  final String materialName;
  final String? unit;
  final double purchasedQuantity;
  final double initializedQuantity;
  final double outQuantity;
  final double remainingQuantity;
  final double totalAmount;

  static InventorySummary fromMap(Map<String, Object?> map) {
    return InventorySummary(
      materialName: map['material_name'] as String,
      unit: map['unit'] as String?,
      purchasedQuantity: (map['purchased_quantity'] as num?)?.toDouble() ?? 0,
      initializedQuantity:
          (map['initialized_quantity'] as num?)?.toDouble() ?? 0,
      outQuantity: (map['out_quantity'] as num?)?.toDouble() ?? 0,
      remainingQuantity: (map['remaining_quantity'] as num?)?.toDouble() ?? 0,
      totalAmount: (map['total_amount'] as num?)?.toDouble() ?? 0,
    );
  }
}

class InventoryInitMaterialRow {
  InventoryInitMaterialRow({
    required this.materialName,
    required this.unit,
    required this.quantity,
  });

  final String materialName;
  final String unit;
  final double quantity;
}

class InventoryOutRecord {
  InventoryOutRecord({
    this.id,
    required this.materialName,
    required this.quantity,
    this.unit,
    this.note,
    required this.createdAt,
  });

  final int? id;
  final String materialName;
  final double quantity;
  final String? unit;
  final String? note;
  final String createdAt;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'material_name': materialName,
      'quantity': quantity,
      'unit': unit,
      'note': note,
      'created_at': createdAt,
    };
  }

  static InventoryOutRecord fromMap(Map<String, Object?> map) {
    return InventoryOutRecord(
      id: map['id'] as int?,
      materialName: map['material_name'] as String,
      quantity: (map['quantity'] as num).toDouble(),
      unit: map['unit'] as String?,
      note: map['note'] as String?,
      createdAt: map['created_at'] as String,
    );
  }
}

class InventoryDetailRecord {
  InventoryDetailRecord({
    required this.id,
    required this.materialName,
    required this.quantity,
    this.unit,
    required this.createdAt,
    this.amount,
    this.note,
    required this.recordType,
  });

  final int id;
  final String materialName;
  final double quantity;
  final String? unit;
  final String createdAt;
  final double? amount;
  final String? note;
  final String recordType;

  bool get isOutbound => recordType == 'out';

  bool get isInitialization => recordType == 'init';
}

class RecordDatabase {
  RecordDatabase._internal();

  static final RecordDatabase instance = RecordDatabase._internal();

  static const String _dbName = 'finflow.db';
  // 数据库版本升级用于触发表结构更新
  static const int _dbVersion = 8;
  static const String _tableName = 'records';
  static const String _billTableName = 'bills';
  static const String _accountTableName = 'accounts';
  static const String _baseMaterialTableName = 'base_materials';
  static const String _inventoryTableName = 'inventory_records';
  static const String _inventoryOutTableName = 'inventory_out_records';
  static const String _projectMaterialRelationTableName =
      'project_material_relations';
  static const String defaultAccountName = '默认账户';
  static const String lineAccountName = '公账材料';

  Database? _database;
  int? _defaultBillId;
  int? _defaultAccountId;

  int get defaultBillId => _defaultBillId ?? 1;
  int get defaultAccountId => _defaultAccountId ?? 1;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    if (Platform.isWindows) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dbPath = await _dbFilePath();
    final exists = await File(dbPath).exists();

    // 关键保护：只有当本地数据库不存在时才从资源复制，确保升级/重装应用（只要文件未被删除）不会覆盖用户现有数据
    if (!exists) {
      try {
        await _copyAssetDatabase(dbPath);
      } catch (_) {}
    }
    return openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: _createDb,
      onUpgrade: _upgradeDb,
    );
  }

  Future<String> _dbFilePath() async {
    final databasesPath = await getDatabasesPath();
    await Directory(databasesPath).create(recursive: true);
    return p.join(databasesPath, _dbName);
  }

  Future<void> _copyAssetDatabase(String targetPath) async {
    final bytes = await rootBundle.load('assets/finflow.db');
    final buffer = bytes.buffer;
    await File(targetPath).writeAsBytes(
      buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
  }

  Future<void> _createDb(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_billTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        is_default INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_accountTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        is_default INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_tableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bill_id INTEGER NOT NULL,
        account_id INTEGER NOT NULL,
        type TEXT NOT NULL,
        amount REAL NOT NULL,
        category TEXT NOT NULL,
        date TEXT NOT NULL,
        note TEXT,
        quantity REAL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_baseMaterialTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        unit TEXT NOT NULL,
        init_quantity REAL NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_inventoryTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        material_name TEXT NOT NULL,
        quantity REAL NOT NULL,
        unit TEXT,
        record_id INTEGER,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_inventoryOutTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        material_name TEXT NOT NULL,
        quantity REAL NOT NULL,
        unit TEXT,
        note TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_projectMaterialRelationTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_name TEXT NOT NULL,
        grade_name TEXT NOT NULL,
        course_name TEXT NOT NULL,
        material_name TEXT NOT NULL,
        UNIQUE(project_name, grade_name, course_name, material_name)
      )
    ''');
  }

  Future<void> _upgradeDb(Database db, int oldVersion, int newVersion) async {
    // 统一走建表逻辑，确保新增表在旧库中创建
    await _createDb(db, newVersion);
    await _ensureColumn(
      db,
      _tableName,
      'bill_id',
      'INTEGER NOT NULL DEFAULT 1',
    );
    await _ensureColumn(
      db,
      _tableName,
      'account_id',
      'INTEGER NOT NULL DEFAULT 1',
    );
    await _ensureColumn(db, _tableName, 'quantity', 'REAL');
    await _ensureColumn(
      db,
      _baseMaterialTableName,
      'init_quantity',
      'REAL NOT NULL DEFAULT 0',
    );
    await db.execute('DROP TABLE IF EXISTS inventory_init_records');
    await db.execute('DROP TABLE IF EXISTS reimbursements');
  }

  Future<void> _ensureColumn(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final result = await db.rawQuery('PRAGMA table_info($table)');
    final exists = result.any((row) => row['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  Future<void> ensureDefaultBillAndAccount() async {
    final db = await database;
    await _ensureColumn(
      db,
      _baseMaterialTableName,
      'init_quantity',
      'REAL NOT NULL DEFAULT 0',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_projectMaterialRelationTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_name TEXT NOT NULL,
        grade_name TEXT NOT NULL,
        course_name TEXT NOT NULL,
        material_name TEXT NOT NULL,
        UNIQUE(project_name, grade_name, course_name, material_name)
      )
    ''');
    final bills = await db.query(_billTableName, orderBy: 'id ASC');
    if (bills.isEmpty) {
      final id = await db.insert(_billTableName, {
        'name': '默认账本',
        'is_default': 1,
      });
      _defaultBillId = id;
    } else {
      final defaultBill = bills.firstWhere(
        (e) => (e['is_default'] as int? ?? 0) == 1,
        orElse: () => bills.first,
      );
      _defaultBillId = defaultBill['id'] as int?;
      if ((defaultBill['is_default'] as int? ?? 0) != 1) {
        await db.update(
          _billTableName,
          {'is_default': 1},
          where: 'id = ?',
          whereArgs: [_defaultBillId],
        );
      }
    }

    final accounts = await db.query(_accountTableName, orderBy: 'id ASC');
    if (accounts.isEmpty) {
      final id = await db.insert(_accountTableName, {
        'name': defaultAccountName,
        'is_default': 1,
      });
      _defaultAccountId = id;
    } else {
      final defaultAccount = accounts.firstWhere(
        (e) => (e['is_default'] as int? ?? 0) == 1,
        orElse: () => accounts.first,
      );
      _defaultAccountId = defaultAccount['id'] as int?;
      if ((defaultAccount['is_default'] as int? ?? 0) != 1) {
        await db.update(
          _accountTableName,
          {'is_default': 1},
          where: 'id = ?',
          whereArgs: [_defaultAccountId],
        );
      }
    }
    final refreshedAccounts = await db.query(
      _accountTableName,
      orderBy: 'id ASC',
    );
    final hasLineAccount = refreshedAccounts.any(
      (item) => (item['name'] as String?)?.trim() == lineAccountName,
    );
    if (!hasLineAccount) {
      await db.insert(_accountTableName, {
        'name': lineAccountName,
        'is_default': 0,
      });
    }
    await _ensureBaseMaterialNameUniqueInternal(db);
    await db.execute('DROP TABLE IF EXISTS inventory_init_records');
    await db.execute('DROP TABLE IF EXISTS reimbursements');
  }

  Future<List<Bill>> fetchBills() async {
    final db = await database;
    final maps = await db.query(_billTableName, orderBy: 'id ASC');
    return maps.map(Bill.fromMap).toList();
  }

  Future<int> insertBill(String name) async {
    final db = await database;
    final currentBills = await fetchBills();
    final isDefault = currentBills.isEmpty ? 1 : 0;
    final id = await db.insert(_billTableName, {
      'name': name,
      'is_default': isDefault,
    });
    if (isDefault == 1) {
      _defaultBillId = id;
    }
    return id;
  }

  Future<void> updateBillName(int billId, String name) async {
    final db = await database;
    await db.update(
      _billTableName,
      {'name': name},
      where: 'id = ?',
      whereArgs: [billId],
    );
  }

  Future<int> countRecordsByBill(int billId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM $_tableName WHERE bill_id = ?',
      [billId],
    );
    return (result.first['total'] as int?) ?? 0;
  }

  Future<void> migrateBillRecordsToDefault(int billId) async {
    final db = await database;
    await db.update(
      _tableName,
      {'bill_id': defaultBillId},
      where: 'bill_id = ?',
      whereArgs: [billId],
    );
  }

  Future<void> deleteBill(int billId) async {
    final db = await database;
    await db.delete(_billTableName, where: 'id = ?', whereArgs: [billId]);
  }

  Future<void> deleteBillWithRecords(int billId) async {
    final db = await database;
    final recordIds = await db.rawQuery(
      'SELECT id FROM $_tableName WHERE bill_id = ?',
      [billId],
    );
    if (recordIds.isNotEmpty) {
      final ids = recordIds.map((e) => e['id'] as int).toList();
      final placeholders = List.filled(ids.length, '?').join(',');
      await db.delete(
        _inventoryTableName,
        where: 'record_id IN ($placeholders)',
        whereArgs: ids,
      );
      await db.delete(
        _tableName,
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
    }
    await deleteBill(billId);
  }

  Future<List<Account>> fetchAccounts() async {
    final db = await database;
    final maps = await db.query(_accountTableName, orderBy: 'id ASC');
    return maps.map(Account.fromMap).toList();
  }

  Future<int> insertAccount(String name) async {
    final db = await database;
    final accounts = await fetchAccounts();
    final isDefault = accounts.isEmpty ? 1 : 0;
    final id = await db.insert(_accountTableName, {
      'name': name,
      'is_default': isDefault,
    });
    if (isDefault == 1) {
      _defaultAccountId = id;
    }
    return id;
  }

  Future<void> updateAccountName(int accountId, String name) async {
    final db = await database;
    final account = await db.query(
      _accountTableName,
      where: 'id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    final accountName = account.isEmpty
        ? ''
        : (account.first['name'] as String? ?? '').trim();
    if (accountName == lineAccountName) {
      return;
    }
    await db.update(
      _accountTableName,
      {'name': name},
      where: 'id = ?',
      whereArgs: [accountId],
    );
  }

  Future<void> deleteAccount(int accountId) async {
    final db = await database;
    final account = await db.query(
      _accountTableName,
      where: 'id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    final accountName = account.isEmpty
        ? ''
        : (account.first['name'] as String? ?? '').trim();
    if (accountName == lineAccountName) {
      return;
    }
    await db.update(
      _tableName,
      {'account_id': defaultAccountId},
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    await db.delete(_accountTableName, where: 'id = ?', whereArgs: [accountId]);
  }

  Future<Map<int, double>> fetchAccountBalances() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT account_id,
             SUM(CASE WHEN type = 'income' THEN amount ELSE -amount END) AS balance
      FROM $_tableName
      GROUP BY account_id
    ''');
    return {
      for (final row in rows)
        row['account_id'] as int: (row['balance'] as num?)?.toDouble() ?? 0,
    };
  }

  Future<List<TransactionRecord>> fetchRecordsByKeyword({
    required int billId,
    required String keyword,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final db = await database;
    final like = '%$keyword%';
    final where = <String>[
      'bill_id = ?',
      '(note LIKE ? OR category LIKE ? OR amount LIKE ?)',
    ];
    final args = <Object?>[billId, like, like, like];
    if (startDate != null) {
      where.add('date(date) >= date(?)');
      args.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      where.add('date(date) <= date(?)');
      args.add(endDate.toIso8601String());
    }
    final maps = await db.query(
      _tableName,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'date DESC, id DESC',
    );
    return maps.map(TransactionRecord.fromMap).toList();
  }

  Future<List<TransactionRecord>> fetchRecords({
    required int billId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final db = await database;
    final where = <String>['bill_id = ?'];
    final args = <Object?>[billId];
    if (startDate != null) {
      where.add('date(date) >= date(?)');
      args.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      where.add('date(date) <= date(?)');
      args.add(endDate.toIso8601String());
    }
    final maps = await db.query(
      _tableName,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'date DESC, id DESC',
    );
    return maps.map(TransactionRecord.fromMap).toList();
  }

  Future<List<String>> fetchRecentRecordDates({
    required int billId,
    String? beforeDate,
    required int limit,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final db = await database;
    final where = <String>['bill_id = ?'];
    final args = <Object?>[billId];
    if (beforeDate != null && beforeDate.isNotEmpty) {
      where.add('date(date) < date(?)');
      args.add(beforeDate);
    }
    if (startDate != null) {
      where.add('date(date) >= date(?)');
      args.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      where.add('date(date) <= date(?)');
      args.add(endDate.toIso8601String());
    }
    final rows = await db.query(
      _tableName,
      columns: ['date(date) AS date_key'],
      where: where.join(' AND '),
      whereArgs: args,
      groupBy: 'date_key',
      orderBy: 'date_key DESC',
      limit: limit,
    );
    return rows.map((e) => e['date_key'] as String).toList();
  }

  Future<List<TransactionRecord>> fetchRecordsByDates({
    required int billId,
    required List<String> dateKeys,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    if (dateKeys.isEmpty) {
      return [];
    }
    final db = await database;
    final placeholders = List.filled(dateKeys.length, '?').join(',');
    final where = <String>['bill_id = ?', 'date(date) IN ($placeholders)'];
    final args = <Object?>[billId, ...dateKeys];
    if (startDate != null) {
      where.add('date(date) >= date(?)');
      args.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      where.add('date(date) <= date(?)');
      args.add(endDate.toIso8601String());
    }
    final maps = await db.rawQuery('''
      SELECT * FROM $_tableName
      WHERE ${where.join(' AND ')}
      ORDER BY date DESC, id DESC
      ''', args);
    return maps.map(TransactionRecord.fromMap).toList();
  }

  Future<List<TransactionRecord>> fetchRecordsByAccount(int accountId) async {
    final db = await database;
    final maps = await db.query(
      _tableName,
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'date DESC, id DESC',
    );
    return maps.map(TransactionRecord.fromMap).toList();
  }

  Future<int> insertRecord(TransactionRecord record) async {
    final db = await database;
    return db.insert(_tableName, record.toMap());
  }

  Future<void> updateRecord(TransactionRecord record) async {
    final db = await database;
    await db.update(
      _tableName,
      record.toMap(),
      where: 'id = ?',
      whereArgs: [record.id],
    );
  }

  Future<void> deleteRecord(int id) async {
    final db = await database;
    await db.delete(
      _inventoryTableName,
      where: 'record_id = ?',
      whereArgs: [id],
    );
    await db.delete(_tableName, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> insertRecords(List<TransactionRecord> records) async {
    if (records.isEmpty) {
      return;
    }
    final db = await database;
    final batch = db.batch();
    for (final record in records) {
      batch.insert(_tableName, record.toMap());
    }
    await batch.commit(noResult: true);
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
      where.add('date(date) >= date(?)');
      args.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      where.add('date(date) <= date(?)');
      args.add(endDate.toIso8601String());
    }
    if (billId != null) {
      where.add('r.bill_id = ?');
      args.add(billId);
    }
    if (accountId != null) {
      where.add('r.account_id = ?');
      args.add(accountId);
    }
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = await db.rawQuery('''
      SELECT r.*, b.name AS book_name, a.name AS account_name
      FROM $_tableName r
      LEFT JOIN $_billTableName b ON r.bill_id = b.id
      LEFT JOIN $_accountTableName a ON r.account_id = a.id
      $whereSql
      ORDER BY r.date DESC, r.id DESC
      ''', args);
    return rows;
  }

  Future<Map<String, Object?>> fetchBusinessTableSnapshot() async {
    final db = await database;
    // 读取当前数据库中的全部业务表，并附带字段定义与全量行数据供大模型使用。
    final tableRows = await db.rawQuery('''
      SELECT name
      FROM sqlite_master
      WHERE type = 'table'
        AND name NOT LIKE 'sqlite_%'
      ORDER BY name ASC
    ''');
    final tables = <Map<String, Object?>>[];
    for (final item in tableRows) {
      final tableName = (item['name'] as String? ?? '').trim();
      if (tableName.isEmpty || tableName == 'android_metadata') {
        continue;
      }
      final escapedTableName = _escapeIdentifier(tableName);
      final columnRows = await db.rawQuery(
        'PRAGMA table_info("$escapedTableName")',
      );
      final dataRows = await db.rawQuery(
        'SELECT * FROM "$escapedTableName" ORDER BY rowid ASC',
      );
      tables.add({
        'table_name': tableName,
        'row_count': dataRows.length,
        'columns': columnRows
            .map(
              (column) => <String, Object?>{
                'name': column['name'],
                'type': column['type'],
                'not_null': column['notnull'],
                'default_value': column['dflt_value'],
                'primary_key': column['pk'],
              },
            )
            .toList(),
        'rows': dataRows
            .map(
              (row) => row.map<String, Object?>(
                (key, value) => MapEntry(key, _normalizeSnapshotValue(value)),
              ),
            )
            .toList(),
      });
    }
    return {
      'generated_at': DateTime.now().toIso8601String(),
      'table_count': tables.length,
      'tables': tables,
    };
  }

  // 转义表名中的双引号，避免动态查询时出现 SQL 语法问题。
  String _escapeIdentifier(String value) {
    return value.replaceAll('"', '""');
  }

  // 统一清洗快照值，确保后续可直接 JSON 序列化。
  Object? _normalizeSnapshotValue(Object? value) {
    if (value is num || value is String || value is bool || value == null) {
      return value;
    }
    if (value is Uint8List) {
      return value.toList();
    }
    return value.toString();
  }

  Future<List<BaseMaterial>> fetchBaseMaterials({
    String? keyword,
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];
    if (keyword != null && keyword.trim().isNotEmpty) {
      where.add('name LIKE ?');
      args.add('%${keyword.trim()}%');
    }
    final maps = await db.query(
      _baseMaterialTableName,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'id DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map(BaseMaterial.fromMap).toList();
  }

  Future<BaseMaterial?> fetchBaseMaterialByName(String name) async {
    final db = await database;
    final maps = await db.query(
      _baseMaterialTableName,
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (maps.isEmpty) {
      return null;
    }
    return BaseMaterial.fromMap(maps.first);
  }

  Future<List<ProjectMaterialRelation>> fetchProjectMaterialRelations({
    String? keyword,
    String searchField = 'all',
  }) async {
    final db = await database;
    final normalized = keyword?.trim() ?? '';
    if (normalized.isEmpty) {
      final maps = await db.query(
        _projectMaterialRelationTableName,
        orderBy:
            'project_name ASC, grade_name ASC, course_name ASC, material_name ASC',
      );
      return maps.map(ProjectMaterialRelation.fromMap).toList();
    }
    final like = '%$normalized%';
    late final String whereSql;
    late final List<Object?> whereArgs;
    switch (searchField) {
      case 'project':
        whereSql = 'project_name LIKE ?';
        whereArgs = [like];
        break;
      case 'grade':
        whereSql = 'grade_name LIKE ?';
        whereArgs = [like];
        break;
      case 'course':
        whereSql = 'course_name LIKE ?';
        whereArgs = [like];
        break;
      case 'material':
        whereSql = 'material_name LIKE ?';
        whereArgs = [like];
        break;
      default:
        whereSql =
            '(project_name LIKE ? OR grade_name LIKE ? OR course_name LIKE ? OR material_name LIKE ?)';
        whereArgs = [like, like, like, like];
        break;
    }
    final maps = await db.query(
      _projectMaterialRelationTableName,
      where: whereSql,
      whereArgs: whereArgs,
      orderBy:
          'project_name ASC, grade_name ASC, course_name ASC, material_name ASC',
    );
    return maps.map(ProjectMaterialRelation.fromMap).toList();
  }

  Future<void> importProjectMaterialRelationsByProject(
    List<ProjectMaterialRelation> rows,
  ) async {
    if (rows.isEmpty) {
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      final projects = rows.map((e) => e.projectName).toSet().toList();
      final placeholders = List.filled(projects.length, '?').join(',');
      await txn.delete(
        _projectMaterialRelationTableName,
        where: 'project_name IN ($placeholders)',
        whereArgs: projects,
      );
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(
          _projectMaterialRelationTableName,
          row.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<int> insertBaseMaterial(BaseMaterial material) async {
    final db = await database;
    return db.insert(_baseMaterialTableName, material.toMap());
  }

  Future<void> updateBaseMaterial(BaseMaterial material) async {
    final db = await database;
    await db.update(
      _baseMaterialTableName,
      {'name': material.name, 'unit': material.unit},
      where: 'id = ?',
      whereArgs: [material.id],
    );
  }

  Future<int> countCourseMaterialRecordsByName(String materialName) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS total
      FROM $_tableName
      WHERE category = '课程材料'
        AND note IS NOT NULL
        AND (note = ? OR note LIKE ?)
      ''',
      [materialName, '$materialName｜%'],
    );
    return (rows.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, int>> renameBaseMaterialAndSync({
    required int materialId,
    required String oldName,
    required String newName,
    required String unit,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      await txn.update(
        _baseMaterialTableName,
        {'name': newName, 'unit': unit},
        where: 'id = ?',
        whereArgs: [materialId],
      );
      final matchedPattern = '$oldName｜%';
      final updatedRecords = await txn.rawUpdate(
        '''
        UPDATE $_tableName
        SET note = CASE
          WHEN note = ? THEN ?
          WHEN note LIKE ? THEN ? || substr(note, length(?) + 1)
          ELSE note
        END
        WHERE category = '课程材料'
          AND note IS NOT NULL
          AND (note = ? OR note LIKE ?)
        ''',
        [
          oldName,
          newName,
          matchedPattern,
          newName,
          oldName,
          oldName,
          matchedPattern,
        ],
      );
      final updatedInventoryIn = await txn.update(
        _inventoryTableName,
        {'material_name': newName},
        where: 'material_name = ?',
        whereArgs: [oldName],
      );
      final updatedInventoryOut = await txn.update(
        _inventoryOutTableName,
        {'material_name': newName},
        where: 'material_name = ?',
        whereArgs: [oldName],
      );
      return {
        'records': updatedRecords,
        'inventoryIn': updatedInventoryIn,
        'inventoryInit': 0,
        'inventoryOut': updatedInventoryOut,
      };
    });
  }

  Future<void> deleteBaseMaterial(int id) async {
    final db = await database;
    await db.delete(_baseMaterialTableName, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> replaceBaseMaterials(List<BaseMaterial> materials) async {
    final db = await database;
    return db.transaction((txn) async {
      await txn.delete(_baseMaterialTableName);
      final batch = txn.batch();
      for (final material in materials) {
        batch.insert(_baseMaterialTableName, material.toMap());
      }
      await batch.commit(noResult: true);
      return materials.length;
    });
  }

  Future<Map<String, int>> upsertBaseMaterials(
    List<BaseMaterial> materials,
  ) async {
    final db = await database;
    int inserted = 0;
    int updated = 0;
    await db.transaction((txn) async {
      for (final material in materials) {
        final existing = await txn.query(
          _baseMaterialTableName,
          where: 'name = ?',
          whereArgs: [material.name],
          limit: 1,
        );
        if (existing.isEmpty) {
          await txn.insert(_baseMaterialTableName, material.toMap());
          inserted += 1;
        } else {
          final id = existing.first['id'] as int;
          await txn.update(
            _baseMaterialTableName,
            {'unit': material.unit},
            where: 'id = ?',
            whereArgs: [id],
          );
          updated += 1;
        }
      }
    });
    return {'inserted': inserted, 'updated': updated};
  }

  Future<void> insertInventoryRecord({
    required String materialName,
    required double quantity,
    String? unit,
    int? recordId,
  }) async {
    final db = await database;
    final record = InventoryRecord(
      materialName: materialName,
      quantity: quantity,
      unit: unit,
      recordId: recordId,
      createdAt: DateTime.now().toIso8601String(),
    );
    await db.insert(_inventoryTableName, record.toMap());
  }

  Future<void> deleteInventoryByRecordId(int recordId) async {
    final db = await database;
    await db.delete(
      _inventoryTableName,
      where: 'record_id = ?',
      whereArgs: [recordId],
    );
  }

  Future<List<InventorySummary>> fetchInventorySummary({
    String? keyword,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];
    if (keyword != null && keyword.trim().isNotEmpty) {
      where.add('bm.name LIKE ?');
      args.add('%${keyword.trim()}%');
    }
    where.add(
      '(COALESCE(in_sum.purchased_quantity, 0) > 0 OR COALESCE(bm.init_quantity, 0) > 0 OR COALESCE(out_sum.out_quantity, 0) > 0)',
    );
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = await db.rawQuery('''
      SELECT bm.name AS material_name,
             COALESCE(in_sum.unit, out_sum.unit, bm.unit) AS unit,
             COALESCE(in_sum.purchased_quantity, 0) AS purchased_quantity,
             COALESCE(bm.init_quantity, 0) AS initialized_quantity,
             COALESCE(out_sum.out_quantity, 0) AS out_quantity,
             COALESCE(in_sum.purchased_quantity, 0) + COALESCE(bm.init_quantity, 0) - COALESCE(out_sum.out_quantity, 0) AS remaining_quantity,
             COALESCE(in_sum.total_amount, 0) AS total_amount
      FROM $_baseMaterialTableName bm
      LEFT JOIN (
        SELECT ir.material_name,
               ir.unit,
               SUM(ir.quantity) AS purchased_quantity,
               SUM(COALESCE(r.amount, 0)) AS total_amount
        FROM $_inventoryTableName ir
        LEFT JOIN $_tableName r ON ir.record_id = r.id
        GROUP BY ir.material_name, ir.unit
      ) in_sum ON in_sum.material_name = bm.name
      LEFT JOIN (
        SELECT orc.material_name,
               orc.unit,
               SUM(orc.quantity) AS out_quantity
        FROM $_inventoryOutTableName orc
        GROUP BY orc.material_name, orc.unit
      ) out_sum ON out_sum.material_name = bm.name
      $whereSql
      ORDER BY remaining_quantity DESC
      ''', args);
    return rows.map(InventorySummary.fromMap).toList();
  }

  Future<List<InventoryDetailRecord>> fetchInventoryDetails(
    String materialName,
  ) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT ir.id,
             ir.material_name,
             ir.quantity,
             ir.unit,
             ir.created_at,
             r.amount AS amount,
             r.note AS note,
             'in' AS record_type
      FROM $_inventoryTableName ir
      LEFT JOIN $_tableName r ON ir.record_id = r.id
      WHERE ir.material_name = ?
      UNION ALL
      SELECT orc.id,
             orc.material_name,
             orc.quantity,
             orc.unit,
             orc.created_at,
             NULL AS amount,
             orc.note AS note,
             'out' AS record_type
      FROM $_inventoryOutTableName orc
      WHERE orc.material_name = ?
      UNION ALL
      SELECT -1 AS id,
             bm.name AS material_name,
             bm.init_quantity AS quantity,
             bm.unit AS unit,
             '1970-01-01T00:00:00.000' AS created_at,
             NULL AS amount,
             NULL AS note,
             'init' AS record_type
      FROM $_baseMaterialTableName bm
      WHERE bm.name = ?
        AND bm.init_quantity > 0
      ORDER BY created_at DESC, id DESC
      ''',
      [materialName, materialName, materialName],
    );
    return rows
        .map(
          (row) => InventoryDetailRecord(
            id: row['id'] as int,
            materialName: row['material_name'] as String,
            quantity: (row['quantity'] as num).toDouble(),
            unit: row['unit'] as String?,
            createdAt: row['created_at'] as String,
            amount: (row['amount'] as num?)?.toDouble(),
            note: row['note'] as String?,
            recordType: row['record_type'] as String,
          ),
        )
        .toList();
  }

  Future<void> upsertInitQuantity({
    required String materialName,
    required String unit,
    required double quantity,
  }) async {
    final db = await database;
    await db.update(
      _baseMaterialTableName,
      {'init_quantity': quantity, 'unit': unit},
      where: 'name = ?',
      whereArgs: [materialName],
    );
  }

  Future<void> importInitQuantitiesOverwrite(
    List<InventoryInitMaterialRow> rows,
  ) async {
    if (rows.isEmpty) {
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final row in rows) {
        batch.update(
          _baseMaterialTableName,
          {'init_quantity': row.quantity, 'unit': row.unit},
          where: 'name = ?',
          whereArgs: [row.materialName],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<InventoryInitMaterialRow>> fetchInitMaterialRows({
    String? keyword,
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];
    if (keyword != null && keyword.trim().isNotEmpty) {
      where.add('bm.name LIKE ?');
      args.add('%${keyword.trim()}%');
    }
    final limitSql = limit == null ? '' : 'LIMIT $limit';
    final offsetSql = offset == null ? '' : 'OFFSET $offset';
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = await db.rawQuery('''
      SELECT bm.name AS material_name,
             bm.unit AS unit,
             COALESCE(bm.init_quantity, 0) AS quantity
      FROM $_baseMaterialTableName bm
      $whereSql
      ORDER BY COALESCE(bm.init_quantity, 0) DESC, bm.id DESC
      $limitSql
      $offsetSql
      ''', args);
    return rows
        .map(
          (row) => InventoryInitMaterialRow(
            materialName: row['material_name'] as String,
            unit: row['unit'] as String? ?? '',
            quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
          ),
        )
        .toList();
  }

  Future<void> syncInitRecordsWithBaseMaterials() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.execute(
        'UPDATE $_baseMaterialTableName SET init_quantity = COALESCE(init_quantity, 0)',
      );
    });
  }

  Future<void> ensureInitOneToOne() async {
    final db = await database;
    await _ensureColumn(
      db,
      _baseMaterialTableName,
      'init_quantity',
      'REAL NOT NULL DEFAULT 0',
    );
    await _ensureBaseMaterialNameUniqueInternal(db);
    await db.execute('DROP TABLE IF EXISTS inventory_init_records');
  }

  Future<void> _ensureBaseMaterialNameUniqueInternal(Database db) async {
    await db.transaction((txn) async {
      final grouped = await txn.rawQuery('''
        SELECT TRIM(name) AS name,
               MAX(COALESCE(unit, '')) AS unit,
               SUM(COALESCE(init_quantity, 0)) AS init_quantity,
               MIN(id) AS keep_id
        FROM $_baseMaterialTableName
        GROUP BY TRIM(name)
        HAVING TRIM(name) <> ''
      ''');
      await txn.delete(_baseMaterialTableName);
      for (final row in grouped) {
        final name = (row['name'] as String?)?.trim() ?? '';
        if (name.isEmpty) {
          continue;
        }
        await txn.insert(_baseMaterialTableName, {
          'id': (row['keep_id'] as num?)?.toInt(),
          'name': name,
          'unit': (row['unit'] as String?)?.trim() ?? '',
          'init_quantity': (row['init_quantity'] as num?)?.toDouble() ?? 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_base_material_name_unique ON $_baseMaterialTableName(name)',
    );
  }

  Future<int> insertOutRecord({
    required String materialName,
    required double quantity,
    String? unit,
    String? note,
    DateTime? outDate,
  }) async {
    final db = await database;
    final record = InventoryOutRecord(
      materialName: materialName,
      quantity: quantity,
      unit: unit,
      note: note,
      createdAt: (outDate ?? DateTime.now()).toIso8601String(),
    );
    return db.insert(_inventoryOutTableName, record.toMap());
  }

  Future<void> updateOutRecord({
    required int id,
    required double quantity,
    String? unit,
    String? note,
    DateTime? outDate,
  }) async {
    final db = await database;
    await db.update(
      _inventoryOutTableName,
      {
        'quantity': quantity,
        'unit': unit,
        'note': note,
        'created_at': (outDate ?? DateTime.now()).toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteOutRecord(int id) async {
    final db = await database;
    await db.delete(_inventoryOutTableName, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> createReimbursement(
    Reimbursement reimbursement,
    List<int> recordIds,
  ) async {
    return 0;
  }

  Future<List<Reimbursement>> fetchReimbursements() async {
    return [];
  }

  Future<List<TransactionRecord>> fetchUnreimbursedRecords() async {
    return fetchAllExpenseRecords();
  }

  Future<List<TransactionRecord>> fetchReimbursedRecords() async {
    return [];
  }

  Future<List<TransactionRecord>> fetchAllExpenseRecords() async {
    final db = await database;
    final maps = await db.query(
      _tableName,
      where: 'type = ?',
      whereArgs: ['expense'],
      orderBy: 'date DESC, id DESC',
    );
    return maps.map(TransactionRecord.fromMap).toList();
  }

  Future<List<TransactionRecord>> fetchRecordsByIds(List<int> ids) async {
    if (ids.isEmpty) {
      return [];
    }
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final maps = await db.query(
      _tableName,
      where: 'id IN ($placeholders)',
      whereArgs: ids,
      orderBy: 'date DESC, id DESC',
    );
    return maps.map(TransactionRecord.fromMap).toList();
  }

  Future<void> clearAllRecords() async {
    final db = await database;
    await db.delete(_inventoryTableName);
    await db.delete(_tableName);
  }

  Future<String> backup() async {
    final dbPath = await _dbFilePath();
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(dir.path, 'backups'));
    await backupDir.create(recursive: true);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '');
    final fileName = 'finflow_backup_$timestamp.db';
    final backupPath = p.join(backupDir.path, fileName);
    await File(dbPath).copy(backupPath);
    return backupPath;
  }

  Future<List<File>> getBackups() async {
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(dir.path, 'backups'));
    if (!await backupDir.exists()) {
      return [];
    }
    final files = backupDir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  Future<void> restore(String path) async {
    final dbPath = await _dbFilePath();
    await _database?.close();
    _database = null;
    await File(path).copy(dbPath);
    _database = await _initDatabase();
  }
}
