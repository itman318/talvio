import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../state/auth_state.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import 'link_device_screen.dart';

/// talvio://u/<id> — the link inside a profile QR code.
String profileLink(int userId) => 'talvio://u/$userId';

/// Reads the user id from a profile link (QR code or talvio:// deep link).
int? profileIdFromLink(String s) {
  final m = RegExp(r'^talvio://u/(\d+)$').firstMatch(s.trim());
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Settings → My QR code: others scan it to open your profile and message you.
class MyQrScreen extends StatefulWidget {
  const MyQrScreen({super.key});

  @override
  State<MyQrScreen> createState() => _MyQrScreenState();
}

class _MyQrScreenState extends State<MyQrScreen> {
  static const _backs = [
    [Color(0xFFFF7A59), Color(0xFFF0446E), Color(0xFF8B5CF6)],
    [Color(0xFF1767CF), Color(0xFF3C9BEA), Color(0xFF5FD0E6)],
    [Color(0xFF0C8A64), Color(0xFF18B892), Color(0xFF8FF0D4)],
    [Color(0xFF151A2E), Color(0xFF2A3152), Color(0xFF59628F)],
    [Color(0xFFA9853F), Color(0xFFC9A45C), Color(0xFFE6C987)],
  ];
  int _back = 0;

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthState>().me;
    if (me == null) return const Scaffold();
    final colors = _backs[_back];
    final link = profileLink(me.id);
    return Scaffold(
      backgroundColor: colors.first,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('My QR code', style: TextStyle(color: Colors.white)),
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: SafeArea(
          child: Column(children: [
            const Spacer(),
            Center(
              child: SizedBox(
                width: 300,
                child: Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter, children: [
                  Container(
                    margin: const EdgeInsets.only(top: 44),
                    padding: const EdgeInsets.fromLTRB(24, 56, 24, 22),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 30, offset: const Offset(0, 12))],
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(me.name, textAlign: TextAlign.center, style: const TextStyle(color: Brand.ink, fontSize: 20, fontWeight: FontWeight.w800)),
                      if (me.username != null) Text('@${me.username}', style: const TextStyle(color: Brand.muted)),
                      const SizedBox(height: 14),
                      QrImageView(
                        data: link,
                        size: 220,
                        backgroundColor: Colors.white,
                        eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.circle, color: colors[1]),
                        dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Brand.ink),
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                      ),
                      const SizedBox(height: 8),
                      const Text('Scan with Talvio to message me', style: TextStyle(color: Brand.muted, fontSize: 13)),
                    ]),
                  ),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    child: ClipOval(child: Avatar(id: me.id, name: me.name, url: me.avatarAbsolute, size: 84)),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 24),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < _backs.length; i++)
                GestureDetector(
                  onTap: () => setState(() => _back = i),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: _backs[i]),
                      border: Border.all(color: Colors.white, width: i == _back ? 3 : 1.5),
                    ),
                  ),
                ),
            ]),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: Row(children: [
                Expanded(
                  child: _pill(Icons.qr_code_scanner_rounded, 'Scan', () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const LinkDeviceScreen(anyCode: true)));
                  }),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _pill(Icons.link_rounded, 'Copy link', () {
                    Clipboard.setData(ClipboardData(text: link));
                    showInfo(context, 'Link copied');
                  }),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _pill(IconData icon, String label, VoidCallback onTap) => Material(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: SizedBox(
            height: 52,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: Colors.white),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );
}
