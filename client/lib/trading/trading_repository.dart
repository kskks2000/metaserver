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

  Future<UpbitConnectionStatus> loadUpbitStatus() async {
    final data = await _apiClient.getJson('/trading/upbit/status');
    return UpbitConnectionStatus.fromJson(data);
  }

  Future<KisPortfolio> loadKisPortfolio() async {
    final data = await _apiClient.getJson('/trading/kis/portfolio');
    return KisPortfolio.fromJson(data);
  }

  Future<UpbitPortfolio> loadUpbitPortfolio() async {
    final data = await _apiClient.getJson('/trading/upbit/portfolio');
    return UpbitPortfolio.fromJson(data);
  }

  Future<KisMarketStatus> loadMarketStatus() async {
    final data = await _apiClient.getJson('/trading/market-status');
    return KisMarketStatus.fromJson(data);
  }

  Future<KisOrderActivity> loadKisOrderActivity({int days = 30}) async {
    final data = await _apiClient.getJson('/trading/order-activity?days=$days');
    return KisOrderActivity.fromJson(data);
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

  Future<DomesticStockQuote> loadOverseasQuote(
    String symbol, {
    String marketCode = 'NASDAQ',
  }) async {
    final data = await _apiClient.getJson(
      '/trading/overseas-stocks/${Uri.encodeComponent(symbol)}/quote?market_code=${Uri.encodeQueryComponent(marketCode)}',
    );
    return DomesticStockQuote.fromJson(data);
  }

  Future<DomesticStockQuote> loadUpbitQuote(String market) async {
    final data = await _apiClient.getJson(
      '/trading/upbit/markets/${Uri.encodeComponent(market)}/ticker',
    );
    return DomesticStockQuote.fromJson(data);
  }

  Future<UpbitOrderbook> loadUpbitOrderbook(String market) async {
    final data = await _apiClient.getJson(
      '/trading/upbit/markets/${Uri.encodeComponent(market)}/orderbook?count=10',
    );
    return UpbitOrderbook.fromJson(data);
  }

  Future<UpbitOrderChance> loadUpbitOrderChance(String market) async {
    final data = await _apiClient.getJson(
      '/trading/upbit/orders/chance?market=${Uri.encodeQueryComponent(market)}',
    );
    return UpbitOrderChance.fromJson(data);
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

  Future<List<DomesticStockSearchResult>> searchUpbitMarkets(
    String query, {
    int limit = 50,
  }) async {
    final data = await _apiClient.getJson(
      '/trading/upbit/markets/search?q=${Uri.encodeQueryComponent(query)}&limit=$limit',
    );
    final rawItems = data['items'];
    if (rawItems is! List) return const [];
    return [
      for (final item in rawItems)
        if (item is Map<String, dynamic>)
          DomesticStockSearchResult.fromUpbitJson(item)
        else if (item is Map)
          DomesticStockSearchResult.fromUpbitJson(
            Map<String, dynamic>.from(item),
          ),
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

  Future<DomesticStockOrderActionResult> cancelDomesticStockOrder(
    DomesticStockOrderCancelDraft draft,
  ) async {
    final data = await _apiClient.postJson(
      '/trading/domestic-stocks/orders/cancel',
      data: draft.toJson(),
    );
    return DomesticStockOrderActionResult.fromJson(data);
  }

  Future<DomesticStockOrderActionResult> amendDomesticStockOrder(
    DomesticStockOrderAmendDraft draft,
  ) async {
    final data = await _apiClient.postJson(
      '/trading/domestic-stocks/orders/amend',
      data: draft.toJson(),
    );
    return DomesticStockOrderActionResult.fromJson(data);
  }

  Future<DomesticStockOrderResult> placeOverseasOrder(
    OverseasStockOrderDraft draft,
  ) async {
    final data = await _apiClient.postJson(
      '/trading/overseas-stocks/orders',
      data: draft.toJson(),
    );
    return DomesticStockOrderResult.fromJson(data);
  }

  Future<DomesticStockOrderResult> placeUpbitOrder(
    UpbitOrderDraft draft,
  ) async {
    final data = await _apiClient.postJson(
      '/trading/upbit/orders',
      data: draft.toJson(),
    );
    return DomesticStockOrderResult.fromUpbitJson(data);
  }

  Future<UpbitOrderActionResult> cancelUpbitOrder(String orderId) async {
    final data = await _apiClient.postJson(
      '/trading/upbit/orders/cancel',
      data: {'order_id': orderId},
    );
    return UpbitOrderActionResult.fromJson(data);
  }

  Future<UpbitOrderActionResult> amendUpbitOrder(
    UpbitOrderAmendDraft draft,
  ) async {
    final data = await _apiClient.postJson(
      '/trading/upbit/orders/amend',
      data: draft.toJson(),
    );
    return UpbitOrderActionResult.fromJson(data);
  }

  Future<TradingConsentStatus> loadTradingRiskNoticeConsent() async {
    final data =
        await _apiClient.getJson('/trading/consents/trading-risk-notice');
    return TradingConsentStatus.fromJson(data);
  }

  Future<TradingConsentStatus> agreeTradingRiskNotice() async {
    final data = await _apiClient.postJson(
      '/trading/consents/trading-risk-notice',
      data: {'agreed': true},
    );
    return TradingConsentStatus.fromJson(data);
  }
}

class TradingConsentStatus {
  const TradingConsentStatus({
    required this.consentType,
    required this.version,
    required this.agreed,
    this.agreedAt,
  });

  final String consentType;
  final String version;
  final bool agreed;
  final String? agreedAt;

  factory TradingConsentStatus.fromJson(Map<String, dynamic> json) {
    return TradingConsentStatus(
      consentType: json['consent_type']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      agreed: json['agreed'] == true,
      agreedAt: json['agreed_at']?.toString(),
    );
  }
}

class KisConnectionStatus {
  const KisConnectionStatus({
    required this.configured,
    required this.defaultEnvironment,
    required this.liveTradingEnabled,
    required this.orderProtocol,
    required this.regularSessionOnly,
    this.accountNoMasked,
    this.productCode,
    this.message,
  });

  final bool configured;
  final String defaultEnvironment;
  final bool liveTradingEnabled;
  final String orderProtocol;
  final bool regularSessionOnly;
  final String? accountNoMasked;
  final String? productCode;
  final String? message;

  factory KisConnectionStatus.fromJson(Map<String, dynamic> json) {
    return KisConnectionStatus(
      configured: json['configured'] == true,
      defaultEnvironment: json['default_environment']?.toString() ?? 'paper',
      liveTradingEnabled: json['live_trading_enabled'] == true,
      orderProtocol: json['order_protocol']?.toString() ?? 'modern',
      regularSessionOnly: json['regular_session_only'] != false,
      accountNoMasked: json['account_no_masked']?.toString(),
      productCode: json['product_code']?.toString(),
      message: json['message']?.toString(),
    );
  }
}

class UpbitConnectionStatus {
  const UpbitConnectionStatus({
    required this.configured,
    required this.liveTradingEnabled,
    this.accessKeyMasked,
    this.message,
  });

  final bool configured;
  final bool liveTradingEnabled;
  final String? accessKeyMasked;
  final String? message;

  factory UpbitConnectionStatus.fromJson(Map<String, dynamic> json) {
    return UpbitConnectionStatus(
      configured: json['configured'] == true,
      liveTradingEnabled: json['live_trading_enabled'] == true,
      accessKeyMasked: json['access_key_masked']?.toString(),
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

class UpbitPortfolio {
  const UpbitPortfolio({
    required this.accountLabel,
    required this.holdings,
    required this.totalPurchaseAmount,
    required this.totalEvaluationAmount,
    required this.totalProfitLoss,
    required this.profitLossRate,
    required this.orderableCash,
    required this.lockedCash,
  });

  final String accountLabel;
  final List<UpbitHolding> holdings;
  final double totalPurchaseAmount;
  final double totalEvaluationAmount;
  final double totalProfitLoss;
  final double profitLossRate;
  final double orderableCash;
  final double lockedCash;

  factory UpbitPortfolio.fromJson(Map<String, dynamic> json) {
    final rawHoldings = json['holdings'];
    return UpbitPortfolio(
      accountLabel: json['account_label']?.toString() ?? 'Upbit',
      holdings: [
        if (rawHoldings is List)
          for (final item in rawHoldings)
            if (item is Map<String, dynamic>)
              UpbitHolding.fromJson(item)
            else if (item is Map)
              UpbitHolding.fromJson(Map<String, dynamic>.from(item)),
      ],
      totalPurchaseAmount: _asDouble(json['total_purchase_amount']) ?? 0,
      totalEvaluationAmount: _asDouble(json['total_evaluation_amount']) ?? 0,
      totalProfitLoss: _asDouble(json['total_profit_loss']) ?? 0,
      profitLossRate: _asDouble(json['profit_loss_rate']) ?? 0,
      orderableCash: _asDouble(json['orderable_cash']) ?? 0,
      lockedCash: _asDouble(json['locked_cash']) ?? 0,
    );
  }
}

class UpbitHolding {
  const UpbitHolding({
    required this.market,
    required this.symbol,
    required this.name,
    required this.quantity,
    required this.lockedQuantity,
    required this.orderableQuantity,
    required this.averagePrice,
    required this.currentPrice,
    required this.purchaseAmount,
    required this.evaluationAmount,
    required this.profitLoss,
    required this.profitLossRate,
    required this.currency,
  });

  final String market;
  final String symbol;
  final String name;
  final double quantity;
  final double lockedQuantity;
  final double orderableQuantity;
  final double averagePrice;
  final double currentPrice;
  final double purchaseAmount;
  final double evaluationAmount;
  final double profitLoss;
  final double profitLossRate;
  final String currency;

  factory UpbitHolding.fromJson(Map<String, dynamic> json) {
    return UpbitHolding(
      market: json['market']?.toString() ?? '',
      symbol: json['symbol']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      quantity: _asDouble(json['quantity']) ?? 0,
      lockedQuantity: _asDouble(json['locked_quantity']) ?? 0,
      orderableQuantity: _asDouble(json['orderable_quantity']) ?? 0,
      averagePrice: _asDouble(json['average_price']) ?? 0,
      currentPrice: _asDouble(json['current_price']) ?? 0,
      purchaseAmount: _asDouble(json['purchase_amount']) ?? 0,
      evaluationAmount: _asDouble(json['evaluation_amount']) ?? 0,
      profitLoss: _asDouble(json['profit_loss']) ?? 0,
      profitLossRate: _asDouble(json['profit_loss_rate']) ?? 0,
      currency: json['currency']?.toString() ?? 'KRW',
    );
  }
}

class KisHolding {
  const KisHolding({
    required this.symbol,
    required this.name,
    required this.quantity,
    required this.assetClass,
    required this.market,
    required this.currency,
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
  final String assetClass;
  final String market;
  final String currency;
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
      assetClass: json['asset_class']?.toString() ?? 'domestic_stock',
      market: json['market']?.toString() ?? 'KOSPI',
      currency: json['currency']?.toString() ?? 'KRW',
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

class KisMarketStatus {
  const KisMarketStatus({
    required this.environment,
    required this.items,
  });

  final String environment;
  final List<KisMarketStatusItem> items;

  factory KisMarketStatus.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return KisMarketStatus(
      environment: json['environment']?.toString() ?? 'paper',
      items: [
        if (rawItems is List)
          for (final item in rawItems)
            if (item is Map<String, dynamic>)
              KisMarketStatusItem.fromJson(item)
            else if (item is Map)
              KisMarketStatusItem.fromJson(Map<String, dynamic>.from(item)),
      ],
    );
  }
}

class KisMarketStatusItem {
  const KisMarketStatusItem({
    required this.label,
    required this.value,
    required this.change,
    required this.changeRate,
  });

  final String label;
  final double? value;
  final double? change;
  final double? changeRate;

  factory KisMarketStatusItem.fromJson(Map<String, dynamic> json) {
    return KisMarketStatusItem(
      label: json['label']?.toString() ?? '',
      value: _asDouble(json['value']),
      change: _asDouble(json['change']),
      changeRate: _asDouble(json['change_rate']),
    );
  }
}

class KisOrderActivity {
  const KisOrderActivity({
    required this.environment,
    required this.accountNoMasked,
    required this.startDate,
    required this.endDate,
    required this.openOrders,
    required this.executions,
  });

  final String environment;
  final String accountNoMasked;
  final String startDate;
  final String endDate;
  final List<KisOrderActivityItem> openOrders;
  final List<KisOrderActivityItem> executions;

  factory KisOrderActivity.fromJson(Map<String, dynamic> json) {
    return KisOrderActivity(
      environment: json['environment']?.toString() ?? 'paper',
      accountNoMasked: json['account_no_masked']?.toString() ?? '',
      startDate: json['start_date']?.toString() ?? '',
      endDate: json['end_date']?.toString() ?? '',
      openOrders: _activityItems(json['open_orders']),
      executions: _activityItems(json['executions']),
    );
  }
}

class KisOrderActivityItem {
  const KisOrderActivityItem({
    required this.broker,
    required this.assetClass,
    required this.market,
    required this.currency,
    required this.symbol,
    required this.name,
    required this.side,
    required this.status,
    required this.quantity,
    required this.filledQuantity,
    required this.remainingQuantity,
    required this.price,
    required this.averagePrice,
    this.orderDate,
    this.orderTime,
    this.orderNo,
    this.branchNo,
    this.originalOrderNo,
    this.orderDivisionCode,
    this.exchangeCode,
    this.orderKindName,
  });

  final String broker;
  final String assetClass;
  final String market;
  final String currency;
  final String symbol;
  final String name;
  final String side;
  final String status;
  final double quantity;
  final double filledQuantity;
  final double remainingQuantity;
  final double price;
  final double averagePrice;
  final String? orderDate;
  final String? orderTime;
  final String? orderNo;
  final String? branchNo;
  final String? originalOrderNo;
  final String? orderDivisionCode;
  final String? exchangeCode;
  final String? orderKindName;

  bool get isBuy => side == 'buy';
  bool get isCrypto =>
      assetClass == 'crypto' || broker.toUpperCase() == 'UPBIT';
  bool get isDomesticStock =>
      assetClass == 'domestic_stock' && broker.toUpperCase() == 'KIS';
  bool get supportsOrderActions => isCrypto || isDomesticStock;

  Map<String, Object?> toJson() {
    return {
      'broker': broker,
      'asset_class': assetClass,
      'market': market,
      'currency': currency,
      'symbol': symbol,
      'name': name,
      'side': side,
      'status': status,
      'quantity': quantity,
      'filled_quantity': filledQuantity,
      'remaining_quantity': remainingQuantity,
      'price': price,
      'average_price': averagePrice,
      'order_date': orderDate,
      'order_time': orderTime,
      'order_no': orderNo,
      'branch_no': branchNo,
      'original_order_no': originalOrderNo,
      'order_division_code': orderDivisionCode,
      'exchange_code': exchangeCode,
      'order_kind_name': orderKindName,
    };
  }

  factory KisOrderActivityItem.fromJson(Map<String, dynamic> json) {
    return KisOrderActivityItem(
      broker: json['broker']?.toString() ?? 'kis',
      assetClass: json['asset_class']?.toString() ?? 'domestic_stock',
      market: json['market']?.toString() ?? '',
      currency: json['currency']?.toString() ?? 'KRW',
      symbol: json['symbol']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      side: json['side']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      quantity: _asDouble(json['quantity']) ?? 0,
      filledQuantity: _asDouble(json['filled_quantity']) ?? 0,
      remainingQuantity: _asDouble(json['remaining_quantity']) ?? 0,
      price: _asDouble(json['price']) ?? 0,
      averagePrice: _asDouble(json['average_price']) ?? 0,
      orderDate: json['order_date']?.toString(),
      orderTime: json['order_time']?.toString(),
      orderNo: json['order_no']?.toString(),
      branchNo: json['branch_no']?.toString(),
      originalOrderNo: json['original_order_no']?.toString(),
      orderDivisionCode: json['order_division_code']?.toString(),
      exchangeCode: json['exchange_code']?.toString(),
      orderKindName: json['order_kind_name']?.toString(),
    );
  }
}

List<KisOrderActivityItem> _activityItems(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map<String, dynamic>)
        KisOrderActivityItem.fromJson(item)
      else if (item is Map)
        KisOrderActivityItem.fromJson(Map<String, dynamic>.from(item)),
  ];
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

  factory DomesticStockSearchResult.fromUpbitJson(Map<String, dynamic> json) {
    return DomesticStockSearchResult(
      market: 'UPBIT',
      symbol: json['market']?.toString() ?? '',
      name: json['korean_name']?.toString() ?? json['market']?.toString() ?? '',
      sector: json['english_name']?.toString() ?? 'Upbit KRW',
      standardCode: json['market_warning']?.toString(),
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
    this.quoteCurrency,
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
  final String? quoteCurrency;

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
      quoteCurrency: json['quote_currency']?.toString(),
    );
  }
}

class DomesticStockOrderDraft {
  const DomesticStockOrderDraft({
    required this.side,
    required this.symbol,
    required this.quantity,
    required this.orderKind,
    this.exchangeCode = 'AUTO',
    this.price,
  });

  final String side;
  final String symbol;
  final int quantity;
  final String orderKind;
  final String exchangeCode;
  final int? price;

  Map<String, dynamic> toJson() {
    return {
      'side': side,
      'symbol': symbol,
      'quantity': quantity,
      'order_kind': orderKind,
      'exchange_code': exchangeCode,
      if (price != null) 'price': price,
    };
  }
}

class DomesticStockOrderCancelDraft {
  const DomesticStockOrderCancelDraft({
    required this.orderId,
    required this.branchNo,
    required this.orderDivisionCode,
    required this.exchangeCode,
    this.quantity,
    this.useRemainingQuantity = true,
  });

  final String orderId;
  final String branchNo;
  final String orderDivisionCode;
  final String exchangeCode;
  final int? quantity;
  final bool useRemainingQuantity;

  Map<String, dynamic> toJson() {
    return {
      'order_id': orderId,
      'branch_no': branchNo,
      'order_division_code': orderDivisionCode,
      'exchange_code': exchangeCode,
      'use_remaining_quantity': useRemainingQuantity,
      if (!useRemainingQuantity && quantity != null) 'quantity': quantity,
    };
  }
}

class DomesticStockOrderAmendDraft {
  const DomesticStockOrderAmendDraft({
    required this.orderId,
    required this.branchNo,
    required this.orderDivisionCode,
    required this.exchangeCode,
    required this.price,
    this.quantity,
    this.useRemainingQuantity = true,
  });

  final String orderId;
  final String branchNo;
  final String orderDivisionCode;
  final String exchangeCode;
  final int price;
  final int? quantity;
  final bool useRemainingQuantity;

  Map<String, dynamic> toJson() {
    return {
      'order_id': orderId,
      'branch_no': branchNo,
      'order_division_code': orderDivisionCode,
      'exchange_code': exchangeCode,
      'price': price,
      'use_remaining_quantity': useRemainingQuantity,
      if (!useRemainingQuantity && quantity != null) 'quantity': quantity,
    };
  }
}

class OverseasStockOrderDraft {
  const OverseasStockOrderDraft({
    required this.side,
    required this.marketCode,
    required this.symbol,
    required this.quantity,
    required this.orderKind,
    this.price,
  });

  final String side;
  final String marketCode;
  final String symbol;
  final int quantity;
  final String orderKind;
  final num? price;

  Map<String, dynamic> toJson() {
    return {
      'side': side,
      'market_code': marketCode,
      'symbol': symbol,
      'quantity': quantity,
      'order_kind': orderKind,
      if (price != null) 'price': price,
    };
  }
}

class UpbitOrderDraft {
  const UpbitOrderDraft({
    required this.side,
    required this.market,
    required this.orderKind,
    this.quantity,
    this.price,
  });

  final String side;
  final String market;
  final String orderKind;
  final num? quantity;
  final num? price;

  Map<String, dynamic> toJson() {
    return {
      'side': side,
      'market': market,
      'order_kind': orderKind,
      if (quantity != null) 'quantity': quantity,
      if (price != null) 'price': price,
    };
  }
}

class UpbitOrderAmendDraft {
  const UpbitOrderAmendDraft({
    required this.orderId,
    required this.price,
    required this.useRemainingQuantity,
    this.quantity,
  });

  final String orderId;
  final num price;
  final bool useRemainingQuantity;
  final num? quantity;

  Map<String, dynamic> toJson() {
    return {
      'order_id': orderId,
      'order_kind': 'limit',
      'price': price,
      'use_remaining_quantity': useRemainingQuantity,
      if (!useRemainingQuantity && quantity != null) 'quantity': quantity,
    };
  }
}

class UpbitOrderActionResult {
  const UpbitOrderActionResult({
    required this.action,
    required this.orderId,
    this.brokerOrderNo,
    this.newBrokerOrderNo,
    this.brokerState,
  });

  final String action;
  final String orderId;
  final String? brokerOrderNo;
  final String? newBrokerOrderNo;
  final String? brokerState;

  factory UpbitOrderActionResult.fromJson(Map<String, dynamic> json) {
    return UpbitOrderActionResult(
      action: json['action']?.toString() ?? '',
      orderId: json['order_id']?.toString() ?? '',
      brokerOrderNo: json['broker_order_no']?.toString(),
      newBrokerOrderNo: json['new_broker_order_no']?.toString(),
      brokerState: json['broker_state']?.toString(),
    );
  }
}

class DomesticStockOrderActionResult {
  const DomesticStockOrderActionResult({
    required this.action,
    required this.orderId,
    this.brokerOrderNo,
    this.newBrokerOrderNo,
    this.brokerOrderTime,
    this.kisMessage,
  });

  final String action;
  final String orderId;
  final String? brokerOrderNo;
  final String? newBrokerOrderNo;
  final String? brokerOrderTime;
  final String? kisMessage;

  factory DomesticStockOrderActionResult.fromJson(Map<String, dynamic> json) {
    return DomesticStockOrderActionResult(
      action: json['action']?.toString() ?? '',
      orderId: json['order_id']?.toString() ?? '',
      brokerOrderNo: json['broker_order_no']?.toString(),
      newBrokerOrderNo: json['new_broker_order_no']?.toString(),
      brokerOrderTime: json['broker_order_time']?.toString(),
      kisMessage: json['kis_message']?.toString(),
    );
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

  factory DomesticStockOrderResult.fromUpbitJson(Map<String, dynamic> json) {
    return DomesticStockOrderResult(
      symbol: json['market']?.toString() ?? '',
      side: json['side']?.toString() ?? '',
      quantity: _asInt(json['quantity']),
      orderDivisionCode: json['order_kind']?.toString() ?? '',
      trId: 'UPBIT',
      brokerOrderNo: json['broker_order_no']?.toString(),
      brokerOrderTime: json['broker_order_time']?.toString(),
      kisMessage: json['broker_state']?.toString(),
    );
  }
}

class UpbitOrderbook {
  const UpbitOrderbook({
    required this.market,
    required this.units,
  });

  final String market;
  final List<UpbitOrderbookUnit> units;

  factory UpbitOrderbook.fromJson(Map<String, dynamic> json) {
    final rawUnits = json['units'];
    return UpbitOrderbook(
      market: json['market']?.toString() ?? '',
      units: [
        if (rawUnits is List)
          for (final item in rawUnits)
            if (item is Map<String, dynamic>)
              UpbitOrderbookUnit.fromJson(item)
            else if (item is Map)
              UpbitOrderbookUnit.fromJson(Map<String, dynamic>.from(item)),
      ],
    );
  }
}

class UpbitOrderbookUnit {
  const UpbitOrderbookUnit({
    required this.askPrice,
    required this.bidPrice,
    required this.askSize,
    required this.bidSize,
  });

  final double askPrice;
  final double bidPrice;
  final double askSize;
  final double bidSize;

  factory UpbitOrderbookUnit.fromJson(Map<String, dynamic> json) {
    return UpbitOrderbookUnit(
      askPrice: _asDouble(json['ask_price']) ?? 0,
      bidPrice: _asDouble(json['bid_price']) ?? 0,
      askSize: _asDouble(json['ask_size']) ?? 0,
      bidSize: _asDouble(json['bid_size']) ?? 0,
    );
  }
}

class UpbitOrderChance {
  const UpbitOrderChance({
    required this.market,
    required this.bidFee,
    required this.askFee,
    required this.bidAccountBalance,
    required this.askAccountBalance,
    required this.minTotal,
  });

  final String market;
  final double bidFee;
  final double askFee;
  final double bidAccountBalance;
  final double askAccountBalance;
  final double minTotal;

  factory UpbitOrderChance.fromJson(Map<String, dynamic> json) {
    return UpbitOrderChance(
      market: json['market']?.toString() ?? '',
      bidFee: _asDouble(json['bid_fee']) ?? 0,
      askFee: _asDouble(json['ask_fee']) ?? 0,
      bidAccountBalance: _asDouble(json['bid_account_balance']) ?? 0,
      askAccountBalance: _asDouble(json['ask_account_balance']) ?? 0,
      minTotal: _asDouble(json['min_total']) ?? 5000,
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
  final text = value?.toString().replaceAll(',', '') ?? '';
  return int.tryParse(text) ?? double.tryParse(text)?.round() ?? 0;
}
