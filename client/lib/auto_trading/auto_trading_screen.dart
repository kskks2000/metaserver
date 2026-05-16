import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../core/api_client.dart';
import '../widgets/brand_mark.dart';
import '../widgets/thousands_input_formatter.dart';
import 'auto_trading_repository.dart';

enum _AutoTab { dashboard, strategy, execution, risk }

const _autoAssetLabels = {
  'domestic_stock': '국내',
  'overseas_stock': '해외',
  'crypto': '코인',
};

String _autoAssetLabel(String? assetClass) {
  return _autoAssetLabels[assetClass] ?? '국내';
}

String _defaultMarketForAutoAsset(String assetClass) {
  return switch (assetClass) {
    'overseas_stock' => 'NASDAQ',
    'crypto' => 'UPBIT',
    _ => 'KOSPI',
  };
}

List<String> _marketsForAutoAsset(String assetClass) {
  return switch (assetClass) {
    'overseas_stock' => const ['NASDAQ', 'NYSE', 'AMEX'],
    'crypto' => const ['UPBIT', 'BITHUMB', 'BINANCE'],
    _ => const ['KOSPI', 'KOSDAQ', 'ETF', 'ETN'],
  };
}

String _symbolHintForAutoAsset(String assetClass) {
  return switch (assetClass) {
    'overseas_stock' => 'AAPL',
    'crypto' => 'BTC-KRW',
    _ => '005930',
  };
}

class AutoTradingScreen extends ConsumerStatefulWidget {
  const AutoTradingScreen({super.key});

  @override
  ConsumerState<AutoTradingScreen> createState() => _AutoTradingScreenState();
}

class _AutoTradingScreenState extends ConsumerState<AutoTradingScreen> {
  late Future<AutoTradingOverview> _overviewFuture;
  _AutoTab _tab = _AutoTab.dashboard;
  String? _notice;
  bool _saving = false;
  bool _evaluating = false;

  @override
  void initState() {
    super.initState();
    _overviewFuture = _loadOverview();
  }

  Future<AutoTradingOverview> _loadOverview() async {
    try {
      final overview =
          await ref.read(autoTradingRepositoryProvider).loadOverview();
      if (mounted) setState(() => _notice = null);
      return overview;
    } catch (error) {
      if (mounted) {
        setState(() {
          _notice = apiFailureMessage(error) ??
              '자동매매 API에 연결하지 못했습니다. 실제 데이터 대신 빈 상태로 표시합니다.';
        });
      }
      if (isRecoverableApiFailure(error)) return AutoTradingOverview.fallback();
      rethrow;
    }
  }

  Future<void> _refresh() async {
    setState(() => _overviewFuture = _loadOverview());
    await _overviewFuture;
  }

  Future<void> _saveControl(AutoTradingControl control) async {
    setState(() => _saving = true);
    try {
      await ref.read(autoTradingRepositoryProvider).saveControl(control);
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = apiFailureMessage(error) ?? error.toString();
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createStrategy(AutoStrategyDraft draft) async {
    setState(() => _saving = true);
    try {
      await ref.read(autoTradingRepositoryProvider).createStrategy(draft);
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = apiFailureMessage(error) ?? error.toString();
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changeStatus(AutoStrategy strategy, String status) async {
    setState(() => _saving = true);
    try {
      await ref
          .read(autoTradingRepositoryProvider)
          .updateStrategyStatus(strategy.id, status);
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = apiFailureMessage(error) ?? error.toString();
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteStrategy(AutoStrategy strategy) async {
    setState(() => _saving = true);
    try {
      await ref.read(autoTradingRepositoryProvider).deleteStrategy(strategy.id);
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${strategy.name} 전략을 삭제했습니다.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = apiFailureMessage(error) ?? error.toString();
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _evaluate() async {
    setState(() => _evaluating = true);
    try {
      final result =
          await ref.read(autoTradingRepositoryProvider).evaluateStrategies();
      if (!mounted) return;
      setState(() => _notice = result.message);
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = apiFailureMessage(error) ?? error.toString();
      });
    } finally {
      if (mounted) setState(() => _evaluating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MetaServerColors.canvas,
      appBar: AppBar(
        toolbarHeight: 70,
        backgroundColor: MetaServerColors.canvas,
        surfaceTintColor: Colors.transparent,
        title: const BrandMark(size: 38),
        actions: [
          _ToolbarButton(
            tooltip: '주식매매',
            icon: Icons.show_chart_rounded,
            onPressed: () => context.go('/trading'),
          ),
          const SizedBox(width: 8),
          _ToolbarButton(
            tooltip: '새로고침',
            icon: Icons.refresh_rounded,
            onPressed: _saving || _evaluating ? null : _refresh,
          ),
          const SizedBox(width: 14),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<AutoTradingOverview>(
          future: _overviewFuture,
          builder: (context, snapshot) {
            final overview = snapshot.data ?? AutoTradingOverview.fallback();
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_notice != null) ...[
                        _Notice(message: _notice!),
                        const SizedBox(height: 14),
                      ],
                      _HeroConsole(
                        overview: overview,
                        saving: _saving,
                        onToggleAutomation: (enabled) {
                          final base =
                              overview.control ?? AutoTradingControl.fallback();
                          _saveControl(base.copyWith(
                            automationEnabled: enabled,
                            killSwitchEnabled:
                                enabled ? false : base.killSwitchEnabled,
                          ));
                        },
                        onToggleKillSwitch: (enabled) {
                          final base =
                              overview.control ?? AutoTradingControl.fallback();
                          _saveControl(base.copyWith(
                            killSwitchEnabled: enabled,
                            automationEnabled:
                                enabled ? false : base.automationEnabled,
                            killSwitchReason: enabled ? '사용자 수동 중지' : '',
                          ));
                        },
                      ),
                      const SizedBox(height: 16),
                      _TabStrip(
                        selected: _tab,
                        onSelected: (tab) => setState(() => _tab = tab),
                      ),
                      const SizedBox(height: 16),
                      if (snapshot.connectionState == ConnectionState.waiting)
                        const LinearProgressIndicator(minHeight: 3),
                      _SelectedTab(
                        tab: _tab,
                        overview: overview,
                        saving: _saving,
                        evaluating: _evaluating,
                        onCreateStrategy: _createStrategy,
                        onChangeStatus: _changeStatus,
                        onDeleteStrategy: _deleteStrategy,
                        onSaveControl: _saveControl,
                        onEvaluate: _evaluate,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SelectedTab extends StatelessWidget {
  const _SelectedTab({
    required this.tab,
    required this.overview,
    required this.saving,
    required this.evaluating,
    required this.onCreateStrategy,
    required this.onChangeStatus,
    required this.onDeleteStrategy,
    required this.onSaveControl,
    required this.onEvaluate,
  });

  final _AutoTab tab;
  final AutoTradingOverview overview;
  final bool saving;
  final bool evaluating;
  final ValueChanged<AutoStrategyDraft> onCreateStrategy;
  final void Function(AutoStrategy strategy, String status) onChangeStatus;
  final ValueChanged<AutoStrategy> onDeleteStrategy;
  final ValueChanged<AutoTradingControl> onSaveControl;
  final VoidCallback onEvaluate;

  @override
  Widget build(BuildContext context) {
    return switch (tab) {
      _AutoTab.dashboard => _DashboardTab(overview: overview),
      _AutoTab.strategy => _StrategyTab(
          overview: overview,
          saving: saving,
          onCreateStrategy: onCreateStrategy,
          onChangeStatus: onChangeStatus,
          onDeleteStrategy: onDeleteStrategy,
        ),
      _AutoTab.execution => _ExecutionTab(
          overview: overview,
          evaluating: evaluating,
          onEvaluate: onEvaluate,
        ),
      _AutoTab.risk => _RiskTab(
          control: overview.control ?? AutoTradingControl.fallback(),
          saving: saving,
          onSave: onSaveControl,
        ),
    };
  }
}

class _HeroConsole extends StatelessWidget {
  const _HeroConsole({
    required this.overview,
    required this.saving,
    required this.onToggleAutomation,
    required this.onToggleKillSwitch,
  });

  final AutoTradingOverview overview;
  final bool saving;
  final ValueChanged<bool> onToggleAutomation;
  final ValueChanged<bool> onToggleKillSwitch;

  @override
  Widget build(BuildContext context) {
    final control = overview.control ?? AutoTradingControl.fallback();
    final enabled = control.automationEnabled && !control.killSwitchEnabled;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: MetaServerColors.ink,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: MetaServerColors.ink.withValues(alpha: 0.16),
            blurRadius: 32,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final header = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: MetaServerColors.mint.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: MetaServerColors.mint.withValues(alpha: 0.28),
                      ),
                    ),
                    child: Icon(
                      enabled
                          ? Icons.precision_manufacturing_rounded
                          : Icons.power_settings_new_rounded,
                      color: MetaServerColors.mint,
                      size: 31,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '자동매매 콘솔',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          enabled
                              ? '활성 전략이 실제 KIS 시세와 리스크 규칙으로 평가됩니다.'
                              : '자동 주문은 비활성 상태입니다.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.72),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _DarkPill(
                    icon: Icons.memory_rounded,
                    label: '${overview.runningRuns}개 실행',
                    color: MetaServerColors.mint,
                  ),
                  _DarkPill(
                    icon: Icons.rule_rounded,
                    label: '${overview.pendingSignals}개 신호 대기',
                    color: MetaServerColors.cyan,
                  ),
                  _DarkPill(
                    icon: Icons.receipt_long_rounded,
                    label: '오늘 ${overview.todayActions}건',
                    color: MetaServerColors.green,
                  ),
                ],
              ),
            ],
          );

          final controls = _HeroControls(
            control: control,
            saving: saving,
            onToggleAutomation: onToggleAutomation,
            onToggleKillSwitch: onToggleKillSwitch,
          );

          if (constraints.maxWidth >= 780) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(flex: 6, child: header),
                const SizedBox(width: 18),
                Expanded(flex: 4, child: controls),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 18),
              controls,
            ],
          );
        },
      ),
    );
  }
}

class _HeroControls extends StatelessWidget {
  const _HeroControls({
    required this.control,
    required this.saving,
    required this.onToggleAutomation,
    required this.onToggleKillSwitch,
  });

  final AutoTradingControl control;
  final bool saving;
  final ValueChanged<bool> onToggleAutomation;
  final ValueChanged<bool> onToggleKillSwitch;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: [
          _DarkSwitchRow(
            label: '자동 감시',
            icon: Icons.sensors_rounded,
            value: control.automationEnabled,
            onChanged: saving ? null : onToggleAutomation,
          ),
          const Divider(height: 18, color: Color(0x3353CAA0)),
          _DarkSwitchRow(
            label: '긴급 중지',
            icon: Icons.gpp_bad_outlined,
            value: control.killSwitchEnabled,
            danger: true,
            onChanged: saving ? null : onToggleKillSwitch,
          ),
        ],
      ),
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.selected,
    required this.onSelected,
  });

  final _AutoTab selected;
  final ValueChanged<_AutoTab> onSelected;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_AutoTab>(
      selected: {selected},
      onSelectionChanged: (value) => onSelected(value.first),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: _AutoTab.dashboard,
          icon: Icon(Icons.space_dashboard_outlined),
          label: Text('현황'),
        ),
        ButtonSegment(
          value: _AutoTab.strategy,
          icon: Icon(Icons.account_tree_outlined),
          label: Text('전략'),
        ),
        ButtonSegment(
          value: _AutoTab.execution,
          icon: Icon(Icons.bolt_outlined),
          label: Text('실행'),
        ),
        ButtonSegment(
          value: _AutoTab.risk,
          icon: Icon(Icons.health_and_safety_outlined),
          label: Text('리스크'),
        ),
      ],
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return MetaServerColors.ink;
          }
          return Colors.white;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.white;
          }
          return MetaServerColors.ink;
        }),
        side: WidgetStateProperty.all(
          const BorderSide(color: MetaServerColors.line),
        ),
      ),
    );
  }
}

class _DashboardTab extends StatelessWidget {
  const _DashboardTab({required this.overview});

  final AutoTradingOverview overview;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ResponsiveGrid(
          minTileWidth: 170,
          children: [
            _MetricPanel(
              icon: Icons.account_tree_rounded,
              label: '전체 전략',
              value: '${overview.totalStrategies}',
              accent: MetaServerColors.cyan,
            ),
            _MetricPanel(
              icon: Icons.play_circle_outline_rounded,
              label: '활성 전략',
              value: '${overview.activeStrategies}',
              accent: MetaServerColors.green,
            ),
            _MetricPanel(
              icon: Icons.pending_actions_rounded,
              label: '대기 신호',
              value: '${overview.pendingSignals}',
              accent: MetaServerColors.amber,
            ),
            _MetricPanel(
              icon: Icons.receipt_long_rounded,
              label: '오늘 액션',
              value: '${overview.todayActions}',
              accent: MetaServerColors.mint,
            ),
          ],
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final strategies = _Panel(
              title: '전략 상태',
              icon: Icons.route_rounded,
              child: overview.strategies.isEmpty
                  ? const _EmptyState(
                      icon: Icons.account_tree_outlined,
                      title: '등록된 전략이 없습니다',
                      subtitle: '전략 탭에서 종목, 조건, 한도를 설정해 주세요.',
                    )
                  : Column(
                      children: [
                        for (final strategy in overview.strategies)
                          _CompactStrategyRow(strategy: strategy),
                      ],
                    ),
            );
            final events = _Panel(
              title: '최근 이벤트',
              icon: Icons.timeline_rounded,
              child: _EventList(events: overview.events),
            );

            if (constraints.maxWidth >= 860) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 6, child: strategies),
                  const SizedBox(width: 16),
                  Expanded(flex: 4, child: events),
                ],
              );
            }
            return Column(
              children: [
                strategies,
                const SizedBox(height: 16),
                events,
              ],
            );
          },
        ),
      ],
    );
  }
}

class _StrategyTab extends StatefulWidget {
  const _StrategyTab({
    required this.overview,
    required this.saving,
    required this.onCreateStrategy,
    required this.onChangeStatus,
    required this.onDeleteStrategy,
  });

  final AutoTradingOverview overview;
  final bool saving;
  final ValueChanged<AutoStrategyDraft> onCreateStrategy;
  final void Function(AutoStrategy strategy, String status) onChangeStatus;
  final ValueChanged<AutoStrategy> onDeleteStrategy;

  @override
  State<_StrategyTab> createState() => _StrategyTabState();
}

class _StrategyTabState extends State<_StrategyTab> {
  final _nameController = TextEditingController(text: '삼성전자 모멘텀 감시');
  final _descriptionController = TextEditingController(
    text: '실시간 현재가 등락률이 기준을 넘으면 승인 대기 신호를 생성합니다.',
  );
  final _symbolController = TextEditingController(text: '005930');
  final _triggerController = TextEditingController(text: '1.0');
  final _maxOrderController = TextEditingController(
    text: formatIntegerInputText('500000'),
  );
  final _maxLossController = TextEditingController(
    text: formatIntegerInputText('100000'),
  );
  String _assetClass = 'domestic_stock';
  String _market = 'KOSPI';
  String _strategyType = 'momentum';
  String _signalSide = 'buy';
  int _cooldownSeconds = 90;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _symbolController.dispose();
    _triggerController.dispose();
    _maxOrderController.dispose();
    _maxLossController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final builder = _Panel(
          title: '전략 설계',
          icon: Icons.schema_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TextInput(
                controller: _nameController,
                label: '전략 이름',
                icon: Icons.edit_note_rounded,
              ),
              const SizedBox(height: 12),
              _TextInput(
                controller: _descriptionController,
                label: '전략 설명',
                icon: Icons.notes_rounded,
                minLines: 2,
              ),
              const SizedBox(height: 14),
              _FieldTitle(icon: Icons.public_rounded, label: '거래 자산'),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                selected: {_assetClass},
                onSelectionChanged: (value) {
                  final nextAssetClass = value.first;
                  setState(() {
                    _assetClass = nextAssetClass;
                    _market = _defaultMarketForAutoAsset(nextAssetClass);
                    _symbolController.text =
                        _symbolHintForAutoAsset(nextAssetClass);
                  });
                },
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: 'domestic_stock',
                    icon: Icon(Icons.flag_circle_outlined),
                    label: Text('국내'),
                  ),
                  ButtonSegment(
                    value: 'overseas_stock',
                    icon: Icon(Icons.public_rounded),
                    label: Text('해외'),
                  ),
                  ButtonSegment(
                    value: 'crypto',
                    icon: Icon(Icons.currency_bitcoin_rounded),
                    label: Text('코인'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _market,
                      decoration: const InputDecoration(
                        labelText: '시장',
                        prefixIcon: Icon(Icons.account_balance_outlined),
                      ),
                      items: [
                        for (final market in _marketsForAutoAsset(_assetClass))
                          DropdownMenuItem(value: market, child: Text(market)),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _market = value);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _TextInput(
                      controller: _symbolController,
                      label: '종목코드',
                      icon: Icons.tag_rounded,
                      hintText: _symbolHintForAutoAsset(_assetClass),
                      keyboardType: _assetClass == 'domestic_stock'
                          ? TextInputType.number
                          : TextInputType.text,
                      digitsOnly: _assetClass == 'domestic_stock',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _TextInput(
                      controller: _triggerController,
                      label: '등락률 기준(%)',
                      icon: Icons.percent_rounded,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _FieldTitle(icon: Icons.category_outlined, label: '전략 유형'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ChoiceChip(
                    label: '모멘텀',
                    selected: _strategyType == 'momentum',
                    onSelected: () => setState(() {
                      _strategyType = 'momentum';
                    }),
                  ),
                  _ChoiceChip(
                    label: '조건식',
                    selected: _strategyType == 'condition',
                    onSelected: () => setState(() {
                      _strategyType = 'condition';
                    }),
                  ),
                  _ChoiceChip(
                    label: '분할매수',
                    selected: _strategyType == 'dca',
                    onSelected: () => setState(() {
                      _strategyType = 'dca';
                      _signalSide = 'buy';
                    }),
                  ),
                  _ChoiceChip(
                    label: '그리드',
                    selected: _strategyType == 'grid',
                    onSelected: () => setState(() {
                      _strategyType = 'grid';
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _FieldTitle(icon: Icons.swap_vert_rounded, label: '신호 방향'),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                selected: {_signalSide},
                onSelectionChanged: (value) {
                  setState(() => _signalSide = value.first);
                },
                showSelectedIcon: false,
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (!states.contains(WidgetState.selected)) {
                      return Colors.white;
                    }
                    return _signalSide == 'buy'
                        ? MetaServerColors.buy
                        : MetaServerColors.sell;
                  }),
                ),
                segments: const [
                  ButtonSegment(
                    value: 'buy',
                    icon: Icon(Icons.add_shopping_cart_rounded),
                    label: Text('매수'),
                  ),
                  ButtonSegment(
                    value: 'sell',
                    icon: Icon(Icons.sell_outlined),
                    label: Text('매도'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _TextInput(
                      controller: _maxOrderController,
                      label: '1회 주문 한도',
                      icon: Icons.payments_outlined,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _TextInput(
                      controller: _maxLossController,
                      label: '일 손실 한도',
                      icon: Icons.trending_down_rounded,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _FieldTitle(
                icon: Icons.timer_outlined,
                label: '재평가 대기 $_cooldownSeconds초',
              ),
              Slider(
                value: _cooldownSeconds.toDouble(),
                min: 30,
                max: 300,
                divisions: 9,
                label: '$_cooldownSeconds초',
                onChanged: (value) => setState(() {
                  _cooldownSeconds = value.round();
                }),
              ),
              const SizedBox(height: 6),
              FilledButton.icon(
                onPressed: widget.saving ? null : _saveDraft,
                icon: const Icon(Icons.save_outlined),
                label: const Text('전략 저장'),
              ),
            ],
          ),
        );

        final list = _Panel(
          title: '전략 목록',
          icon: Icons.account_tree_outlined,
          child: widget.overview.strategies.isEmpty
              ? const _EmptyState(
                  icon: Icons.route_outlined,
                  title: '아직 만든 전략이 없습니다',
                  subtitle: '저장한 전략은 초안 상태로 시작하고, 활성화해야 평가됩니다.',
                )
              : Column(
                  children: [
                    for (final strategy in widget.overview.strategies)
                      _StrategyCard(
                        strategy: strategy,
                        saving: widget.saving,
                        onChangeStatus: widget.onChangeStatus,
                        onDeleteStrategy: widget.onDeleteStrategy,
                      ),
                  ],
                ),
        );

        if (constraints.maxWidth >= 920) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: builder),
              const SizedBox(width: 16),
              Expanded(flex: 5, child: list),
            ],
          );
        }
        return Column(
          children: [
            builder,
            const SizedBox(height: 16),
            list,
          ],
        );
      },
    );
  }

  void _saveDraft() {
    widget.onCreateStrategy(
      AutoStrategyDraft(
        name: _nameController.text.trim().isEmpty
            ? '자동매매 전략'
            : _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        strategyType: _strategyType,
        assetClass: _assetClass,
        market: _market,
        symbol: _symbolController.text.trim(),
        signalSide: _signalSide,
        triggerChangeRate: _triggerController.text.trim().isEmpty
            ? '1.0'
            : _triggerController.text.trim(),
        maxOrderAmount: removeNumberGrouping(_maxOrderController.text),
        maxDailyLossAmount: removeNumberGrouping(_maxLossController.text),
        cooldownSeconds: _cooldownSeconds,
      ),
    );
  }
}

class _ExecutionTab extends StatelessWidget {
  const _ExecutionTab({
    required this.overview,
    required this.evaluating,
    required this.onEvaluate,
  });

  final AutoTradingOverview overview;
  final bool evaluating;
  final VoidCallback onEvaluate;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ExecutionToolbar(
          overview: overview,
          evaluating: evaluating,
          onEvaluate: onEvaluate,
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final queue = _Panel(
              title: '신호 큐',
              icon: Icons.rule_folder_outlined,
              child: overview.signals.isEmpty
                  ? const _EmptyState(
                      icon: Icons.bolt_outlined,
                      title: '대기 중인 자동매매 신호가 없습니다',
                      subtitle:
                          '활성 전략을 만든 뒤 전략 평가를 실행하면 실제 KIS 현재가 기준으로 신호가 생성됩니다.',
                    )
                  : Column(
                      children: [
                        for (final signal in overview.signals)
                          _SignalRow(signal: signal),
                      ],
                    ),
            );

            final actions = _Panel(
              title: '액션 로그',
              icon: Icons.manage_history_rounded,
              child: overview.actions.isEmpty
                  ? const _EmptyState(
                      icon: Icons.history_toggle_off_rounded,
                      title: '기록된 자동매매 액션이 없습니다',
                      subtitle: '신호 승인 대기, 리스크 차단, 주문 전송 결과가 여기에 기록됩니다.',
                    )
                  : Column(
                      children: [
                        for (final action in overview.actions)
                          _ActionRow(action: action),
                      ],
                    ),
            );

            if (constraints.maxWidth >= 860) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: queue),
                  const SizedBox(width: 16),
                  Expanded(child: actions),
                ],
              );
            }
            return Column(
              children: [
                queue,
                const SizedBox(height: 16),
                actions,
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ExecutionToolbar extends StatelessWidget {
  const _ExecutionToolbar({
    required this.overview,
    required this.evaluating,
    required this.onEvaluate,
  });

  final AutoTradingOverview overview;
  final bool evaluating;
  final VoidCallback onEvaluate;

  @override
  Widget build(BuildContext context) {
    final control = overview.control ?? AutoTradingControl.fallback();
    final canEvaluate = control.automationEnabled && !control.killSwitchEnabled;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Row(
        children: [
          _SoftIcon(
              icon: Icons.verified_rounded, color: MetaServerColors.green),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              canEvaluate
                  ? '활성 전략 ${overview.activeStrategies}개를 KIS 현재가와 리스크 규칙으로 평가할 수 있습니다.'
                  : '자동 감시를 켜고 긴급 중지를 해제하면 전략 평가를 실행할 수 있습니다.',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: canEvaluate && !evaluating ? onEvaluate : null,
            icon: evaluating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Text(evaluating ? '평가 중' : '전략 평가 실행'),
          ),
        ],
      ),
    );
  }
}

class _RiskTab extends StatefulWidget {
  const _RiskTab({
    required this.control,
    required this.saving,
    required this.onSave,
  });

  final AutoTradingControl control;
  final bool saving;
  final ValueChanged<AutoTradingControl> onSave;

  @override
  State<_RiskTab> createState() => _RiskTabState();
}

class _RiskTabState extends State<_RiskTab> {
  late TextEditingController _maxSingleController;
  late TextEditingController _maxDailyOrderController;
  late TextEditingController _maxDailyLossController;
  late int _maxStrategies;
  late bool _requireApproval;
  late bool _liveTrading;

  @override
  void initState() {
    super.initState();
    _setFromControl(widget.control);
  }

  @override
  void didUpdateWidget(covariant _RiskTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.control != widget.control) {
      _maxSingleController.dispose();
      _maxDailyOrderController.dispose();
      _maxDailyLossController.dispose();
      _setFromControl(widget.control);
    }
  }

  void _setFromControl(AutoTradingControl control) {
    _maxSingleController = TextEditingController(
      text: formatIntegerInputText(control.maxSingleOrderAmount),
    );
    _maxDailyOrderController = TextEditingController(
      text: formatIntegerInputText(control.maxDailyAutoOrderAmount),
    );
    _maxDailyLossController = TextEditingController(
      text: formatIntegerInputText(control.maxDailyAutoLossAmount),
    );
    _maxStrategies = control.maxConcurrentStrategies;
    _requireApproval = control.requireSignalApproval;
    _liveTrading = control.liveTradingEnabled;
  }

  @override
  void dispose() {
    _maxSingleController.dispose();
    _maxDailyOrderController.dispose();
    _maxDailyLossController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final settings = _Panel(
          title: '주문 보호장치',
          icon: Icons.health_and_safety_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TextInput(
                controller: _maxSingleController,
                label: '단일 자동주문 한도',
                icon: Icons.payments_outlined,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              _TextInput(
                controller: _maxDailyOrderController,
                label: '일 자동주문 총액 한도',
                icon: Icons.account_balance_wallet_outlined,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              _TextInput(
                controller: _maxDailyLossController,
                label: '일 손실 중지 한도',
                icon: Icons.warning_amber_rounded,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 14),
              _FieldTitle(
                icon: Icons.layers_outlined,
                label: '동시 평가 전략 $_maxStrategies개',
              ),
              Slider(
                value: _maxStrategies.toDouble(),
                min: 0,
                max: 10,
                divisions: 10,
                label: '$_maxStrategies개',
                onChanged: (value) => setState(() {
                  _maxStrategies = value.round();
                }),
              ),
              const SizedBox(height: 8),
              _PlainSwitchRow(
                icon: Icons.verified_user_outlined,
                label: '신호 승인 후 주문',
                value: _requireApproval,
                onChanged: (value) => setState(() {
                  _requireApproval = value;
                }),
              ),
              const SizedBox(height: 8),
              _PlainSwitchRow(
                icon: Icons.real_estate_agent_outlined,
                label: '실전 주문 허용',
                value: _liveTrading,
                onChanged: (value) => setState(() {
                  _liveTrading = value;
                }),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: widget.saving
                    ? null
                    : () {
                        widget.onSave(
                          widget.control.copyWith(
                            maxSingleOrderAmount: removeNumberGrouping(
                              _maxSingleController.text,
                            ),
                            maxDailyAutoOrderAmount: removeNumberGrouping(
                              _maxDailyOrderController.text,
                            ),
                            maxDailyAutoLossAmount: removeNumberGrouping(
                              _maxDailyLossController.text,
                            ),
                            maxConcurrentStrategies: _maxStrategies,
                            requireSignalApproval: _requireApproval,
                            liveTradingEnabled: _liveTrading,
                          ),
                        );
                      },
                icon: const Icon(Icons.lock_outline_rounded),
                label: const Text('리스크 설정 저장'),
              ),
            ],
          ),
        );

        final guard = _Panel(
          title: '실제 주문 게이트',
          icon: Icons.fact_check_outlined,
          child: Column(
            children: [
              _GuardRow(
                icon: Icons.sensors_rounded,
                title: '자동 감시',
                value: widget.control.automationEnabled ? '켜짐' : '꺼짐',
                passed: widget.control.automationEnabled,
              ),
              _GuardRow(
                icon: Icons.pan_tool_alt_outlined,
                title: '승인 필요',
                value: widget.control.requireSignalApproval ? '켜짐' : '꺼짐',
                passed: widget.control.requireSignalApproval,
              ),
              _GuardRow(
                icon: Icons.payments_outlined,
                title: '단일 주문 한도',
                value: _won(widget.control.maxSingleOrderAmount),
                passed: int.tryParse(widget.control.maxSingleOrderAmount) != 0,
              ),
              _GuardRow(
                icon: Icons.account_balance_wallet_outlined,
                title: '일 주문 총액 한도',
                value: _won(widget.control.maxDailyAutoOrderAmount),
                passed:
                    int.tryParse(widget.control.maxDailyAutoOrderAmount) != 0,
              ),
              const SizedBox(height: 12),
              const _RiskNote(),
            ],
          ),
        );

        if (constraints.maxWidth >= 900) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: settings),
              const SizedBox(width: 16),
              Expanded(flex: 4, child: guard),
            ],
          );
        }
        return Column(
          children: [
            settings,
            const SizedBox(height: 16),
            guard,
          ],
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
        boxShadow: [
          BoxShadow(
            color: MetaServerColors.ink.withValues(alpha: 0.05),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SoftIcon(icon: icon),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: MetaServerColors.ink,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _ResponsiveGrid extends StatelessWidget {
  const _ResponsiveGrid({
    required this.children,
    required this.minTileWidth,
  });

  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = (constraints.maxWidth / minTileWidth)
            .floor()
            .clamp(1, children.length);
        return GridView.count(
          crossAxisCount: count,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 2.45,
          children: children,
        );
      },
    );
  }
}

class _MetricPanel extends StatelessWidget {
  const _MetricPanel({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Row(
        children: [
          _SoftIcon(icon: icon, color: accent, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: MetaServerColors.ink.withValues(alpha: 0.58),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    color: MetaServerColors.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 24,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StrategyCard extends StatelessWidget {
  const _StrategyCard({
    required this.strategy,
    required this.saving,
    required this.onChangeStatus,
    required this.onDeleteStrategy,
  });

  final AutoStrategy strategy;
  final bool saving;
  final void Function(AutoStrategy strategy, String status) onChangeStatus;
  final ValueChanged<AutoStrategy> onDeleteStrategy;

  @override
  Widget build(BuildContext context) {
    final assetClass = strategy.config['asset_class']?.toString();
    final market = strategy.config['market']?.toString();
    final symbol = strategy.config['symbol']?.toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MetaServerColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SoftIcon(icon: _strategyIcon(strategy.strategyType)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strategy.name,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        _strategyLabel(strategy.strategyType),
                        strategy.environment == 'live' ? '실전' : '모의',
                        _autoAssetLabel(assetClass),
                        if (market != null && market.isNotEmpty) market,
                        if (symbol != null && symbol.isNotEmpty) symbol,
                      ].join(' · '),
                      style: TextStyle(
                        color: MetaServerColors.ink.withValues(alpha: 0.58),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              _StatusBadge(status: strategy.status),
            ],
          ),
          if ((strategy.description ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              strategy.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: MetaServerColors.ink.withValues(alpha: 0.72),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoChip(
                icon: Icons.payments_outlined,
                label: '한도 ${_won(strategy.maxOrderAmount)}',
              ),
              _InfoChip(
                icon: Icons.timer_outlined,
                label: '${strategy.cooldownSeconds}초 대기',
              ),
              if (strategy.status == 'active')
                _SmallButton(
                  icon: Icons.pause_rounded,
                  label: '일시정지',
                  onPressed:
                      saving ? null : () => onChangeStatus(strategy, 'paused'),
                )
              else
                _SmallButton(
                  icon: Icons.play_arrow_rounded,
                  label: '활성화',
                  onPressed:
                      saving ? null : () => onChangeStatus(strategy, 'active'),
                ),
              _SmallButton(
                icon: Icons.stop_rounded,
                label: '중지',
                onPressed:
                    saving ? null : () => onChangeStatus(strategy, 'stopped'),
              ),
              _SmallButton(
                icon: Icons.delete_outline_rounded,
                label: '삭제',
                foregroundColor: MetaServerColors.danger,
                onPressed: saving ? null : () => _confirmDelete(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('전략 삭제'),
          content: Text(
            '${strategy.name} 전략을 삭제할까요? 삭제하면 전략 목록과 자동 평가 대상에서 제외됩니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('취소'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('삭제'),
              style: FilledButton.styleFrom(
                backgroundColor: MetaServerColors.danger,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      onDeleteStrategy(strategy);
    }
  }
}

class _CompactStrategyRow extends StatelessWidget {
  const _CompactStrategyRow({required this.strategy});

  final AutoStrategy strategy;

  @override
  Widget build(BuildContext context) {
    final assetClass = strategy.config['asset_class']?.toString();
    final market = strategy.config['market']?.toString();
    final symbol = strategy.config['symbol']?.toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MetaServerColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Row(
        children: [
          _SoftIcon(icon: _strategyIcon(strategy.strategyType), size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strategy.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    _strategyLabel(strategy.strategyType),
                    _autoAssetLabel(assetClass),
                    if (market != null && market.isNotEmpty) market,
                    if (symbol != null && symbol.isNotEmpty) symbol,
                    strategy.environment == 'live' ? '실전' : '모의',
                  ].join(' · '),
                  style: TextStyle(
                    color: MetaServerColors.ink.withValues(alpha: 0.58),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          _StatusBadge(status: strategy.status),
        ],
      ),
    );
  }
}

class _SignalRow extends StatelessWidget {
  const _SignalRow({required this.signal});

  final AutoTradeSignal signal;

  @override
  Widget build(BuildContext context) {
    final blocked = signal.status == 'blocked';
    final color = blocked ? MetaServerColors.amber : MetaServerColors.green;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: MetaServerColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Row(
        children: [
          _SoftIcon(
            icon: blocked ? Icons.block_rounded : Icons.bolt_rounded,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${signal.symbol} · ${_sideLabel(signal.signalType)} · ${_signalStatus(signal.status)}',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  signal.reason ?? signal.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: MetaServerColors.ink.withValues(alpha: 0.62),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '현재가 ${_won(signal.marketPrice.toString())} · 권장 ${signal.recommendedQuantity}주',
                  style: TextStyle(
                    color: MetaServerColors.ink.withValues(alpha: 0.5),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 58,
            child: Column(
              children: [
                Text(
                  '${(signal.confidence * 100).round()}',
                  style: TextStyle(color: color, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: signal.confidence.clamp(0, 1),
                  minHeight: 4,
                  backgroundColor: MetaServerColors.line,
                  color: color,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action});

  final AutoTradeAction action;

  @override
  Widget build(BuildContext context) {
    final color = switch (action.status) {
      'succeeded' || 'sent' => MetaServerColors.green,
      'failed' || 'canceled' => MetaServerColors.danger,
      _ => MetaServerColors.amber,
    };
    final title = [
      action.symbol ?? action.requestPayload['symbol']?.toString() ?? '종목',
      _actionLabel(action.actionType),
      _actionStatus(action.status),
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: MetaServerColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Row(
        children: [
          _SoftIcon(icon: Icons.receipt_long_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text(
                  action.errorMessage ??
                      action.requestPayload['message']?.toString() ??
                      action.strategyName ??
                      '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: MetaServerColors.ink.withValues(alpha: 0.62),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Text(
            _shortTime(action.createdAt),
            style: TextStyle(
              color: MetaServerColors.ink.withValues(alpha: 0.5),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _EventList extends StatelessWidget {
  const _EventList({required this.events});

  final List<AutoStrategyEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const _EmptyState(
        icon: Icons.timeline_outlined,
        title: '아직 이벤트가 없습니다',
        subtitle: '전략 실행과 리스크 판단 결과가 여기에 기록됩니다.',
      );
    }
    return Column(
      children: [
        for (final event in events) _EventRow(event: event),
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final AutoStrategyEvent event;

  @override
  Widget build(BuildContext context) {
    final color = switch (event.severity) {
      'warning' => MetaServerColors.amber,
      'error' || 'critical' => MetaServerColors.danger,
      _ => MetaServerColors.cyan,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, color: color, size: 10),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.eventType,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  event.message,
                  style: TextStyle(
                    color: MetaServerColors.ink.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Text(
            _shortTime(event.createdAt),
            style: TextStyle(
              color: MetaServerColors.ink.withValues(alpha: 0.5),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _GuardRow extends StatelessWidget {
  const _GuardRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.passed,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool passed;

  @override
  Widget build(BuildContext context) {
    final color = passed ? MetaServerColors.green : MetaServerColors.amber;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title,
                style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
          Text(value,
              style: TextStyle(color: color, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

class _RiskNote extends StatelessWidget {
  const _RiskNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: MetaServerColors.mint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: MetaServerColors.mint.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: MetaServerColors.green),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '자동 주문은 자동 감시, 긴급 중지 해제, 전략 활성화, 한도, 보유/현금, 실전 허용 게이트를 모두 통과한 경우에만 전송됩니다.',
              style: TextStyle(
                color: MetaServerColors.ink.withValues(alpha: 0.74),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TextInput extends StatelessWidget {
  const _TextInput({
    required this.controller,
    required this.label,
    required this.icon,
    this.hintText,
    this.keyboardType,
    this.minLines = 1,
    this.digitsOnly = false,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? hintText;
  final TextInputType? keyboardType;
  final int minLines;
  final bool digitsOnly;

  @override
  Widget build(BuildContext context) {
    final numeric = keyboardType == TextInputType.number;
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: digitsOnly
          ? [FilteringTextInputFormatter.digitsOnly]
          : numeric
              ? const [ThousandsSeparatorInputFormatter()]
              : null,
      minLines: minLines,
      maxLines: minLines == 1 ? 1 : 4,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        prefixIcon: Icon(icon),
      ),
      style: const TextStyle(fontWeight: FontWeight.w800),
    );
  }
}

class _PlainSwitchRow extends StatelessWidget {
  const _PlainSwitchRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: MetaServerColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Row(
        children: [
          Icon(icon, color: MetaServerColors.cyan),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _DarkSwitchRow extends StatelessWidget {
  const _DarkSwitchRow({
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? MetaServerColors.danger : MetaServerColors.mint;
    return Row(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeColor: color,
        ),
      ],
    );
  }
}

class _FieldTitle extends StatelessWidget {
  const _FieldTitle({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: MetaServerColors.cyan, size: 19),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: MetaServerColors.ink.withValues(alpha: 0.72),
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      selected: selected,
      onSelected: (_) => onSelected(),
      label: Text(label),
      showCheckmark: false,
      selectedColor: MetaServerColors.mint.withValues(alpha: 0.34),
      side: BorderSide(
        color: selected ? MetaServerColors.cyan : MetaServerColors.line,
      ),
      labelStyle: const TextStyle(fontWeight: FontWeight.w900),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
  }
}

class _SoftIcon extends StatelessWidget {
  const _SoftIcon({
    required this.icon,
    this.color = MetaServerColors.cyan,
    this.size = 44,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Icon(icon, color: color, size: size * 0.55),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'active' => MetaServerColors.green,
      'paused' => MetaServerColors.amber,
      'stopped' => MetaServerColors.danger,
      _ => MetaServerColors.cyan,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        _statusLabel(status),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: MetaServerColors.cyan, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.foregroundColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: foregroundColor,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
    );
  }
}

class _DarkPill extends StatelessWidget {
  const _DarkPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: MetaServerColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Column(
        children: [
          _SoftIcon(icon: icon),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: MetaServerColors.ink.withValues(alpha: 0.58),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: MetaServerColors.amber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: MetaServerColors.amber.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: MetaServerColors.amber),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 23),
      style: IconButton.styleFrom(
        fixedSize: const Size(44, 44),
        backgroundColor: Colors.white,
        foregroundColor: MetaServerColors.ink,
        disabledBackgroundColor: MetaServerColors.line.withValues(alpha: 0.55),
        side: const BorderSide(color: MetaServerColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

IconData _strategyIcon(String type) {
  return switch (type) {
    'momentum' => Icons.trending_up_rounded,
    'dca' => Icons.stacked_line_chart_rounded,
    'rebalance' => Icons.balance_rounded,
    'grid' => Icons.grid_view_rounded,
    _ => Icons.rule_rounded,
  };
}

String _strategyLabel(String type) {
  return switch (type) {
    'momentum' => '모멘텀',
    'dca' => '분할매수',
    'rebalance' => '리밸런싱',
    'grid' => '그리드',
    _ => '조건식',
  };
}

String _statusLabel(String status) {
  return switch (status) {
    'active' => '활성',
    'paused' => '일시정지',
    'stopped' => '중지',
    'archived' => '보관',
    _ => '초안',
  };
}

String _sideLabel(String side) {
  return switch (side) {
    'sell' || 'exit' || 'risk_stop' => '매도',
    'hold' => '보류',
    _ => '매수',
  };
}

String _signalStatus(String status) {
  return switch (status) {
    'approved' => '승인됨',
    'blocked' => '차단',
    'submitted' => '전송됨',
    'expired' => '만료',
    'discarded' => '폐기',
    _ => '승인 대기',
  };
}

String _actionLabel(String action) {
  return switch (action) {
    'place_order' => '주문 전송',
    'cancel_order' => '주문 취소',
    'pause_strategy' => '전략 정지',
    'stop_strategy' => '전략 중지',
    _ => '알림',
  };
}

String _actionStatus(String status) {
  return switch (status) {
    'succeeded' => '성공',
    'sent' => '전송',
    'failed' => '실패',
    'canceled' => '취소',
    _ => '대기',
  };
}

String _won(String? value) {
  final number =
      int.tryParse(removeNumberGrouping((value ?? '0').split('.').first)) ?? 0;
  return '${_comma(number)}원';
}

String _comma(int value) {
  final text = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final remaining = text.length - i;
    buffer.write(text[i]);
    if (remaining > 1 && remaining % 3 == 1) {
      buffer.write(',');
    }
  }
  return buffer.toString();
}

String _shortTime(String value) {
  if (value.length >= 16 && value.contains('T')) {
    return value.substring(11, 16);
  }
  if (value.length >= 16 && value.contains(' ')) {
    return value.substring(11, 16);
  }
  return value;
}
