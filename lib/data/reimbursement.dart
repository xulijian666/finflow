// 报销记录实体
class Reimbursement {
  Reimbursement({
    this.id,
    required this.totalAmount,
    required this.date,
    this.note,
    required this.createdAt,
  });

  final int? id;
  final double totalAmount;
  final DateTime date;
  final String? note;
  final DateTime createdAt;

  // 复制并替换指定字段
  Reimbursement copyWith({
    int? id,
    double? totalAmount,
    DateTime? date,
    String? note,
    DateTime? createdAt,
  }) {
    return Reimbursement(
      id: id ?? this.id,
      totalAmount: totalAmount ?? this.totalAmount,
      date: date ?? this.date,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  // 转换为数据库存储 Map
  Map<String, Object?> toMap() {
    return {
      'id': id,
      'total_amount': totalAmount,
      'date': date.toIso8601String(),
      'note': note,
      'created_at': createdAt.toIso8601String(),
    };
  }

  // 从数据库 Map 构建记录
  static Reimbursement fromMap(Map<String, Object?> map) {
    return Reimbursement(
      id: map['id'] as int?,
      totalAmount: (map['total_amount'] as num).toDouble(),
      date: DateTime.parse(map['date'] as String),
      note: map['note'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
