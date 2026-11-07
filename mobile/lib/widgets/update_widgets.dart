import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../core/updater.dart';
import '../theme/brand.dart';
import '../utils/format.dart';

/// Thin bar at the top of the chat list while a newer Hushavia is ready. It also does the checking:
/// on start and whenever the app comes back to the screen (at most every 3 hours).
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> with WidgetsBindingObserver {
  bool _forcedShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // a few seconds after start: never slows the first screen
    Future<void>.delayed(const Duration(seconds: 4), _check);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (!mounted) return;
    final i = await AppUpdater.instance.check(context.read<AppServices>().api);
    if (!mounted || i == null || !i.available || !i.force || _forcedShown) return;
    _forcedShown = true;
    await showUpdateSheet(context);
    _forcedShown = false;
  }

  @override
  Widget build(BuildContext context) {
    final up = AppUpdater.instance;
    return ListenableBuilder(
      listenable: up,
      builder: (context, _) {
        if (!up.hasUpdate) return const SizedBox.shrink();
        final busy = up.stage == UpdateStage.downloading || up.stage == UpdateStage.verifying;
        return Material(
          color: Brand.primary,
          child: InkWell(
            onTap: () => showUpdateSheet(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(children: [
                const Icon(Icons.system_update_rounded, color: Colors.white, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    busy ? 'Downloading Hushavia ${up.info!.version}… ${(up.progress * 100).round()}%' : 'Hushavia ${up.info!.version} is ready — tap to update',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
                if (busy)
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white, value: up.progress > 0 ? up.progress : null))
                else
                  const Icon(Icons.chevron_right_rounded, color: Colors.white),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// "What's new" + Update button with live progress. Dismissible unless the update is required.
Future<void> showUpdateSheet(BuildContext context) {
  final up = AppUpdater.instance;
  final force = up.info?.force == true;
  return showModalBottomSheet<void>(
    context: context,
    isDismissible: !force,
    enableDrag: !force,
    showDragHandle: !force,
    isScrollControlled: true,
    builder: (ctx) => PopScope(
      canPop: !force,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: up,
          builder: (ctx, _) {
            final i = up.info;
            if (i == null) return const SizedBox(height: 120);
            final busy = up.stage == UpdateStage.downloading || up.stage == UpdateStage.verifying;
            return Padding(
              padding: EdgeInsets.fromLTRB(24, force ? 24 : 0, 24, 20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(gradient: Brand.heroGradient, borderRadius: BorderRadius.circular(20)),
                    child: const Icon(Icons.rocket_launch_rounded, color: Colors.white, size: 32),
                  ),
                ),
                const SizedBox(height: 14),
                Text(force ? 'Please update Hushavia' : 'New Hushavia is here',
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('Version ${i.version}${i.size > 0 ? ' · ${fileSize(i.size)}' : ''}',
                    textAlign: TextAlign.center, style: const TextStyle(color: Brand.muted)),
                if (i.notes.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Brand.primary.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(12)),
                    child: Text(i.notes),
                  ),
                ],
                if (force) ...[
                  const SizedBox(height: 10),
                  const Text('This version of the app is too old to keep working.', textAlign: TextAlign.center, style: TextStyle(color: Brand.muted)),
                ],
                const SizedBox(height: 18),
                if (busy) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(minHeight: 8, value: up.stage == UpdateStage.verifying ? null : up.progress),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    up.stage == UpdateStage.verifying
                        ? 'Checking the download…'
                        : 'Downloading… ${(up.progress * 100).round()}%${i.size > 0 ? ' of ${fileSize(i.size)}' : ''}',
                    textAlign: TextAlign.center,
                  ),
                  TextButton(onPressed: up.cancel, child: const Text('Cancel')),
                ] else ...[
                  if (up.error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(up.error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
                    ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                    onPressed: up.downloadAndInstall,
                    icon: Icon(up.stage == UpdateStage.ready ? Icons.install_mobile_rounded : Icons.download_rounded),
                    label: Text(up.stage == UpdateStage.ready ? 'Install' : 'Update now'),
                  ),
                  if (!force)
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
                ],
              ]),
            );
          },
        ),
      ),
    ),
  );
}
