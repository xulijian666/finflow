import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
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
    required this.outQuantity,
    required this.remainingQuantity,
    required this.totalAmount,
  });

  final String materialName;
  final String? unit;
  final double purchasedQuantity;
  final double outQuantity;
  final double remainingQuantity;
  final double totalAmount;

  static InventorySummary fromMap(Map<String, Object?> map) {
    return InventorySummary(
      materialName: map['material_name'] as String,
      unit: map['unit'] as String?,
      purchasedQuantity: (map['purchased_quantity'] as num?)?.toDouble() ?? 0,
      outQuantity: (map['out_quantity'] as num?)?.toDouble() ?? 0,
      remainingQuantity: (map['remaining_quantity'] as num?)?.toDouble() ?? 0,
      totalAmount: (map['total_amount'] as num?)?.toDouble() ?? 0,
    );
  }
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
    required this.isOutbound,
  });

  final int id;
  final String materialName;
  final double quantity;
  final String? unit;
  final String createdAt;
  final double? amount;
  final String? note;
  final bool isOutbound;
}

class RecordDatabase {
  RecordDatabase._internal();

  static final RecordDatabase instance = RecordDatabase._internal();

  static const String _dbName = 'finflow.db';
  // 数据库版本升级用于触发表结构更新
  static const int _dbVersion = 6;
  static const String _tableName = 'records';
  static const String _billTableName = 'bills';
  static const String _accountTableName = 'accounts';
  static const String _baseMaterialTableName = 'base_materials';
  static const String _inventoryTableName = 'inventory_records';
  static const String _inventoryOutTableName = 'inventory_out_records';
  static const String _reimbursementTableName = 'reimbursements';

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
        reimbursement_id INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_baseMaterialTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        unit TEXT NOT NULL
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
      CREATE TABLE IF NOT EXISTS $_reimbursementTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        total_amount REAL NOT NULL,
        date TEXT NOT NULL,
        note TEXT,
        created_at TEXT NOT NULL
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
    await _ensureColumn(db, _tableName, 'reimbursement_id', 'INTEGER');
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
        'name': '默认账户',
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
    await db.update(
      _accountTableName,
      {'name': name},
      where: 'id = ?',
      whereArgs: [accountId],
    );
  }

  Future<void> deleteAccount(int accountId) async {
    final db = await database;
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
    final where = <String>[
      'bill_id = ?',
      'date(date) IN ($placeholders)',
    ];
    final args = <Object?>[billId, ...dateKeys];
    if (startDate != null) {
      where.add('date(date) >= date(?)');
      args.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      where.add('date(date) <= date(?)');
      args.add(endDate.toIso8601String());
    }
    final maps = await db.rawQuery(
      '''
      SELECT * FROM $_tableName
      WHERE ${where.join(' AND ')}
      ORDER BY date DESC, id DESC
      ''',
      args,
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

  Future<int> insertBaseMaterial(BaseMaterial material) async {
    final db = await database;
    return db.insert(_baseMaterialTableName, material.toMap());
  }

  Future<void> updateBaseMaterial(BaseMaterial material) async {
    final db = await database;
    await db.update(
      _baseMaterialTableName,
      material.toMap(),
      where: 'id = ?',
      whereArgs: [material.id],
    );
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
      '(COALESCE(in_sum.purchased_quantity, 0) > 0 OR COALESCE(out_sum.out_quantity, 0) > 0)',
    );
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = await db.rawQuery('''
      SELECT bm.name AS material_name,
             COALESCE(in_sum.unit, out_sum.unit, bm.unit) AS unit,
             COALESCE(in_sum.purchased_quantity, 0) AS purchased_quantity,
             COALESCE(out_sum.out_quantity, 0) AS out_quantity,
             COALESCE(in_sum.purchased_quantity, 0) - COALESCE(out_sum.out_quantity, 0) AS remaining_quantity,
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
      ORDER BY created_at DESC, id DESC
      ''',
      [materialName, materialName],
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
            isOutbound: (row['record_type'] as String) == 'out',
          ),
        )
        .toList();
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
    final db = await database;
    return db.transaction((txn) async {
      final id = await txn.insert(
        _reimbursementTableName,
        reimbursement.toMap(),
      );
      for (final recordId in recordIds) {
        await txn.update(
          _tableName,
          {'reimbursement_id': id},
          where: 'id = ?',
          whereArgs: [recordId],
        );
      }
      return id;
    });
  }

  Future<List<Reimbursement>> fetchReimbursements() async {
    final db = await database;
    final maps = await db.query(
      _reimbursementTableName,
      orderBy: 'date DESC, id DESC',
    );
    return maps.map(Reimbursement.fromMap).toList();
  }

  Future<List<TransactionRecord>> fetchUnreimbursedRecords() async {
    final db = await database;
    final maps = await db.query(
      _tableName,
      where: 'reimbursement_id IS NULL AND type = ?',
      whereArgs: ['expense'],
      orderBy: 'date DESC, id DESC',
    );
    return maps.map(TransactionRecord.fromMap).toList();
  }

  Future<List<TransactionRecord>> fetchReimbursedRecords() async {
    final db = await database;
    final maps = await db.query(
      _tableName,
      where: 'reimbursement_id IS NOT NULL',
      orderBy: 'date DESC, id DESC',
    );
    return maps.map(TransactionRecord.fromMap).toList();
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
    await db.delete(_reimbursementTableName);
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
