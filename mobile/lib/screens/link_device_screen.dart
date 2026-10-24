import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/api_client.dart';
import '../core/services.dart';
import '../utils/format.dart';
import 'qr_screens.dart';
import 'user_profile_screen.dart';

/// Settings → Devices → Link a device: scan the QR code shown on chat.example.com/web.
class LinkDeviceScreen extends StatefulWidget {
  const LinkDeviceScreen({super.key, this.anyCode = false});

  /// Also accept profile QR codes (talvio://u/<id>) — the general "Scan QR code" screen.
  final bool anyCode;

  @override
  State<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends State<LinkDeviceScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    String? raw;
    for (final b in capture.barcodes) {
      final v = b.rawValue ?? '';
      if (v.startsWith('talvio://login?token=')) raw = v;
      final uid = widget.anyCode ? profileIdFromLink(v) : null;
      if (uid != null) {
        _busy = true;
        await _controller.stop();
        if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => UserProfileScreen(userId: uid)));
        return;
      }
    }
    if (raw == null) return;
    setState(() => _busy = true);
    await _controller.stop();
    if (!mounted) return;
    final api = context.read<AppServices>().api;
    try {
      final info = Map<String, dynamic>.from(await api.post('/auth/qr/scan', {'token': raw}) as Map);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Log in on this computer?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${info['device_name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
            if (info['ip'] != null) Text('IP ${info['ip']}'),
            const SizedBox(height: 12),
            const Text('Only continue if you are logging in yourself. That computer will see all your chats (except vault chats).'),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Log in')),
          ],
        ),
      );
      if (ok == true) {
        await api.post('/auth/qr/approve', {'token': raw});
        if (mounted) {
          showInfo(context, 'Computer linked');
          Navigator.pop(context, true);
        }
      } else {
        await api.post('/auth/qr/decline', {'token': raw}).catchError((_) => null);
        if (mounted) Navigator.pop(context, false);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      showInfo(context, e.message);
      setState(() => _busy = false);
      await _controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = Uri.parse(AppConfig.serverUrl).host;
    return Scaffold(
      appBar: AppBar(title: Text(widget.anyCode ? 'Scan QR code' : 'Link a device')),
      body: Column(children: [
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            MobileScanner(controller: _controller, onDetect: _onDetect),
            Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(20)),
              ),
            ),
            if (_busy) const Center(child: CircularProgressIndicator()),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text('On your computer open  $host/web  and point your phone at the QR code.', textAlign: TextAlign.center),
        ),
      ]),
    );
  }
}
