class User {
  final String id;
  final String email;
  final String username;
  final String? fullName;
  final bool isActive;
  final DateTime createdAt;

  User({
    required this.id,
    required this.email,
    required this.username,
    this.fullName,
    this.isActive = true,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'email': email,
      'username': username,
      'full_name': fullName,
      'is_active': isActive,
      'created_at': createdAt.toIso8601String(),
    };
  }

  User.fromMap(Map<String, dynamic> map)
      : id = map['id'] as String,
        email = map['email'] as String,
        username = map['username'] as String,
        fullName = map['full_name'] as String?,
        isActive = (map['is_active'] as bool?) ?? true,
        createdAt = DateTime.parse(map['created_at'] as String);

  User copyWith({
    String? id,
    String? email,
    String? username,
    String? fullName,
    bool? isActive,
    DateTime? createdAt,
  }) {
    return User(
      id: id ?? this.id,
      email: email ?? this.email,
      username: username ?? this.username,
      fullName: fullName ?? this.fullName,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
