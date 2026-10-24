import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'avatar.dart';

import '../theme/brand.dart';

/// Shared "premium" building blocks: gradient buttons, grouped settings cards, empty states.

/// Main call-to-action button with the Aurora gradient and a soft glow.
class AuroraButton extends StatelessWidget {
  const AuroraButton({super.key, required this.label, required this.onPressed, this.icon, this.busy = false, this.height = 52});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: enabled || busy ? 1 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: Brand.aurora,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Brand.rose.withValues(alpha: 0.32), blurRadius: 18, offset: const Offset(0, 8))],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: enabled ? onPressed : null,
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: Center(
                child: busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        if (icon != null) ...[Icon(icon, color: Colors.white, size: 20), const SizedBox(width: 8)],
                        Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15.5, letterSpacing: 0.1)),
                      ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Round gradient floating button.
class AuroraFab extends StatelessWidget {
  const AuroraFab({super.key, required this.icon, required this.onPressed, this.tooltip});
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = DecoratedBox(
      decoration: BoxDecoration(
        gradient: Brand.aurora,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Brand.rose.withValues(alpha: 0.4), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onPressed,
          child: SizedBox(width: 60, height: 60, child: Icon(icon, color: Colors.white, size: 26)),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// Gradient pill with a number (unread counters).
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, this.muted = false});
  final int count;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        gradient: muted ? null : Brand.aurora,
        color: muted ? Brand.faint : null,
        borderRadius: BorderRadius.circular(11),
      ),
      // widthFactor 1: the pill hugs the number (never stretches to fill a ListTile)
      child: Center(
        widthFactor: 1,
        child: Text(count > 999 ? '999+' : '$count', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

/// A rounded card holding a group of settings rows (iOS-style inset grouped list).
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, required this.children});
  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) rows.add(Divider(height: 1, indent: 62, color: dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFEDEFF5)));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
            child: Text(title!.toUpperCase(),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            boxShadow: dark ? null : [BoxShadow(color: Brand.ink.withValues(alpha: 0.05), blurRadius: 16, offset: const Offset(0, 4))],
            border: dark ? Border.all(color: Colors.white.withValues(alpha: 0.05)) : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: rows),
        ),
      ]),
    );
  }
}

/// One settings row: coloured rounded icon tile, title, optional subtitle and trailing text.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
    this.trailingWidget,
    this.maxSubtitleLines = 2,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final String? trailing;
  final VoidCallback? onTap;
  final bool danger;
  final Widget? trailingWidget;
  final int maxSubtitleLines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: LinearGradient(
                colors: [Color.lerp(color, Colors.white, 0.18)!, color],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 19),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: danger ? Colors.red : scheme.onSurface)),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(subtitle!, maxLines: maxSubtitleLines, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                ),
            ]),
          ),
          if (trailing != null) Text(trailing!, style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant)),
          if (trailingWidget != null) Padding(padding: const EdgeInsets.only(left: 8), child: trailingWidget!),
          if (onTap != null && !danger && trailingWidget == null) Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
        ]),
      ),
    );
  }
}

/// Friendly empty screen with a Tali emoji.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.tali, required this.title, this.subtitle, this.action, this.onAction});
  final String tali; // name of a Tali emoji (assets/emoji/tali/<name>.png)
  final String title;
  final String? subtitle;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: Brand.auroraSoft(Theme.of(context).brightness == Brightness.dark)),
            padding: const EdgeInsets.all(14),
            child: Image.asset('assets/emoji/tali/$tali.png'),
          ),
          const SizedBox(height: 18),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4)),
          ],
          if (action != null && onAction != null) ...[
            const SizedBox(height: 20),
            SizedBox(width: 220, child: AuroraButton(label: action!, onPressed: onAction, height: 48)),
          ],
        ]),
      ),
    );
  }
}


/// Settings row with a switch on the right (the whole row toggles it).
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({super.key, required this.icon, required this.color, required this.title, this.subtitle, required this.value, required this.onChanged});
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SettingsTile(
        icon: icon,
        color: color,
        title: title,
        subtitle: subtitle,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailingWidget: Switch(value: value, onChanged: onChanged),
      );
}

/// Big profile header used by people, groups and channels: soft aurora backdrop (or the blurred photo),
/// ringed avatar (tap → full-screen photo), name with badges, a status line and equal-width action buttons.
class ProfileHero extends StatelessWidget {
  const ProfileHero({
    super.key,
    required this.id,
    required this.name,
    this.avatarUrl,
    this.status,
    this.statusColor,
    this.badges = const [],
    this.actions = const [],
    this.online = false,
    this.onAvatarTap,
    this.avatarBadge,
    this.topPadding = 0,
  });
  final int id;
  final String name;
  final String? avatarUrl;
  final String? status;
  final Color? statusColor;
  final List<Widget> badges;
  final List<ProfileAction> actions;
  final bool online;
  final VoidCallback? onAvatarTap;
  final Widget? avatarBadge;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final url = avatarUrl;
    return Stack(children: [
      // backdrop
      Positioned.fill(
        child: url == null
            ? DecoratedBox(decoration: BoxDecoration(gradient: Brand.auroraSoft(dark)))
            : ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36, tileMode: TileMode.decal),
                child: Opacity(opacity: dark ? 0.55 : 0.45, child: Image.network(url, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox())),
              ),
      ),
      // fade into the page
      Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [bg.withValues(alpha: 0), bg.withValues(alpha: 0.35), bg],
              stops: const [0, 0.6, 1],
            ),
          ),
        ),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(16, topPadding + 8, 16, 14),
        child: Column(children: [
          GestureDetector(
            onTap: onAvatarTap ?? (url == null ? null : () => showPhotoViewer(context, url, tag: 'avatar-$id')),
            child: Stack(clipBehavior: Clip.none, children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  gradient: Brand.aurora,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Brand.rose.withValues(alpha: 0.28), blurRadius: 28, offset: const Offset(0, 10))],
                ),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                  child: Hero(tag: 'avatar-$id', child: ClipOval(child: Avatar(id: id, name: name, url: url, size: 108))),
                ),
              ),
              if (online)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(color: Brand.accent, shape: BoxShape.circle, border: Border.all(color: bg, width: 3)),
                  ),
                ),
              if (avatarBadge != null) Positioned(right: 0, bottom: 0, child: avatarBadge!),
            ]),
          ),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Flexible(
              child: Text(name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800, letterSpacing: -0.6, height: 1.15)),
            ),
            ...badges.map((b) => Padding(padding: const EdgeInsets.only(left: 6), child: b)),
          ]),
          if (status != null) ...[
            const SizedBox(height: 5),
            Text(status!,
                textAlign: TextAlign.center,
                style: TextStyle(color: statusColor ?? Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600, fontSize: 14)),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 20),
            Row(children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: actions[i]),
              ],
            ]),
          ],
        ]),
      ),
    ]);
  }
}

/// One of the round-cornered action buttons under a profile header.
class ProfileAction extends StatelessWidget {
  const ProfileAction({super.key, required this.icon, required this.label, required this.onTap, this.highlight = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          height: 66,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: highlight ? Brand.aurora : null,
            color: highlight ? null : (dark ? Colors.white.withValues(alpha: 0.07) : Colors.white.withValues(alpha: 0.85)),
            border: highlight ? null : Border.all(color: dark ? Colors.white.withValues(alpha: 0.06) : Colors.white),
            boxShadow: [
              BoxShadow(
                color: highlight ? Brand.rose.withValues(alpha: 0.3) : Brand.ink.withValues(alpha: dark ? 0 : 0.06),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: highlight ? Colors.white : Brand.primary, size: 23),
            const SizedBox(height: 4),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: highlight ? Colors.white : Theme.of(context).colorScheme.onSurface)),
          ]),
        ),
      ),
    );
  }
}

/// Full-screen photo (pinch to zoom, tap or swipe down to close).
Future<void> showPhotoViewer(BuildContext context, String url, {String? tag}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, _, __) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: Colors.white),
      extendBodyBehindAppBar: true,
      body: GestureDetector(
        onTap: () => Navigator.pop(ctx),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0).abs() > 300) Navigator.pop(ctx);
        },
        child: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: tag == null ? Image.network(url) : Hero(tag: tag, child: Image.network(url)),
          ),
        ),
      ),
    ),
    transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
  ));
}


/// Square shortcut tile (Settings → My Notes, QR code, Theme, Devices).
class QuickTile extends StatelessWidget {
  const QuickTile({super.key, required this.icon, required this.label, required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          height: 78,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: dark ? Border.all(color: Colors.white.withValues(alpha: 0.05)) : null,
            boxShadow: dark ? null : [BoxShadow(color: Brand.ink.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                gradient: LinearGradient(colors: [Color.lerp(color, Colors.white, 0.2)!, color], begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
              child: Icon(icon, color: Colors.white, size: 19),
            ),
            const SizedBox(height: 6),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

/// Round gradient icon used as the leading of list rows (New group, New channel…).
class GradientIcon extends StatelessWidget {
  const GradientIcon(this.icon, {super.key, this.color = Brand.primary, this.size = 44});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.34),
          gradient: LinearGradient(colors: [Color.lerp(color, Colors.white, 0.2)!, color], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.48),
      );
}

/// Pulsing red dot while a voice message is recorded.
class RecordingDot extends StatefulWidget {
  const RecordingDot({super.key});

  @override
  State<RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<RecordingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: const Color(0xFFE5484D),
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: const Color(0xFFE5484D).withValues(alpha: 0.5), blurRadius: 8)],
          ),
        ),
      );
}

/// Live-looking sound bars while recording.
class RecordingWave extends StatefulWidget {
  const RecordingWave({super.key, this.color = Brand.primary});
  final Color color;

  @override
  State<RecordingWave> createState() => _RecordingWaveState();
}

class _RecordingWaveState extends State<RecordingWave> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, box) {
      final n = (box.maxWidth / 6).floor().clamp(0, 40);
      return AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            for (var i = 0; i < n; i++)
              Container(
                width: 3,
                height: 6 + 16 * (0.5 + 0.5 * math.sin(_c.value * math.pi * 2 + i * 0.7)) * (0.55 + 0.45 * math.sin(i * 1.7).abs()),
                margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(color: widget.color.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(2)),
              ),
          ],
        ),
      );
    });
  }
}

/// Three dots bouncing one after another ("typing…").
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color = Brand.primary, this.size = 4.5});
  final Color color;
  final double size;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: EdgeInsets.only(right: i < 2 ? widget.size * 0.6 : 0),
            child: Transform.translate(
              offset: Offset(0, -widget.size * 0.7 * _bounce((_c.value - i * 0.18) % 1)),
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(color: widget.color.withValues(alpha: 0.5 + 0.5 * _bounce((_c.value - i * 0.18) % 1)), shape: BoxShape.circle),
              ),
            ),
          ),
      ]),
    );
  }

  static double _bounce(double t) => t < 0.4 ? math.sin(math.pi * t / 0.4) : 0;
}

Future<void> showChatActions(BuildContext context, Chat chat) async {
  final store = context.read<ChatStore>();
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Wrap(children: [
        ListTile(
          leading: Icon(chat.isPinned ? Icons.push_pin_outlined : Icons.push_pin),
          title: Text(chat.isPinned ? 'Unpin' : 'Pin to top'),
          onTap: () => Navigator.pop(ctx, 'pin'),
        ),
        ListTile(
          leading: Icon(chat.unreadCount > 0 || chat.markedUnread ? Icons.mark_chat_read_outlined : Icons.mark_chat_unread_outlined),
          title: Text(chat.unreadCount > 0 || chat.markedUnread ? 'Mark as read' : 'Mark as unread'),
          onTap: () => Navigator.pop(ctx, 'unread'),
        ),
        ListTile(
          leading: Icon(chat.isMuted ? Icons.volume_up : Icons.volume_off),
          title: Text(chat.isMuted ? 'Unmute' : 'Mute notifications'),
          onTap: () => Navigator.pop(ctx, 'mute'),
        ),
        ListTile(
          leading: Icon(chat.isArchived ? Icons.unarchive : Icons.archive),
          title: Text(chat.isArchived ? 'Unarchive' : 'Archive'),
          onTap: () => Navigator.pop(ctx, 'archive'),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline, color: Colors.red),
          title: Text(chat.isChannel ? 'Leave channel' : (chat.isGroup ? 'Leave group' : 'Delete chat'), style: const TextStyle(color: Colors.red)),
          onTap: () => Navigator.pop(ctx, 'delete'),
        ),
      ]),
    ),
  );
  if (action == null || !context.mounted) return;
  try {
    switch (action) {
      case 'pin':
        await store.updateChatSettings(chat.id, {'is_pinned': !chat.isPinned});
        break;
      case 'mute':
        await store.updateChatSettings(chat.id, {'muted_until': chat.isMuted ? null : 'forever'});
        break;
      case 'unread':
        await store.setMarkedUnread(chat, !(chat.unreadCount > 0 || chat.markedUnread));
        break;
      case 'archive':
        await store.updateChatSettings(chat.id, {'is_archived': !chat.isArchived});
        break;
      case 'delete':
        final ok = await confirm(
          context,
          chat.isMulti ? 'Leave “${chat.title}”?' : 'Delete chat?',
          chat.isMulti ? 'You will stop receiving messages from “${chat.title}”.' : 'The chat history will be removed for you.',
          ok: chat.isMulti ? 'Leave' : 'Delete',
          danger: true,
        );
        if (ok) await store.leaveOrDelete(chat.id);
        break;
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class ArchivedChatsScreen extends StatefulWidget {
  const ArchivedChatsScreen({super.key});

  @override
  State<ArchivedChatsScreen> createState() => _ArchivedChatsScreenState();
}

class _ArchivedChatsScreenState extends State<ArchivedChatsScreen> {
  late Future<List<Chat>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<ChatStore>().loadArchived();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Archived chats')),
      body: FutureBuilder<List<Chat>>(
        future: _future,
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return snap.hasError ? Center(child: Text('${snap.error}')) : const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          if (list.isEmpty) return const Center(child: Text('No archived chats'));
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) => ListTile(
              leading: Avatar(id: list[i].id, name: list[i].title, url: list[i].avatarAbsolute),
              title: Text(list[i].title),
              subtitle: Text(list[i].lastMessage?.preview ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.unarchive),
                tooltip: 'Unarchive',
                onPressed: () async {
                  try {
                    await context.read<ChatStore>().updateChatSettings(list[i].id, {'is_archived': false});
                    if (mounted) setState(() => _future = context.read<ChatStore>().loadArchived());
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: list[i].id, initial: list[i]))),
            ),
          );
        },
      ),
    );
  }
}


/// Chats → Message requests.
class RequestsScreen extends StatelessWidget {
  const RequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final list = context.watch<ChatStore>().requests;
    return Scaffold(
      appBar: AppBar(title: const Text('Message requests')),
      body: list.isEmpty
          ? const EmptyState(tali: 'cool', title: 'No requests', subtitle: 'Messages from people who are not in your contacts wait here, without notifications.')
          : ListView(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Text('These people are not in your contacts. Open a chat to accept, block or delete it.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
              ),
              ...list.map((c) => ChatTile(chat: c)),
            ]),
    );
  }
}
