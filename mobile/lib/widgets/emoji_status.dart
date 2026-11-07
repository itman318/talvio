import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../screens/premium_screens.dart' show showPlusFeature;
import '../state/auth_state.dart';
import '../theme/brand.dart';

/// The emoji next to someone's name (nothing when they have none).
/// Plus members' status glows softly where it is shown large (profile, chat header).
class EmojiStatusBadge extends StatelessWidget {
  const EmojiStatusBadge(this.user, {super.key, this.size = 16, this.padLeft = 4});
  final AppUser? user;
  final double size;
  final double padLeft;

  @override
  Widget build(BuildContext context) {
    final e = user?.statusEmoji;
    if (e == null) return const SizedBox.shrink();
    final text = Text(e, style: TextStyle(fontSize: size, height: 1.1));
    return Padding(
      padding: EdgeInsets.only(left: padLeft),
      child: user!.isPremium && size >= 18 ? _Glow(child: text) : text,
    );
  }
}

class _Glow extends StatefulWidget {
  const _Glow({required this.child});
  final Widget child;

  @override
  State<_Glow> createState() => _GlowState();
}

class _GlowState extends State<_Glow> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (_, child) {
          final t = Curves.easeInOut.transform(_c.value);
          return Transform.scale(
            scale: 1 + 0.08 * t,
            child: DecoratedBox(
              decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
                BoxShadow(color: const Color(0xFFFFC94D).withValues(alpha: 0.25 + 0.35 * t), blurRadius: 10 + 8 * t),
              ]),
              child: child,
            ),
          );
        },
      );
}

/// Statuses only Hushavia Plus members can wear (same list on the server).
const plusStatuses = ['💠', '🪐', '🦋', '🐉', '🦄', '🌟', '🔮', '🪷', '🏵️', '🎖️', '🥇', '💫', '🌌', '🧿', '🕊️', '🫧'];

const _groups = <String, List<String>>{
  '⭐ Plus': plusStatuses,
  'Mood': ['😀', '😎', '🥳', '😴', '🤒', '🤔', '😇', '🤩', '😡', '🥲', '😌', '🫡', '🤯', '🥶', '🤫', '😈'],
  'Busy': ['💼', '💻', '📚', '✍️', '📞', '🎧', '🚗', '✈️', '🏋️', '🏃', '🍽️', '☕', '🕌', '🛌', '🎮', '🔕'],
  'Vibes': ['🔥', '⭐', '💎', '🚀', '❤️', '💯', '⚡', '🌙', '☀️', '🌈', '🍀', '🎯', '👑', '🏆', '💰', '📈'],
  'Places': ['🇵🇰', '🇸🇦', '🇦🇪', '🇬🇧', '🇺🇸', '🇹🇷', '🏖️', '🏔️', '🏠', '🏢', '🎓', '🏏', '⚽', '🎬', '🎵', '📸'],
};

const _durations = <String, Duration?>{
  'Until I change it': null,
  '1 hour': Duration(hours: 1),
  '8 hours': Duration(hours: 8),
  '1 day': Duration(days: 1),
  '2 days': Duration(days: 2),
  '1 week': Duration(days: 7),
};

/// Pick (or remove) my emoji status.
Future<void> showEmojiStatusPicker(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _Picker(),
  );
}

class _Picker extends StatefulWidget {
  const _Picker();

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  String _duration = 'Until I change it';
  bool _busy = false;

  Future<void> _set(String? emoji) async {
    if (_busy) return;
    if (emoji != null && plusStatuses.contains(emoji) && context.read<AuthState>().me?.limits?['plus_status'] != true) {
      await showPlusFeature(context,
          icon: Icons.auto_awesome_rounded,
          title: 'Plus statuses ✨',
          text: 'Rare emoji statuses that glow next to your name — only for Hushavia Plus members.');
      return;
    }
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AuthState>().setEmojiStatus(emoji, duration: _durations[_duration]);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = context.watch<AuthState>().me?.statusEmoji;
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Row(children: [
              const Expanded(child: Text('Emoji status', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
              if (current != null)
                TextButton.icon(
                  onPressed: _busy ? null : () => _set(null),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Remove'),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text('Shown next to your name everywhere in Hushavia.', style: TextStyle(color: muted, fontSize: 13)),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final d in _durations.keys)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(d),
                      selected: _duration == d,
                      onSelected: (_) => setState(() => _duration = d),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 16), children: [
              for (final g in _groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
                  child: Text(g.key.toUpperCase(), style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                ),
                GridView.count(
                  crossAxisCount: 8,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    for (final e in g.value)
                      InkWell(
                        key: ValueKey(e),
                        borderRadius: BorderRadius.circular(12),
                        onTap: _busy ? null : () => _set(e),
                        child: Container(
                          alignment: Alignment.center,
                          decoration: e == current
                              ? BoxDecoration(color: Brand.primary.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12))
                              : null,
                          child: Text(e, style: const TextStyle(fontSize: 26)),
                        ),
                      ),
                  ],
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
