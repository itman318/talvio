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
import '../theme/brand.dart';
import '../widgets/premium.dart';

// ------------------------------------------------------------------ login (email or phone)
/// First screen: log in with an email code (free) or a phone number (SMS), whichever the admin allows.
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  final _code = TextEditingController(text: AppConfig.defaultCountryCode);
  final _number = TextEditingController();
  final _email = TextEditingController();
  bool _busy = false;
  bool? _useEmail; // null → default from server settings

  String get _phone {
    var n = _number.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (n.startsWith('0')) n = n.substring(1); // 0300... → 300...
    var c = _code.text.trim();
    if (!c.startsWith('+')) c = '+$c';
    return '$c$n';
  }

  static final _emailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$');

  Future<void> _submit(bool email) async {
    final auth = context.read<AuthState>();
    final target = email ? _email.text.trim().toLowerCase() : _phone;
    if (email ? !_emailRe.hasMatch(target) : _number.text.trim().length < 6) {
      showInfo(context, email ? 'Enter a valid email address' : 'Enter your phone number');
      return;
    }
    if (email && target == 'demo@talvio.app') return _demo();
    setState(() => _busy = true);
    try {
      final r = email ? await auth.requestEmailCode(target) : await auth.requestOtp(target);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => OtpScreen(
          phone: (r[email ? 'email' : 'phone'] as String?) ?? target,
          isEmail: email,
          devCode: r['dev_code'] as String?,
        ),
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _demo() async {
    setState(() => _busy = true);
    try {
      await context.read<AuthState>().startDemo();
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
    final canEmail = auth.emailLoginEnabled;
    final canPhone = auth.phoneLoginEnabled || !canEmail;
    final email = canEmail && (_useEmail ?? true) || !canPhone;
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
            const SizedBox(height: 24),
            SizedBox(
              height: 150,
              child: Stack(alignment: Alignment.center, children: [
                Container(
                  width: 150,
                  height: 150,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [Color(0x55F0446E), Color(0x308B5CF6), Color(0x00FFFFFF)], stops: [0, 0.55, 1]),
                  ),
                ),
                const BrandMark(size: 88),
              ]),
            ),
            const SizedBox(height: 16),
            Text(email ? 'Welcome to ${AppConfig.appName}' : 'Your phone number',
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(email ? 'Enter your email — we will send you a 6-digit login code.' : 'We will send you a verification code by SMS.',
                textAlign: TextAlign.center),
            if (reason != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Brand.primary.withAlpha(25), borderRadius: BorderRadius.circular(12)),
                child: Text(reason, textAlign: TextAlign.center),
              ),
            ],
            const SizedBox(height: 24),
            if (canEmail && canPhone) ...[
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, icon: Icon(Icons.alternate_email_rounded), label: Text('Email')),
                  ButtonSegment(value: false, icon: Icon(Icons.phone_iphone_rounded), label: Text('Phone')),
                ],
                selected: {email},
                onSelectionChanged: (v) => setState(() => _useEmail = v.first),
              ),
              const SizedBox(height: 20),
            ],
            if (email)
              TextField(
                key: const ValueKey('email-field'),
                controller: _email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.go,
                decoration: const InputDecoration(labelText: 'Email address', hintText: 'name@gmail.com', border: OutlineInputBorder()),
                onSubmitted: (_) => _submit(true),
              )
            else
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
                      key: const ValueKey('phone-field'),
                      controller: _number,
                      autofocus: true,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]'))],
                      decoration: const InputDecoration(labelText: 'Phone number', hintText: '300 1234567', border: OutlineInputBorder()),
                      onSubmitted: (_) => _submit(false),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 24),
            AuroraButton(label: 'Next', busy: _busy, onPressed: () => _submit(email)),
            if (!auth.addingAccount) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('demo-button'),
                onPressed: _busy ? null : _demo,
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                icon: const Icon(Icons.play_circle_outline_rounded),
                label: const Text('Try demo account'),
              ),
              const SizedBox(height: 6),
              Text('Explore the app with sample chats — no sign-up, works offline.',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            ],
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ OTP
class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key, required this.phone, this.isEmail = false, this.devCode});

  /// Where the code went: a phone number or (when [isEmail]) an email address.
  final String phone;
  final bool isEmail;
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
    if (code.length < 4 || _busy) return;
    setState(() => _busy = true);
    final auth = context.read<AuthState>();
    try {
      if (widget.isEmail) {
        await auth.verifyEmailCode(widget.phone, code);
      } else {
        await auth.verifyOtp(widget.phone, code);
      }
      if (!mounted) return;
      if (auth.passwordChallenge != null) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const PasswordLoginScreen()));
        return;
      }
      Navigator.of(context).popUntil((r) => r.isFirst);
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
    final auth = context.read<AuthState>();
    try {
      final r = widget.isEmail ? await auth.requestEmailCode(widget.phone) : await auth.requestOtp(widget.phone);
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
          Icon(widget.isEmail ? Icons.mark_email_read_rounded : Icons.sms_rounded, size: 56, color: Brand.primary),
          const SizedBox(height: 12),
          Text('Enter code', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(widget.isEmail ? 'We emailed a 6-digit code to ${widget.phone}' : 'We sent an SMS with a code to ${widget.phone}',
              textAlign: TextAlign.center),
          if (widget.isEmail) ...[
            const SizedBox(height: 6),
            const Text('Not in your inbox? Check the Spam / Promotions folder.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Brand.muted)),
          ],
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
                backgroundColor: Brand.primary,
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
  // Same ink background as the native launch screen, so start-up has no flash.
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: Brand.ink,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BrandMark(size: 96),
            SizedBox(height: 18),
            Text(AppConfig.appName, style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
            SizedBox(height: 6),
            Text('Fast · Private · Beautiful', style: TextStyle(color: Color(0x99FFFFFF), fontSize: 13, letterSpacing: 0.4)),
          ]),
        ),
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
                  Icon(icon, size: 64, color: Brand.primary),
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


// ------------------------------------------------------------------ two-step verification
class PasswordLoginScreen extends StatefulWidget {
  const PasswordLoginScreen({super.key});

  @override
  State<PasswordLoginScreen> createState() => _PasswordLoginScreenState();
}

class _PasswordLoginScreenState extends State<PasswordLoginScreen> {
  final _pw = TextEditingController();
  bool _busy = false;
  bool _show = false;

  Future<void> _submit() async {
    if (_pw.text.isEmpty) return;
    setState(() => _busy = true);
    try {
      await context.read<AuthState>().verifyPassword(_pw.text);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'login_expired') {
        showInfo(context, e.message);
        Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      showInfo(context, e.message);
      _pw.clear();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final auth = context.read<AuthState>();
    final ok = await confirm(
      context,
      'Reset password?',
      'For your security, the password will be removed after 7 days. If you remember it before then, just log in with it — or cancel the reset from a device where you are logged in.',
      ok: 'Reset',
    );
    if (!ok) return;
    try {
      final until = await auth.requestPasswordReset();
      if (mounted && until != null) {
        showInfo(context, 'Reset requested. You can log in without the password after ${until.day}/${until.month}/${until.year}.');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ch = context.watch<AuthState>().passwordChallenge ?? const {};
    final hint = '${ch['hint'] ?? ''}';
    final pending = ch['reset_pending_until'] as String?;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(24), children: [
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(color: Brand.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: const Icon(Icons.lock_rounded, color: Brand.primary, size: 40),
            ),
          ),
          const SizedBox(height: 18),
          Text('Two-step verification', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('Your account is protected with an extra password. Enter it to finish logging in.', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          TextField(
            controller: _pw,
            autofocus: true,
            obscureText: !_show,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              helperText: hint.isEmpty ? null : 'Hint: $hint',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _show = !_show)),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Log in'),
          ),
          const SizedBox(height: 8),
          if (pending != null)
            Text('Password reset requested — it will be removed on ${DateTime.parse(pending).toLocal().toString().substring(0, 10)}.',
                textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor))
          else
            TextButton(onPressed: _forgot, child: const Text('Forgot password?')),
        ]),
      ),
    );
  }
}
