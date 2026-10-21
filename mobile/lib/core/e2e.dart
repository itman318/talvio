import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// End-to-end encryption for secret chats.
///
///  1. Each device makes a fresh X25519 key pair per secret chat; only public keys go to the server.
///  2. shared = X25519(myPrivate, theirPublic)
///     root  = HKDF-SHA256(shared, salt: "chatapp-secret:<chatId>", info: "chatapp-secret-v1", 64 bytes)
///     two chain keys: initiator→peer = root[0..32], peer→initiator = root[32..64]
///  3. Symmetric ratchet per message:  messageKey = HMAC(chainKey, 0x01), chainKey = HMAC(chainKey, 0x02)
///     (old keys are forgotten → past messages stay safe if a phone is later compromised)
///  4. Each message: AES-256-GCM(messageKey, random 12-byte nonce, AAD = "<chatId>:<n>:<direction>")
///  5. Key fingerprint = SHA-256(shared ‖ initiatorPublic ‖ peerPublic) — compare emoji on both phones.
class E2E {
  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _hmac = Hmac.sha256();
  static final _rand = Random.secure();

  static Uint8List randomBytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => _rand.nextInt(256)));

  /// New key pair → (privateB64, publicB64).
  static Future<(String, String)> newKeyPair() async {
    final kp = await _x25519.newKeyPair();
    final priv = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();
    return (base64Encode(priv), base64Encode(pub.bytes));
  }

  /// Derives the two chain keys and the fingerprint once both public keys are known.
  static Future<SecretKeys> derive({
    required int chatId,
    required bool isInitiator,
    required String myPrivate,
    required String myPublic,
    required String theirPublic,
  }) async {
    final kp = SimpleKeyPairData(
      base64Decode(myPrivate),
      publicKey: SimplePublicKey(base64Decode(myPublic), type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: SimplePublicKey(base64Decode(theirPublic), type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    final root = await Hkdf(hmac: _hmac, outputLength: 64).deriveKey(
      secretKey: SecretKey(sharedBytes),
      nonce: utf8.encode('chatapp-secret:$chatId'),
      info: utf8.encode('chatapp-secret-v1'),
    );
    final r = await root.extractBytes();
    final i2p = r.sublist(0, 32);
    final p2i = r.sublist(32, 64);
    final initiatorPub = isInitiator ? myPublic : theirPublic;
    final peerPub = isInitiator ? theirPublic : myPublic;
    final fp = await Sha256().hash([...sharedBytes, ...base64Decode(initiatorPub), ...base64Decode(peerPub)]);
    return SecretKeys(
      sendChain: base64Encode(isInitiator ? i2p : p2i),
      recvChain: base64Encode(isInitiator ? p2i : i2p),
      fingerprint: base64Encode(fp.bytes),
    );
  }

  static Future<(List<int> messageKey, List<int> nextChain)> _step(List<int> chain) async {
    final mk = await _hmac.calculateMac([1], secretKey: SecretKey(chain));
    final ck = await _hmac.calculateMac([2], secretKey: SecretKey(chain));
    return (mk.bytes, ck.bytes);
  }

  /// Encrypts [plain] with the next sending key. Mutates [state] (persist it BEFORE sending).
  static Future<String> encrypt(RatchetState state, Map<String, dynamic> plain) async {
    final n = state.sendN;
    final (mk, next) = await _step(base64Decode(state.sendChain));
    state.sendChain = base64Encode(next);
    state.sendN = n + 1;
    final nonce = randomBytes(12);
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(plain)),
      secretKey: SecretKey(mk),
      nonce: nonce,
      aad: utf8.encode('${state.chatId}:$n:${state.isInitiator ? 'i' : 'p'}'),
    );
    final env = {'v': 1, 'n': n, 'iv': base64Encode(nonce), 'ct': base64Encode([...box.cipherText, ...box.mac.bytes])};
    return base64Encode(utf8.encode(jsonEncode(env)));
  }

  /// Decrypts a message from the other device. Returns null for duplicates. Throws if tampered with.
  static Future<Map<String, dynamic>?> decrypt(RatchetState state, String ciphertext) async {
    final env = jsonDecode(utf8.decode(base64Decode(ciphertext))) as Map<String, dynamic>;
    final n = (env['n'] as num).toInt();
    List<int> mk;
    if (n < state.recvN) {
      final saved = state.skipped.remove('$n');
      if (saved == null) return null; // already read (or too old)
      mk = base64Decode(saved);
    } else {
      if (n - state.recvN > 1000) throw const FormatException('Message counter jumped too far');
      var chain = base64Decode(state.recvChain);
      for (var i = state.recvN; i < n; i++) {
        final (skipKey, next) = await _step(chain);
        state.skipped['$i'] = base64Encode(skipKey); // out-of-order delivery
        chain = Uint8List.fromList(next);
      }
      final (key, next) = await _step(chain);
      mk = key;
      state.recvChain = base64Encode(next);
      state.recvN = n + 1;
      while (state.skipped.length > 300) {
        state.skipped.remove(state.skipped.keys.first);
      }
    }
    final raw = base64Decode(env['ct'] as String);
    final box = SecretBox(raw.sublist(0, raw.length - 16), nonce: base64Decode(env['iv'] as String), mac: Mac(raw.sublist(raw.length - 16)));
    final plain = await _aes.decrypt(
      box,
      secretKey: SecretKey(mk),
      aad: utf8.encode('${state.chatId}:$n:${state.isInitiator ? 'p' : 'i'}'),
    );
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  // ------------------------------------------------------------------ files
  /// Encrypts a file's bytes with a fresh random key → (ciphertext, keyB64, nonceB64).
  static Future<(List<int>, String, String)> encryptFile(List<int> bytes) async {
    final key = randomBytes(32);
    final nonce = randomBytes(12);
    final box = await _aes.encrypt(bytes, secretKey: SecretKey(key), nonce: nonce);
    return ([...box.cipherText, ...box.mac.bytes], base64Encode(key), base64Encode(nonce));
  }

  static Future<List<int>> decryptFile(List<int> data, String keyB64, String nonceB64) async {
    final box = SecretBox(data.sublist(0, data.length - 16), nonce: base64Decode(nonceB64), mac: Mac(data.sublist(data.length - 16)));
    return _aes.decrypt(box, secretKey: SecretKey(base64Decode(keyB64)));
  }

  /// Local at-rest encryption (message history on this phone).
  static Future<List<int>> sealLocal(List<int> key, List<int> data) async {
    final nonce = randomBytes(12);
    final box = await _aes.encrypt(data, secretKey: SecretKey(key), nonce: nonce);
    return [...nonce, ...box.cipherText, ...box.mac.bytes];
  }

  static Future<List<int>> openLocal(List<int> key, List<int> data) async {
    final box = SecretBox(data.sublist(12, data.length - 16), nonce: data.sublist(0, 12), mac: Mac(data.sublist(data.length - 16)));
    return _aes.decrypt(box, secretKey: SecretKey(key));
  }

  // ------------------------------------------------------------------ fingerprint display
  static const _emoji = [
    '😀', '😎', '🥳', '😇', '🤖', '👻', '🐶', '🐱', '🦊', '🐼', '🐸', '🐵', '🦁', '🐯', '🐮', '🐷',
    '🐔', '🐧', '🐦', '🦉', '🐝', '🦋', '🐢', '🐍', '🐙', '🐬', '🐳', '🦈', '🌵', '🌲', '🌻', '🍀',
    '🍎', '🍌', '🍉', '🍇', '🍓', '🍒', '🥝', '🌽', '🍕', '🍔', '🍩', '🍪', '🎂', '☕', '⚽', '🏀',
    '🎸', '🎧', '🎮', '🎲', '🚗', '🚀', '✈️', '⛵', '🏠', '⏰', '💡', '🔑', '🎁', '📚', '✏️', '❤️',
  ];

  static List<String> fingerprintEmoji(String fpB64) => base64Decode(fpB64).take(4).map((b) => _emoji[b % 64]).toList();

  static List<String> fingerprintHex(String fpB64) {
    final hex = base64Decode(fpB64).take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)];
  }
}

class SecretKeys {
  final String sendChain;
  final String recvChain;
  final String fingerprint;
  SecretKeys({required this.sendChain, required this.recvChain, required this.fingerprint});
}

/// Per-chat key material, kept only in the phone's secure storage.
class RatchetState {
  final int chatId;
  final bool isInitiator;
  final String myPrivate;
  final String myPublic;
  String? theirPublic;
  String sendChain;
  String recvChain;
  int sendN;
  int recvN;
  String? fingerprint;
  final Map<String, String> skipped;

  RatchetState({
    required this.chatId,
    required this.isInitiator,
    required this.myPrivate,
    required this.myPublic,
    this.theirPublic,
    this.sendChain = '',
    this.recvChain = '',
    this.sendN = 0,
    this.recvN = 0,
    this.fingerprint,
    Map<String, String>? skipped,
  }) : skipped = skipped ?? {};

  bool get ready => sendChain.isNotEmpty && recvChain.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'chat_id': chatId,
        'initiator': isInitiator,
        'priv': myPrivate,
        'pub': myPublic,
        'their': theirPublic,
        'sc': sendChain,
        'rc': recvChain,
        'sn': sendN,
        'rn': recvN,
        'fp': fingerprint,
        'skip': skipped,
      };

  factory RatchetState.fromJson(Map<String, dynamic> j) => RatchetState(
        chatId: (j['chat_id'] as num).toInt(),
        isInitiator: j['initiator'] == true,
        myPrivate: j['priv'] as String,
        myPublic: j['pub'] as String,
        theirPublic: j['their'] as String?,
        sendChain: (j['sc'] ?? '') as String,
        recvChain: (j['rc'] ?? '') as String,
        sendN: (j['sn'] as num?)?.toInt() ?? 0,
        recvN: (j['rn'] as num?)?.toInt() ?? 0,
        fingerprint: j['fp'] as String?,
        skipped: Map<String, String>.from((j['skip'] as Map?) ?? {}),
      );
}
