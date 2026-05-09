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
    );
  }

  factory AutoTradingOverview.fallback() {
    final control = AutoTradingControl.fallback();
    final strategies = [
      const AutoStrategy(
        id: 'demo-momentum',
        name: 'KOSPI 모멘텀 감시',
        description: '거래대금과 5일 추세가 같이 붙을 때만 신호를 생성합니다.',
        strategyType: 'momentum',
        environment: 'paper',
        status: 'active',
        liveTradingAllowed: false,
        maxOrderAmount: '500000',
        maxDailyLossAmount: '80000',
        cooldownSeconds: 90,
      ),
      const AutoStrategy(
        id: 'demo-risk',
        name: '보유 종목 손실 방어',
        description: '평가손실이 정해진 범위를 넘으면 자동으로 매도 검토 신호를 만듭니다.',
        strategyType: 'condition',
        environment: 'paper',
        status: 'paused',
        liveTradingAllowed: false,
        maxOrderAmount: '300000',
        maxDailyLossAmount: '50000',
        cooldownSeconds: 180,
      ),
    ];

    return AutoTradingOverview(
      control: control,
      totalStrategies: strategies.length,
      activeStrategies: 1,
      pausedStrategies: 1,
      runningRuns: 1,
      pendingSignals: 2,
      todayActions: 4,
      strategies: strategies,
      events: const [
        AutoStrategyEvent(
          id: 'demo-event-1',
          severity: 'info',
          eventType: 'signal.generated',
          message: '삼성전자 5일 추세 돌파 조건을 감지했습니다.',
          createdAt: '09:32',
        ),
        AutoStrategyEvent(
          id: 'demo-event-2',
          severity: 'warning',
          eventType: 'risk.blocked',
          message: '단일 주문 한도를 초과해 주문 전송을 보류했습니다.',
          createdAt: '09:18',
        ),
      ],
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
      automationEnabled: true,
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
    );
  }
}

class AutoStrategyDraft {
  const AutoStrategyDraft({
    required this.name,
    required this.description,
    required this.strategyType,
    required this.maxOrderAmount,
    required this.maxDailyLossAmount,
    required this.cooldownSeconds,
  });

  final String name;
  final String description;
  final String strategyType;
  final String maxOrderAmount;
  final String maxDailyLossAmount;
  final int cooldownSeconds;

  Map<String, dynamic> toJson() {
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
      },
    };
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

String _asMoney(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return '0';
  return text.split('.').first;
}
