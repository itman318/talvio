import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import '../theme/brand.dart';

/// Talvio's emoji category bar: rounded chips, the active one in the aurora gradient, backspace at the end.
class PremiumEmojiCategoryBar extends StatefulWidget {
  const PremiumEmojiCategoryBar(this.config, this.state, this.tabController, this.pageController, {super.key});
  final Config config;
  final EmojiViewState state;
  final TabController tabController;
  final PageController pageController;

  @override
  State<PremiumEmojiCategoryBar> createState() => _PremiumEmojiCategoryBarState();
}

class _PremiumEmojiCategoryBarState extends State<PremiumEmojiCategoryBar> {
  @override
  void initState() {
    super.initState();
    widget.tabController.addListener(_changed);
  }

  @override
  void dispose() {
    widget.tabController.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cats = widget.state.categoryEmoji;
    final sel = widget.tabController.index;
    return Container(
      height: 48,
      color: widget.config.categoryViewConfig.backgroundColor,
      padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
      child: Row(children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: dark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF1F2F7),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.all(3),
            child: Row(children: [
              for (var i = 0; i < cats.length; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      widget.tabController.animateTo(i);
                      widget.pageController.jumpToPage(i);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      decoration: BoxDecoration(
                        gradient: i == sel ? Brand.aurora : null,
                        borderRadius: BorderRadius.circular(11),
                        boxShadow: i == sel ? [BoxShadow(color: Brand.rose.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 2))] : null,
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        getIconForCategory(widget.config.categoryViewConfig.categoryIcons, cats[i].category),
                        size: 19,
                        color: i == sel ? Colors.white : (dark ? Colors.white54 : Brand.muted),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 40,
          child: IconButton(
            tooltip: 'Delete',
            padding: EdgeInsets.zero,
            icon: Icon(Icons.backspace_rounded, size: 21, color: dark ? Colors.white60 : Brand.muted),
            onPressed: () => widget.state.onBackspacePressed?.call(),
          ),
        ),
      ]),
    );
  }
}
