import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/voice_playback.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'media_widgets.dart' show speedLabel;

/// Thin bar under the app bar while a voice message plays (also after leaving the chat):
/// play/pause, who it's from, speed, close. Tap → [onOpen] (open that chat).
class VoiceMiniPlayer extends StatelessWidget {
  const VoiceMiniPlayer({super.key, this.onOpen});
  final void Function(int chatId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final vp = context.watch<VoicePlayback>();
    final m = vp.current;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: m == null
          ? const SizedBox(width: double.infinity)
          : Material(
              color: dark ? const Color(0xFF161A2E) : Colors.white,
              child: InkWell(
                onTap: onOpen == null ? null : () => onOpen!(m.chatId),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    height: 46,
                    child: Row(children: [
                      IconButton(
                        tooltip: vp.playing ? 'Pause' : 'Play',
                        icon: Icon(vp.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Brand.primary),
                        onPressed: () => vp.playing ? vp.pause() : vp.toggle(m),
                      ),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text(vp.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                          StreamBuilder<Duration>(
                            stream: vp.player.positionStream,
                            builder: (_, snap) => Text(
                              '${vp.earpiece ? 'Earpiece · ' : ''}Voice message · ${duration((snap.data ?? Duration.zero).inSeconds)}',
                              style: const TextStyle(fontSize: 11.5, color: Brand.muted),
                            ),
                          ),
                        ]),
                      ),
                      TextButton(
                        onPressed: vp.cycleSpeed,
                        style: TextButton.styleFrom(minimumSize: const Size(44, 32), padding: const EdgeInsets.symmetric(horizontal: 8)),
                        child: Text(speedLabel(vp.speed), style: const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded, size: 20, color: Brand.muted), onPressed: vp.stop),
                    ]),
                  ),
                  // progress line
                  StreamBuilder<Duration>(
                    stream: vp.player.positionStream,
                    builder: (_, snap) {
                      final total = vp.player.duration?.inMilliseconds ?? 0;
                      final f = total > 0 ? ((snap.data ?? Duration.zero).inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: f,
                          child: Container(height: 2, decoration: const BoxDecoration(gradient: Brand.aurora)),
                        ),
                      );
                    },
                  ),
                ]),
              ),
            ),
    );
  }
}
