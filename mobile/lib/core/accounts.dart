import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// An account saved on this phone. The active account's tokens live in ApiClient;
/// the others keep theirs here until you switch to them.
class StoredAccount {
  final int id;
  final String name;
  final String? phone;
  final String? avatarUrl;
  final String? access;
  final String? refresh;

  StoredAccount({required this.id, required this.name, this.phone, this.avatarUrl, this.access, this.refresh});

  StoredAccount copyWith({String? name, String? phone, String? avatarUrl, String? access, String? refresh, bool clearTokens = false}) => StoredAccount(
        id: id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        access: clearTokens ? null : access ?? this.access,
        refresh: clearTokens ? null : refresh ?? this.refresh,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'avatar_url': avatarUrl, 'access': access, 'refresh': refresh};

  factory StoredAccount.fromJson(Map<String, dynamic> j) => StoredAccount(
        id: (j['id'] as num).toInt(),
        name: (j['name'] ?? '') as String,
        phone: j['phone'] as String?,
        avatarUrl: j['avatar_url'] as String?,
        access: j['access'] as String?,
        refresh: j['refresh'] as String?,
      );
}

class AccountStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'accounts_v1';
  List<StoredAccount> list = [];

  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _key);
      list = raw == null ? [] : (jsonDecode(raw) as List).map((j) => StoredAccount.fromJson(Map<String, dynamic>.from(j as Map))).toList();
    } catch (_) {
      list = [];
    }
  }

  Future<void> _save() => _storage.write(key: _key, value: jsonEncode(list.map((a) => a.toJson()).toList()));

  StoredAccount? byId(int id) {
    for (final a in list) {
      if (a.id == id) return a;
    }
    return null;
  }

  Future<void> upsert(StoredAccount a) async {
    final i = list.indexWhere((x) => x.id == a.id);
    if (i >= 0) {
      list[i] = a;
    } else {
      list.add(a);
    }
    await _save();
  }

  Future<void> remove(int id) async {
    list.removeWhere((a) => a.id == id);
    await _save();
  }

  /// Accounts we can switch to (have saved tokens).
  List<StoredAccount> others(int? activeId) => list.where((a) => a.id != activeId && a.refresh != null).toList();
}
