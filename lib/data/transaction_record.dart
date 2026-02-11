// 记账记录实体
class TransactionRecord {
  TransactionRecord({
    this.id,
    required this.billId,
    required this.accountId,
    required this.type,
    required this.amount,
    required this.category,
    required this.date,
    this.note,
  });

  final int? id;
  final int billId;
  final int accountId;
  final String type;
  final double amount;
  final String category;
  final DateTime date;
  final String? note;

  // 复制并替换指定字段
  TransactionRecord copyWith({
    int? id,
    int? billId,
    int? accountId,
    String? type,
    double? amount,
    String? category,
    DateTime? date,
    String? note,
  }) {
    return TransactionRecord(
      id: id ?? this.id,
      billId: billId ?? this.billId,
      accountId: accountId ?? this.accountId,
      type: type ?? this.type,
      amount: amount ?? this.amount,
      category: category ?? this.category,
      date: date ?? this.date,
      note: note ?? this.note,
    );
  }

  // 转换为数据库存储 Map
  Map<String, Object?> toMap() {
    return {
      'id': id,
      'bill_id': billId,
      'account_id': accountId,
      'type': type,
      'amount': amount,
      'category': category,
      'date': date.toIso8601String(),
      'note': note,
    };
  }

  // 从数据库 Map 构建记录
  static TransactionRecord fromMap(Map<String, Object?> map) {
    return TransactionRecord(
      id: map['id'] as int?,
      billId: map['bill_id'] as int,
      accountId: map['account_id'] as int,
      type: map['type'] as String,
      amount: (map['amount'] as num).toDouble(),
      category: map['category'] as String,
      date: DateTime.parse(map['date'] as String),
      note: map['note'] as String?,
    );
  }
}

// 账本实体
class Bill {
  Bill({
    this.id,
    required this.name,
    required this.isDefault,
  });

  final int? id;
  final String name;
  final bool isDefault;

  // 转换为数据库存储 Map
  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'is_default': isDefault ? 1 : 0,
    };
  }

  // 从数据库 Map 构建账本
  static Bill fromMap(Map<String, Object?> map) {
    return Bill(
      id: map['id'] as int?,
      name: map['name'] as String,
      isDefault: (map['is_default'] as int? ?? 0) == 1,
    );
  }
}

// 账户实体
class Account {
  Account({
    this.id,
    required this.name,
    required this.isDefault,
  });

  final int? id;
  final String name;
  final bool isDefault;

  // 转换为数据库存储 Map
  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'is_default': isDefault ? 1 : 0,
    };
  }

  // 从数据库 Map 构建账户
  static Account fromMap(Map<String, Object?> map) {
    return Account(
      id: map['id'] as int?,
      name: map['name'] as String,
      isDefault: (map['is_default'] as int? ?? 0) == 1,
    );
  }
}
