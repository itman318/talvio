import 'package:flutter/material.dart';

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
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: muted ? null : Brand.aurora,
        color: muted ? Brand.faint : null,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(count > 999 ? '999+' : '$count', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
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
  });
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final String? trailing;
  final VoidCallback? onTap;
  final bool danger;

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
                  child: Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                ),
            ]),
          ),
          if (trailing != null) Text(trailing!, style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant)),
          if (onTap != null && !danger) Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
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
