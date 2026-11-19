import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'coins_screen.dart' show CoinsScreen, fmtCoins;

/// Promote a public channel with coins: it shows first in Explore channels (marked "Promoted") for N days.
Future<void> showChannelBoost(BuildContext context, Chat chat) async {
  final api = context.read<AppServices>().api;
  Map<String, dynamic> info;
  try {
    info = Map<String, dynamic>.from(await api.get('/chats/${chat.id}/boost') as Map);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;
  final options = [for (final o in info['options'] as List) Map<String, dynamic>.from(o as Map)];
  var pick = options.length > 2 ? 2 : 0;
  var busy = false;
  final until = DateTime.tryParse('${info['promoted_until'] ?? ''}')?.toLocal();
  final public = info['public'] == true;

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final o = options[pick];
        final cost = (o['coins'] as num).toInt();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(colors: [Color(0xFF6D4AFF), Color(0xFF2FBFA8)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                ),
                child: Row(children: [
                  const Icon(Icons.rocket_launch_rounded, color: Colors.white, size: 34),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Promote channel', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text(
                        until != null && until.isAfter(DateTime.now())
                            ? 'Promoted until ${shortDate(until)} — more days are added on top'
                            : 'Show ${chat.title} first in Explore channels',
                        style: const TextStyle(color: Colors.white, height: 1.3),
                      ),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              if (!public)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('Give the channel a public @link first — only public channels can be promoted.', style: TextStyle(color: Brand.rose)),
                ),
              const Text('How long?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (var i = 0; i < options.length; i++)
                  ChoiceChip(
                    label: Text('${options[i]['days']} day${options[i]['days'] == 1 ? '' : 's'}'),
                    selected: pick == i,
                    onSelected: (_) => set(() => pick = i),
                  ),
              ]),
              const SizedBox(height: 14),
              const Text(
                '• Shown at the top of Explore channels with a “Promoted” label\n'
                '• A few promoted channels take turns at the top\n'
                '• Paid once from your coins — no subscription',
                style: TextStyle(color: Brand.muted, height: 1.5),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy || !public
                    ? null
                    : () async {
                        set(() => busy = true);
                        try {
                          final r = Map<String, dynamic>.from(
                              await api.post('/chats/${chat.id}/boost', {'days': o['days'], 'expected_coins': cost}) as Map);
                          if (ctx.mounted) Navigator.pop(ctx);
                          final end = DateTime.tryParse('${r['promoted_until']}')?.toLocal();
                          if (context.mounted) showInfo(context, 'Promoted${end == null ? '' : ' until ${shortDate(end)}'} 🚀');
                        } catch (e) {
                          set(() => busy = false);
                          if (!ctx.mounted) return;
                          if ('$e'.contains('enough coins')) {
                            final buy = await confirm(ctx, 'Not enough coins', 'Promoting for ${o['days']} days costs ${fmtCoins(cost)} coins.', ok: 'Get coins');
                            if (buy && ctx.mounted) Navigator.push(ctx, MaterialPageRoute(builder: (_) => const CoinsScreen()));
                          } else {
                            showError(ctx, e);
                          }
                        }
                      },
                icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.rocket_launch_rounded, size: 19),
                label: Text('Promote for ${fmtCoins(cost)} coins 🪙'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: const StadiumBorder()),
              ),
            ]),
          ),
        );
      },
    ),
  );
}
