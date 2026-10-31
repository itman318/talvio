import 'package:flutter/material.dart';

/// Talvio custom emoji ("Tali the Fox" faces). Each is one Private Use Area character
/// (U+E900 + index), so it takes exactly one character in text and in the input field.
/// Other apps / notifications show it as 🦊.
const taliNames = [
  'hello', 'love', 'laugh', 'thanks', 'like', 'wow', 'cry', 'angry', 'sleepy', 'cool',
  'party', 'think', 'coffee', 'kiss', 'shy', 'starstruck', 'gift', 'please', 'busy', 'king',
];

const _base = 0xE900;

String taliChar(int i) => String.fromCharCode(_base + i);
bool isTaliRune(int r) => r >= _base && r < _base + taliNames.length;
String taliAsset(int rune) => 'assets/emoji/tali/${taliNames[rune - _base]}.png';

final _taliRe = RegExp('[-]');
bool hasTali(String s) => _taliRe.hasMatch(s);

/// Replaces custom emoji with 🦊 (chat list previews, notifications, copy).
String taliToPlain(String s) => s.replaceAll(_taliRe, '🦊');

/// True when the text is just 1–3 custom emoji (shown big, without a bubble look).
bool isOnlyTali(String s) {
  final t = s.replaceAll(RegExp(r'\s'), '');
  if (t.isEmpty || t.runes.length > 3) return false;
  return t.runes.every(isTaliRune);
}

/// Splits [text] into spans, turning custom emoji into inline images sized to the text.
List<InlineSpan> taliSpans(String text, TextStyle? style, {double scale = 1.3}) {
  if (!hasTali(text)) return [TextSpan(text: text, style: style)];
  final size = (style?.fontSize ?? 15) * scale;
  final out = <InlineSpan>[];
  final buf = StringBuffer();
  for (final r in text.runes) {
    if (isTaliRune(r)) {
      if (buf.isNotEmpty) {
        out.add(TextSpan(text: buf.toString(), style: style));
        buf.clear();
      }
      out.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Image.asset(taliAsset(r), width: size, height: size, filterQuality: FilterQuality.medium),
      ));
    } else {
      buf.writeCharCode(r);
    }
  }
  if (buf.isNotEmpty) out.add(TextSpan(text: buf.toString(), style: style));
  return out;
}

/// The message field: shows custom emoji as pictures while typing.
class EmojiTextController extends TextEditingController {
  EmojiTextController({super.text});

  /// **bold**, _italic_, ~strike~, `code`, ||spoiler||: what you see in the box is already formatted —
  /// the marker characters are kept (that's how the message is sent) but drawn invisible.
  static final _fmt = RegExp(r'(\*\*)(.+?)(\*\*)|(\|\|)(.+?)(\|\|)|(`)([^`\n]+?)(`)|(~)([^~\n]+?)(~)|(?<![\w_])(_)([^_\n]+?)(_)(?![\w_])', dotAll: true);

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final hasFmt = _fmt.hasMatch(text);
    if (!hasFmt && !hasTali(text)) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    if (!hasFmt) return TextSpan(style: style, children: taliSpans(text, style, scale: 1.25));
    final base = style ?? const TextStyle();
    final hidden = base.copyWith(color: Colors.transparent, fontSize: 0.1, letterSpacing: 0);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _fmt.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start), style: base));
      String open, body, close;
      TextStyle st;
      if (m[1] != null) {
        (open, body, close) = (m[1]!, m[2]!, m[3]!);
        st = base.copyWith(fontWeight: FontWeight.w800);
      } else if (m[4] != null) {
        (open, body, close) = (m[4]!, m[5]!, m[6]!);
        st = base.copyWith(backgroundColor: dark ? Colors.white24 : const Color(0x332B2F45));
      } else if (m[7] != null) {
        (open, body, close) = (m[7]!, m[8]!, m[9]!);
        st = base.copyWith(fontFamily: 'monospace', backgroundColor: dark ? Colors.white12 : const Color(0x14000000));
      } else if (m[10] != null) {
        (open, body, close) = (m[10]!, m[11]!, m[12]!);
        st = base.copyWith(decoration: TextDecoration.lineThrough);
      } else {
        (open, body, close) = (m[13]!, m[14]!, m[15]!);
        st = base.copyWith(fontStyle: FontStyle.italic);
      }
      spans.add(TextSpan(text: open, style: hidden));
      spans.add(TextSpan(text: body, style: st));
      spans.add(TextSpan(text: close, style: hidden));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last), style: base));
    return TextSpan(style: base, children: spans);
  }

  /// Inserts [s] at the cursor (or at the end).
  void insert(String s) {
    final sel = selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    value = TextEditingValue(
      text: text.replaceRange(start, end, s),
      selection: TextSelection.collapsed(offset: start + s.length),
    );
  }
}

/// Row of Tali emoji above the normal emoji keyboard.
class TaliEmojiStrip extends StatelessWidget {
  const TaliEmojiStrip({super.key, required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: taliNames.length,
        itemBuilder: (_, i) => InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onPick(taliChar(i)),
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Image.asset('assets/emoji/tali/${taliNames[i]}.png', width: 40, height: 40),
          ),
        ),
      ),
    );
  }
}


/// Message text without the formatting marks (for reply quotes, previews and notifications).
String stripFormatting(String t) => t
    .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*', dotAll: true), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'\|\|(.+?)\|\|', dotAll: true), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'`([^`\n]+?)`'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'~([^~\n]+?)~'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'(?<![\w_])_([^_\n]+?)_(?![\w_])'), (m) => m[1]!);
