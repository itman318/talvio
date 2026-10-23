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

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (!hasTali(text)) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    return TextSpan(style: style, children: taliSpans(text, style, scale: 1.25));
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
