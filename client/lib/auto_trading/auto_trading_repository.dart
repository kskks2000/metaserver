import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';

final autoTradingRepositoryProvider = Provider<AutoTradingRepository>((ref) {
  return AutoTradingRepository(ref.read(apiClientProvider));
});

class AutoTradingRepository {
  const AutoTradingRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<AutoTradingOverview> loadOverview() async {
    final data = await _apiClient.getJson('/auto-trading/overview');
    return AutoTradingOverview.fromJson(data);
  }

  Future<AutoTradingControl> saveControl(AutoTradingControl control) async {
    final data = await _apiClient.putJson(
      '/auto-trading/controls',
      data: control.toJson(),
    );
    return AutoTradingControl.fromJson(data);
  }

  Future<AutoStrategy> createStrategy(AutoStrategyDraft draft) async {
    final data = await _apiClient.postJson(
      '/auto-trading/strategies',
      data: draft.toJson(),
    );
    return AutoStrategy.fromJson(data);
  }

  Future<AutoStrategy> updateStrategyStatus(
    String strategyId,
    String status, {
    String? message,
  }) async {
    final data = await _apiClient.patchJson(
      '/auto-trading/strategies/$strategyId/status',
      data: {
        'status': status,
        if (message != null) 'message': message,
      },
    );
    return AutoStrategy.fromJson(data);
  }

  Future<AutoEvaluationResult> evaluateStrategies() async {
    final data = await _apiClient.postJson('/auto-trading/evaluate');
    return AutoEvaluationResult.fromJson(data);
  }
}

class AutoTradingOverview {
  const AutoTradingOverview({
    required this.control,
    required this.totalStrategies,
    required this.activeStrategies,
    required this.pausedStrategies,
    required this.runningRuns,
    required this.pendingSignals,
    required this.todayActions,
    required this.strategies,
    required this.events,
    required this.signals,
    required this.actions,
  });

  final AutoTradingControl? control;
  final int totalStrategies;
  final int activeStrategies;
  final int pausedStrategies;
  final int runningRuns;
  final int pendingSignals;
  final int todayActions;
  final List<AutoStrategy> strategies;
  final List<AutoStrategyEvent> events;
  final List<AutoTradeSignal> signals;
  final List<AutoTradeAction> actions;

  factory AutoTradingOverview.fromJson(Map<String, dynamic> json) {
    return AutoTradingOverview(
      control: json['control'] is Map<String, dynamic>
          ? AutoTradingControl.fromJson(json['control'] as Map<String, dynamic>)
          : null,
      totalStrategies: _asInt(json['total_strategies']),
      activeStrategies: _asInt(json['active_strategies']),
      pausedStrategies: _asInt(json['paused_strategies']),
      runningRuns: _asInt(json['running_runs']),
      pendingSignals: _asInt(json['pending_signals']),
      todayActions: _asInt(json['today_actions']),
      strategies: _asList(json['strategies'])
          .map(AutoStrategy.fromJson)
          .toList(growable: false),
      events: _asList(json['events'])
          .map(AutoStrategyEvent.fromJson)
          .toList(growable: false),
      signals: _asList(json['signals'])
          .map(AutoTradeSignal.fromJson)
          .toList(growable: false),
      actions: _asList(json['actions'])
          .map(AutoTradeAction.fromJson)
          .toList(growable: false),
    );
  }

  factory AutoTradingOverview.fallback() {
    return AutoTradingOverview(
      control: AutoTradingControl.fallback(),
      totalStrategies: 0,
      activeStrategies: 0,
      pausedStrategies: 0,
      runningRuns: 0,
      pendingSignals: 0,
      todayActions: 0,
      strategies: const [],
      events: const [],
      signals: const [],
      actions: const [],
    );
  }
}

class AutoTradingControl {
  const AutoTradingControl({
    this.id,
    this.tradingAccountId,
    required this.automationEnabled,
    required this.liveTradingEnabled,
    required this.killSwitchEnabled,
    this.killSwitchReason,
    required this.maxConcurrentStrategies,
    required this.maxDailyAutoOrderAmount,
    required this.maxDailyAutoLossAmount,
    required this.maxSingleOrderAmount,
    required this.requireSignalApproval,
  });

  final String? id;
  final String? tradingAccountId;
  final bool automationEnabled;
  final bool liveTradingEnabled;
  final bool killSwitchEnabled;
  final String? killSwitchReason;
  final int maxConcurrentStrategies;
  final String maxDailyAutoOrderAmount;
  final String maxDailyAutoLossAmount;
  final String maxSingleOrderAmount;
  final bool requireSignalApproval;

  factory AutoTradingControl.fromJson(Map<String, dynamic> json) {
    return AutoTradingControl(
      id: json['id']?.toString(),
      tradingAccountId: json['trading_account_id']?.toString(),
      automationEnabled: json['automation_enabled'] == true,
      liveTradingEnabled: json['live_trading_enabled'] == true,
      killSwitchEnabled: json['kill_switch_enabled'] == true,
      killSwitchReason: json['kill_switch_reason']?.toString(),
      maxConcurrentStrategies: _asInt(json['max_concurrent_strategies'], 3),
      maxDailyAutoOrderAmount: _asMoney(json['max_daily_auto_order_amount']),
      maxDailyAutoLossAmount: _asMoney(json['max_daily_auto_loss_amount']),
      maxSingleOrderAmount: _asMoney(json['max_single_order_amount']),
      requireSignalApproval: json['require_signal_approval'] != false,
    );
  }

  factory AutoTradingControl.fallback() {
    return const AutoTradingControl(
      automationEnabled: false,
      liveTradingEnabled: false,
      killSwitchEnabled: false,
      maxConcurrentStrategies: 3,
      maxDailyAutoOrderAmount: '3000000',
      maxDailyAutoLossAmount: '150000',
      maxSingleOrderAmount: '500000',
      requireSignalApproval: true,
    );
  }

  AutoTradingControl copyWith({
    bool? automationEnabled,
    bool? liveTradingEnabled,
    bool? killSwitchEnabled,
    String? killSwitchReason,
    int? maxConcurrentStrategies,
    String? maxDailyAutoOrderAmount,
    String? maxDailyAutoLossAmount,
    String? maxSingleOrderAmount,
    bool? requireSignalApproval,
  }) {
    return AutoTradingControl(
      id: id,
      tradingAccountId: tradingAccountId,
      automationEnabled: automationEnabled ?? this.automationEnabled,
      liveTradingEnabled: liveTradingEnabled ?? this.liveTradingEnabled,
      killSwitchEnabled: killSwitchEnabled ?? this.killSwitchEnabled,
      killSwitchReason: killSwitchReason ?? this.killSwitchReason,
      maxConcurrentStrategies:
          maxConcurrentStrategies ?? this.maxConcurrentStrategies,
      maxDailyAutoOrderAmount:
          maxDailyAutoOrderAmount ?? this.maxDailyAutoOrderAmount,
      maxDailyAutoLossAmount:
          maxDailyAutoLossAmount ?? this.maxDailyAutoLossAmount,
      maxSingleOrderAmount: maxSingleOrderAmount ?? this.maxSingleOrderAmount,
      requireSignalApproval:
          requireSignalApproval ?? this.requireSignalApproval,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'trading_account_id': tradingAccountId,
      'automation_enabled': automationEnabled,
      'live_trading_enabled': liveTradingEnabled,
      'kill_switch_enabled': killSwitchEnabled,
      'kill_switch_reason': killSwitchReason,
      'max_concurrent_strategies': maxConcurrentStrategies,
      'max_daily_auto_order_amount': maxDailyAutoOrderAmount,
      'max_daily_auto_loss_amount': maxDailyAutoLossAmount,
      'max_single_order_amount': maxSingleOrderAmount,
      'require_signal_approval': requireSignalApproval,
      'config': <String, dynamic>{},
    };
  }
}

class AutoStrategy {
  const AutoStrategy({
    required this.id,
    required this.name,
    this.description,
    required this.strategyType,
    required this.environment,
    required this.status,
    required this.liveTradingAllowed,
    this.maxOrderAmount,
    this.maxDailyLossAmount,
    required this.cooldownSeconds,
    this.config = const {},
  });

  final String id;
  final String name;
  final String? description;
  final String strategyType;
  final String environment;
  final String status;
  final bool liveTradingAllowed;
  final String? maxOrderAmount;
  final String? maxDailyLossAmount;
  final int cooldownSeconds;
  final Map<String, dynamic> config;

  factory AutoStrategy.fromJson(Map<String, dynamic> json) {
    return AutoStrategy(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '자동매매 전략',
      description: json['description']?.toString(),
      strategyType: json['strategy_type']?.toString() ?? 'condition',
      environment: json['environment']?.toString() ?? 'paper',
      status: json['status']?.toString() ?? 'draft',
      liveTradingAllowed: json['live_trading_allowed'] == true,
      maxOrderAmount: json['max_order_amount']?.toString(),
      maxDailyLossAmount: json['max_daily_loss_amount']?.toString(),
      cooldownSeconds: _asInt(json['cooldown_seconds'], 60),
      config: _asMap(json['config']),
    );
  }
}

class AutoStrategyDraft {
  const AutoStrategyDraft({
    required this.name,
    required this.description,
    required this.strategyType,
    required this.assetClass,
    required this.market,
    required this.symbol,
    required this.signalSide,
    required this.triggerChangeRate,
    required this.maxOrderAmount,
    required this.maxDailyLossAmount,
    required this.cooldownSeconds,
  });

  final String name;
  final String description;
  final String strategyType;
  final String assetClass;
  final String market;
  final String symbol;
  final String signalSide;
  final String triggerChangeRate;
  final String maxOrderAmount;
  final String maxDailyLossAmount;
  final int cooldownSeconds;

  Map<String, dynamic> toJson() {
    final normalizedSymbol = _normalizeStrategySymbol(symbol, assetClass);
    return {
      'name': name,
      'description': description,
      'strategy_type': strategyType,
      'environment': 'paper',
      'live_trading_allowed': false,
      'max_order_amount': maxOrderAmount,
      'max_daily_loss_amount': maxDailyLossAmount,
      'cooldown_seconds': cooldownSeconds,
      'config': {
        'template': strategyType,
        'ui_created': true,
        'asset_class': assetClass,
        'market': market,
        'symbol': normalizedSymbol,
        'signal_side': signalSide,
        'trigger_change_rate': triggerChangeRate,
        'order_kind': 'limit',
        'limit_offset_rate': '0',
        'quantity_type': 'amount',
      },
    };
  }
}

String _normalizeStrategySymbol(String symbol, String assetClass) {
  final trimmed = symbol.trim().toUpperCase();
  if (assetClass == 'domestic_stock') {
    return trimmed.replaceAll(RegExp(r'[^0-9]'), '');
  }
  if (assetClass == 'crypto') {
    return trimmed
        .replaceAll('/', '-')
        .replaceAll('_', '-')
        .replaceAll(RegExp(r'[^A-Z0-9:-]'), '');
  }
  return trimmed.replaceAll(RegExp(r'[^A-Z0-9./-]'), '');
}

class AutoTradeSignal {
  const AutoTradeSignal({
    required this.id,
    required this.strategyId,
    this.strategyName,
    required this.symbol,
    required this.name,
    required this.signalType,
    required this.status,
    this.reason,
    required this.confidence,
    required this.marketPrice,
    required this.recommendedQuantity,
    required this.recommendedPrice,
    required this.riskChecks,
    required this.generatedAt,
  });

  final String id;
  final String strategyId;
  final String? strategyName;
  final String symbol;
  final String name;
  final String signalType;
  final String status;
  final String? reason;
  final double confidence;
  final int marketPrice;
  final int recommendedQuantity;
  final int recommendedPrice;
  final Map<String, dynamic> riskChecks;
  final String generatedAt;

  factory AutoTradeSignal.fromJson(Map<String, dynamic> json) {
    return AutoTradeSignal(
      id: json['id']?.toString() ?? '',
      strategyId: json['strategy_id']?.toString() ?? '',
      strategyName: json['strategy_name']?.toString(),
      symbol: json['symbol']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      signalType: json['signal_type']?.toString() ?? 'buy',
      status: json['status']?.toString() ?? 'generated',
      reason: json['reason']?.toString(),
      confidence: _asDouble(json['confidence']),
      marketPrice: _asInt(json['market_price']),
      recommendedQuantity: _asInt(json['recommended_quantity']),
      recommendedPrice: _asInt(json['recommended_price']),
      riskChecks: _asMap(json['risk_checks']),
      generatedAt: json['generated_at']?.toString() ?? '',
    );
  }
}

class AutoTradeAction {
  const AutoTradeAction({
    required this.id,
    required this.strategyId,
    this.strategyName,
    this.signalId,
    this.symbol,
    this.name,
    required this.actionType,
    required this.status,
    required this.requestPayload,
    required this.responsePayload,
    this.errorMessage,
    required this.createdAt,
  });

  final String id;
  final String strategyId;
  final String? strategyName;
  final String? signalId;
  final String? symbol;
  final String? name;
  final String actionType;
  final String status;
  final Map<String, dynamic> requestPayload;
  final Map<String, dynamic> responsePayload;
  final String? errorMessage;
  final String createdAt;

  factory AutoTradeAction.fromJson(Map<String, dynamic> json) {
    return AutoTradeAction(
      id: json['id']?.toString() ?? '',
      strategyId: json['strategy_id']?.toString() ?? '',
      strategyName: json['strategy_name']?.toString(),
      signalId: json['signal_id']?.toString(),
      symbol: json['symbol']?.toString(),
      name: json['name']?.toString(),
      actionType: json['action_type']?.toString() ?? 'notify',
      status: json['status']?.toString() ?? 'pending',
      requestPayload: _asMap(json['request_payload']),
      responsePayload: _asMap(json['response_payload']),
      errorMessage: json['error_message']?.toString(),
      createdAt: json['created_at']?.toString() ?? '',
    );
  }
}

class AutoEvaluationResult {
  const AutoEvaluationResult({
    required this.evaluatedStrategies,
    required this.generatedSignals,
    required this.blockedSignals,
    required this.submittedActions,
    required this.message,
    required this.signals,
    required this.actions,
  });

  final int evaluatedStrategies;
  final int generatedSignals;
  final int blockedSignals;
  final int submittedActions;
  final String message;
  final List<AutoTradeSignal> signals;
  final List<AutoTradeAction> actions;

  factory AutoEvaluationResult.fromJson(Map<String, dynamic> json) {
    return AutoEvaluationResult(
      evaluatedStrategies: _asInt(json['evaluated_strategies']),
      generatedSignals: _asInt(json['generated_signals']),
      blockedSignals: _asInt(json['blocked_signals']),
      submittedActions: _asInt(json['submitted_actions']),
      message: json['message']?.toString() ?? '',
      signals: _asList(json['signals'])
          .map(AutoTradeSignal.fromJson)
          .toList(growable: false),
      actions: _asList(json['actions'])
          .map(AutoTradeAction.fromJson)
          .toList(growable: false),
    );
  }
}

class AutoStrategyEvent {
  const AutoStrategyEvent({
    required this.id,
    required this.severity,
    required this.eventType,
    required this.message,
    required this.createdAt,
  });

  final String id;
  final String severity;
  final String eventType;
  final String message;
  final String createdAt;

  factory AutoStrategyEvent.fromJson(Map<String, dynamic> json) {
    return AutoStrategyEvent(
      id: json['id']?.toString() ?? '',
      severity: json['severity']?.toString() ?? 'info',
      eventType: json['event_type']?.toString() ?? 'event',
      message: json['message']?.toString() ?? '',
      createdAt: json['created_at']?.toString() ?? '',
    );
  }
}

List<Map<String, dynamic>> _asList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => item.cast<String, dynamic>())
      .toList(growable: false);
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _asDouble(Object? value, [double fallback = 0]) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is! Map) return const {};
  return value.cast<String, dynamic>();
}

String _asMoney(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return '0';
  return text.split('.').first;
}
