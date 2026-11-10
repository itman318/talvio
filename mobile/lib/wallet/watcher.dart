import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/message_notifications.dart';
import 'portfolio.dart';
import 'tron_crypto.dart';
import 'wallet_store.dart';

/// "You received 20 USDT": when the app opens (and every few minutes while it's open) the balances
/// are compared with the last ones seen; anything that went UP becomes a notification.
/// Only public balances are read — the phrase is never touched.
class WalletWatcher {
  WalletWatcher._();
  static DateTime? _last;
  static bool _running = false;
  static Timer? _timer;

  static void start(int userId, bool Function() enabled) {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 4), (_) {
      if (enabled()) check(userId);
    });
    if (enabled()) check(userId);
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<void> check(int userId, {bool force = false}) async {
    if (_running) return;
    if (!force && _last != null && DateTime.now().difference(_last!) < const Duration(minutes: 2)) return;
    _running = true;
    _last = DateTime.now();
    try {
      final w = WalletStore(userId);
      await w.load();
      if (!w.exists || w.evmAddress == null) return;
      final assets = Portfolio.build(tron: w.net, custom: w.customTokens);
      await Portfolio.load(assets, tronAddress: w.address!, evmAddress: w.evmAddress!, tron: w.net);
      final p = await SharedPreferences.getInstance();
      final key = 'wallet_seen_v1_${userId}_${w.net.id}';
      final seen = Map<String, dynamic>.from(jsonDecode(p.getString(key) ?? '{}') as Map);
      final first = seen.isEmpty;
      final next = Map<String, dynamic>.from(seen);
      var shown = 0;
      for (final a in assets) {
        final b = a.balance;
        if (b == null) continue; // that network didn't answer: compare next time
        final before = BigInt.tryParse('${seen[a.key] ?? ''}');
        next[a.key] = '$b';
        if (first || before == null || b <= before) continue;
        final got = b - before;
        await _notify(a, got, shown++);
      }
      await p.setString(key, jsonEncode(next));
    } catch (_) {
      // best effort: never disturbs the app
    } finally {
      _running = false;
    }
  }

  static Future<void> _notify(WalletAsset a, BigInt got, int n) async {
    await MessageNotifications.init();
    final amount = Units.format(got, decimals: a.decimals, maxFraction: 6);
    final usd = a.price == null ? '' : ' (≈ \$${(Units.toDouble(got, decimals: a.decimals) * a.price!).toStringAsFixed(2)})';
    await MessageNotifications.plugin.show(
      900000 + n + DateTime.now().millisecond,
      'Received $amount ${a.symbol}',
      'On ${a.networkName}$usd — open Wallet to see it',
      const NotificationDetails(
        android: AndroidNotificationDetails('wallet', 'Wallet', channelDescription: 'Coins arriving in your wallet', importance: Importance.high, priority: Priority.high),
        iOS: DarwinNotificationDetails(threadIdentifier: 'wallet'),
      ),
    );
  }
}
