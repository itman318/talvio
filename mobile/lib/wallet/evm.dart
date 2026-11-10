import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'tron_api.dart' show WalletException;
import 'tron_crypto.dart';

/// One EVM network. Several public endpoints each: if one is down or busy the next one answers.
class EvmChain {
  const EvmChain({
    required this.id,
    required this.chainId,
    required this.name,
    required this.symbol,
    required this.coinName,
    required this.gecko,
    required this.platform,
    required this.rpcs,
    required this.explorer,
    required this.color,
    required this.maxFeeNative,
  });
  final String id; // 'eth', 'bsc' …
  final int chainId;
  final String name;
  final String symbol; // native coin
  final String coinName;
  final String gecko; // CoinGecko id of the native coin
  final String platform; // CoinGecko platform id (token prices)
  final List<String> rpcs;
  final String explorer; // …/tx/  and …/address/
  final int color;
  /// Refuse fees above this many native coins (a lying endpoint can't drain the wallet through gas).
  final double maxFeeNative;

  static const eth = EvmChain(
    id: 'eth', chainId: 1, name: 'Ethereum', symbol: 'ETH', coinName: 'Ethereum', gecko: 'ethereum', platform: 'ethereum',
    rpcs: ['https://ethereum-rpc.publicnode.com', 'https://eth.llamarpc.com', 'https://rpc.ankr.com/eth'],
    explorer: 'https://etherscan.io', color: 0xFF627EEA, maxFeeNative: 0.05,
  );
  static const bsc = EvmChain(
    id: 'bsc', chainId: 56, name: 'BNB Chain', symbol: 'BNB', coinName: 'BNB', gecko: 'binancecoin', platform: 'binance-smart-chain',
    rpcs: ['https://bsc-rpc.publicnode.com', 'https://bsc-dataseed.bnbchain.org', 'https://rpc.ankr.com/bsc'],
    explorer: 'https://bscscan.com', color: 0xFFF0B90B, maxFeeNative: 0.02,
  );
  static const polygon = EvmChain(
    id: 'polygon', chainId: 137, name: 'Polygon', symbol: 'POL', coinName: 'Polygon', gecko: 'polygon-ecosystem-token', platform: 'polygon-pos',
    rpcs: ['https://polygon-bor-rpc.publicnode.com', 'https://polygon-rpc.com', 'https://rpc.ankr.com/polygon'],
    explorer: 'https://polygonscan.com', color: 0xFF8247E5, maxFeeNative: 20,
  );
  static const arbitrum = EvmChain(
    id: 'arbitrum', chainId: 42161, name: 'Arbitrum', symbol: 'ETH', coinName: 'Ethereum', gecko: 'ethereum', platform: 'arbitrum-one',
    rpcs: ['https://arbitrum-one-rpc.publicnode.com', 'https://arb1.arbitrum.io/rpc', 'https://rpc.ankr.com/arbitrum'],
    explorer: 'https://arbiscan.io', color: 0xFF28A0F0, maxFeeNative: 0.01,
  );
  static const base = EvmChain(
    id: 'base', chainId: 8453, name: 'Base', symbol: 'ETH', coinName: 'Ethereum', gecko: 'ethereum', platform: 'base',
    rpcs: ['https://base-rpc.publicnode.com', 'https://mainnet.base.org', 'https://rpc.ankr.com/base'],
    explorer: 'https://basescan.org', color: 0xFF0052FF, maxFeeNative: 0.01,
  );
  static const avalanche = EvmChain(
    id: 'avalanche', chainId: 43114, name: 'Avalanche', symbol: 'AVAX', coinName: 'Avalanche', gecko: 'avalanche-2', platform: 'avalanche',
    rpcs: ['https://avalanche-c-chain-rpc.publicnode.com', 'https://api.avax.network/ext/bc/C/rpc', 'https://rpc.ankr.com/avalanche'],
    explorer: 'https://snowtrace.io', color: 0xFFE84142, maxFeeNative: 1,
  );

  static const all = [eth, bsc, polygon, arbitrum, base, avalanche];
  static EvmChain? byId(String id) => all.where((c) => c.id == id).firstOrNull;
}

/// A token we know (address + decimals checked against the chain in CI).
class EvmToken {
  const EvmToken(this.chain, this.address, this.symbol, this.name, this.decimals, {this.gecko});
  final String chain;
  final String address;
  final String symbol;
  final String name;
  final int decimals;
  final String? gecko;

  Map<String, dynamic> toJson() => {'chain': chain, 'address': address, 'symbol': symbol, 'name': name, 'decimals': decimals};
  static EvmToken fromJson(Map j) => EvmToken('${j['chain']}', '${j['address']}', '${j['symbol']}', '${j['name']}', (j['decimals'] as num).toInt());

  static const builtIn = [
    EvmToken('eth', '0xdAC17F958D2ee523a2206206994597C13D831ec7', 'USDT', 'Tether', 6, gecko: 'tether'),
    EvmToken('eth', '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', 'USDC', 'USD Coin', 6, gecko: 'usd-coin'),
    EvmToken('bsc', '0x55d398326f99059fF775485246999027B3197955', 'USDT', 'Tether', 18, gecko: 'tether'),
    EvmToken('bsc', '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d', 'USDC', 'USD Coin', 18, gecko: 'usd-coin'),
    EvmToken('polygon', '0xc2132D05D31c914a87C6611C10748AEb04B58e8F', 'USDT', 'Tether', 6, gecko: 'tether'),
    EvmToken('polygon', '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359', 'USDC', 'USD Coin', 6, gecko: 'usd-coin'),
    EvmToken('arbitrum', '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9', 'USDT', 'Tether', 6, gecko: 'tether'),
    EvmToken('arbitrum', '0xaf88d065e77c8cC2239327C5EDb3A432268e5831', 'USDC', 'USD Coin', 6, gecko: 'usd-coin'),
    EvmToken('base', '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', 'USDC', 'USD Coin', 6, gecko: 'usd-coin'),
    EvmToken('avalanche', '0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7', 'USDT', 'Tether', 6, gecko: 'tether'),
    EvmToken('avalanche', '0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E', 'USDC', 'USD Coin', 6, gecko: 'usd-coin'),
  ];
}

// ======================================================================== keys, addresses, transactions
class EvmCrypto {
  EvmCrypto._();

  /// m/44'/60'/0'/0/i — the same path MetaMask and Trust Wallet use, so one phrase shows the same coins there.
  static Uint8List privateKey(String phrase, {int index = 0}) => TronCrypto.privateKeyFor(phrase, coin: 60, index: index);

  static String addressOf(Uint8List priv) {
    final pub = TronCrypto.publicKey(priv);
    return checksum(TronCrypto.hex(TronCrypto.keccak256(pub.sublist(1)).sublist(12)));
  }

  /// EIP-55 mixed-case address.
  static String checksum(String hex40) {
    final a = hex40.toLowerCase().replaceFirst('0x', '');
    final h = TronCrypto.hex(TronCrypto.keccak256(utf8.encode(a)));
    final sb = StringBuffer('0x');
    for (var i = 0; i < a.length; i += 1) {
      final ch = a[i];
      sb.write(RegExp('[a-f]').hasMatch(ch) && int.parse(h[i], radix: 16) >= 8 ? ch.toUpperCase() : ch);
    }
    return sb.toString();
  }

  /// A valid 0x address. Mixed-case addresses must have the right checksum (catches typos).
  static bool isValidAddress(String a) {
    final s = a.trim();
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(s)) return false;
    final body = s.substring(2);
    if (body == body.toLowerCase() || body == body.toUpperCase()) return true;
    return checksum(body) == s;
  }

  // ---- RLP
  static List<int> rlp(Object x) {
    if (x is List<Object>) {
      final body = [for (final i in x) ...rlp(i)];
      return [..._len(body.length, 0xc0), ...body];
    }
    final b = x is BigInt ? _big(x) : x is int ? _big(BigInt.from(x)) : (x as List<int>);
    if (b.length == 1 && b[0] < 0x80) return b;
    return [..._len(b.length, 0x80), ...b];
  }

  static List<int> _len(int n, int offset) {
    if (n < 56) return [offset + n];
    final l = _big(BigInt.from(n));
    return [offset + 55 + l.length, ...l];
  }

  static List<int> _big(BigInt v) {
    if (v == BigInt.zero) return const [];
    final h = v.toRadixString(16);
    return TronCrypto.fromHex(h.length.isOdd ? '0$h' : h);
  }

  /// EIP-155 transaction, signed on the phone. Returns the raw transaction bytes.
  static Uint8List signLegacy({
    required int chainId,
    required BigInt nonce,
    required BigInt gasPrice,
    required BigInt gas,
    required List<int> to,
    required BigInt value,
    required List<int> data,
    required Uint8List priv,
  }) {
    final fields = <Object>[nonce, gasPrice, gas, to, value, data];
    final hash = TronCrypto.keccak256(rlp([...fields, chainId, 0, 0]));
    final sig = TronCrypto.sign(hash, priv); // r ‖ s ‖ 27+rec
    final v = BigInt.from(sig[64] - 27 + chainId * 2 + 35);
    final r = BigInt.parse(TronCrypto.hex(sig.sublist(0, 32)), radix: 16);
    final s = BigInt.parse(TronCrypto.hex(sig.sublist(32, 64)), radix: 16);
    return Uint8List.fromList(rlp([...fields, v, r, s]));
  }

  static Uint8List txHash(Uint8List raw) => TronCrypto.keccak256(raw);

  /// ERC-20 transfer(address,uint256)
  static List<int> transferData(String to, BigInt amount) => [
        0xa9, 0x05, 0x9c, 0xbb,
        ...List.filled(12, 0), ...TronCrypto.fromHex(to.substring(2)),
        ...TronCrypto.fromHex(amount.toRadixString(16).padLeft(64, '0')),
      ];
}

// ======================================================================== network
class EvmPrepared {
  EvmPrepared({required this.chain, required this.to, required this.amount, required this.symbol, required this.decimals, required this.token,
      required this.nonce, required this.gasPrice, required this.gas, required this.txTo, required this.value, required this.data});
  final EvmChain chain;
  final String to; // who gets it
  final BigInt amount;
  final String symbol;
  final int decimals;
  final EvmToken? token;
  final BigInt nonce;
  final BigInt gasPrice;
  final BigInt gas;
  final String txTo; // the token contract for tokens
  final BigInt value;
  final List<int> data;
  BigInt get fee => gasPrice * gas;
}

class EvmApi {
  EvmApi(this.chain, {http.Client? client}) : _http = client ?? http.Client();
  final EvmChain chain;
  final http.Client _http;
  static final Map<String, int> _good = {}; // chain → index of the endpoint that last worked
  static final Set<String> _verified = {}; // endpoints whose chain id we checked

  Future<dynamic> _rpc(String method, List<Object?> params) async {
    final start = _good[chain.id] ?? 0;
    Object? last;
    for (var k = 0; k < chain.rpcs.length; k += 1) {
      final i = (start + k) % chain.rpcs.length;
      final url = chain.rpcs[i];
      try {
        if (!_verified.contains(url)) {
          final id = await _call(url, 'eth_chainId', const []);
          if (BigInt.parse((id as String).substring(2), radix: 16).toInt() != chain.chainId) throw WalletException('wrong network');
          _verified.add(url);
        }
        final r = await _call(url, method, params);
        _good[chain.id] = i;
        return r;
      } on _RpcError catch (e) {
        throw WalletException(_friendly(e.message)); // the network answered: an error about THIS request
      } catch (e) {
        last = e;
      }
    }
    throw WalletException(last is WalletException ? last.message : 'Can’t reach ${chain.name}. Try again.');
  }

  Future<dynamic> _call(String url, String method, List<Object?> params) async {
    final r = await _http
        .post(Uri.parse(url), headers: {'content-type': 'application/json'}, body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final j = jsonDecode(r.body);
    if (j is! Map) throw Exception('bad answer');
    if (j['error'] != null) throw _RpcError('${(j['error'] as Map)['message']}');
    return j['result'];
  }

  static BigInt _q(dynamic hex) {
    final s = '$hex';
    if (!s.startsWith('0x') || s.length < 3) return BigInt.zero;
    return BigInt.parse(s.substring(2), radix: 16);
  }

  Future<BigInt> balance(String address) async => _q(await _rpc('eth_getBalance', [address, 'latest']));

  Future<BigInt> tokenBalance(String token, String address) async {
    final data = '0x70a08231${address.substring(2).toLowerCase().padLeft(64, '0')}';
    final r = await _rpc('eth_call', [{'to': token, 'data': data}, 'latest']);
    return '$r' == '0x' ? BigInt.zero : _q(r);
  }

  /// Name, symbol and decimals of any ERC-20 contract (to add a token by its address).
  Future<EvmToken> tokenInfo(String address) async {
    Future<String> str(String sel) async {
      final r = '${await _rpc('eth_call', [{'to': address, 'data': sel}, 'latest'])}';
      return _abiString(r);
    }

    final dec = _q(await _rpc('eth_call', [{'to': address, 'data': '0x313ce567'}, 'latest'])).toInt();
    final sym = await str('0x95d89b41');
    final name = await str('0x06fdde03');
    if (sym.isEmpty || dec > 36) throw WalletException('This address is not a token on ${chain.name}');
    return EvmToken(chain.id, EvmCrypto.checksum(address.substring(2)), sym.length > 12 ? sym.substring(0, 12) : sym, name.isEmpty ? sym : name, dec);
  }

  static String _abiString(String hex) {
    if (!hex.startsWith('0x') || hex.length < 66) return '';
    final b = TronCrypto.fromHex(hex.substring(2));
    try {
      if (b.length >= 96) {
        final len = BigInt.parse(TronCrypto.hex(b.sublist(32, 64)), radix: 16).toInt();
        if (len > 0 && 64 + len <= b.length) return utf8.decode(b.sublist(64, 64 + len), allowMalformed: true).trim();
      }
      // some old tokens return bytes32
      return utf8.decode(b.sublist(0, 32).where((x) => x != 0).toList(), allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }

  Future<EvmPrepared> prepare({required String from, required String to, required BigInt amount, EvmToken? token}) async {
    if (!EvmCrypto.isValidAddress(to)) throw WalletException('This is not a valid ${chain.name} address');
    final toAddr = TronCrypto.fromHex(to.substring(2));
    final txTo = token == null ? to : token.address;
    final data = token == null ? <int>[] : EvmCrypto.transferData(to, amount);
    final value = token == null ? amount : BigInt.zero;
    final results = await Future.wait([
      _rpc('eth_getTransactionCount', [from, 'pending']),
      _rpc('eth_gasPrice', const []),
      _rpc('eth_estimateGas', [
        {'from': from, 'to': txTo, 'value': '0x${value.toRadixString(16)}', if (data.isNotEmpty) 'data': '0x${TronCrypto.hex(data)}'},
      ]),
    ]);
    final nonce = _q(results[0]);
    // a little above the current price, so it goes through quickly
    final gasPrice = _q(results[1]) * BigInt.from(115) ~/ BigInt.from(100);
    var gas = _q(results[2]) * BigInt.from(120) ~/ BigInt.from(100);
    if (token == null && toAddr.length == 20 && gas < BigInt.from(21000)) gas = BigInt.from(21000);
    final p = EvmPrepared(
      chain: chain, to: to, amount: amount, symbol: token?.symbol ?? chain.symbol, decimals: token?.decimals ?? 18, token: token,
      nonce: nonce, gasPrice: gasPrice, gas: gas, txTo: txTo, value: value, data: data,
    );
    final feeNative = p.fee.toDouble() / 1e18;
    if (feeNative > chain.maxFeeNative || gas > BigInt.from(500000)) {
      throw WalletException('The network fee looks too high right now (${feeNative.toStringAsFixed(5)} ${chain.symbol}). Try again later.');
    }
    return p;
  }

  /// Signs on the phone and sends. Returns the transaction hash.
  Future<String> send(EvmPrepared p, Uint8List priv) async {
    final raw = EvmCrypto.signLegacy(
      chainId: chain.chainId, nonce: p.nonce, gasPrice: p.gasPrice, gas: p.gas,
      to: TronCrypto.fromHex(p.txTo.substring(2)), value: p.value, data: p.data, priv: priv,
    );
    final hash = '0x${TronCrypto.hex(EvmCrypto.txHash(raw))}';
    final r = await _rpc('eth_sendRawTransaction', ['0x${TronCrypto.hex(raw)}']);
    if ('$r'.toLowerCase() != hash.toLowerCase()) throw WalletException('The network gave back a different transaction');
    return hash;
  }

  static String _friendly(String m) {
    final l = m.toLowerCase();
    if (l.contains('insufficient funds')) return 'Not enough balance to pay the network fee';
    if (l.contains('execution reverted') || l.contains('transfer amount exceeds')) return 'The token refused this transfer (not enough balance?)';
    if (l.contains('nonce too low') || l.contains('already known')) return 'This transfer was already sent';
    return m.length > 140 ? '${m.substring(0, 140)}…' : m;
  }
}

class _RpcError implements Exception {
  _RpcError(this.message);
  final String message;
}
