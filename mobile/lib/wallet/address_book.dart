import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SavedAddress {
  SavedAddress(this.name, this.address);
  final String name;
  final String address;
  bool get isTron => address.startsWith('T');
}

/// Addresses the person saved with a name (on this phone), plus two safety checks:
/// "first time sending here" and "looks like an address you know, but isn't" (address poisoning).
class AddressBook {
  AddressBook(this.userId);
  final int userId;
  String get _key => 'wallet_book_v1_$userId';

  Future<List<SavedAddress>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return [];
      return [for (final j in jsonDecode(raw) as List) SavedAddress('${j['name']}', '${j['address']}')];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<SavedAddress> list) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode([for (final x in list) {'name': x.name, 'address': x.address}]));

  Future<void> add(String name, String address) async {
    final list = (await load()).where((x) => x.address.toLowerCase() != address.toLowerCase()).toList();
    list.insert(0, SavedAddress(name.trim(), address.trim()));
    await _save(list);
  }

  Future<void> remove(String address) async => _save((await load()).where((x) => x.address.toLowerCase() != address.toLowerCase()).toList());

  static String? nameFor(List<SavedAddress> book, String address) =>
      book.where((x) => x.address.toLowerCase() == address.toLowerCase()).firstOrNull?.name;

  /// A known address that starts AND ends like [address] but is not it — a classic scam trick.
  static String? lookalike(Iterable<String> known, String address) {
    final a = address.toLowerCase();
    if (a.length < 12) return null;
    for (final k in known) {
      final b = k.toLowerCase();
      if (b == a || b.length != a.length) continue;
      final head = a.startsWith('0x') ? 6 : 4;
      if (a.substring(0, head) == b.substring(0, head) && a.substring(a.length - 4) == b.substring(b.length - 4)) return k;
    }
    return null;
  }
}
