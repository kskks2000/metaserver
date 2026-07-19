import 'package:flutter/material.dart';

import '../app/theme.dart';

class AssetLogo extends StatelessWidget {
  const AssetLogo({
    super.key,
    required this.symbol,
    this.assetClass,
    this.name,
    this.market,
    this.size = 42,
    this.compact = false,
    this.onDark = false,
  });

  final String symbol;
  final String? assetClass;
  final String? name;
  final String? market;
  final double size;
  final bool compact;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final normalizedClass = normalizeAssetClass(
      assetClass: assetClass,
      symbol: symbol,
      market: market,
    );
    final accent = assetAccentColor(normalizedClass);
    final urls = assetLogoUrls(
      symbol: symbol,
      assetClass: normalizedClass,
      market: market,
    );

    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(compact ? 3 : 4),
      decoration: BoxDecoration(
        color: onDark ? Colors.white.withValues(alpha: 0.12) : Colors.white,
        borderRadius: BorderRadius.circular(compact ? 7 : 8),
        border: Border.all(
          color: accent.withValues(alpha: onDark ? 0.36 : 0.28),
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: onDark ? 0.18 : 0.11),
            blurRadius: compact ? 8 : 12,
            offset: Offset(0, compact ? 3 : 5),
          ),
          if (!onDark)
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.88),
              blurRadius: 2,
              offset: const Offset(0, -1),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(compact ? 5 : 6),
        child: urls.isEmpty
            ? _LogoFallback(
                symbol: symbol,
                name: name,
                assetClass: normalizedClass,
                accent: accent,
                compact: compact,
                onDark: onDark,
              )
            : _NetworkLogo(
                urls: urls,
                fallback: _LogoFallback(
                  symbol: symbol,
                  name: name,
                  assetClass: normalizedClass,
                  accent: accent,
                  compact: compact,
                  onDark: onDark,
                ),
              ),
      ),
    );
  }
}

String normalizeAssetClass({
  String? assetClass,
  String? symbol,
  String? market,
}) {
  final raw = (assetClass ?? '').trim().toLowerCase();
  if (raw == 'crypto' || raw == 'coin') return 'crypto';
  if (raw == 'overseas_stock' || raw == 'overseas') return 'overseas_stock';
  if (raw == 'domestic_stock' || raw == 'stock') return 'domestic_stock';

  final normalizedSymbol = (symbol ?? '').trim().toUpperCase();
  final normalizedMarket = (market ?? '').trim().toUpperCase();
  if (normalizedSymbol.startsWith('KRW-') ||
      normalizedSymbol.startsWith('BTC-') ||
      normalizedSymbol.startsWith('USDT-') ||
      normalizedMarket == 'UPBIT' ||
      normalizedMarket == 'BITHUMB' ||
      normalizedMarket == 'BINANCE') {
    return 'crypto';
  }
  if (_companyLogoDomains.containsKey(normalizedSymbol) &&
      !_isDomesticSymbol(normalizedSymbol)) {
    return 'overseas_stock';
  }
  return 'domestic_stock';
}

Color assetAccentColor(String assetClass) {
  return switch (assetClass) {
    'crypto' => MetaServerColors.amber,
    'overseas_stock' => const Color(0xFF4768A8),
    _ => MetaServerColors.green,
  };
}

List<String> assetLogoUrls({
  required String symbol,
  String? assetClass,
  String? market,
}) {
  final normalizedClass = normalizeAssetClass(
    assetClass: assetClass,
    symbol: symbol,
    market: market,
  );
  final normalizedSymbol = symbol.trim().toUpperCase();
  if (normalizedClass == 'crypto') {
    final ticker = cryptoLogoTicker(normalizedSymbol);
    if (ticker == null) return const [];
    return [
      'https://assets.coincap.io/assets/icons/${ticker.toLowerCase()}@2x.png',
      if (_cryptoLogoNames[ticker] != null)
        'https://cryptologos.cc/logos/${_cryptoLogoNames[ticker]}-${ticker.toLowerCase()}-logo.png?v=035',
    ];
  }

  final domain = _companyLogoDomains[normalizedSymbol];
  if (domain == null) return const [];
  return [
    'https://logo.clearbit.com/$domain',
    'https://icons.duckduckgo.com/ip3/$domain.ico',
  ];
}

String? cryptoLogoTicker(String symbol) {
  final normalized = symbol.trim().toUpperCase();
  if (normalized.isEmpty) return null;
  final parts = normalized.split('-');
  final ticker = parts.length > 1 ? parts.last : normalized;
  return ticker;
}

bool _isDomesticSymbol(String symbol) {
  return RegExp(r'^\d{6}$').hasMatch(symbol);
}

const _companyLogoDomains = {
  '005930': 'samsung.com',
  '000660': 'skhynix.com',
  '247540': 'ecoprobm.co.kr',
  '035420': 'naver.com',
  '005380': 'hyundai.com',
  '035720': 'kakaocorp.com',
  '068270': 'celltrion.com',
  '207940': 'samsungbiologics.com',
  '005490': 'posco-inc.com',
  '051910': 'lgchem.com',
  '373220': 'lgenergysolution.com',
  '000270': 'kia.com',
  '105560': 'kbfg.com',
  '055550': 'shinhan.com',
  '012330': 'mobis.co.kr',
  '096770': 'skinnovation.com',
  '028260': 'samsungcnt.com',
  '086520': 'ecopro.co.kr',
  '091990': 'celltrionhealthcare.com',
  '069500': 'samsungfund.com',
  'AAPL': 'apple.com',
  'MSFT': 'microsoft.com',
  'NVDA': 'nvidia.com',
  'TSLA': 'tesla.com',
  'GOOGL': 'abc.xyz',
  'GOOG': 'abc.xyz',
  'AMZN': 'amazon.com',
  'META': 'meta.com',
  'BRK.B': 'berkshirehathaway.com',
  'BRK-B': 'berkshirehathaway.com',
};

const _cryptoLogoNames = {
  'BTC': 'bitcoin',
  'ETH': 'ethereum',
  'SOL': 'solana',
  'XRP': 'xrp',
};

class _NetworkLogo extends StatefulWidget {
  const _NetworkLogo({
    required this.urls,
    required this.fallback,
  });

  final List<String> urls;
  final Widget fallback;

  @override
  State<_NetworkLogo> createState() => _NetworkLogoState();
}

class _NetworkLogoState extends State<_NetworkLogo> {
  int _index = 0;

  @override
  void didUpdateWidget(covariant _NetworkLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.urls.join('|') != widget.urls.join('|')) {
      _index = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_index >= widget.urls.length) return widget.fallback;
    return Image.network(
      widget.urls[_index],
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      errorBuilder: (context, error, stackTrace) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _index >= widget.urls.length) return;
          setState(() => _index += 1);
        });
        return widget.fallback;
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return widget.fallback;
      },
    );
  }
}

class _LogoFallback extends StatelessWidget {
  const _LogoFallback({
    required this.symbol,
    required this.assetClass,
    required this.accent,
    this.name,
    required this.compact,
    required this.onDark,
  });

  final String symbol;
  final String assetClass;
  final Color accent;
  final String? name;
  final bool compact;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final label = _fallbackLabel(symbol: symbol, name: name);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: onDark ? 0.25 : 0.15),
            Colors.white.withValues(alpha: onDark ? 0.1 : 0.94),
          ],
        ),
      ),
      child: Center(
        child: assetClass == 'crypto'
            ? Icon(
                Icons.currency_bitcoin_rounded,
                color: accent,
                size: compact ? 16 : 22,
              )
            : Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  color: onDark ? Colors.white : MetaServerColors.ink,
                  fontSize: compact ? 10 : 13,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
      ),
    );
  }
}

String _fallbackLabel({required String symbol, String? name}) {
  final cleanName = (name ?? '').trim();
  if (cleanName.isNotEmpty) {
    final ascii = RegExp(r'[A-Za-z0-9]+')
        .allMatches(cleanName)
        .map((match) {
          return match.group(0) ?? '';
        })
        .where((part) => part.isNotEmpty)
        .toList();
    if (ascii.isNotEmpty) {
      final letters = ascii.map((part) => part[0]).join();
      return letters.length > 2
          ? letters.substring(0, 2).toUpperCase()
          : letters.toUpperCase();
    }
    return cleanName.characters.take(2).toString();
  }
  final normalized = symbol.trim().toUpperCase();
  if (normalized.contains('-')) return normalized.split('-').last;
  return normalized.length > 3 ? normalized.substring(0, 3) : normalized;
}
