// lib/models/points.dart
class Points {
  final String userId;
  final int total;
  final DateTime updatedAt;

  Points({
    required this.userId,
    required this.total,
    required this.updatedAt,
  });

  factory Points.fromJson(Map<String, dynamic> json) {
    return Points(
      userId: (json['user_id'] ?? '') as String,
      total: (json['total'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'total': total,
    'updated_at': updatedAt.toIso8601String(),
  };
}
