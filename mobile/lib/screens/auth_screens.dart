import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/api_client.dart';
import '../state/auth_state.dart';
import '../utils/format.dart';
import 'more_screens.dart';

// ------------------------------------------------------------------ phone number
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  final _code = TextEditingController(text: AppConfig.defaultCountryCode);
  final _number = TextEditingController();
  bool _busy = false;

  String get _phone {
    var n = _number.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (n.startsWith('0')) n = n.substring(1); // 0300... → 300...
    var c = _code.text.trim();
    if (!c.startsWith('+')) c = '+$c';
    return '$c$n';
  }

  Future<void> _submit() async {
    if (_number.text.trim().length < 6) {
      showInfo(context, 'Enter your phone number');
      return;
    }
    setState(() => _busy = true);
    final phone = _phone;
    try {
      final r = await context.read<AuthState>().requestOtp(phone);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => OtpScreen(phone: r['phone'] as String? ?? phone, devCode: r['dev_code'] as String?),
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final reason = auth.logoutReason;
    return Scaffold(
      appBar: auth.addingAccount && auth.otherAccounts.isNotEmpty
          ? AppBar(
              leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Cancel', onPressed: auth.cancelAddAccount),
              title: const Text('Add account'),
            )
          : null,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 40),
            const Icon(Icons.send_rounded, size: 72, color: Color(0xFF2AABEE)),
            const SizedBox(height: 16),
            Text('Your phone number', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text('We will send you a verification code by SMS.', textAlign: TextAlign.center),
            if (reason != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(8)),
                child: Text(reason, textAlign: TextAlign.center),
              ),
            ],
            const SizedBox(height: 28),
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _code,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Code', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _number,
                    autofocus: true,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]'))],
                    decoration: const InputDecoration(labelText: 'Phone number', hintText: '300 1234567', border: OutlineInputBorder()),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Next'),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ OTP
class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key, required this.phone, this.devCode});
  final String phone;
  final String? devCode;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  int _resendIn = 60;
  String? _devCode;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _devCode = widget.devCode;
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _resendIn = 60;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendIn--);
      if (_resendIn <= 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length < 4) return;
    setState(() => _busy = true);
    try {
      await context.read<AuthState>().verifyOtp(widget.phone, code);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'account_banned') {
        _code.clear();
        await showBannedDialog(context, e);
        return;
      }
      final left = e.extra['attempts_left'];
      showInfo(context, left != null ? '${e.message} ($left attempts left)' : e.message);
      _code.clear();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    try {
      final r = await context.read<AuthState>().requestOtp(widget.phone);
      if (!mounted) return;
      setState(() => _devCode = r['dev_code'] as String?);
      _startTimer();
      showInfo(context, 'A new code was sent');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Enter code', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text('We sent an SMS with a code to ${widget.phone}', textAlign: TextAlign.center),
          if (_devCode != null) ...[
            const SizedBox(height: 12),
            Text('Dev mode code: $_devCode', textAlign: TextAlign.center, style: const TextStyle(color: Colors.deepOrange)),
          ],
          const SizedBox(height: 24),
          TextField(
            controller: _code,
            autofocus: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            style: const TextStyle(fontSize: 28, letterSpacing: 12),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(counterText: '', border: OutlineInputBorder()),
            onChanged: (v) {
              if (v.length == 6) _verify();
            },
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _verify,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Verify'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _resendIn > 0 ? null : _resend,
            child: Text(_resendIn > 0 ? 'Resend code in $_resendIn s' : 'Resend code'),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ profile setup
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _first = TextEditingController();
  final _last = TextEditingController();
  String? _avatarPath;
  bool _busy = false;

  Future<void> _pick() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
    if (x != null) setState(() => _avatarPath = x.path);
  }

  Future<void> _save() async {
    if (_first.text.trim().isEmpty) {
      showInfo(context, 'Enter your first name');
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<AuthState>().saveProfile(
            firstName: _first.text.trim(),
            lastName: _last.text.trim(),
            avatarPath: _avatarPath,
          );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your profile'),
        actions: [TextButton(onPressed: () => context.read<AuthState>().logout(), child: const Text('Cancel'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: GestureDetector(
              onTap: _pick,
              child: CircleAvatar(
                radius: 52,
                backgroundColor: const Color(0xFF2AABEE),
                backgroundImage: _avatarPath != null ? FileImage(File(_avatarPath!)) : null,
                child: _avatarPath == null ? const Icon(Icons.add_a_photo, color: Colors.white, size: 34) : null,
              ),
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _first,
            textCapitalization: TextCapitalization.words,
            maxLength: 64,
            decoration: const InputDecoration(labelText: 'First name (required)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _last,
            textCapitalization: TextCapitalization.words,
            maxLength: 64,
            decoration: const InputDecoration(labelText: 'Last name (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Continue'),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ simple status screens
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: Icon(Icons.send_rounded, size: 72, color: Color(0xFF2AABEE))),
      );
}

class MessageScreen extends StatelessWidget {
  const MessageScreen({super.key, required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 64, color: const Color(0xFF2AABEE)),
                  const SizedBox(height: 16),
                  Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(body, textAlign: TextAlign.center),
                  if (action != null) ...[const SizedBox(height: 20), action!],
                ],
              ),
            ),
          ),
        ),
      );
}
