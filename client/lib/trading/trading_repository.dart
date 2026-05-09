import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';

final tradingRepositoryProvider = Provider<TradingRepository>((ref) {
  return TradingRepository(ref.read(apiClientProvider));
});

class TradingRepository {
  const TradingRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<KisConnectionStatus> loadKisStatus() async {
    final data = await _apiClient.getJson('/trading/kis/status');
    return KisConnectionStatus.fromJson(data);
  }

  Future<KisPortfolio> loadKisPortfolio() async {
    final data = await _apiClient.getJson('/trading/kis/portfolio');
    return KisPortfolio.fromJson(data);
  }

  Future<DomesticStockQuote> loadQuote(
    String symbol, {
    String marketCode = 'J',
  }) async {
    final data = await _apiClient.getJson(
      '/trading/domestic-stocks/$symbol/quote?market_code=$marketCode',
    );
    return DomesticStockQuote.fromJson(data);
  }

  Future<List<DomesticStockSearchResult>> searchDomesticStocks(
    String query, {
    int limit = 50,
  }) async {
    final data = await _apiClient.getJson(
      '/trading/domestic-stocks/search?q=${Uri.encodeQueryComponent(query)}&limit=$limit',
    );
    final rawItems = data['items'];
    if (rawItems is! List) return const [];
    return [
      for (final item in rawItems)
        if (item is Map<String, dynamic>)
          DomesticStockSearchResult.fromJson(item)
        else if (item is Map)
          DomesticStockSearchResult.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<DomesticStockOrderResult> placeOrder(
    DomesticStockOrderDraft draft,
  ) async {
    final data = await _apiClient.postJson(
      '/trading/domestic-stocks/orders',
      data: draft.toJson(),
    );
    return DomesticStockOrderResult.fromJson(data);
  }
}

class KisConnectionStatus {
  const KisConnectionStatus({
    required this.configured,
    required this.defaultEnvironment,
    required this.liveTradingEnabled,
    this.accountNoMasked,
    this.productCode,
    this.message,
  });

  final bool configured;
  final String defaultEnvironment;
  final bool liveTradingEnabled;
  final String? accountNoMasked;
  final String? productCode;
  final String? message;

  factory KisConnectionStatus.fromJson(Map<String, dynamic> json) {
    return KisConnectionStatus(
      configured: json['configured'] == true,
      defaultEnvironment: json['default_environment']?.toString() ?? 'paper',
      liveTradingEnabled: json['live_trading_enabled'] == true,
      accountNoMasked: json['account_no_masked']?.toString(),
      productCode: json['product_code']?.toString(),
      message: json['message']?.toString(),
    );
  }
}

class KisPortfolio {
  const KisPortfolio({
    required this.environment,
    required this.accountNoMasked,
    required this.holdings,
    required this.totalPurchaseAmount,
    required this.totalEvaluationAmount,
    required this.totalProfitLoss,
    required this.profitLossRate,
    required this.orderableCash,
  });

  final String environment;
  final String accountNoMasked;
  final List<KisHolding> holdings;
  final double totalPurchaseAmount;
  final double totalEvaluationAmount;
  final double totalProfitLoss;
  final double profitLossRate;
  final double orderableCash;

  factory KisPortfolio.fromJson(Map<String, dynamic> json) {
    final rawHoldings = json['holdings'];
    return KisPortfolio(
      environment: json['environment']?.toString() ?? 'paper',
      accountNoMasked: json['account_no_masked']?.toString() ?? '',
      holdings: [
        if (rawHoldings is List)
          for (final item in rawHoldings)
            if (item is Map<String, dynamic>)
              KisHolding.fromJson(item)
            else if (item is Map)
              KisHolding.fromJson(Map<String, dynamic>.from(item)),
      ],
      totalPurchaseAmount: _asDouble(json['total_purchase_amount']) ?? 0,
      totalEvaluationAmount: _asDouble(json['total_evaluation_amount']) ?? 0,
      totalProfitLoss: _asDouble(json['total_profit_loss']) ?? 0,
      profitLossRate: _asDouble(json['profit_loss_rate']) ?? 0,
      orderableCash: _asDouble(json['orderable_cash']) ?? 0,
    );
  }
}

class KisHolding {
  const KisHolding({
    required this.symbol,
    required this.name,
    required this.quantity,
    required this.orderableQuantity,
    required this.averagePrice,
    required this.currentPrice,
    required this.purchaseAmount,
    required this.evaluationAmount,
    required this.profitLoss,
    required this.profitLossRate,
  });

  final String symbol;
  final String name;
  final double quantity;
  final double orderableQuantity;
  final double averagePrice;
  final double currentPrice;
  final double purchaseAmount;
  final double evaluationAmount;
  final double profitLoss;
  final double profitLossRate;

  factory KisHolding.fromJson(Map<String, dynamic> json) {
    return KisHolding(
      symbol: json['symbol']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      quantity: _asDouble(json['quantity']) ?? 0,
      orderableQuantity: _asDouble(json['orderable_quantity']) ?? 0,
      averagePrice: _asDouble(json['average_price']) ?? 0,
      currentPrice: _asDouble(json['current_price']) ?? 0,
      purchaseAmount: _asDouble(json['purchase_amount']) ?? 0,
      evaluationAmount: _asDouble(json['evaluation_amount']) ?? 0,
      profitLoss: _asDouble(json['profit_loss']) ?? 0,
      profitLossRate: _asDouble(json['profit_loss_rate']) ?? 0,
    );
  }
}

class DomesticStockSearchResult {
  const DomesticStockSearchResult({
    required this.market,
    required this.symbol,
    required this.name,
    required this.sector,
    this.standardCode,
  });

  final String market;
  final String symbol;
  final String name;
  final String sector;
  final String? standardCode;

  factory DomesticStockSearchResult.fromJson(Map<String, dynamic> json) {
    return DomesticStockSearchResult(
      market: json['market']?.toString() ?? '',
      symbol: json['symbol']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      sector: json['sector']?.toString() ?? '상장종목',
      standardCode: json['standard_code']?.toString(),
    );
  }
}

class DomesticStockQuote {
  const DomesticStockQuote({
    required this.symbol,
    required this.environment,
    this.price,
    this.previousClose,
    this.changePrice,
    this.changeRate,
    this.openPrice,
    this.highPrice,
    this.lowPrice,
    this.accumulatedVolume,
    this.accumulatedTradeAmount,
  });

  final String symbol;
  final String environment;
  final double? price;
  final double? previousClose;
  final double? changePrice;
  final double? changeRate;
  final double? openPrice;
  final double? highPrice;
  final double? lowPrice;
  final double? accumulatedVolume;
  final double? accumulatedTradeAmount;

  factory DomesticStockQuote.fromJson(Map<String, dynamic> json) {
    return DomesticStockQuote(
      symbol: json['symbol']?.toString() ?? '',
      environment: json['environment']?.toString() ?? 'paper',
      price: _asDouble(json['price']),
      previousClose: _asDouble(json['previous_close']),
      changePrice: _asDouble(json['change_price']),
      changeRate: _asDouble(json['change_rate']),
      openPrice: _asDouble(json['open_price']),
      highPrice: _asDouble(json['high_price']),
      lowPrice: _asDouble(json['low_price']),
      accumulatedVolume: _asDouble(json['accumulated_volume']),
      accumulatedTradeAmount: _asDouble(json['accumulated_trade_amount']),
    );
  }
}

class DomesticStockOrderDraft {
  const DomesticStockOrderDraft({
    required this.side,
    required this.symbol,
    required this.quantity,
    required this.orderKind,
    this.price,
  });

  final String side;
  final String symbol;
  final int quantity;
  final String orderKind;
  final int? price;

  Map<String, dynamic> toJson() {
    return {
      'side': side,
      'symbol': symbol,
      'quantity': quantity,
      'order_kind': orderKind,
      if (price != null) 'price': price,
    };
  }
}

class DomesticStockOrderResult {
  const DomesticStockOrderResult({
    required this.symbol,
    required this.side,
    required this.quantity,
    required this.orderDivisionCode,
    required this.trId,
    this.brokerOrderNo,
    this.brokerOrderTime,
    this.kisMessage,
  });

  final String symbol;
  final String side;
  final int quantity;
  final String orderDivisionCode;
  final String trId;
  final String? brokerOrderNo;
  final String? brokerOrderTime;
  final String? kisMessage;

  factory DomesticStockOrderResult.fromJson(Map<String, dynamic> json) {
    return DomesticStockOrderResult(
      symbol: json['symbol']?.toString() ?? '',
      side: json['side']?.toString() ?? '',
      quantity: _asInt(json['quantity']),
      orderDivisionCode: json['order_division_code']?.toString() ?? '',
      trId: json['tr_id']?.toString() ?? '',
      brokerOrderNo: json['broker_order_no']?.toString(),
      brokerOrderTime: json['broker_order_time']?.toString(),
      kisMessage: json['kis_message']?.toString(),
    );
  }
}

double? _asDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().replaceAll(',', ''));
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
