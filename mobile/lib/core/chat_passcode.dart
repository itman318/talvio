import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/brand.dart';
import 'chat_lock.dart';

/// A passcode for one chat, kept only on this phone (hashed). Opening the chat asks for it.
/// Forgot it? The phone's fingerprint / screen lock removes it.
class ChatPasscode {
  ChatPasscode._();

  static SharedPreferences? _p;
  static final Set<int> _open = {}; // unlocked until the app goes to the background

  static Future<void> load() async => _p ??= await SharedPreferences.getInstance();

  static String _key(int chatId) => 'chat_pin_$chatId';
  static String _hash(int chatId, String pin) => sha256.convert(utf8.encode('talvio-chat-pin:$chatId:$pin')).toString();

  static bool has(int chatId) => _p?.containsKey(_key(chatId)) ?? false;
  static bool isOpen(int chatId) => _open.contains(chatId);
  static bool needsCode(int chatId) => has(chatId) && !isOpen(chatId);

  static Future<void> set(int chatId, String pin) async {
    await load();
    await _p!.setString(_key(chatId), _hash(chatId, pin));
    _open.add(chatId);
  }

  static Future<void> remove(int chatId) async {
    await load();
    await _p!.remove(_key(chatId));
  }

  static bool check(int chatId, String pin) {
    final ok = _p?.getString(_key(chatId)) == _hash(chatId, pin);
    if (ok) _open.add(chatId);
    return ok;
  }

  /// Locks every passcode chat again (app went to the background).
  static void closeAll() => _open.clear();

  /// Asks for a new passcode twice. Returns the code, or null when cancelled.
  static Future<String?> askNew(BuildContext context) async {
    final first = await askCode(context, title: 'Set a passcode', subtitle: '4 to 8 digits — only on this phone');
    if (first == null || !context.mounted) return null;
    final again = await askCode(context, title: 'Repeat the passcode');
    if (again == null) return null;
    if (again != first) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The passcodes didn’t match')));
      return null;
    }
    return first;
  }

  /// A small number-pad sheet.
  static Future<String?> askCode(BuildContext context, {required String title, String? subtitle, bool Function(String)? verify}) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PinPad(title: title, subtitle: subtitle, verify: verify),
    );
  }

  /// "Forgot passcode": the phone's own lock proves it's the owner, then the passcode is removed.
  static Future<bool> resetWithDevice(BuildContext context, int chatId) async {
    ChatLock.close(); // always ask, even right after another unlock
    if (!await ChatLock.unlock(context, reason: 'Remove this chat’s passcode')) return false;
    await remove(chatId);
    _open.add(chatId);
    return true;
  }
}

class _PinPad extends StatefulWidget {
  const _PinPad({required this.title, this.subtitle, this.verify});
  final String title;
  final String? subtitle;
  final bool Function(String)? verify;

  @override
  State<_PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<_PinPad> {
  String _code = '';
  bool _wrong = false;

  void _tap(String d) {
    if (_code.length >= 8) return;
    HapticFeedback.selectionClick();
    setState(() {
      _code += d;
      _wrong = false;
    });
    // checking codes: open as soon as the right one is typed
    if (widget.verify != null && _code.length >= 4 && widget.verify!(_code)) Navigator.pop(context, _code);
  }

  void _done() {
    if (_code.length < 4) return;
    if (widget.verify != null && !widget.verify!(_code)) {
      HapticFeedback.heavyImpact();
      setState(() {
        _wrong = true;
        _code = '';
      });
      return;
    }
    Navigator.pop(context, _code);
  }

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, IconData? icon}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onTap ?? () => _tap(label),
                child: SizedBox(
                  height: 56,
                  child: Center(child: icon != null ? Icon(icon) : Text(label, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
                ),
              ),
            ),
          ),
        );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          if (widget.subtitle != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(widget.subtitle!, style: const TextStyle(color: Brand.muted))),
          const SizedBox(height: 18),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < (_code.length < 4 ? 4 : _code.length); i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 6),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: i < _code.length ? Brand.aurora : null,
                  border: i < _code.length ? null : Border.all(color: _wrong ? Colors.red : Brand.muted, width: 1.6),
                ),
              ),
          ]),
          SizedBox(
            height: 26,
            child: _wrong ? const Padding(padding: EdgeInsets.only(top: 8), child: Text('Wrong passcode', style: TextStyle(color: Colors.red))) : null,
          ),
          for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']]) Row(children: [for (final d in row) key(d)]),
          Row(children: [
            key('', icon: Icons.backspace_outlined, onTap: () => setState(() => _code = _code.isEmpty ? '' : _code.substring(0, _code.length - 1))),
            key('0'),
            key('', icon: Icons.check_rounded, onTap: _done),
          ]),
        ]),
      ),
    );
  }
}
