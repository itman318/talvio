/// Safety check for messages from people who are NOT in my contacts: the usual tricks
/// (asking for a code, for money, "you won a prize", unknown links) get a warning under the message.
/// Everything is checked on the phone — nothing is sent anywhere.
enum ScamKind { code, money, prize, link }

class ScamGuard {
  ScamGuard._();

  static final _code = RegExp(
    r'\b(otp|o\.t\.p|verification code|verify code|login code|security code|pin code|atm pin|cvv|cvc|card number|card no)\b'
    r'|\b(code|pin|otp|password)\b.{0,25}\b(bhej\w*|bata\w*|send|share|forward|tell|give|dein|dedo|de do|do)\b'
    r'|\b(send|share|tell|give|forward|bhej\w*|bata\w*)\b.{0,25}\b(code|pin|otp|password)\b',
    caseSensitive: false,
  );
  static const _codeUrdu = ['کوڈ', 'او ٹی پی', 'پاس ورڈ', 'پاسورڈ'];

  static final _money = RegExp(
    r'\b(easypaisa|easy paisa|jazzcash|jazz cash|sadapay|nayapay|raast|iban|western union|usdt|bitcoin|binance|crypto)\b'
    r'|\b(send|transfer|bhej\w*|daal\w*|jama)\b.{0,25}\b(money|paise|paisay|pese|paisa|rupay|rupees|rs|pkr|amount|raqam|fees?|balance|load)\b'
    r'|\b(money|paise|paisay|pese|rupay|rupees|raqam|fees?|load|balance)\b.{0,25}\b(bhej\w*|send|transfer|chahiye|chahye|urgent|udhar|qarz)\b'
    r'|\b(invest\w*|double (your )?money|guaranteed profit|daily profit|processing fee|registration fee|advance payment|loan approved|udhar|qarz)\b',
    caseSensitive: false,
  );
  static const _moneyUrdu = ['پیسے', 'پیسہ', 'رقم', 'ایزی پیسہ', 'جاز کیش', 'ادھار', 'قرض'];

  static final _prize = RegExp(
    r'\b(lottery|lucky draw|prize|inaam|inam|winner|you (have )?won|jeet (gaye|gae|liya|chuke)|bisp|benazir|ehsaas|8171|jeeto pakistan|kbc'
    r'|free (gift|laptop|mobile|recharge|data|balance))\b',
    caseSensitive: false,
  );
  static const _prizeUrdu = ['انعام', 'لاٹری', 'قرعہ اندازی', 'بینظیر', 'احساس پروگرام'];

  static final _link = RegExp(
    r'(https?://|www\.)\S+|\b[\w-]+\.(com|net|org|pk|xyz|top|info|link|ly|me|co|io|app|site|online|shop|live|click)\b',
    caseSensitive: false,
  );

  /// What a message from a stranger looks like, or null when nothing stands out.
  static ScamKind? check(String text) {
    if (text.length < 3) return null;
    bool has(List<String> words) => words.any(text.contains);
    if (_code.hasMatch(text) || has(_codeUrdu)) return ScamKind.code;
    if (_money.hasMatch(text) || has(_moneyUrdu)) return ScamKind.money;
    if (_prize.hasMatch(text) || has(_prizeUrdu)) return ScamKind.prize;
    if (_link.hasMatch(text)) return ScamKind.link;
    return null;
  }

  /// True when what I am about to send looks like a login / bank code (4–8 digits).
  static bool looksLikeCode(String text) {
    final t = text.trim();
    if (t.length > 60) return false;
    final digits = t.replaceAll(RegExp(r'[\s-]'), '');
    if (RegExp(r'^\d{4,8}$').hasMatch(digits)) return true;
    return RegExp(r'\b(otp|code|pin)\b', caseSensitive: false).hasMatch(t) && RegExp(r'\d{4,8}').hasMatch(digits);
  }

  static String title(ScamKind k) => switch (k) {
        ScamKind.code => 'Never share codes or PINs',
        ScamKind.money => 'Careful with money requests',
        ScamKind.prize => 'This may be a fake prize',
        ScamKind.link => 'Link from someone you don’t know',
      };

  static String tip(ScamKind k) => switch (k) {
        ScamKind.code =>
          'No real company, bank or Hushavia will ever ask for your code, PIN or password in a chat. Anyone who has it can take over your account or your money.',
        ScamKind.money =>
          'This person is not in your contacts. Scammers often pretend to be a relative, a friend or an office. Call the person on their real number before you send anything.',
        ScamKind.prize =>
          'You can’t win a lottery you never entered. Fake prizes and “support programmes” ask for a fee or your details first — then disappear.',
        ScamKind.link =>
          'Links from strangers can lead to fake login pages or harmful apps. Open it only if you were expecting it.',
      };
}
