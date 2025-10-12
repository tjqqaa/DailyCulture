// lib/models/activity.dart
class Activity {
  final String id;
  final String title;
  final String status; // 'open' | 'done' | etc.
  final String? kind;

  final DateTime? dueDate;
  final bool anyTime;

  final String? placeName;
  final double? placeLat;
  final double? placeLon;
  final int? radiusM;

  final int? pointsOnComplete;

  final DateTime? createdAt;
  final DateTime? completedAt;

  const Activity({
    required this.id,
    required this.title,
    this.status = 'open',
    this.kind,
    this.dueDate,
    this.anyTime = true,
    this.placeName,
    this.placeLat,
    this.placeLon,
    this.radiusM,
    this.pointsOnComplete,
    this.createdAt,
    this.completedAt,
  });

  bool get isDone => status.toLowerCase() == 'done';

  Activity copyWith({
    String? id,
    String? title,
    String? status,
    String? kind,
    DateTime? dueDate,
    bool? anyTime,
    String? placeName,
    double? placeLat,
    double? placeLon,
    int? radiusM,
    int? pointsOnComplete,
    DateTime? createdAt,
    DateTime? completedAt,
  }) {
    return Activity(
      id: id ?? this.id,
      title: title ?? this.title,
      status: status ?? this.status,
      kind: kind ?? this.kind,
      dueDate: dueDate ?? this.dueDate,
      anyTime: anyTime ?? this.anyTime,
      placeName: placeName ?? this.placeName,
      placeLat: placeLat ?? this.placeLat,
      placeLon: placeLon ?? this.placeLon,
      radiusM: radiusM ?? this.radiusM,
      pointsOnComplete: pointsOnComplete ?? this.pointsOnComplete,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  // -------- JSON helpers --------
  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static DateTime? _toDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is String && v.isNotEmpty) {
      try {
        return DateTime.parse(v);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  factory Activity.fromJson(Map<String, dynamic> json) {
    return Activity(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      status: (json['status'] ?? 'open').toString(),
      kind: json['kind']?.toString(),
      // soporta 'due_date' o 'dueDate'
      dueDate: _toDate(json['due_date'] ?? json['dueDate']),
      // soporta 'any_time' o 'anyTime'
      anyTime: (json['any_time'] ?? json['anyTime'] ?? true) == true ||
          (json['any_time']?.toString() == 'true'),
      // place_*
      placeName: (json['place_name'] ?? json['placeName'])?.toString(),
      placeLat: _toDouble(json['place_lat'] ?? json['placeLat']),
      placeLon: _toDouble(json['place_lon'] ?? json['placeLon']),
      radiusM: _toInt(json['radius_m'] ?? json['radiusM']),
      // puntos
      pointsOnComplete:
      _toInt(json['points_on_complete'] ?? json['pointsOnComplete']),
      // timestamps opcionales
      createdAt: _toDate(json['created_at'] ?? json['createdAt']),
      completedAt: _toDate(json['completed_at'] ?? json['completedAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'status': status,
      'kind': kind,
      'due_date': dueDate?.toIso8601String(),
      'any_time': anyTime,
      'place_name': placeName,
      'place_lat': placeLat,
      'place_lon': placeLon,
      'radius_m': radiusM,
      'points_on_complete': pointsOnComplete,
      'created_at': createdAt?.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
    };
  }
}
