import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../theme/brand.dart';

/// Telegram-style "Undo" bar: a ring counts down the seconds next to the message. The action
/// already happened on screen; [commit] runs (asks the server) only when the bar goes away
/// without Undo. [undo] puts everything back instantly.
void showUndoBar(
  BuildContext context, {
  required String text,
  IconData icon = Icons.delete_outline_rounded,
  required Future<void> Function() commit,
  required VoidCallback undo,
  Duration duration = const Duration(seconds: 5),
}) {
  final messenger = ScaffoldMessenger.of(context);
  var undone = false;
  messenger.hideCurrentSnackBar(); // an older bar commits right away
  final bar = messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    duration: duration,
    dismissDirection: DismissDirection.horizontal,
    padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
    content: Row(children: [
      _CountdownRing(duration: duration),
      const SizedBox(width: 12),
      Icon(icon, color: Colors.white70, size: 20),
      const SizedBox(width: 8),
      Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
    ]),
    action: SnackBarAction(
      label: 'UNDO',
      textColor: const Color(0xFFB9A8FF),
      onPressed: () {
        undone = true;
        undo();
      },
    ),
  ));
  bar.closed.then((_) async {
    if (undone) return;
    try {
      await commit();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e is ApiException ? e.message : 'Couldn’t finish that — please try again')));
    }
  });
}

class _CountdownRing extends StatelessWidget {
  const _CountdownRing({required this.duration});
  final Duration duration;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 1, end: 0),
        duration: duration,
        builder: (_, v, __) => SizedBox(
          width: 28,
          height: 28,
          child: Stack(alignment: Alignment.center, children: [
            CircularProgressIndicator(value: v, strokeWidth: 2.5, color: Brand.primary, backgroundColor: Colors.white12),
            Text('${(v * duration.inSeconds).ceil().clamp(1, duration.inSeconds)}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
          ]),
        ),
      );
}
