import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../core/api_client.dart';
import '../widgets/brand_mark.dart';
import '../widgets/thousands_input_formatter.dart';
import 'trading_local_storage.dart';
import 'trading_repository.dart';

enum _TradeSide { buy, sell }

enum _AssetClass { domesticStock, overseasStock, crypto }

extension _AssetClassMeta on _AssetClass {
  String get storageValue => switch (this) {
        _AssetClass.domesticStock => 'domestic_stock',
        _AssetClass.overseasStock => 'overseas_stock',
        _AssetClass.crypto => 'crypto',
      };

  String get label => switch (this) {
        _AssetClass.domesticStock => '국내',
        _AssetClass.overseasStock => '해외',
        _AssetClass.crypto => '코인',
      };

  Color get accent => switch (this) {
        _AssetClass.domesticStock => MetaServerColors.green,
        _AssetClass.overseasStock => const Color(0xFF4768A8),
        _AssetClass.crypto => MetaServerColors.amber,
      };

  bool get usesDomesticKisApi => this == _AssetClass.domesticStock;

  bool get supportsKisQuote =>
      this == _AssetClass.domesticStock ||
      this == _AssetClass.overseasStock ||
      this == _AssetClass.crypto;

  bool get supportsKisOrder =>
      this == _AssetClass.domesticStock ||
      this == _AssetClass.overseasStock ||
      this == _AssetClass.crypto;

  bool get usesDecimalPrice =>
      this == _AssetClass.overseasStock || this == _AssetClass.crypto;

  bool get usesDecimalQuantity => this == _AssetClass.crypto;
}

_AssetClass _assetClassFromStorage(Object? value) {
  return switch (value?.toString()) {
    'overseas_stock' => _AssetClass.overseasStock,
    'crypto' => _AssetClass.crypto,
    _ => _AssetClass.domesticStock,
  };
}

_AssetClass _assetClassFromApi(Object? value) {
  return switch (value?.toString()) {
    'overseas_stock' => _AssetClass.overseasStock,
    'crypto' => _AssetClass.crypto,
    _ => _AssetClass.domesticStock,
  };
}

const _watchlistStorageKey = 'metaserver.trading.watchlist.custom.v1';
const _watchlistGroupsStorageKey = 'metaserver.trading.watchlist.groups.v1';
const _executionHistoryStorageKey = 'metaserver.trading.executions.v1';
const _executionHistoryLimit = 500;
const _defaultWatchlistGroupId = 'default';

String _defaultWatchlistGroupIdForAssetClass(_AssetClass assetClass) {
  return '${_defaultWatchlistGroupId}_${assetClass.storageValue}';
}

String _assetScopedWatchlistGroupId(String groupId, _AssetClass assetClass) {
  return '${groupId}_${assetClass.storageValue}';
}

List<_WatchlistGroup> _normalizeWatchlistGroups(
  List<_WatchlistGroup> groups,
) {
  final normalized = <_WatchlistGroup>[];
  final usedIds = <String>{};

  for (final group in groups) {
    final instruments = <_Instrument>[];
    final usedAssetKeys = <String>{};
    for (final instrument in group.instruments) {
      if (instrument.assetClass != group.assetClass) continue;
      if (!usedAssetKeys.add(instrument.assetKey)) continue;
      instruments.add(instrument);
    }

    var id = group.id;
    if (!usedIds.add(id)) {
      id = _assetScopedWatchlistGroupId(group.id, group.assetClass);
      var suffix = 2;
      while (!usedIds.add(id)) {
        id =
            '${_assetScopedWatchlistGroupId(group.id, group.assetClass)}_$suffix';
        suffix += 1;
      }
    }

    normalized.add(
      _WatchlistGroup(
        id: id,
        assetClass: group.assetClass,
        name: group.name,
        instruments: instruments,
      ),
    );
  }

  for (final assetClass in _AssetClass.values) {
    final hasAssetGroup =
        normalized.any((group) => group.assetClass == assetClass);
    if (!hasAssetGroup) {
      normalized.add(
        _WatchlistGroup(
          id: _defaultWatchlistGroupIdForAssetClass(assetClass),
          assetClass: assetClass,
          name: '기본',
          instruments: [_defaultInstrumentForAssetClass(assetClass)],
        ),
      );
    }
  }

  return normalized;
}

_Instrument _instrumentSelectionFor(
  _AssetClass assetClass,
  List<_Instrument> instruments, [
  _Instrument? current,
]) {
  if (current != null) {
    for (final instrument in instruments) {
      if (instrument.assetKey == current.assetKey) {
        return instrument;
      }
    }
  }
  if (instruments.isNotEmpty) return instruments.first;
  return _defaultInstrumentForAssetClass(assetClass);
}

_Instrument _instrumentSelectionForGroup(
  _WatchlistGroup group, [
  _Instrument? current,
]) {
  return _instrumentSelectionFor(group.assetClass, group.instruments, current);
}

class TradingScreen extends ConsumerStatefulWidget {
  const TradingScreen({super.key});

  @override
  ConsumerState<TradingScreen> createState() => _TradingScreenState();
}

class _TradingScreenState extends ConsumerState<TradingScreen> {
  int _tabIndex = 0;
  _TradeSide _tradeSide = _TradeSide.buy;
  _AssetClass _selectedAssetClass = _AssetClass.domesticStock;
  late List<_WatchlistGroup> _watchlistGroups;
  late String _selectedGroupId;
  late List<_Instrument> _instruments;
  late _Instrument _selectedInstrument;
  final Map<_AssetClass, String> _selectedGroupIdsByAssetClass = {};
  late Future<KisPortfolio> _portfolioFuture;
  KisPortfolio? _cachedPortfolio;
  late Future<UpbitPortfolio> _upbitPortfolioFuture;
  UpbitPortfolio? _cachedUpbitPortfolio;
  late Future<KisConnectionStatus> _kisStatusFuture;
  KisConnectionStatus? _cachedKisStatus;
  late Future<UpbitConnectionStatus> _upbitStatusFuture;
  UpbitConnectionStatus? _cachedUpbitStatus;
  late Future<KisMarketStatus> _marketStatusFuture;
  KisMarketStatus? _cachedMarketStatus;
  bool _quoteLoading = false;

  @override
  void initState() {
    super.initState();
    _watchlistGroups = _restoreWatchlistGroups();
    _selectedAssetClass = _AssetClass.domesticStock;
    final initialGroup = _groupsForAssetClass(_selectedAssetClass).first;
    _selectedGroupId = initialGroup.id;
    _selectedGroupIdsByAssetClass[_selectedAssetClass] = initialGroup.id;
    _instruments = List<_Instrument>.of(initialGroup.instruments);
    _selectedInstrument = _instrumentSelectionForGroup(initialGroup);
    _portfolioFuture = _loadPortfolio();
    _upbitPortfolioFuture = _loadUpbitPortfolio();
    _kisStatusFuture = _loadKisStatus();
    _upbitStatusFuture = _loadUpbitStatus();
    _marketStatusFuture = _loadMarketStatus();
    Future.microtask(() => _refreshWatchlistQuotes(showMessage: false));
  }

  List<_WatchlistGroup> _restoreWatchlistGroups() {
    final savedGroups = loadTradingLocalValue(_watchlistGroupsStorageKey);
    if (savedGroups != null && savedGroups.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(savedGroups);
        if (decoded is List) {
          final groups = [
            for (final item in decoded)
              if (item is Map)
                ..._WatchlistGroup.fromJson(
                  Map<String, Object?>.from(item),
                ),
          ];
          if (groups.isNotEmpty) return _normalizeWatchlistGroups(groups);
        }
      } catch (_) {
        // Fall through to the legacy watchlist migration path.
      }
    }

    return _normalizeWatchlistGroups([
      for (final assetClass in _AssetClass.values)
        _WatchlistGroup(
          id: _defaultWatchlistGroupIdForAssetClass(assetClass),
          assetClass: assetClass,
          name: '기본',
          instruments: [
            for (final instrument in _restoreLegacyWatchlistInstruments())
              if (instrument.assetClass == assetClass) instrument,
          ],
        ),
    ]);
  }

  List<_Instrument> _restoreLegacyWatchlistInstruments() {
    final instruments = List<_Instrument>.of(_defaultInstruments);
    final saved = loadTradingLocalValue(_watchlistStorageKey);
    if (saved == null || saved.trim().isEmpty) return instruments;

    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List) return instruments;
      final defaultKeys =
          _defaultInstruments.map((instrument) => instrument.assetKey).toSet();
      for (final item in decoded) {
        if (item is! Map) continue;
        final instrument = _Instrument.fromJson(
          Map<String, Object?>.from(item),
        );
        if (instrument == null) continue;
        final alreadyListed = instruments.any(
          (current) => current.assetKey == instrument.assetKey,
        );
        if (!alreadyListed && !defaultKeys.contains(instrument.assetKey)) {
          instruments.add(instrument);
        }
      }
    } catch (_) {
      // Ignore malformed local watchlist data and keep the built-in list.
    }
    return instruments;
  }

  _WatchlistGroup get _selectedGroup {
    final groups = _groupsForAssetClass(_selectedAssetClass);
    return groups.firstWhere(
      (group) => group.id == _selectedGroupId,
      orElse: () => groups.first,
    );
  }

  List<_WatchlistGroup> _groupsForAssetClass(_AssetClass assetClass) {
    return [
      for (final group in _watchlistGroups)
        if (group.assetClass == assetClass) group,
    ];
  }

  List<_Instrument> get _visibleInstruments {
    return [
      for (final instrument in _instruments)
        if (instrument.assetClass == _selectedAssetClass) instrument,
    ];
  }

  void _selectAssetClass(_AssetClass assetClass) {
    if (_selectedAssetClass == assetClass) return;
    _selectedGroupIdsByAssetClass[_selectedAssetClass] = _selectedGroupId;
    final groups = _groupsForAssetClass(assetClass);
    final rememberedGroupId = _selectedGroupIdsByAssetClass[assetClass];
    final nextGroup = groups.firstWhere(
      (group) => group.id == rememberedGroupId,
      orElse: () => groups.first,
    );
    setState(() {
      _selectedAssetClass = assetClass;
      _selectedGroupId = nextGroup.id;
      _selectedGroupIdsByAssetClass[assetClass] = nextGroup.id;
      _instruments = List<_Instrument>.of(nextGroup.instruments);
      _selectedInstrument =
          _instrumentSelectionForGroup(nextGroup, _selectedInstrument);
    });
    Future.microtask(() => _refreshWatchlistQuotes(showMessage: false));
  }

  void _saveWatchlistGroups() {
    saveTradingLocalValue(
      _watchlistGroupsStorageKey,
      jsonEncode(_watchlistGroups.map((group) => group.toJson()).toList()),
    );
  }

  void _replaceSelectedGroupInstruments(List<_Instrument> instruments) {
    _instruments = List<_Instrument>.of(instruments);
    _watchlistGroups = [
      for (final group in _watchlistGroups)
        if (group.id == _selectedGroupId)
          group.copyWith(
            instruments: [
              for (final instrument in instruments)
                if (instrument.assetClass == group.assetClass) instrument,
            ],
          )
        else
          group,
    ];
  }

  void _selectWatchlistGroup(String groupId) {
    final group = _groupsForAssetClass(_selectedAssetClass).firstWhere(
      (item) => item.id == groupId,
      orElse: () => _selectedGroup,
    );
    final groupInstruments = List<_Instrument>.of(group.instruments);
    final nextSelectedInstrument =
        _instrumentSelectionForGroup(group, _selectedInstrument);
    setState(() {
      _selectedGroupId = group.id;
      _selectedGroupIdsByAssetClass[_selectedAssetClass] = group.id;
      _instruments = groupInstruments;
      _selectedInstrument = nextSelectedInstrument;
    });
    Future.microtask(() => _refreshWatchlistQuotes(showMessage: false));
  }

  void _openOrder(_Instrument instrument, _TradeSide side) {
    setState(() {
      _selectedInstrument = instrument;
      _tradeSide = side;
      _tabIndex = 2;
    });
    Future.microtask(() => _refreshSelectedQuote(showMessage: false));
  }

  Future<KisPortfolio> _loadPortfolio() async {
    final portfolio =
        await ref.read(tradingRepositoryProvider).loadKisPortfolio();
    if (mounted) {
      setState(() {
        _cachedPortfolio = portfolio;
      });
    }
    return portfolio;
  }

  Future<UpbitPortfolio> _loadUpbitPortfolio() async {
    final portfolio =
        await ref.read(tradingRepositoryProvider).loadUpbitPortfolio();
    if (mounted) {
      setState(() {
        _cachedUpbitPortfolio = portfolio;
      });
    }
    return portfolio;
  }

  Future<KisConnectionStatus> _loadKisStatus() async {
    final status = await ref.read(tradingRepositoryProvider).loadKisStatus();
    if (mounted) {
      setState(() {
        _cachedKisStatus = status;
      });
    }
    return status;
  }

  Future<UpbitConnectionStatus> _loadUpbitStatus() async {
    final status = await ref.read(tradingRepositoryProvider).loadUpbitStatus();
    if (mounted) {
      setState(() {
        _cachedUpbitStatus = status;
      });
    }
    return status;
  }

  Future<KisMarketStatus> _loadMarketStatus() async {
    final status = await ref.read(tradingRepositoryProvider).loadMarketStatus();
    if (mounted) {
      setState(() {
        _cachedMarketStatus = status;
      });
    }
    return status;
  }

  Future<void> _refreshTradingData() async {
    setState(() {
      _portfolioFuture = _loadPortfolio();
      _upbitPortfolioFuture = _loadUpbitPortfolio();
      _kisStatusFuture = _loadKisStatus();
      _upbitStatusFuture = _loadUpbitStatus();
      _marketStatusFuture = _loadMarketStatus();
    });
    await _refreshWatchlistQuotes();
  }

  Future<void> _refreshSelectedQuote({bool showMessage = true}) async {
    if (_quoteLoading) return;
    if (!_selectedInstrument.assetClass.supportsKisQuote) {
      if (showMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_selectedInstrument.assetClass.label} 시세 어댑터는 준비 중입니다.',
            ),
          ),
        );
      }
      return;
    }
    setState(() => _quoteLoading = true);
    try {
      final quote = await _loadQuoteForInstrument(
        ref.read(tradingRepositoryProvider),
        _selectedInstrument,
      );
      if (!mounted) return;
      final updated = _mergeQuote(_selectedInstrument, quote);
      setState(() {
        _selectedInstrument = updated;
        _replaceSelectedGroupInstruments([
          for (final instrument in _instruments)
            if (instrument.assetKey == updated.assetKey)
              updated
            else
              instrument,
        ]);
      });
      _saveWatchlistGroups();
      if (showMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_selectedInstrument.symbol} 현재가를 갱신했습니다.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      final message = !_selectedAssetClass.supportsKisQuote
          ? '${_selectedAssetClass.label} 실시간 시세 어댑터는 준비 중입니다.'
          : isRecoverableApiFailure(error)
              ? 'KIS 조회에 실패했습니다. 백엔드 KIS 키와 계좌 설정을 확인해 주세요.'
              : error.toString();
      if (showMessage) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _quoteLoading = false);
    }
  }

  Future<void> _refreshWatchlistQuotes({bool showMessage = true}) async {
    if (_quoteLoading) return;
    setState(() => _quoteLoading = true);
    var refreshedCount = 0;
    final refreshingGroupId = _selectedGroupId;
    final instrumentsSnapshot = List<_Instrument>.of(_visibleInstruments)
        .where((instrument) => instrument.assetClass.supportsKisQuote)
        .toList();
    final refreshedInstruments = List<_Instrument>.of(_instruments);
    var refreshedSelectedInstrument = _selectedInstrument;
    try {
      if (_visibleInstruments.isEmpty) {
        if (showMessage) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '현재 그룹에 ${_selectedAssetClass.label} 종목이 없습니다.',
              ),
            ),
          );
        }
        return;
      }
      if (instrumentsSnapshot.isEmpty) {
        throw StateError(
          'No live quote adapter is available for this asset class.',
        );
      }
      final repository = ref.read(tradingRepositoryProvider);
      for (var index = 0; index < instrumentsSnapshot.length; index++) {
        final instrument = instrumentsSnapshot[index];
        try {
          final quote = await _loadQuoteForInstrument(repository, instrument);
          if (!mounted) return;
          final updated = _mergeQuote(instrument, quote);
          refreshedCount += 1;
          final fullIndex = refreshedInstruments.indexWhere(
            (item) => item.assetKey == updated.assetKey,
          );
          if (fullIndex >= 0) {
            refreshedInstruments[fullIndex] = updated;
          }
          if (refreshedSelectedInstrument.assetKey == updated.assetKey) {
            refreshedSelectedInstrument = updated;
          }
        } catch (_) {
          // Keep showing the last known value for this symbol and continue.
        }
        if (index < instrumentsSnapshot.length - 1) {
          await Future<void>.delayed(const Duration(milliseconds: 450));
        }
      }
      if (!mounted) return;
      if (refreshedCount == 0) {
        throw StateError('No KIS quotes were refreshed.');
      }
      if (_selectedGroupId == refreshingGroupId) {
        setState(() {
          _replaceSelectedGroupInstruments(refreshedInstruments);
          _selectedInstrument = refreshedSelectedInstrument;
        });
        _saveWatchlistGroups();
      }
      if (showMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              refreshedCount == instrumentsSnapshot.length
                  ? 'KIS 현재가를 갱신했습니다.'
                  : '일부 종목 현재가를 갱신했습니다.',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      final message = !_selectedAssetClass.supportsKisQuote
          ? '${_selectedAssetClass.label} 실시간 시세 어댑터는 준비 중입니다.'
          : isRecoverableApiFailure(error)
              ? 'KIS 조회에 실패했습니다. API 도메인과 계정 설정을 확인해 주세요.'
              : error.toString();
      if (showMessage) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    } finally {
      if (mounted) setState(() => _quoteLoading = false);
    }
  }

  Future<void> _showAddInstrumentDialog() async {
    final draft = await showDialog<_InstrumentDraft>(
      context: context,
      builder: (context) => _AddInstrumentDialog(
        assetClass: _selectedAssetClass,
        existingAssetKeys: _instruments.map((item) => item.assetKey).toSet(),
      ),
    );
    if (draft == null || !mounted) return;

    setState(() => _quoteLoading = true);
    DomesticStockQuote? quote;
    try {
      if (draft.assetClass.supportsKisQuote) {
        quote = await _loadQuoteForDraft(
          ref.read(tradingRepositoryProvider),
          draft,
        );
      }
    } catch (_) {
      quote = null;
    }
    if (!mounted) return;

    final hasLiveQuote = _quoteHasPrice(quote);
    final instrument = hasLiveQuote
        ? _instrumentFromQuote(draft, quote!)
        : _instrumentFromDraft(draft);
    setState(() {
      _replaceSelectedGroupInstruments([..._instruments, instrument]);
      _selectedInstrument = instrument;
    });
    _saveWatchlistGroups();
    setState(() => _quoteLoading = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          hasLiveQuote
              ? '${instrument.symbol} 현재가를 확인하고 추가했습니다.'
              : '${instrument.symbol} 관심종목을 추가했습니다. 현재가는 연결되면 갱신됩니다.',
        ),
      ),
    );
  }

  Future<void> _showCreateGroupDialog() async {
    final controller = TextEditingController();
    String? validationError;
    try {
      final groupName = await showDialog<String>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              void submit() {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  setDialogState(() => validationError = '그룹명을 입력해 주세요.');
                  return;
                }
                final duplicated = _watchlistGroups.any(
                  (group) =>
                      group.assetClass == _selectedAssetClass &&
                      group.name.toLowerCase() == value.toLowerCase(),
                );
                if (duplicated) {
                  setDialogState(
                    () => validationError =
                        '${_selectedAssetClass.label} 탭에 이미 있는 그룹명입니다.',
                  );
                  return;
                }
                Navigator.of(context).pop(value);
              }

              return AlertDialog(
                title: const Text('관심그룹 추가'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: '그룹명',
                        hintText: '예: 반도체, 단기매매, 장기보유',
                      ),
                      onSubmitted: (_) => submit(),
                    ),
                    if (validationError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        validationError!,
                        style: const TextStyle(
                          color: MetaServerColors.danger,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('취소'),
                  ),
                  FilledButton.icon(
                    onPressed: submit,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('만들기'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (groupName == null || !mounted) return;

      final newGroup = _WatchlistGroup(
        id: 'group_${DateTime.now().microsecondsSinceEpoch}',
        assetClass: _selectedAssetClass,
        name: groupName,
        instruments: const <_Instrument>[],
      );
      setState(() {
        _watchlistGroups = [..._watchlistGroups, newGroup];
        _selectedGroupId = newGroup.id;
        _selectedGroupIdsByAssetClass[_selectedAssetClass] = newGroup.id;
        _instruments = List<_Instrument>.of(newGroup.instruments);
        _selectedInstrument =
            _instrumentSelectionForGroup(newGroup, _selectedInstrument);
      });
      _saveWatchlistGroups();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$groupName 그룹을 비워 둔 상태로 만들었습니다.')),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _deleteSelectedGroup() async {
    final assetGroups = _groupsForAssetClass(_selectedAssetClass);
    if (assetGroups.length <= 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(
          content: Text(
            '${_selectedAssetClass.label} 탭의 마지막 그룹은 삭제할 수 없습니다.',
          ),
        ),
      );
      return;
    }
    final group = _selectedGroup;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('관심그룹 삭제'),
        content: Text('${group.name} 그룹을 삭제할까요? 그룹 안의 종목 목록도 함께 제거됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final remaining =
        _watchlistGroups.where((item) => item.id != group.id).toList();
    final nextGroup = remaining.firstWhere(
      (item) => item.assetClass == _selectedAssetClass,
    );
    setState(() {
      _watchlistGroups = remaining;
      _selectedGroupId = nextGroup.id;
      _selectedGroupIdsByAssetClass[_selectedAssetClass] = nextGroup.id;
      _instruments = List<_Instrument>.of(nextGroup.instruments);
      _selectedInstrument =
          _instrumentSelectionForGroup(nextGroup, _selectedInstrument);
    });
    _saveWatchlistGroups();
  }

  void _removeInstrumentFromSelectedGroup(_Instrument instrument) {
    final nextInstruments = [
      for (final item in _instruments)
        if (item.assetKey != instrument.assetKey) item,
    ];
    setState(() {
      _replaceSelectedGroupInstruments(nextInstruments);
      if (_selectedInstrument.assetKey == instrument.assetKey) {
        _selectedInstrument =
            _instrumentSelectionFor(_selectedAssetClass, nextInstruments);
      }
    });
    _saveWatchlistGroups();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${instrument.name} 종목을 그룹에서 삭제했습니다.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleInstruments = _visibleInstruments;
    final assetGroups = _groupsForAssetClass(_selectedAssetClass);
    final tabs = [
      _TradingHomeTab(
        instruments: _instruments,
        portfolioFuture: _portfolioFuture,
        cachedPortfolio: _cachedPortfolio,
        upbitPortfolioFuture: _upbitPortfolioFuture,
        cachedUpbitPortfolio: _cachedUpbitPortfolio,
        marketStatusFuture: _marketStatusFuture,
        cachedMarketStatus: _cachedMarketStatus,
        kisStatusFuture: _kisStatusFuture,
        cachedKisStatus: _cachedKisStatus,
        upbitStatusFuture: _upbitStatusFuture,
        cachedUpbitStatus: _cachedUpbitStatus,
        onOrder: _openOrder,
      ),
      _MarketTab(
        selectedAssetClass: _selectedAssetClass,
        onAssetClassChanged: _selectAssetClass,
        groups: assetGroups,
        selectedGroupId: _selectedGroupId,
        instruments: visibleInstruments,
        selectedInstrument: _selectedInstrument,
        onGroupSelected: _selectWatchlistGroup,
        onCreateGroup: _showCreateGroupDialog,
        onDeleteGroup: _deleteSelectedGroup,
        onSelected: (instrument) {
          setState(() {
            _selectedInstrument = instrument;
          });
          Future.microtask(() => _refreshSelectedQuote(showMessage: false));
        },
        onOrder: _openOrder,
        onAddInstrument: _showAddInstrumentDialog,
        onRemoveInstrument: _removeInstrumentFromSelectedGroup,
      ),
      _OrderTicketTab(
        instrument: _selectedInstrument,
        initialSide: _tradeSide,
        portfolioFuture: _portfolioFuture,
        cachedPortfolio: _cachedPortfolio,
        upbitPortfolioFuture: _upbitPortfolioFuture,
        cachedUpbitPortfolio: _cachedUpbitPortfolio,
        onSideChanged: (side) => setState(() => _tradeSide = side),
      ),
      const _ActivityTab(),
      _TradingAccountTab(
        statusFuture: _kisStatusFuture,
        cachedStatus: _cachedKisStatus,
      ),
    ];

    return Scaffold(
      backgroundColor: MetaServerColors.canvas,
      appBar: AppBar(
        toolbarHeight: 70,
        backgroundColor: MetaServerColors.canvas,
        surfaceTintColor: Colors.transparent,
        title: const BrandMark(size: 38),
        actions: [
          _ToolbarIconButton(
            tooltip: '자동매매',
            icon: Icons.precision_manufacturing_rounded,
            onPressed: () => context.go('/auto-trading'),
          ),
          const SizedBox(width: 8),
          _ToolbarIconButton(
            tooltip: '새로고침',
            icon: Icons.refresh_rounded,
            onPressed: () => _refreshTradingData(),
          ),
          const SizedBox(width: 8),
          _ToolbarIconButton(
            tooltip: '계정',
            icon: Icons.person_outline_rounded,
            onPressed: () => context.go('/account'),
          ),
          const SizedBox(width: 14),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(index: _tabIndex, children: tabs),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorColor: MetaServerColors.mint.withValues(alpha: 0.35),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard_rounded),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.show_chart_outlined),
            selectedIcon: Icon(Icons.show_chart_rounded),
            label: '시장',
          ),
          NavigationDestination(
            icon: Icon(Icons.swap_vert_rounded),
            selectedIcon: Icon(Icons.swap_vertical_circle_rounded),
            label: '주문',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long_rounded),
            label: '체결',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_outlined),
            selectedIcon: Icon(Icons.account_balance_rounded),
            label: '계좌',
          ),
        ],
      ),
    );
  }
}

Future<DomesticStockQuote> _loadQuoteForInstrument(
  TradingRepository repository,
  _Instrument instrument,
) {
  return switch (instrument.assetClass) {
    _AssetClass.domesticStock => repository.loadQuote(instrument.symbol),
    _AssetClass.overseasStock => repository.loadOverseasQuote(
        instrument.symbol,
        marketCode: instrument.market,
      ),
    _AssetClass.crypto => repository.loadUpbitQuote(instrument.symbol),
  };
}

Future<DomesticStockQuote> _loadQuoteForDraft(
  TradingRepository repository,
  _InstrumentDraft draft,
) {
  return switch (draft.assetClass) {
    _AssetClass.domesticStock => repository.loadQuote(draft.symbol),
    _AssetClass.overseasStock => repository.loadOverseasQuote(
        draft.symbol,
        marketCode: draft.market,
      ),
    _AssetClass.crypto => repository.loadUpbitQuote(draft.symbol),
  };
}

_Instrument _mergeQuote(_Instrument instrument, DomesticStockQuote quote) {
  final hasPrice = _quoteHasPrice(quote);
  return instrument.copyWith(
    price: hasPrice ? quote.price : null,
    changeRate: quote.changeRate,
    open: quote.openPrice,
    high: quote.highPrice,
    low: quote.lowPrice,
    tradeAmount: quote.accumulatedTradeAmount,
    hasLiveQuote: hasPrice ? true : null,
  );
}

bool _quoteHasPrice(DomesticStockQuote? quote) {
  final price = quote?.price;
  return price != null && price > 0;
}

_Instrument _instrumentFromQuote(
  _InstrumentDraft draft,
  DomesticStockQuote quote,
) {
  final price = quote.price;
  if (price == null || price <= 0) {
    throw StateError('KIS current price is unavailable.');
  }
  return _Instrument(
    assetClass: draft.assetClass,
    market: draft.market,
    symbol: draft.symbol,
    name: draft.name.isNotEmpty ? draft.name : draft.symbol,
    sector: draft.sector.isNotEmpty ? draft.sector : '관심종목',
    price: price,
    changeRate: quote.changeRate ?? 0,
    open: quote.openPrice ?? price,
    high: quote.highPrice ?? price,
    low: quote.lowPrice ?? price,
    tradeAmount: quote.accumulatedTradeAmount ?? 0,
    chart: [price / 1000],
    hasLiveQuote: true,
  );
}

_Instrument _instrumentFromDraft(_InstrumentDraft draft) {
  final catalogItem = _stockCatalogItemBySymbol(
    draft.symbol,
    assetClass: draft.assetClass,
  );
  return _Instrument(
    assetClass: draft.assetClass,
    market: draft.market,
    symbol: draft.symbol,
    name: draft.name.isNotEmpty
        ? draft.name
        : (catalogItem?.name ?? draft.symbol),
    sector: draft.sector.isNotEmpty
        ? draft.sector
        : (catalogItem?.sector ?? '관심종목'),
    price: 0,
    changeRate: 0,
    open: 0,
    high: 0,
    low: 0,
    tradeAmount: 0,
    chart: const [0, 0],
    hasLiveQuote: false,
  );
}

class _InstrumentDraft {
  const _InstrumentDraft({
    required this.assetClass,
    required this.market,
    required this.symbol,
    required this.name,
    required this.sector,
  });

  final _AssetClass assetClass;
  final String market;
  final String symbol;
  final String name;
  final String sector;

  String get assetKey => _assetKey(assetClass, market, symbol);
}

String _normalizeAssetSymbol(String value, _AssetClass assetClass) {
  final trimmed = value.trim().toUpperCase();
  return switch (assetClass) {
    _AssetClass.domesticStock => trimmed.replaceAll(RegExp(r'[^0-9]'), ''),
    _AssetClass.overseasStock =>
      trimmed.replaceAll(RegExp(r'[^A-Z0-9./-]'), ''),
    _AssetClass.crypto => _normalizeUpbitMarket(trimmed),
  };
}

String _normalizeUpbitMarket(String value) {
  final text = value
      .replaceAll('/', '-')
      .replaceAll('_', '-')
      .replaceAll(RegExp(r'[^A-Z0-9:-]'), '');
  final parts = text.split('-').where((part) => part.isNotEmpty).toList();
  if (parts.length == 1) return 'KRW-${parts.first}';
  if (parts.length >= 2) {
    const quoteCurrencies = {'KRW', 'BTC', 'USDT'};
    if (quoteCurrencies.contains(parts.first)) {
      return '${parts.first}-${parts[1]}';
    }
    if (quoteCurrencies.contains(parts[1])) return '${parts[1]}-${parts.first}';
  }
  return text;
}

String _assetKey(_AssetClass assetClass, String market, String symbol) {
  return '${assetClass.storageValue}:${market.toUpperCase()}:${symbol.toUpperCase()}';
}

String _defaultMarketForAssetClass(_AssetClass assetClass) {
  return switch (assetClass) {
    _AssetClass.domesticStock => 'KOSPI',
    _AssetClass.overseasStock => 'NASDAQ',
    _AssetClass.crypto => 'UPBIT',
  };
}

String _symbolHint(_AssetClass assetClass) {
  return switch (assetClass) {
    _AssetClass.domesticStock => '005930',
    _AssetClass.overseasStock => 'AAPL',
    _AssetClass.crypto => 'KRW-BTC',
  };
}

String _searchHint(_AssetClass assetClass) {
  return switch (assetClass) {
    _AssetClass.domesticStock => '예: 하이닉스, 삼성전자, 005930',
    _AssetClass.overseasStock => '예: Apple, NVIDIA, AAPL',
    _AssetClass.crypto => '예: Bitcoin, Ethereum, KRW-BTC',
  };
}

List<String> _marketsForAssetClass(_AssetClass assetClass) {
  return switch (assetClass) {
    _AssetClass.domesticStock => const ['KOSPI', 'KOSDAQ', 'ETF', 'ETN'],
    _AssetClass.overseasStock => const ['NASDAQ', 'NYSE', 'AMEX'],
    _AssetClass.crypto => const ['UPBIT'],
  };
}

class _AddInstrumentDialog extends ConsumerStatefulWidget {
  const _AddInstrumentDialog({
    required this.assetClass,
    required this.existingAssetKeys,
  });

  final _AssetClass assetClass;
  final Set<String> existingAssetKeys;

  @override
  ConsumerState<_AddInstrumentDialog> createState() =>
      _AddInstrumentDialogState();
}

class _AddInstrumentDialogState extends ConsumerState<_AddInstrumentDialog> {
  late final TextEditingController _searchController;
  late final TextEditingController _symbolController;
  late final TextEditingController _nameController;
  late final TextEditingController _sectorController;
  Timer? _searchDebounce;
  var _searchEpoch = 0;
  late String _market;
  String? _validationError;
  String? _searchError;
  bool _searching = false;
  List<DomesticStockSearchResult> _searchResults = const [];
  DomesticStockSearchResult? _selectedItem;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _symbolController = TextEditingController();
    _nameController = TextEditingController();
    _sectorController = TextEditingController();
    _market = _defaultMarketForAssetClass(widget.assetClass);
    Future.microtask(() => _runSearch(''));
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _symbolController.dispose();
    _nameController.dispose();
    _sectorController.dispose();
    super.dispose();
  }

  void _scheduleSearch(String query) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      _runSearch(query);
    });
  }

  Future<void> _runSearch(String query) async {
    final epoch = ++_searchEpoch;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final repository = ref.read(tradingRepositoryProvider);
      final results = widget.assetClass.usesDomesticKisApi
          ? await repository.searchDomesticStocks(query, limit: 60)
          : widget.assetClass == _AssetClass.crypto
              ? await repository.searchUpbitMarkets(query, limit: 60)
              : _localCatalogResults(query);
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _searchResults = results;
        _searching = false;
      });
    } catch (_) {
      if (!mounted || epoch != _searchEpoch) return;
      final fallback = _localCatalogResults(query);
      setState(() {
        _searchResults = fallback;
        _searching = false;
        _searchError = '${widget.assetClass.label} 종목 검색을 불러오지 못했습니다.';
      });
    }
  }

  List<DomesticStockSearchResult> _localCatalogResults(String query) {
    final normalizedQuery = query.trim().toLowerCase();
    final items = normalizedQuery.isEmpty
        ? _popularCatalogItems(widget.assetClass)
        : _stockCatalog
            .where((item) =>
                item.assetClass == widget.assetClass &&
                item.matches(normalizedQuery))
            .toList();
    return [
      for (final item in items.take(8))
        DomesticStockSearchResult(
          market: item.market,
          symbol: item.symbol,
          name: item.name,
          sector: item.sector,
        ),
    ];
  }

  void _selectCatalogItem(_StockCatalogItem item) {
    _selectItem(
      DomesticStockSearchResult(
        market: item.market,
        symbol: item.symbol,
        name: item.name,
        sector: item.sector,
      ),
    );
  }

  void _selectItem(DomesticStockSearchResult item) {
    setState(() {
      _selectedItem = item;
      _market = item.market;
      _symbolController.text = item.symbol;
      _nameController.text = item.name;
      _sectorController.text = item.sector;
      _searchController.text = '${item.name} ${item.symbol}';
      _validationError = null;
    });
  }

  void _submit() {
    final searchSymbol =
        _normalizeAssetSymbol(_searchController.text, widget.assetClass);
    final exactSearchMatch = _searchResults.where(
      (item) => item.symbol == searchSymbol,
    );
    if (_symbolController.text.trim().isEmpty && searchSymbol.isNotEmpty) {
      _symbolController.text = searchSymbol;
      if (exactSearchMatch.isNotEmpty) {
        final item = exactSearchMatch.first;
        _market = item.market;
        _nameController.text = item.name;
        _sectorController.text = item.sector;
      }
    }

    final symbol =
        _normalizeAssetSymbol(_symbolController.text, widget.assetClass);
    if (symbol.isEmpty) {
      setState(
        () => _validationError = '${widget.assetClass.label} 종목 코드를 입력해 주세요.',
      );
      return;
    }
    final assetKey = _assetKey(widget.assetClass, _market, symbol);
    if (widget.existingAssetKeys.contains(assetKey)) {
      setState(() => _validationError = '이미 관심종목에 추가된 종목입니다.');
      return;
    }

    final searchItem = _selectedItem?.symbol == symbol ? _selectedItem : null;
    final catalogItem = _stockCatalogItemBySymbol(
      symbol,
      assetClass: widget.assetClass,
    );
    Navigator.of(context).pop(
      _InstrumentDraft(
        assetClass: widget.assetClass,
        market: _market,
        symbol: symbol,
        name: _nameController.text.trim().isNotEmpty
            ? _nameController.text.trim()
            : (searchItem?.name ?? catalogItem?.name ?? ''),
        sector: _sectorController.text.trim().isNotEmpty
            ? _sectorController.text.trim()
            : (searchItem?.sector ?? catalogItem?.sector ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final dialogWidth = math.min(screen.width - 32, 760.0);
    final dialogHeight = math.min(screen.height - 48, 700.0);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: dialogHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const _IconBadge(icon: Icons.add_chart_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '관심종목 추가',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${widget.assetClass.label} 종목명 또는 코드로 선택',
                          style: TextStyle(
                            color: MetaServerColors.ink.withValues(alpha: 0.58),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '닫기',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '검색어 지우기',
                          onPressed: () {
                            setState(() {
                              _searchController.clear();
                              _selectedItem = null;
                              _validationError = null;
                            });
                            _scheduleSearch('');
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                  labelText: '종목 검색',
                  hintText: _searchHint(widget.assetClass),
                ),
                onChanged: (value) {
                  setState(() {
                    _validationError = null;
                    _selectedItem = null;
                  });
                  _scheduleSearch(value);
                },
                onSubmitted: (_) {
                  if (_searchResults.length == 1) {
                    _selectItem(_searchResults.first);
                  } else {
                    _submit();
                  }
                },
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item
                      in _popularCatalogItems(widget.assetClass).take(6))
                    ActionChip(
                      avatar: const Icon(Icons.trending_up_rounded, size: 17),
                      label: Text(item.name),
                      onPressed: () => _selectCatalogItem(item),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 680;
                    final results = _SearchResultsPanel(
                      assetClass: widget.assetClass,
                      items: _searchResults,
                      selectedSymbol: _selectedItem?.symbol,
                      existingAssetKeys: widget.existingAssetKeys,
                      searching: _searching,
                      errorMessage: _searchError,
                      onSelected: _selectItem,
                    );
                    final form = _ManualInstrumentForm(
                      assetClass: widget.assetClass,
                      market: _market,
                      symbolController: _symbolController,
                      nameController: _nameController,
                      sectorController: _sectorController,
                      validationError: _validationError,
                      onMarketChanged: (value) {
                        if (value == null) return;
                        setState(() => _market = value);
                      },
                      onChanged: () {
                        setState(() {
                          _selectedItem = null;
                          _validationError = null;
                        });
                      },
                    );
                    if (narrow) {
                      return ListView(
                        children: [
                          SizedBox(height: 248, child: results),
                          const SizedBox(height: 14),
                          form,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 6, child: results),
                        const SizedBox(width: 14),
                        Expanded(flex: 4, child: form),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '현재가 조회 실패 시에도 목록에 추가됩니다.',
                      style: TextStyle(
                        color: MetaServerColors.ink.withValues(alpha: 0.58),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('추가'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchResultsPanel extends StatelessWidget {
  const _SearchResultsPanel({
    required this.assetClass,
    required this.items,
    required this.selectedSymbol,
    required this.existingAssetKeys,
    required this.searching,
    required this.errorMessage,
    required this.onSelected,
  });

  final _AssetClass assetClass;
  final List<DomesticStockSearchResult> items;
  final String? selectedSymbol;
  final Set<String> existingAssetKeys;
  final bool searching;
  final String? errorMessage;
  final ValueChanged<DomesticStockSearchResult> onSelected;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: MetaServerColors.canvas,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: MetaServerColors.line),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (searching) ...[
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                searching
                    ? '${assetClass.label} 종목 검색 중입니다.'
                    : (errorMessage ?? '검색 결과가 없습니다. 직접 종목코드로 추가하세요.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: errorMessage == null
                      ? MetaServerColors.ink.withValues(alpha: 0.58)
                      : MetaServerColors.danger,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return _StockSearchTile(
              assetClass: assetClass,
              item: item,
              selected: item.symbol == selectedSymbol,
              alreadyAdded: existingAssetKeys.contains(
                _assetKey(assetClass, item.market, item.symbol),
              ),
              onTap: () => onSelected(item),
            );
          },
        ),
        if (searching)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: MetaServerColors.line),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 7),
                  Text('검색 중', style: TextStyle(fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _StockSearchTile extends StatelessWidget {
  const _StockSearchTile({
    required this.assetClass,
    required this.item,
    required this.selected,
    required this.alreadyAdded,
    required this.onTap,
  });

  final _AssetClass assetClass;
  final DomesticStockSearchResult item;
  final bool selected;
  final bool alreadyAdded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? MetaServerColors.mint.withValues(alpha: 0.12)
            : MetaServerColors.canvas,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: selected ? MetaServerColors.cyan : MetaServerColors.line,
          ),
        ),
        child: ListTile(
          enabled: !alreadyAdded,
          onTap: alreadyAdded ? null : onTap,
          leading: _IconBadge(
            icon: Icons.show_chart_rounded,
            color: alreadyAdded
                ? MetaServerColors.ink.withValues(alpha: 0.38)
                : MetaServerColors.green,
          ),
          title: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          subtitle: Text(
            '${assetClass.label} · ${item.market} · ${item.symbol} · ${item.sector}',
          ),
          trailing: alreadyAdded
              ? const Text('추가됨', style: TextStyle(fontWeight: FontWeight.w900))
              : const Icon(Icons.add_circle_outline_rounded),
        ),
      ),
    );
  }
}

class _ManualInstrumentForm extends StatelessWidget {
  const _ManualInstrumentForm({
    required this.assetClass,
    required this.market,
    required this.symbolController,
    required this.nameController,
    required this.sectorController,
    required this.validationError,
    required this.onMarketChanged,
    required this.onChanged,
  });

  final _AssetClass assetClass;
  final String market;
  final TextEditingController symbolController;
  final TextEditingController nameController;
  final TextEditingController sectorController;
  final String? validationError;
  final ValueChanged<String?> onMarketChanged;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MetaServerColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '직접 입력',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: symbolController,
            keyboardType: assetClass == _AssetClass.domesticStock
                ? TextInputType.number
                : TextInputType.text,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: '종목코드',
              hintText: _symbolHint(assetClass),
            ),
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: '종목명',
              hintText: '선택 입력',
            ),
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: market,
            decoration: const InputDecoration(labelText: '시장'),
            items: [
              for (final market in _marketsForAssetClass(assetClass))
                DropdownMenuItem(value: market, child: Text(market)),
            ],
            onChanged: onMarketChanged,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: sectorController,
            decoration: const InputDecoration(
              labelText: '분류',
              hintText: '선택 입력',
            ),
            onChanged: (_) => onChanged(),
          ),
          if (validationError != null) ...[
            const SizedBox(height: 12),
            Text(
              validationError!,
              style: const TextStyle(
                color: MetaServerColors.danger,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TradingHomeTab extends ConsumerWidget {
  const _TradingHomeTab({
    required this.instruments,
    required this.portfolioFuture,
    required this.cachedPortfolio,
    required this.upbitPortfolioFuture,
    required this.cachedUpbitPortfolio,
    required this.marketStatusFuture,
    required this.cachedMarketStatus,
    required this.kisStatusFuture,
    required this.cachedKisStatus,
    required this.upbitStatusFuture,
    required this.cachedUpbitStatus,
    required this.onOrder,
  });

  final List<_Instrument> instruments;
  final Future<KisPortfolio> portfolioFuture;
  final KisPortfolio? cachedPortfolio;
  final Future<UpbitPortfolio> upbitPortfolioFuture;
  final UpbitPortfolio? cachedUpbitPortfolio;
  final Future<KisMarketStatus> marketStatusFuture;
  final KisMarketStatus? cachedMarketStatus;
  final Future<KisConnectionStatus> kisStatusFuture;
  final KisConnectionStatus? cachedKisStatus;
  final Future<UpbitConnectionStatus> upbitStatusFuture;
  final UpbitConnectionStatus? cachedUpbitStatus;
  final void Function(_Instrument instrument, _TradeSide side) onOrder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ScreenScroll(
      child: FutureBuilder<KisPortfolio>(
        future: portfolioFuture,
        builder: (context, snapshot) {
          final portfolio = snapshot.data ?? cachedPortfolio;
          final loading = snapshot.connectionState == ConnectionState.waiting &&
              portfolio == null;
          final errorMessage = snapshot.hasError && portfolio == null
              ? (apiFailureMessage(snapshot.error!) ?? 'KIS 잔고 조회에 실패했습니다.')
              : null;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AccountSummaryPanel(
                portfolio: portfolio,
                loading: loading,
                errorMessage: errorMessage,
              ),
              const SizedBox(height: 16),
              FutureBuilder<UpbitPortfolio>(
                future: upbitPortfolioFuture,
                builder: (context, upbitSnapshot) {
                  final upbitPortfolio =
                      upbitSnapshot.data ?? cachedUpbitPortfolio;
                  final upbitLoading = upbitSnapshot.connectionState ==
                          ConnectionState.waiting &&
                      upbitPortfolio == null;
                  final upbitError =
                      upbitSnapshot.hasError && upbitPortfolio == null
                          ? (apiFailureMessage(upbitSnapshot.error!) ??
                              'Upbit balance lookup failed.')
                          : null;
                  return _UpbitSummaryPanel(
                    portfolio: upbitPortfolio,
                    loading: upbitLoading,
                    errorMessage: upbitError,
                  );
                },
              ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, constraints) {
                  final holdingsPanel = _HoldingsPanel(
                    portfolio: portfolio,
                    upbitPortfolio: cachedUpbitPortfolio,
                    loading: loading,
                    errorMessage: errorMessage,
                    instruments: instruments,
                    onOrder: onOrder,
                  );
                  if (constraints.maxWidth >= 860) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 6, child: holdingsPanel),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 4,
                          child: _RiskAndMarketPanel(
                            marketStatusFuture: marketStatusFuture,
                            cachedMarketStatus: cachedMarketStatus,
                            kisStatusFuture: kisStatusFuture,
                            cachedKisStatus: cachedKisStatus,
                            upbitStatusFuture: upbitStatusFuture,
                            cachedUpbitStatus: cachedUpbitStatus,
                          ),
                        ),
                      ],
                    );
                  }

                  return Column(
                    children: [
                      holdingsPanel,
                      const SizedBox(height: 16),
                      _RiskAndMarketPanel(
                        marketStatusFuture: marketStatusFuture,
                        cachedMarketStatus: cachedMarketStatus,
                        kisStatusFuture: kisStatusFuture,
                        cachedKisStatus: cachedKisStatus,
                        upbitStatusFuture: upbitStatusFuture,
                        cachedUpbitStatus: cachedUpbitStatus,
                      ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MarketTab extends StatelessWidget {
  const _MarketTab({
    required this.selectedAssetClass,
    required this.onAssetClassChanged,
    required this.groups,
    required this.selectedGroupId,
    required this.instruments,
    required this.selectedInstrument,
    required this.onGroupSelected,
    required this.onCreateGroup,
    required this.onDeleteGroup,
    required this.onSelected,
    required this.onOrder,
    required this.onAddInstrument,
    required this.onRemoveInstrument,
  });

  final _AssetClass selectedAssetClass;
  final ValueChanged<_AssetClass> onAssetClassChanged;
  final List<_WatchlistGroup> groups;
  final String selectedGroupId;
  final List<_Instrument> instruments;
  final _Instrument selectedInstrument;
  final ValueChanged<String> onGroupSelected;
  final VoidCallback onCreateGroup;
  final VoidCallback onDeleteGroup;
  final ValueChanged<_Instrument> onSelected;
  final void Function(_Instrument instrument, _TradeSide side) onOrder;
  final VoidCallback onAddInstrument;
  final ValueChanged<_Instrument> onRemoveInstrument;

  @override
  Widget build(BuildContext context) {
    return _ScreenScroll(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final list = _WatchlistPanel(
            selectedAssetClass: selectedAssetClass,
            onAssetClassChanged: onAssetClassChanged,
            groups: groups,
            selectedGroupId: selectedGroupId,
            instruments: instruments,
            selectedInstrument: selectedInstrument,
            onGroupSelected: onGroupSelected,
            onCreateGroup: onCreateGroup,
            onDeleteGroup: onDeleteGroup,
            onSelected: onSelected,
            onOrder: onOrder,
            onAddInstrument: onAddInstrument,
            onRemoveInstrument: onRemoveInstrument,
          );
          final detail = _InstrumentDetailPanel(
            instrument: selectedInstrument,
            onOrder: onOrder,
          );

          if (constraints.maxWidth >= 900) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 5, child: list),
                const SizedBox(width: 16),
                Expanded(flex: 5, child: detail),
              ],
            );
          }

          return Column(children: [list, const SizedBox(height: 16), detail]);
        },
      ),
    );
  }
}

class _OrderTicketTab extends ConsumerStatefulWidget {
  const _OrderTicketTab({
    required this.instrument,
    required this.initialSide,
    required this.portfolioFuture,
    required this.cachedPortfolio,
    required this.upbitPortfolioFuture,
    required this.cachedUpbitPortfolio,
    required this.onSideChanged,
  });

  final _Instrument instrument;
  final _TradeSide initialSide;
  final Future<KisPortfolio> portfolioFuture;
  final KisPortfolio? cachedPortfolio;
  final Future<UpbitPortfolio> upbitPortfolioFuture;
  final UpbitPortfolio? cachedUpbitPortfolio;
  final ValueChanged<_TradeSide> onSideChanged;

  @override
  ConsumerState<_OrderTicketTab> createState() => _OrderTicketTabState();
}

class _OrderTicketTabState extends ConsumerState<_OrderTicketTab> {
  late final TextEditingController _quantityController;
  late final TextEditingController _priceController;
  late _TradeSide _side;
  bool _marketOrder = false;
  bool _submitting = false;
  bool _riskNoticeAgreed = false;
  bool _riskNoticeLoading = true;
  String? _riskNoticeError;
  String? _upbitMarketForFutures;
  Future<UpbitOrderChance>? _upbitOrderChanceFuture;
  Future<UpbitOrderbook>? _upbitOrderbookFuture;

  @override
  void initState() {
    super.initState();
    _side = widget.initialSide;
    _quantityController = TextEditingController(text: '1');
    _priceController = TextEditingController(
      text: _orderPriceText(widget.instrument),
    );
    _syncUpbitFutures();
    unawaited(_loadRiskNoticeConsent());
  }

  @override
  void didUpdateWidget(covariant _OrderTicketTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextPriceText = _orderPriceText(widget.instrument);
    final previousPriceText = removeNumberGrouping(
      _orderPriceText(oldWidget.instrument),
    );
    final currentPriceText = removeNumberGrouping(_priceController.text);
    if (oldWidget.instrument.assetKey != widget.instrument.assetKey) {
      _setPriceText(nextPriceText);
    } else if (nextPriceText.isNotEmpty &&
        (currentPriceText.isEmpty ||
            currentPriceText == '0' ||
            currentPriceText == '1' ||
            currentPriceText == previousPriceText)) {
      _setPriceText(nextPriceText);
    }
    if (oldWidget.initialSide != widget.initialSide) {
      _side = widget.initialSide;
    }
    _syncUpbitFutures();
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  void _syncUpbitFutures() {
    if (widget.instrument.assetClass != _AssetClass.crypto) return;
    final market = widget.instrument.symbol;
    if (_upbitMarketForFutures == market) return;
    final repository = ref.read(tradingRepositoryProvider);
    _upbitMarketForFutures = market;
    _upbitOrderChanceFuture = repository.loadUpbitOrderChance(market);
    _upbitOrderbookFuture = repository.loadUpbitOrderbook(market);
  }

  @override
  Widget build(BuildContext context) {
    final quantity = _parseOrderQuantity(_quantityController.text);
    final referencePriceReady = _hasDisplayQuote(widget.instrument);
    final livePrice = _hasLiveQuote(widget.instrument);
    final price = _marketOrder
        ? (livePrice ? widget.instrument.price : 0.0)
        : _parseOrderPrice(_priceController.text);
    final estimated = quantity * price;
    final isDomestic =
        widget.instrument.assetClass == _AssetClass.domesticStock;
    final isOverseas =
        widget.instrument.assetClass == _AssetClass.overseasStock;
    final isCrypto = widget.instrument.assetClass == _AssetClass.crypto;
    final orderCurrency = _priceCurrencySuffix(widget.instrument);
    final orderValidationMessage = _orderValidationMessage(
      quantity: quantity,
      price: price,
      livePrice: livePrice,
      referencePriceReady: referencePriceReady,
    );
    final sideColor =
        _side == _TradeSide.buy ? MetaServerColors.buy : MetaServerColors.sell;

    if (isCrypto) {
      return _buildUpbitTicket(
        context: context,
        quantity: quantity,
        price: price,
        estimated: estimated,
        referencePriceReady: referencePriceReady,
        livePrice: livePrice,
        orderCurrency: orderCurrency,
        orderValidationMessage: orderValidationMessage,
        sideColor: sideColor,
      );
    }

    return FutureBuilder<KisPortfolio>(
      future: widget.portfolioFuture,
      builder: (context, snapshot) {
        final portfolio = snapshot.data ?? widget.cachedPortfolio;
        final accountLoading =
            snapshot.connectionState == ConnectionState.waiting &&
                portfolio == null;
        final accountErrorMessage = snapshot.hasError && portfolio == null
            ? (apiFailureMessage(snapshot.error!) ?? 'KIS 잔고 조회에 실패했습니다.')
            : null;
        final accountReady = portfolio != null && accountErrorMessage == null;
        final accountValidationMessage =
            orderValidationMessage == null && !accountReady
                ? (accountLoading
                    ? 'KIS 계좌 잔고 조회 후 주문할 수 있습니다.'
                    : accountErrorMessage ?? 'KIS 계좌 설정을 확인해 주세요.')
                : null;
        final validationMessage =
            orderValidationMessage ?? accountValidationMessage;
        final canSubmit =
            validationMessage == null && !_submitting && !_riskNoticeLoading;
        final orderableCash = portfolio?.orderableCash;
        final afterOrderCash =
            orderableCash == null ? null : orderableCash - estimated;

        return _ScreenScroll(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final ticket = _Panel(
                title: '주문 티켓',
                icon: Icons.swap_vertical_circle_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SelectedInstrumentHeader(instrument: widget.instrument),
                    const SizedBox(height: 14),
                    SegmentedButton<_TradeSide>(
                      segments: const [
                        ButtonSegment(
                          value: _TradeSide.buy,
                          label: Text('매수'),
                          icon: Icon(Icons.add_chart_rounded),
                        ),
                        ButtonSegment(
                          value: _TradeSide.sell,
                          label: Text('매도'),
                          icon: Icon(Icons.show_chart_rounded),
                        ),
                      ],
                      selected: {_side},
                      onSelectionChanged: (value) {
                        final side = value.first;
                        setState(() => _side = side);
                        widget.onSideChanged(side);
                      },
                      style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        foregroundColor:
                            WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.selected)) {
                            return Colors.white;
                          }
                          return MetaServerColors.ink;
                        }),
                        backgroundColor:
                            WidgetStateProperty.resolveWith((states) {
                          if (!states.contains(WidgetState.selected)) {
                            return Colors.white;
                          }
                          return _side == _TradeSide.buy
                              ? MetaServerColors.buy
                              : MetaServerColors.sell;
                        }),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _FieldLabel(
                      label: '계좌',
                      child: _SelectLikeBox(
                        icon: Icons.account_balance_wallet_outlined,
                        title: _orderAccountTitle(
                          portfolio: portfolio,
                          loading: accountLoading,
                          errorMessage: accountErrorMessage,
                        ),
                        subtitle: _orderAccountSubtitle(
                          portfolio: portfolio,
                          loading: accountLoading,
                          errorMessage: accountErrorMessage,
                          isOverseas: isOverseas,
                          orderCurrency: orderCurrency,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _OrderTypeSwitch(
                      marketOrder: _marketOrder,
                      onChanged: (value) =>
                          setState(() => _marketOrder = value),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _NumberField(
                            label: '수량',
                            controller: _quantityController,
                            suffix: '주',
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _NumberField(
                            label: '가격',
                            controller: _priceController,
                            suffix: orderCurrency,
                            allowDecimal:
                                widget.instrument.assetClass.usesDecimalPrice,
                            enabled: !_marketOrder,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _EstimateBox(
                      rows: [
                        _Metric('예상 주문금액',
                            _assetMoney(widget.instrument, estimated)),
                        _Metric('예상 수수료/세금',
                            _assetMoney(widget.instrument, estimated * 0.0015)),
                        _Metric(
                          isDomestic ? '주문 후 예수금' : '주문 통화',
                          isDomestic
                              ? (afterOrderCash == null
                                  ? '--'
                                  : _won(afterOrderCash))
                              : orderCurrency,
                        ),
                      ],
                    ),
                    if (validationMessage != null) ...[
                      const SizedBox(height: 10),
                      _OrderValidationNotice(message: validationMessage),
                    ],
                    const SizedBox(height: 14),
                    ElevatedButton.icon(
                      onPressed: canSubmit
                          ? () => _showOrderReview(context, estimated)
                          : null,
                      icon: Icon(
                        _side == _TradeSide.buy
                            ? Icons.shopping_cart_checkout_rounded
                            : Icons.sell_outlined,
                      ),
                      label: Text(
                        _submitting
                            ? '주문 전송 중'
                            : (_side == _TradeSide.buy
                                ? '매수 주문 확인'
                                : '매도 주문 확인'),
                      ),
                      style:
                          ElevatedButton.styleFrom(backgroundColor: sideColor),
                    ),
                  ],
                ),
              );

              final guide = _Panel(
                title: '주문 전 점검',
                icon: Icons.verified_user_outlined,
                child: Column(
                  children: [
                    _CheckRow(
                      label: '실시간 시세 기준 가격 확인',
                      checked: referencePriceReady,
                    ),
                    _CheckRow(
                      label: accountReady
                          ? '계좌 연결 및 잔고 확인 완료'
                          : accountLoading
                              ? '계좌 연결 및 잔고 확인 중'
                              : '계좌 연결 및 잔고 확인 필요',
                      checked: accountReady,
                    ),
                    const _CheckRow(label: '일 주문 한도와 손실 한도 확인', checked: true),
                    _CheckRow(
                      label: _riskNoticeAgreed
                          ? '실거래 전 투자위험 고지 동의 완료'
                          : _riskNoticeLoading
                              ? '실거래 전 투자위험 고지 동의 확인 중'
                              : '실거래 전 투자위험 고지 동의 필요',
                      checked: _riskNoticeAgreed,
                    ),
                    if (_riskNoticeError != null && !_riskNoticeAgreed) ...[
                      const SizedBox(height: 10),
                      _OrderValidationNotice(message: _riskNoticeError!),
                    ],
                  ],
                ),
              );

              if (constraints.maxWidth >= 900) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: ticket),
                    const SizedBox(width: 16),
                    Expanded(flex: 4, child: guide),
                  ],
                );
              }

              return Column(
                  children: [ticket, const SizedBox(height: 16), guide]);
            },
          ),
        );
      },
    );
  }

  Widget _buildUpbitTicket({
    required BuildContext context,
    required num quantity,
    required double price,
    required num estimated,
    required bool referencePriceReady,
    required bool livePrice,
    required String orderCurrency,
    required String? orderValidationMessage,
    required Color sideColor,
  }) {
    return FutureBuilder<UpbitPortfolio>(
      future: widget.upbitPortfolioFuture,
      builder: (context, snapshot) {
        final portfolio = snapshot.data ?? widget.cachedUpbitPortfolio;
        final accountLoading =
            snapshot.connectionState == ConnectionState.waiting &&
                portfolio == null;
        final accountErrorMessage = snapshot.hasError && portfolio == null
            ? (apiFailureMessage(snapshot.error!) ?? 'Upbit 잔고 조회에 실패했습니다.')
            : null;
        final holding =
            _upbitHoldingForInstrument(portfolio, widget.instrument);
        final orderableCash = portfolio?.orderableCash;
        final afterOrderCash =
            orderableCash == null ? null : orderableCash - estimated;
        String? accountValidationMessage;
        if (orderValidationMessage == null) {
          if (accountLoading) {
            accountValidationMessage = 'Upbit 잔고 조회 후 주문할 수 있습니다.';
          } else if (accountErrorMessage != null || portfolio == null) {
            accountValidationMessage =
                accountErrorMessage ?? 'Upbit API 키와 잔고를 확인해 주세요.';
          } else if (_side == _TradeSide.buy &&
              orderableCash != null &&
              estimated > orderableCash) {
            accountValidationMessage = '주문가능 KRW를 초과했습니다.';
          } else if (_side == _TradeSide.sell &&
              (holding == null || quantity > holding.orderableQuantity)) {
            accountValidationMessage = '매도 가능 수량을 초과했습니다.';
          }
        }
        final validationMessage =
            orderValidationMessage ?? accountValidationMessage;
        final canSubmit =
            validationMessage == null && !_submitting && !_riskNoticeLoading;

        return _ScreenScroll(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final ticket = _Panel(
                title: 'Upbit 주문 패널',
                icon: Icons.currency_bitcoin_rounded,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SelectedInstrumentHeader(instrument: widget.instrument),
                    const SizedBox(height: 14),
                    SegmentedButton<_TradeSide>(
                      segments: const [
                        ButtonSegment(
                          value: _TradeSide.buy,
                          label: Text('매수'),
                          icon: Icon(Icons.add_chart_rounded),
                        ),
                        ButtonSegment(
                          value: _TradeSide.sell,
                          label: Text('매도'),
                          icon: Icon(Icons.show_chart_rounded),
                        ),
                      ],
                      selected: {_side},
                      onSelectionChanged: (value) {
                        final side = value.first;
                        setState(() => _side = side);
                        widget.onSideChanged(side);
                      },
                      style: ButtonStyle(
                        backgroundColor:
                            WidgetStateProperty.resolveWith((states) {
                          if (!states.contains(WidgetState.selected)) {
                            return Colors.white;
                          }
                          return _side == _TradeSide.buy
                              ? MetaServerColors.buy
                              : MetaServerColors.sell;
                        }),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _FieldLabel(
                      label: '계좌',
                      child: _SelectLikeBox(
                        icon: Icons.account_balance_wallet_outlined,
                        title: accountLoading
                            ? 'Upbit 잔고 조회 중'
                            : accountErrorMessage != null
                                ? 'Upbit 잔고 확인 필요'
                                : 'Upbit KRW 마켓',
                        subtitle: accountErrorMessage ??
                            '주문가능 ${_won(orderableCash ?? 0)} · 보유 ${_formatQuantity(holding?.orderableQuantity ?? 0)} ${_cryptoBaseSymbol(widget.instrument.symbol)}',
                      ),
                    ),
                    const SizedBox(height: 12),
                    _OrderTypeSwitch(
                      marketOrder: _marketOrder,
                      onChanged: (value) =>
                          setState(() => _marketOrder = value),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _NumberField(
                            label: '수량',
                            controller: _quantityController,
                            suffix: _cryptoBaseSymbol(widget.instrument.symbol),
                            allowDecimal: widget
                                .instrument.assetClass.usesDecimalQuantity,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _NumberField(
                            label: '가격',
                            controller: _priceController,
                            suffix: orderCurrency,
                            allowDecimal: true,
                            enabled: !_marketOrder,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _EstimateBox(
                      rows: [
                        _Metric('예상 주문금액',
                            _assetMoney(widget.instrument, estimated)),
                        _Metric('예상 수수료',
                            _assetMoney(widget.instrument, estimated * 0.0005)),
                        _Metric(
                          '주문 후 KRW',
                          afterOrderCash == null ? '--' : _won(afterOrderCash),
                        ),
                      ],
                    ),
                    if (validationMessage != null) ...[
                      const SizedBox(height: 10),
                      _OrderValidationNotice(message: validationMessage),
                    ],
                    const SizedBox(height: 14),
                    ElevatedButton.icon(
                      onPressed: canSubmit
                          ? () => _showOrderReview(context, estimated)
                          : null,
                      icon: Icon(
                        _side == _TradeSide.buy
                            ? Icons.shopping_cart_checkout_rounded
                            : Icons.sell_outlined,
                      ),
                      label: Text(
                        _submitting
                            ? '주문 전송 중'
                            : (_side == _TradeSide.buy
                                ? 'Upbit 매수 확인'
                                : 'Upbit 매도 확인'),
                      ),
                      style:
                          ElevatedButton.styleFrom(backgroundColor: sideColor),
                    ),
                  ],
                ),
              );

              final guide = Column(
                children: [
                  _Panel(
                    title: '주문 전 점검',
                    icon: Icons.verified_user_outlined,
                    child: Column(
                      children: [
                        _CheckRow(label: '가격 표시', checked: referencePriceReady),
                        _CheckRow(label: 'Upbit 실시간 가격', checked: livePrice),
                        _CheckRow(
                          label: 'Upbit 잔고 연결',
                          checked:
                              portfolio != null && accountErrorMessage == null,
                        ),
                        _CheckRow(
                          label: '시장가/지정가 파라미터 검증',
                          checked: validationMessage == null,
                        ),
                        _CheckRow(
                          label: _riskNoticeAgreed
                              ? '투자위험 고지 동의 완료'
                              : '투자위험 고지 동의 필요',
                          checked: _riskNoticeAgreed,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _UpbitChancePanel(future: _upbitOrderChanceFuture),
                  const SizedBox(height: 16),
                  _UpbitOrderbookPanel(future: _upbitOrderbookFuture),
                ],
              );

              if (constraints.maxWidth >= 980) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: ticket),
                    const SizedBox(width: 16),
                    Expanded(flex: 4, child: guide),
                  ],
                );
              }

              return Column(
                children: [ticket, const SizedBox(height: 16), guide],
              );
            },
          ),
        );
      },
    );
  }

  String _orderAccountTitle({
    required KisPortfolio? portfolio,
    required bool loading,
    required String? errorMessage,
  }) {
    if (loading) return 'KIS 계좌 확인 중';
    if (errorMessage != null) return 'KIS 계좌 확인 필요';
    final title = 'KIS ${_kisEnvironmentLabel(portfolio?.environment)} 계좌';
    final accountLabel = portfolio?.accountNoMasked.trim() ?? '';
    return accountLabel.isEmpty ? title : '$title $accountLabel';
  }

  String _orderAccountSubtitle({
    required KisPortfolio? portfolio,
    required bool loading,
    required String? errorMessage,
    required bool isOverseas,
    required String orderCurrency,
  }) {
    if (loading) return '주문가능 금액 조회 중';
    if (errorMessage != null) return 'KIS 잔고 조회 실패';
    if (isOverseas) return '미국 주식 지정가 주문 · $orderCurrency 기준';
    final orderableCash = portfolio?.orderableCash;
    if (orderableCash == null) return '주문가능 금액 확인 필요';
    return '주문가능 ${_won(orderableCash)}';
  }

  Future<void> _loadRiskNoticeConsent() async {
    try {
      final status = await ref
          .read(tradingRepositoryProvider)
          .loadTradingRiskNoticeConsent();
      if (!mounted) return;
      setState(() {
        _riskNoticeAgreed = status.agreed;
        _riskNoticeLoading = false;
        _riskNoticeError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _riskNoticeLoading = false;
        _riskNoticeError =
            apiFailureMessage(error) ?? '투자위험 고지 동의 상태를 확인하지 못했습니다.';
      });
    }
  }

  Future<bool> _agreeRiskNoticeConsent() async {
    try {
      final status =
          await ref.read(tradingRepositoryProvider).agreeTradingRiskNotice();
      if (!mounted) return false;
      setState(() {
        _riskNoticeAgreed = status.agreed;
        _riskNoticeLoading = false;
        _riskNoticeError = null;
      });
      return status.agreed;
    } catch (error) {
      if (!mounted) return false;
      final message = apiFailureMessage(error) ?? '투자위험 고지 동의 저장에 실패했습니다.';
      setState(() {
        _riskNoticeError = message;
        _riskNoticeLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      return false;
    }
  }

  void _showOrderReview(BuildContext context, num estimated) {
    final sideText = _side == _TradeSide.buy ? '매수' : '매도';
    final brokerName =
        widget.instrument.assetClass == _AssetClass.crypto ? 'Upbit' : 'KIS';
    var riskNoticeAccepted = _riskNoticeAgreed;
    var savingConsent = false;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final canSend = riskNoticeAccepted && !savingConsent;
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '$sideText 주문 확인',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 14),
                    _ReviewRow(
                      label: '종목',
                      value:
                          '${widget.instrument.name} ${widget.instrument.symbol}',
                    ),
                    _ReviewRow(label: '구분', value: sideText),
                    _ReviewRow(
                      label: '주문금액',
                      value: _assetMoney(widget.instrument, estimated),
                    ),
                    const SizedBox(height: 14),
                    if (!_riskNoticeAgreed) ...[
                      _RiskNoticeConsentBox(
                        checked: riskNoticeAccepted,
                        onChanged: savingConsent
                            ? null
                            : (value) => setModalState(
                                  () => riskNoticeAccepted = value ?? false,
                                ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    FilledButton.icon(
                      onPressed: canSend
                          ? () async {
                              if (!_riskNoticeAgreed) {
                                setModalState(() => savingConsent = true);
                                final saved = await _agreeRiskNoticeConsent();
                                if (!saved) {
                                  if (context.mounted) {
                                    setModalState(() => savingConsent = false);
                                  }
                                  return;
                                }
                              }
                              if (!context.mounted) return;
                              Navigator.of(context).pop();
                              unawaited(_submitOrder());
                            }
                          : null,
                      icon: Icon(
                        savingConsent
                            ? Icons.hourglass_top_rounded
                            : Icons.lock_outline_rounded,
                      ),
                      label: Text(
                        savingConsent
                            ? '동의 저장 중'
                            : (_riskNoticeAgreed
                                ? '$brokerName 주문 전송'
                                : '동의 후 $brokerName 주문 전송'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _submitOrder() async {
    if (!_riskNoticeAgreed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('실거래 전 투자위험 고지 동의가 필요합니다.')),
      );
      return;
    }
    final quantity = _parseOrderQuantity(_quantityController.text);
    final limitPrice =
        _marketOrder ? null : _parseOrderPrice(_priceController.text);
    final orderPrice =
        _marketOrder ? widget.instrument.price : (limitPrice ?? 0).toDouble();
    final validationMessage = _orderValidationMessage(
      quantity: quantity,
      price: orderPrice,
      livePrice: _hasLiveQuote(widget.instrument),
      referencePriceReady: _hasDisplayQuote(widget.instrument),
    );
    if (validationMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(validationMessage)));
      return;
    }
    setState(() => _submitting = true);
    try {
      final repository = ref.read(tradingRepositoryProvider);
      final result = switch (widget.instrument.assetClass) {
        _AssetClass.domesticStock => await repository.placeOrder(
            DomesticStockOrderDraft(
              side: _side == _TradeSide.buy ? 'buy' : 'sell',
              symbol: widget.instrument.symbol,
              quantity: quantity.round(),
              orderKind: _marketOrder ? 'market' : 'limit',
              price: limitPrice?.round(),
            ),
          ),
        _AssetClass.overseasStock => await repository.placeOverseasOrder(
            OverseasStockOrderDraft(
              side: _side == _TradeSide.buy ? 'buy' : 'sell',
              marketCode: widget.instrument.market,
              symbol: widget.instrument.symbol,
              quantity: quantity.round(),
              orderKind: 'limit',
              price: limitPrice,
            ),
          ),
        _AssetClass.crypto => await repository.placeUpbitOrder(
            UpbitOrderDraft(
              side: _side == _TradeSide.buy ? 'buy' : 'sell',
              market: widget.instrument.symbol,
              quantity:
                  _marketOrder && _side == _TradeSide.buy ? null : quantity,
              orderKind: _marketOrder ? 'market' : 'limit',
              price: _marketOrder && _side == _TradeSide.buy
                  ? orderPrice * quantity
                  : limitPrice,
            ),
          ),
      };
      if (!mounted) return;
      final orderNo = result.brokerOrderNo ?? result.trId;
      final brokerName =
          widget.instrument.assetClass == _AssetClass.crypto ? 'Upbit' : 'KIS';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$brokerName 주문이 접수되었습니다. 주문번호: $orderNo')),
      );
    } catch (error) {
      if (!mounted) return;
      final detail = apiFailureMessage(error);
      final brokerName =
          widget.instrument.assetClass == _AssetClass.crypto ? 'Upbit' : 'KIS';
      final message = detail != null
          ? '$brokerName 주문 전송 실패: $detail'
          : isRecoverableApiFailure(error)
              ? '$brokerName 주문 전송에 실패했습니다. 키, 계좌, 실전주문 허용 설정을 확인해 주세요.'
              : error.toString();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _orderPriceText(_Instrument instrument) {
    if (!_hasDisplayQuote(instrument)) return '';
    if (instrument.assetClass.usesDecimalPrice) {
      return formatDecimalInputText(instrument.price.toStringAsFixed(2));
    }
    return formatIntegerInputText(instrument.price.toStringAsFixed(0));
  }

  void _setPriceText(String value) {
    _priceController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  String? _orderValidationMessage({
    required num quantity,
    required double price,
    required bool livePrice,
    required bool referencePriceReady,
  }) {
    if (quantity <= 0) return '수량을 1주 이상 입력해 주세요.';
    if (!widget.instrument.assetClass.supportsKisOrder) {
      return '${widget.instrument.assetClass.label} 주문 어댑터는 준비 중입니다.';
    }
    if (widget.instrument.assetClass == _AssetClass.domesticStock) {
      if (!_isDomesticExtendedSessionNow()) {
        return '국내주식 주문은 평일 08:00~20:00(KST)에 전송할 수 있습니다.';
      }
    }
    if (_marketOrder) {
      if (widget.instrument.assetClass == _AssetClass.overseasStock) {
        return '미국 주식은 현재 지정가 주문만 지원합니다.';
      }
      return livePrice ? null : '시장가 주문은 현재가 조회 후 전송할 수 있습니다.';
    }
    if (price <= 0) return '지정가를 입력해 주세요.';
    if (!referencePriceReady) return '현재가 조회 후 주문 가격을 다시 확인해 주세요.';

    final referencePrice = widget.instrument.price;
    final lowerLimit = referencePrice * 0.7;
    final upperLimit = referencePrice * 1.3;
    if (price < lowerLimit || price > upperLimit) {
      return '지정가가 현재가 기준 허용 범위를 벗어났습니다. 현재가 ${_assetMoney(widget.instrument, referencePrice)} 근처 가격으로 다시 확인해 주세요.';
    }
    return null;
  }

  double _parseOrderPrice(String value) {
    return double.tryParse(removeNumberGrouping(value)) ?? 0;
  }

  double _parseOrderQuantity(String value) {
    return double.tryParse(removeNumberGrouping(value)) ?? 0;
  }
}

class _OrderValidationNotice extends StatelessWidget {
  const _OrderValidationNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MetaServerColors.amber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: MetaServerColors.amber.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: MetaServerColors.amber),
          const SizedBox(width: 10),
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

class _RiskNoticeConsentBox extends StatelessWidget {
  const _RiskNoticeConsentBox({
    required this.checked,
    required this.onChanged,
  });

  final bool checked;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: MetaServerColors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: MetaServerColors.amber.withValues(alpha: 0.36),
        ),
      ),
      child: CheckboxListTile(
        value: checked,
        onChanged: onChanged,
        controlAffinity: ListTileControlAffinity.leading,
        activeColor: MetaServerColors.green,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        title: const Text(
          '실거래 전 투자위험 고지를 확인하고 동의합니다.',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        subtitle: Text(
          '시장가격 변동, 주문 거부, 체결 지연, 원금 손실 가능성을 이해했으며 본인 책임으로 주문을 전송합니다.',
          style: TextStyle(
            color: MetaServerColors.ink.withValues(alpha: 0.68),
            height: 1.35,
          ),
        ),
      ),
    );
  }
}

class _ActivityTab extends ConsumerStatefulWidget {
  const _ActivityTab();

  @override
  ConsumerState<_ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends ConsumerState<_ActivityTab> {
  static const List<int> _activityDayOptions = [1, 7, 30, 90, 0];

  late Future<KisOrderActivity> _activityFuture;
  String? _workingOrderId;
  int _activityDays = 30;
  List<KisOrderActivityItem> _cachedExecutions = const [];

  @override
  void initState() {
    super.initState();
    _cachedExecutions = _loadCachedExecutions();
    _activityFuture = _loadActivity();
  }

  Future<KisOrderActivity> _loadActivity() async {
    final activity = await ref
        .read(tradingRepositoryProvider)
        .loadKisOrderActivity(days: _activityDays == 0 ? 90 : _activityDays);
    _rememberExecutions(activity.executions);
    return activity;
  }

  void _refreshActivity() {
    setState(() {
      _activityFuture = _loadActivity();
    });
  }

  void _changeActivityDays(int days) {
    if (days == _activityDays) return;
    setState(() {
      _activityDays = days;
      _activityFuture = _loadActivity();
    });
  }

  List<KisOrderActivityItem> _loadCachedExecutions() {
    final saved = loadTradingLocalValue(_executionHistoryStorageKey);
    if (saved == null || saved.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List) return const [];
      final items = [
        for (final item in decoded)
          if (item is Map)
            KisOrderActivityItem.fromJson(Map<String, dynamic>.from(item)),
      ];
      return _sortedExecutions(items).take(_executionHistoryLimit).toList();
    } catch (_) {
      return const [];
    }
  }

  void _rememberExecutions(List<KisOrderActivityItem> executions) {
    if (executions.isEmpty) return;
    final merged = _mergeExecutions(_cachedExecutions, executions)
        .take(_executionHistoryLimit)
        .toList();
    saveTradingLocalValue(
      _executionHistoryStorageKey,
      jsonEncode([for (final item in merged) item.toJson()]),
    );
    if (!mounted) return;
    setState(() => _cachedExecutions = merged);
  }

  List<KisOrderActivityItem> _visibleExecutions(
    List<KisOrderActivityItem> fetchedExecutions,
  ) {
    final merged = _mergeExecutions(_cachedExecutions, fetchedExecutions);
    if (_activityDays == 0) return merged;
    final cutoff = _nowInKst().subtract(Duration(days: _activityDays - 1));
    final cutoffDate = DateTime(cutoff.year, cutoff.month, cutoff.day);
    return [
      for (final item in merged)
        if (_executionDate(item)?.isBefore(cutoffDate) != true) item,
    ];
  }

  Future<void> _withOrderAction(
    KisOrderActivityItem order,
    Future<void> Function() action,
  ) async {
    final orderId = order.orderNo?.trim();
    if (orderId == null || orderId.isEmpty || _workingOrderId != null) return;
    setState(() => _workingOrderId = orderId);
    try {
      await action();
      if (!mounted) return;
      _refreshActivity();
    } catch (error) {
      if (!mounted) return;
      final message = apiFailureMessage(error) ?? error.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) setState(() => _workingOrderId = null);
    }
  }

  Future<void> _showCancelOrderDialog(KisOrderActivityItem order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('미체결 주문 취소'),
        content: Text(
          '${order.name} ${_cryptoBaseSymbol(order.symbol)} 주문을 취소합니다.\n남은 수량 ${_formatQuantity(order.remainingQuantity)}개',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('닫기'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('취소 전송'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _withOrderAction(order, () async {
      final orderId = order.orderNo!.trim();
      await ref.read(tradingRepositoryProvider).cancelUpbitOrder(orderId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Upbit 취소 주문을 전송했습니다.')),
      );
    });
  }

  Future<void> _showAmendOrderDialog(KisOrderActivityItem order) async {
    final result = await showDialog<UpbitOrderAmendDraft>(
      context: context,
      builder: (context) => _UpbitAmendOrderDialog(order: order),
    );
    if (result == null) return;
    await _withOrderAction(order, () async {
      final response =
          await ref.read(tradingRepositoryProvider).amendUpbitOrder(result);
      if (!mounted) return;
      final newOrderNo = response.newBrokerOrderNo;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newOrderNo == null || newOrderNo.isEmpty
                ? 'Upbit 정정 주문을 전송했습니다.'
                : 'Upbit 정정 주문을 전송했습니다. 새 주문번호: $newOrderNo',
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return _ScreenScroll(
      child: FutureBuilder<KisOrderActivity>(
        future: _activityFuture,
        builder: (context, snapshot) {
          final activity = snapshot.data;
          final loading = snapshot.connectionState == ConnectionState.waiting &&
              activity == null &&
              _cachedExecutions.isEmpty;
          final errorMessage = snapshot.hasError && activity == null
              ? apiFailureMessage(snapshot.error!) ?? snapshot.error.toString()
              : null;
          final openOrderItems =
              activity?.openOrders ?? const <KisOrderActivityItem>[];
          final executionItems = _visibleExecutions(
            activity?.executions ?? const <KisOrderActivityItem>[],
          );

          return LayoutBuilder(
            builder: (context, constraints) {
              final openOrders = _Panel(
                title: '미체결 주문',
                icon: Icons.pending_actions_outlined,
                trailing: IconButton(
                  tooltip: '새로고침',
                  onPressed: loading ? null : _refreshActivity,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                child: _ActivityPanelBody(
                  loading: loading,
                  errorMessage: errorMessage,
                  emptyMessage: '현재 미체결 주문이 없습니다.',
                  children: [
                    for (final order in openOrderItems)
                      _OrderTile(
                        order: order,
                        working: _workingOrderId == order.orderNo,
                        onAmend: order.isCrypto
                            ? () => _showAmendOrderDialog(order)
                            : null,
                        onCancel: order.isCrypto
                            ? () => _showCancelOrderDialog(order)
                            : null,
                      ),
                  ],
                ),
              );
              final executions = _Panel(
                title: '체결 내역',
                icon: Icons.fact_check_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ActivityRangeSelector(
                      days: _activityDays,
                      options: _activityDayOptions,
                      enabled: !loading,
                      onChanged: _changeActivityDays,
                    ),
                    const SizedBox(height: 12),
                    _ActivityPanelBody(
                      loading: loading,
                      errorMessage:
                          executionItems.isEmpty ? errorMessage : null,
                      emptyMessage: _activityEmptyMessage(_activityDays),
                      children: [
                        for (final execution in executionItems)
                          _ExecutionTile(execution: execution),
                      ],
                    ),
                  ],
                ),
              );

              if (constraints.maxWidth >= 900) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: openOrders),
                    const SizedBox(width: 16),
                    Expanded(child: executions),
                  ],
                );
              }

              return Column(
                children: [openOrders, const SizedBox(height: 16), executions],
              );
            },
          );
        },
      ),
    );
  }
}

class _ActivityRangeSelector extends StatelessWidget {
  const _ActivityRangeSelector({
    required this.days,
    required this.options,
    required this.enabled,
    required this.onChanged,
  });

  final int days;
  final List<int> options;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<int>(
      segments: [
        for (final option in options)
          ButtonSegment<int>(
            value: option,
            label: Text(
              option == 0
                  ? '전체'
                  : option == 1
                      ? '오늘'
                      : '$option일',
            ),
          ),
      ],
      selected: {days},
      onSelectionChanged: enabled
          ? (selection) {
              if (selection.isNotEmpty) onChanged(selection.first);
            }
          : null,
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class _ActivityPanelBody extends StatelessWidget {
  const _ActivityPanelBody({
    required this.loading,
    required this.errorMessage,
    required this.emptyMessage,
    required this.children,
  });

  final bool loading;
  final String? errorMessage;
  final String emptyMessage;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const _PanelStateMessage(
        icon: Icons.sync_rounded,
        message: 'KIS 체결 데이터를 불러오는 중입니다.',
      );
    }

    if (errorMessage != null) {
      return _PanelStateMessage(
        icon: Icons.error_outline_rounded,
        message: errorMessage!,
        danger: true,
      );
    }

    if (children.isEmpty) {
      return _PanelStateMessage(
        icon: Icons.inventory_2_outlined,
        message: emptyMessage,
      );
    }

    return Column(children: children);
  }
}

class _UpbitAmendOrderDialog extends StatefulWidget {
  const _UpbitAmendOrderDialog({required this.order});

  final KisOrderActivityItem order;

  @override
  State<_UpbitAmendOrderDialog> createState() => _UpbitAmendOrderDialogState();
}

class _UpbitAmendOrderDialogState extends State<_UpbitAmendOrderDialog> {
  late final TextEditingController _priceController;
  late final TextEditingController _quantityController;
  bool _useRemainingQuantity = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final price =
        widget.order.price > 0 ? widget.order.price : widget.order.averagePrice;
    _priceController = TextEditingController(
      text: price > 0 ? formatDecimalInputText(price, maxDecimalPlaces: 8) : '',
    );
    _quantityController = TextEditingController(
      text: widget.order.remainingQuantity > 0
          ? formatDecimalInputText(
              widget.order.remainingQuantity,
              maxDecimalPlaces: 8,
            )
          : '',
    );
  }

  @override
  void dispose() {
    _priceController.dispose();
    _quantityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseSymbol = _cryptoBaseSymbol(widget.order.symbol);
    return AlertDialog(
      title: const Text('Upbit 주문 정정'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.order.name} · ${widget.order.symbol}',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              '남은 수량 ${_formatQuantity(widget.order.remainingQuantity)} $baseSymbol',
              style: TextStyle(
                color: MetaServerColors.ink.withValues(alpha: 0.64),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _priceController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: const [
                DecimalThousandsSeparatorInputFormatter(maxDecimalPlaces: 8),
              ],
              decoration: const InputDecoration(
                labelText: '정정 가격',
                suffixText: 'KRW',
              ),
              onChanged: (_) => setState(() => _errorMessage = null),
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _useRemainingQuantity,
              onChanged: (value) => setState(() {
                _useRemainingQuantity = value;
                _errorMessage = null;
              }),
              title: const Text('남은 수량 그대로 정정'),
              subtitle: const Text('부분체결된 주문도 현재 미체결 잔량만 새 주문으로 넘깁니다.'),
            ),
            TextField(
              controller: _quantityController,
              enabled: !_useRemainingQuantity,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: const [
                DecimalThousandsSeparatorInputFormatter(maxDecimalPlaces: 8),
              ],
              decoration: InputDecoration(
                labelText: '새 주문 수량',
                suffixText: baseSymbol,
              ),
              onChanged: (_) => setState(() => _errorMessage = null),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                _errorMessage!,
                style: const TextStyle(
                  color: MetaServerColors.danger,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.edit_rounded),
          label: const Text('정정 전송'),
        ),
      ],
    );
  }

  void _submit() {
    final orderId = widget.order.orderNo?.trim() ?? '';
    final price = double.tryParse(removeNumberGrouping(_priceController.text));
    final quantity =
        double.tryParse(removeNumberGrouping(_quantityController.text));
    if (orderId.isEmpty) {
      setState(() => _errorMessage = '주문번호를 확인할 수 없습니다.');
      return;
    }
    if (price == null || price <= 0) {
      setState(() => _errorMessage = '정정 가격을 입력해 주세요.');
      return;
    }
    if (!_useRemainingQuantity && (quantity == null || quantity <= 0)) {
      setState(() => _errorMessage = '새 주문 수량을 입력해 주세요.');
      return;
    }
    Navigator.of(context).pop(
      UpbitOrderAmendDraft(
        orderId: orderId,
        price: price,
        useRemainingQuantity: _useRemainingQuantity,
        quantity: quantity,
      ),
    );
  }
}

class _TradingAccountTab extends ConsumerWidget {
  const _TradingAccountTab({
    required this.statusFuture,
    required this.cachedStatus,
  });

  final Future<KisConnectionStatus> statusFuture;
  final KisConnectionStatus? cachedStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ScreenScroll(
      child: FutureBuilder<KisConnectionStatus>(
        future: statusFuture,
        builder: (context, snapshot) {
          final status = snapshot.data ?? cachedStatus;
          final loading = snapshot.connectionState == ConnectionState.waiting &&
              status == null;
          final errorMessage = snapshot.hasError && status == null
              ? (apiFailureMessage(snapshot.error!) ?? 'KIS 계좌 상태 조회에 실패했습니다.')
              : null;
          final connected = status?.configured == true;
          final environment = switch (status?.defaultEnvironment) {
            'live' => '실전',
            'paper' => '모의',
            _ => '확인중',
          };
          final liveTrading = status?.liveTradingEnabled == true ? '켜짐' : '꺼짐';
          final accountLabel = status?.accountNoMasked;
          final productCode = status?.productCode;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Panel(
                title: 'KIS 계좌 연결',
                icon: Icons.account_balance_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ConnectionStatus(
                      connected: connected,
                      loading: loading,
                      message: errorMessage ?? status?.message,
                    ),
                    const SizedBox(height: 14),
                    _CredentialRow(
                      icon: Icons.vpn_key_outlined,
                      title: 'App Key',
                      value: connected ? '서버 환경변수 등록됨' : '미설정',
                      status: connected ? '등록됨' : '확인 필요',
                    ),
                    const SizedBox(height: 10),
                    _CredentialRow(
                      icon: Icons.lock_outline_rounded,
                      title: 'App Secret',
                      value: connected ? '보안 저장됨' : '미설정',
                      status: connected ? '보호됨' : '확인 필요',
                    ),
                    const SizedBox(height: 10),
                    _CredentialRow(
                      icon: Icons.account_balance_wallet_outlined,
                      title: '계좌번호',
                      value: accountLabel ??
                          (loading ? '불러오는 중' : '계좌 설정을 확인해 주세요'),
                      status: environment,
                    ),
                    if (productCode != null) ...[
                      const SizedBox(height: 10),
                      _CredentialRow(
                        icon: Icons.confirmation_number_outlined,
                        title: '상품코드',
                        value: productCode,
                        status: 'KIS',
                      ),
                    ],
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: () => context.go('/account'),
                      icon: const Icon(Icons.manage_accounts_outlined),
                      label: const Text('MetaServer 계정 관리'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Panel(
                title: '거래 보호 설정',
                icon: Icons.health_and_safety_outlined,
                child: Column(
                  children: [
                    _LimitRow(
                      label: '실전 주문 허용',
                      value: liveTrading,
                      enabled: status?.liveTradingEnabled == true,
                    ),
                    const _LimitRow(
                      label: '1회 주문 한도',
                      value: '1,000,000원',
                      enabled: true,
                    ),
                    const _LimitRow(
                      label: '1일 주문 한도',
                      value: '5,000,000원',
                      enabled: true,
                    ),
                    const _LimitRow(
                      label: '확장시간 주문',
                      value: '켜짐',
                      enabled: true,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AccountSummaryPanel extends StatelessWidget {
  const _AccountSummaryPanel({
    required this.portfolio,
    required this.loading,
    required this.errorMessage,
  });

  final KisPortfolio? portfolio;
  final bool loading;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final totalEvaluation = portfolio?.totalEvaluationAmount ?? 0;
    final totalProfitLoss = portfolio?.totalProfitLoss ?? 0;
    final profitLossRate = portfolio?.profitLossRate ?? 0;
    final orderableCash = portfolio?.orderableCash ?? 0;
    final accountLabel = portfolio?.accountNoMasked.isNotEmpty == true
        ? portfolio!.accountNoMasked
        : '';
    final accountTitle = loading
        ? 'KIS 계좌 조회 중'
        : errorMessage != null
            ? 'KIS 계좌 확인 필요'
            : 'KIS ${_kisEnvironmentLabel(portfolio?.environment)} 계좌';
    final headline = loading
        ? '조회 중'
        : errorMessage != null
            ? '조회 실패'
            : _won(totalEvaluation);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: MetaServerColors.ink,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: MetaServerColors.ink.withValues(alpha: 0.16),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 16,
            runSpacing: 12,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    accountLabel.isEmpty
                        ? accountTitle
                        : '$accountTitle $accountLabel',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    headline,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                ],
              ),
              _EnvironmentBadge(
                environment: portfolio?.environment,
                loading: loading,
                errorMessage: errorMessage,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _SummaryMetric(
                label: '평가손익',
                value: loading || errorMessage != null
                    ? '--'
                    : _signedWon(totalProfitLoss),
                positive: loading || errorMessage != null
                    ? null
                    : totalProfitLoss >= 0,
              ),
              _SummaryMetric(
                label: '수익률',
                value: loading || errorMessage != null
                    ? '--'
                    : _signedPercent(profitLossRate),
                positive: loading || errorMessage != null
                    ? null
                    : profitLossRate >= 0,
              ),
              _SummaryMetric(
                label: '주문가능',
                value: loading || errorMessage != null
                    ? '--'
                    : _won(orderableCash),
                positive: null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UpbitSummaryPanel extends StatelessWidget {
  const _UpbitSummaryPanel({
    required this.portfolio,
    required this.loading,
    required this.errorMessage,
  });

  final UpbitPortfolio? portfolio;
  final bool loading;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final totalEvaluation = portfolio?.totalEvaluationAmount ?? 0;
    final totalProfitLoss = portfolio?.totalProfitLoss ?? 0;
    final profitLossRate = portfolio?.profitLossRate ?? 0;
    final orderableCash = portfolio?.orderableCash ?? 0;
    final headline = loading
        ? '조회 중'
        : errorMessage != null
            ? '조회 실패'
            : _won(totalEvaluation);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: MetaServerColors.amber.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _IconBadge(icon: Icons.currency_bitcoin_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Upbit 코인 계좌',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      headline,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                  ],
                ),
              ),
              if (errorMessage != null)
                Tooltip(
                  message: errorMessage!,
                  child: const Icon(Icons.error_outline_rounded,
                      color: MetaServerColors.danger),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _SummaryMetric(
                label: '평가손익',
                value: loading || errorMessage != null
                    ? '--'
                    : _signedWon(totalProfitLoss),
                positive: loading || errorMessage != null
                    ? null
                    : totalProfitLoss >= 0,
              ),
              _SummaryMetric(
                label: '수익률',
                value: loading || errorMessage != null
                    ? '--'
                    : _signedPercent(profitLossRate),
                positive: loading || errorMessage != null
                    ? null
                    : profitLossRate >= 0,
              ),
              _SummaryMetric(
                label: '주문가능 KRW',
                value: loading || errorMessage != null
                    ? '--'
                    : _won(orderableCash),
                positive: null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HoldingsPanel extends StatelessWidget {
  const _HoldingsPanel({
    required this.portfolio,
    required this.upbitPortfolio,
    required this.loading,
    required this.errorMessage,
    required this.instruments,
    required this.onOrder,
  });

  final KisPortfolio? portfolio;
  final UpbitPortfolio? upbitPortfolio;
  final bool loading;
  final String? errorMessage;
  final List<_Instrument> instruments;
  final void Function(_Instrument instrument, _TradeSide side) onOrder;

  @override
  Widget build(BuildContext context) {
    final kisHoldings = portfolio?.holdings ?? const <KisHolding>[];
    final cryptoHoldings = [
      for (final holding in upbitPortfolio?.holdings ?? const <UpbitHolding>[])
        if (holding.quantity > 0) _kisHoldingFromUpbit(holding),
    ];
    final holdings = [...kisHoldings, ...cryptoHoldings];
    return _Panel(
      title: '보유 종목',
      icon: Icons.pie_chart_outline_rounded,
      child: Column(
        children: [
          if (loading && holdings.isEmpty)
            const _PanelStateMessage(
              icon: Icons.sync_rounded,
              message: 'KIS 계좌 보유종목을 조회 중입니다.',
            )
          else if (errorMessage != null && holdings.isEmpty)
            _PanelStateMessage(
              icon: Icons.error_outline_rounded,
              message: errorMessage!,
              danger: true,
            )
          else if (holdings.isEmpty)
            const _PanelStateMessage(
              icon: Icons.inventory_2_outlined,
              message: 'KIS 잔고 기준으로 보유수량이 있는 주식이 없습니다.',
            )
          else ...[
            if (errorMessage != null) ...[
              const _PanelStateMessage(
                icon: Icons.error_outline_rounded,
                message: 'KIS 보유종목 일부를 불러오지 못했습니다.',
                danger: true,
              ),
              const SizedBox(height: 10),
            ],
            for (final holding in holdings)
              _HoldingTile(
                holding: holding,
                instrument: _instrumentForHolding(instruments, holding),
                onOrder: onOrder,
              ),
          ],
        ],
      ),
    );
  }
}

class _PanelStateMessage extends StatelessWidget {
  const _PanelStateMessage({
    required this.icon,
    required this.message,
    this.danger = false,
  });

  final IconData icon;
  final String message;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? MetaServerColors.danger : MetaServerColors.green;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
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

class _RiskAndMarketPanel extends StatelessWidget {
  const _RiskAndMarketPanel({
    required this.marketStatusFuture,
    required this.cachedMarketStatus,
    required this.kisStatusFuture,
    required this.cachedKisStatus,
    required this.upbitStatusFuture,
    required this.cachedUpbitStatus,
  });

  final Future<KisMarketStatus> marketStatusFuture;
  final KisMarketStatus? cachedMarketStatus;
  final Future<KisConnectionStatus> kisStatusFuture;
  final KisConnectionStatus? cachedKisStatus;
  final Future<UpbitConnectionStatus> upbitStatusFuture;
  final UpbitConnectionStatus? cachedUpbitStatus;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FutureBuilder<KisMarketStatus>(
          future: marketStatusFuture,
          builder: (context, snapshot) {
            final status = snapshot.data ?? cachedMarketStatus;
            final loading =
                snapshot.connectionState == ConnectionState.waiting &&
                    status == null;
            final errorMessage = snapshot.hasError && status == null
                ? (apiFailureMessage(snapshot.error!) ?? '시장 지수 조회에 실패했습니다.')
                : null;
            return _Panel(
              title: '시장 상태',
              icon: Icons.timeline_rounded,
              child: _MarketStatusBody(
                status: status,
                loading: loading,
                errorMessage: errorMessage,
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        FutureBuilder<UpbitConnectionStatus>(
          future: upbitStatusFuture,
          builder: (context, snapshot) {
            final status = snapshot.data ?? cachedUpbitStatus;
            final loading =
                snapshot.connectionState == ConnectionState.waiting &&
                    status == null;
            final errorMessage = snapshot.hasError && status == null
                ? (apiFailureMessage(snapshot.error!) ?? 'Upbit 설정 조회에 실패했습니다.')
                : null;
            return _Panel(
              title: 'Upbit 연결',
              icon: Icons.currency_bitcoin_rounded,
              child: _UpbitGuardBody(
                status: status,
                loading: loading,
                errorMessage: errorMessage,
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        FutureBuilder<KisConnectionStatus>(
          future: kisStatusFuture,
          builder: (context, snapshot) {
            final status = snapshot.data ?? cachedKisStatus;
            final loading =
                snapshot.connectionState == ConnectionState.waiting &&
                    status == null;
            final errorMessage = snapshot.hasError && status == null
                ? (apiFailureMessage(snapshot.error!) ?? 'KIS 설정 조회에 실패했습니다.')
                : null;
            return _Panel(
              title: '리스크 가드',
              icon: Icons.security_rounded,
              child: _RiskGuardBody(
                status: status,
                loading: loading,
                errorMessage: errorMessage,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _MarketStatusBody extends StatelessWidget {
  const _MarketStatusBody({
    required this.status,
    required this.loading,
    required this.errorMessage,
  });

  final KisMarketStatus? status;
  final bool loading;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const _PanelStateMessage(
        icon: Icons.sync_rounded,
        message: 'KIS 시장 지수를 조회 중입니다.',
      );
    }
    if (errorMessage != null) {
      return _PanelStateMessage(
        icon: Icons.error_outline_rounded,
        message: errorMessage!,
        danger: true,
      );
    }
    final items = status?.items ?? const <KisMarketStatusItem>[];
    if (items.isEmpty) {
      return const _PanelStateMessage(
        icon: Icons.query_stats_rounded,
        message: '표시할 시장 지수가 없습니다.',
      );
    }
    return Column(
      children: [
        for (final item in items)
          _MarketStatusRow(
            label: item.label,
            value: _marketValue(item.value),
            change: _marketChange(item.changeRate),
          ),
      ],
    );
  }
}

class _RiskGuardBody extends StatelessWidget {
  const _RiskGuardBody({
    required this.status,
    required this.loading,
    required this.errorMessage,
  });

  final KisConnectionStatus? status;
  final bool loading;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const _PanelStateMessage(
        icon: Icons.sync_rounded,
        message: 'KIS 보호 설정을 확인 중입니다.',
      );
    }
    if (errorMessage != null) {
      return _PanelStateMessage(
        icon: Icons.error_outline_rounded,
        message: errorMessage!,
        danger: true,
      );
    }
    final connected = status?.configured == true;
    return Column(
      children: [
        _CheckRow(label: 'KIS 계좌 연결', checked: connected),
        _CheckRow(
          label: '실전투자 모드',
          checked: status?.defaultEnvironment == 'live',
        ),
        _CheckRow(
          label: '실전주문 허용',
          checked: status?.liveTradingEnabled == true,
        ),
        _CheckRow(
          label: '자동 거래소 라우팅',
          checked: status?.orderProtocol == 'modern',
        ),
        _CheckRow(
          label: '주문 시간대 검증',
          checked: status?.regularSessionOnly == true,
        ),
      ],
    );
  }
}

class _UpbitGuardBody extends StatelessWidget {
  const _UpbitGuardBody({
    required this.status,
    required this.loading,
    required this.errorMessage,
  });

  final UpbitConnectionStatus? status;
  final bool loading;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const _PanelStateMessage(
        icon: Icons.sync_rounded,
        message: 'Upbit 설정을 확인 중입니다.',
      );
    }
    if (errorMessage != null) {
      return _PanelStateMessage(
        icon: Icons.error_outline_rounded,
        message: errorMessage!,
        danger: true,
      );
    }
    final connected = status?.configured == true;
    return Column(
      children: [
        _CheckRow(label: 'API Key 연결', checked: connected),
        _CheckRow(
          label: '실전 주문 허용',
          checked: status?.liveTradingEnabled == true,
        ),
        _CheckRow(
          label: status?.accessKeyMasked == null
              ? '키 마스킹 확인'
              : '키 ${status!.accessKeyMasked}',
          checked: connected,
        ),
      ],
    );
  }
}

class _UpbitChancePanel extends StatelessWidget {
  const _UpbitChancePanel({required this.future});

  final Future<UpbitOrderChance>? future;

  @override
  Widget build(BuildContext context) {
    final chanceFuture = future;
    return _Panel(
      title: 'Upbit 주문 조건',
      icon: Icons.rule_rounded,
      child: chanceFuture == null
          ? const _PanelStateMessage(
              icon: Icons.info_outline_rounded,
              message: '코인 종목을 선택하면 주문 조건을 조회합니다.',
            )
          : FutureBuilder<UpbitOrderChance>(
              future: chanceFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const _PanelStateMessage(
                    icon: Icons.sync_rounded,
                    message: '주문 가능 정보를 조회 중입니다.',
                  );
                }
                if (snapshot.hasError && !snapshot.hasData) {
                  return _PanelStateMessage(
                    icon: Icons.error_outline_rounded,
                    message: apiFailureMessage(snapshot.error!) ??
                        '주문 가능 정보 조회에 실패했습니다.',
                    danger: true,
                  );
                }
                final chance = snapshot.data;
                if (chance == null) {
                  return const _PanelStateMessage(
                    icon: Icons.info_outline_rounded,
                    message: '주문 가능 정보가 없습니다.',
                  );
                }
                return Column(
                  children: [
                    _ReviewRow(
                      label: '최소 주문',
                      value: _won(chance.minTotal),
                    ),
                    _ReviewRow(
                      label: '매수 수수료',
                      value: _signedPercent(chance.bidFee * 100),
                    ),
                    _ReviewRow(
                      label: '매도 수수료',
                      value: _signedPercent(chance.askFee * 100),
                    ),
                    _ReviewRow(
                      label: '주문가능 KRW',
                      value: _won(chance.bidAccountBalance),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _UpbitOrderbookPanel extends StatelessWidget {
  const _UpbitOrderbookPanel({required this.future});

  final Future<UpbitOrderbook>? future;

  @override
  Widget build(BuildContext context) {
    final orderbookFuture = future;
    return _Panel(
      title: '호가',
      icon: Icons.format_list_numbered_rounded,
      child: orderbookFuture == null
          ? const _PanelStateMessage(
              icon: Icons.info_outline_rounded,
              message: '코인 종목을 선택하면 호가를 조회합니다.',
            )
          : FutureBuilder<UpbitOrderbook>(
              future: orderbookFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const _PanelStateMessage(
                    icon: Icons.sync_rounded,
                    message: '호가를 조회 중입니다.',
                  );
                }
                if (snapshot.hasError && !snapshot.hasData) {
                  return _PanelStateMessage(
                    icon: Icons.error_outline_rounded,
                    message:
                        apiFailureMessage(snapshot.error!) ?? '호가 조회에 실패했습니다.',
                    danger: true,
                  );
                }
                final units = snapshot.data?.units ?? const [];
                if (units.isEmpty) {
                  return const _PanelStateMessage(
                    icon: Icons.info_outline_rounded,
                    message: '표시할 호가가 없습니다.',
                  );
                }
                return Column(
                  children: [
                    for (final unit in units.take(6))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _won(unit.bidPrice),
                                style: const TextStyle(
                                  color: MetaServerColors.fall,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            Text(
                              _formatQuantity(unit.bidSize),
                              style: TextStyle(
                                color: MetaServerColors.ink
                                    .withValues(alpha: 0.52),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _formatQuantity(unit.askSize),
                              style: TextStyle(
                                color: MetaServerColors.ink
                                    .withValues(alpha: 0.52),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                _won(unit.askPrice),
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  color: MetaServerColors.rise,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

class _WatchlistPanel extends StatelessWidget {
  const _WatchlistPanel({
    required this.selectedAssetClass,
    required this.onAssetClassChanged,
    required this.groups,
    required this.selectedGroupId,
    required this.instruments,
    required this.selectedInstrument,
    required this.onGroupSelected,
    required this.onCreateGroup,
    required this.onDeleteGroup,
    required this.onSelected,
    required this.onOrder,
    required this.onAddInstrument,
    required this.onRemoveInstrument,
  });

  final _AssetClass selectedAssetClass;
  final ValueChanged<_AssetClass> onAssetClassChanged;
  final List<_WatchlistGroup> groups;
  final String selectedGroupId;
  final List<_Instrument> instruments;
  final _Instrument selectedInstrument;
  final ValueChanged<String> onGroupSelected;
  final VoidCallback onCreateGroup;
  final VoidCallback onDeleteGroup;
  final ValueChanged<_Instrument> onSelected;
  final void Function(_Instrument instrument, _TradeSide side) onOrder;
  final VoidCallback onAddInstrument;
  final ValueChanged<_Instrument> onRemoveInstrument;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: '관심 종목',
      icon: Icons.star_border_rounded,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '그룹 추가',
            onPressed: onCreateGroup,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            tooltip: '현재 그룹 삭제',
            onPressed: groups.length > 1 ? onDeleteGroup : null,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
          IconButton(
            tooltip: '종목 추가',
            onPressed: onAddInstrument,
            icon: const Icon(Icons.add_circle_outline_rounded),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AssetClassSelector(
            selected: selectedAssetClass,
            onChanged: onAssetClassChanged,
          ),
          const SizedBox(height: 12),
          _WatchlistGroupBar(
            selectedAssetClass: selectedAssetClass,
            groups: groups,
            selectedGroupId: selectedGroupId,
            onSelected: onGroupSelected,
          ),
          const SizedBox(height: 14),
          if (instruments.isEmpty)
            _PanelStateMessage(
              icon: Icons.folder_open_rounded,
              message:
                  '이 그룹에는 ${selectedAssetClass.label} 종목이 없습니다. 오른쪽 위 + 버튼으로 추가해 주세요.',
            )
          else
            for (final instrument in instruments)
              _InstrumentTile(
                instrument: instrument,
                selected: instrument.assetKey == selectedInstrument.assetKey,
                onTap: () => onSelected(instrument),
                onOrder: onOrder,
                onRemove: () => onRemoveInstrument(instrument),
              ),
        ],
      ),
    );
  }
}

class _AssetClassSelector extends StatelessWidget {
  const _AssetClassSelector({
    required this.selected,
    required this.onChanged,
  });

  final _AssetClass selected;
  final ValueChanged<_AssetClass> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: MetaServerColors.line.withValues(alpha: 0.86)),
        image: const DecorationImage(
          image: AssetImage('assets/ui/asset-selector-texture.jpg'),
          fit: BoxFit.cover,
          opacity: 0.13,
        ),
        boxShadow: [
          BoxShadow(
            color: MetaServerColors.ink.withValues(alpha: 0.06),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.75),
            blurRadius: 3,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: Row(
        children: [
          for (final assetClass in _AssetClass.values) ...[
            Expanded(
              child: _AssetClassTab(
                assetClass: assetClass,
                selected: selected == assetClass,
                onTap: () => onChanged(assetClass),
              ),
            ),
            if (assetClass != _AssetClass.values.last) const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}

class _AssetClassTab extends StatelessWidget {
  const _AssetClassTab({
    required this.assetClass,
    required this.selected,
    required this.onTap,
  });

  final _AssetClass assetClass;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = assetClass.accent;
    final foreground = selected
        ? MetaServerColors.ink
        : MetaServerColors.ink.withValues(alpha: 0.72);
    final iconBackground = selected
        ? accent.withValues(alpha: 0.16)
        : Colors.white.withValues(alpha: 0.64);
    final iconColor =
        selected ? accent : MetaServerColors.ink.withValues(alpha: 0.68);

    return Tooltip(
      message: assetClass.label,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: selected ? null : onTap,
          borderRadius: BorderRadius.circular(6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutQuart,
            height: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(
              gradient: selected
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white,
                        accent.withValues(alpha: 0.11),
                      ],
                    )
                  : null,
              color: selected ? null : Colors.white.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected
                    ? accent.withValues(alpha: 0.28)
                    : Colors.white.withValues(alpha: 0.18),
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.14),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.9),
                        blurRadius: 2,
                        offset: const Offset(0, -1),
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (selected)
                  Positioned(
                    bottom: 5,
                    left: 18,
                    right: 18,
                    child: Container(
                      height: 2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            accent.withValues(alpha: 0),
                            accent,
                            accent.withValues(alpha: 0),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: iconBackground,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: selected
                              ? accent.withValues(alpha: 0.22)
                              : Colors.white.withValues(alpha: 0.42),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: selected
                                ? accent.withValues(alpha: 0.12)
                                : MetaServerColors.ink.withValues(alpha: 0.04),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: _AssetClassGlyph(
                        assetClass: assetClass,
                        color: iconColor,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        assetClass.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          height: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AssetClassGlyph extends StatelessWidget {
  const _AssetClassGlyph({
    required this.assetClass,
    required this.color,
  });

  final _AssetClass assetClass;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _AssetClassGlyphPainter(assetClass: assetClass, color: color),
      size: const Size(18, 18),
    );
  }
}

class _AssetClassGlyphPainter extends CustomPainter {
  const _AssetClassGlyphPainter({
    required this.assetClass,
    required this.color,
  });

  final _AssetClass assetClass;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;

    switch (assetClass) {
      case _AssetClass.domesticStock:
        final area = Rect.fromLTWH(
          size.width * 0.12,
          size.height * 0.18,
          size.width * 0.76,
          size.height * 0.64,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(area, const Radius.circular(3)),
          fill,
        );
        final path = Path()
          ..moveTo(size.width * 0.22, size.height * 0.68)
          ..lineTo(size.width * 0.42, size.height * 0.50)
          ..lineTo(size.width * 0.55, size.height * 0.58)
          ..lineTo(size.width * 0.78, size.height * 0.34);
        canvas.drawPath(path, stroke);
        canvas.drawLine(
          Offset(size.width * 0.22, size.height * 0.76),
          Offset(size.width * 0.82, size.height * 0.76),
          stroke..strokeWidth = 1.2,
        );
      case _AssetClass.overseasStock:
        final center = Offset(size.width / 2, size.height / 2);
        final radius = size.shortestSide * 0.37;
        canvas.drawCircle(center, radius, fill);
        canvas.drawCircle(center, radius, stroke);
        canvas.drawOval(
          Rect.fromCenter(
            center: center,
            width: radius * 0.88,
            height: radius * 2,
          ),
          stroke,
        );
        canvas.drawLine(
          Offset(center.dx - radius, center.dy),
          Offset(center.dx + radius, center.dy),
          stroke,
        );
      case _AssetClass.crypto:
        final center = Offset(size.width / 2, size.height / 2);
        final radius = size.shortestSide * 0.34;
        final backStroke = Paint()
          ..color = color.withValues(alpha: 0.34)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25
          ..strokeCap = StrokeCap.round;
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(size.width * 0.43, size.height * 0.58),
            width: size.width * 0.58,
            height: size.height * 0.30,
          ),
          backStroke,
        );
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(size.width * 0.45, size.height * 0.52),
            width: size.width * 0.60,
            height: size.height * 0.34,
          ),
          backStroke,
        );
        canvas.drawCircle(center, radius, fill);
        canvas.drawCircle(center, radius, stroke);
        canvas.drawCircle(center, radius * 0.68, backStroke);
        final coin = Path()
          ..moveTo(size.width * 0.45, size.height * 0.31)
          ..lineTo(size.width * 0.45, size.height * 0.69)
          ..moveTo(size.width * 0.53, size.height * 0.31)
          ..lineTo(size.width * 0.53, size.height * 0.69)
          ..moveTo(size.width * 0.38, size.height * 0.38)
          ..lineTo(size.width * 0.55, size.height * 0.38)
          ..quadraticBezierTo(
            size.width * 0.67,
            size.height * 0.38,
            size.width * 0.67,
            size.height * 0.49,
          )
          ..quadraticBezierTo(
            size.width * 0.67,
            size.height * 0.59,
            size.width * 0.55,
            size.height * 0.59,
          )
          ..lineTo(size.width * 0.38, size.height * 0.59)
          ..moveTo(size.width * 0.55, size.height * 0.49)
          ..lineTo(size.width * 0.39, size.height * 0.49);
        canvas.drawPath(coin, stroke..strokeWidth = 1.45);
    }
  }

  @override
  bool shouldRepaint(covariant _AssetClassGlyphPainter oldDelegate) {
    return oldDelegate.assetClass != assetClass || oldDelegate.color != color;
  }
}

class _WatchlistGroupBar extends StatelessWidget {
  const _WatchlistGroupBar({
    required this.selectedAssetClass,
    required this.groups,
    required this.selectedGroupId,
    required this.onSelected,
  });

  final _AssetClass selectedAssetClass;
  final List<_WatchlistGroup> groups;
  final String selectedGroupId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final group in groups)
          _WatchlistGroupChip(
            group: group,
            selectedAssetClass: selectedAssetClass,
            selected: group.id == selectedGroupId,
            onTap: () => onSelected(group.id),
          ),
      ],
    );
  }
}

class _WatchlistGroupChip extends StatelessWidget {
  const _WatchlistGroupChip({
    required this.group,
    required this.selectedAssetClass,
    required this.selected,
    required this.onTap,
  });

  final _WatchlistGroup group;
  final _AssetClass selectedAssetClass;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? MetaServerColors.green : MetaServerColors.ink;
    final visibleCount = group.assetCount(selectedAssetClass);
    final totalCount = group.instruments.length;
    return Tooltip(
      message:
          '${group.name} ${selectedAssetClass.label} $visibleCount개 · 전체 $totalCount개',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 168, minHeight: 38),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: selected ? MetaServerColors.green : Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      selected ? MetaServerColors.green : MetaServerColors.line,
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: MetaServerColors.green.withValues(alpha: 0.16),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected ? Icons.folder_rounded : Icons.folder_outlined,
                    size: 18,
                    color:
                        selected ? Colors.white : accent.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      '${group.name} $visibleCount',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? Colors.white : MetaServerColors.ink,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InstrumentDetailPanel extends StatelessWidget {
  const _InstrumentDetailPanel({
    required this.instrument,
    required this.onOrder,
  });

  final _Instrument instrument;
  final void Function(_Instrument instrument, _TradeSide side) onOrder;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: '종목 상세',
      icon: Icons.candlestick_chart_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SelectedInstrumentHeader(instrument: instrument),
          const SizedBox(height: 16),
          SizedBox(
            height: 128,
            child: _Sparkline(
              values: _hasDisplayQuote(instrument)
                  ? instrument.chart
                  : const [0, 0],
              positive: instrument.changeRate >= 0,
            ),
          ),
          const SizedBox(height: 16),
          _EstimateBox(
            rows: [
              _Metric('시가', _quoteMetric(instrument, instrument.open)),
              _Metric('고가', _quoteMetric(instrument, instrument.high)),
              _Metric('저가', _quoteMetric(instrument, instrument.low)),
              _Metric(
                '거래대금',
                _hasDisplayQuote(instrument)
                    ? '${_compact(instrument.tradeAmount)}원'
                    : '--',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => onOrder(instrument, _TradeSide.buy),
                  icon: const Icon(Icons.add_chart_rounded),
                  label: const Text('매수'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: MetaServerColors.buy,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => onOrder(instrument, _TradeSide.sell),
                  icon: const Icon(Icons.sell_outlined),
                  label: const Text('매도'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: MetaServerColors.sell,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

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
              _IconBadge(icon: icon),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: MetaServerColors.ink,
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _ScreenScroll extends StatelessWidget {
  const _ScreenScroll({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 26),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: child,
        ),
      ),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
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
        side: const BorderSide(color: MetaServerColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

class _IconBadge extends StatelessWidget {
  const _IconBadge({required this.icon, this.color = MetaServerColors.cyan});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Icon(icon, color: color, size: 23),
    );
  }
}

class _EnvironmentBadge extends StatelessWidget {
  const _EnvironmentBadge({
    required this.loading,
    required this.errorMessage,
    this.environment,
  });

  final String? environment;
  final bool loading;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final label = loading
        ? '조회 중'
        : errorMessage != null
            ? '확인 필요'
            : _kisEnvironmentLabel(environment);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: MetaServerColors.mint.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: MetaServerColors.mint.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.science_outlined,
            size: 18,
            color: MetaServerColors.mint,
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.positive,
  });

  final String label;
  final String value;
  final bool? positive;

  @override
  Widget build(BuildContext context) {
    final color = positive == null
        ? Colors.white
        : positive == true
            ? MetaServerColors.riseOnDark
            : MetaServerColors.fallOnDark;
    return Container(
      constraints: const BoxConstraints(minWidth: 126),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.62),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(color: color, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class _HoldingTile extends StatelessWidget {
  const _HoldingTile({
    required this.holding,
    required this.instrument,
    required this.onOrder,
  });

  final KisHolding holding;
  final _Instrument instrument;
  final void Function(_Instrument instrument, _TradeSide side) onOrder;

  @override
  Widget build(BuildContext context) {
    final evaluationAmount = holding.evaluationAmount > 0
        ? holding.evaluationAmount
        : instrument.price * holding.quantity;
    final profitRate = holding.profitLossRate;
    final quantity = _formatQuantity(holding.quantity);
    final isCrypto = holding.assetClass == 'crypto';
    final quantitySuffix = isCrypto ? _cryptoBaseSymbol(holding.symbol) : '주';
    final currency = holding.currency.trim().isNotEmpty
        ? holding.currency
        : (holding.assetClass == 'overseas_stock' ? 'USD' : 'KRW');
    return _DataTile(
      leading: _IconBadge(
        icon: isCrypto
            ? Icons.currency_bitcoin_rounded
            : Icons.business_center_outlined,
        color: isCrypto ? MetaServerColors.amber : MetaServerColors.green,
      ),
      title: holding.name,
      subtitle:
          '${holding.market} · ${holding.symbol} · $quantity$quantitySuffix · 평균 ${_moneyByCurrency(holding.averagePrice, currency)}',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _moneyByCurrency(evaluationAmount, currency),
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          _ChangeText(value: profitRate),
        ],
      ),
      actions: [
        _MiniAction(
          label: '매수',
          icon: Icons.add,
          onTap: () => onOrder(instrument, _TradeSide.buy),
          color: MetaServerColors.buy,
        ),
        _MiniAction(
          label: '매도',
          icon: Icons.remove,
          onTap: () => onOrder(instrument, _TradeSide.sell),
          color: MetaServerColors.sell,
        ),
      ],
    );
  }
}

class _InstrumentTile extends StatelessWidget {
  const _InstrumentTile({
    required this.instrument,
    required this.selected,
    required this.onTap,
    required this.onOrder,
    required this.onRemove,
  });

  final _Instrument instrument;
  final bool selected;
  final VoidCallback onTap;
  final void Function(_Instrument instrument, _TradeSide side) onOrder;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final hasQuote = _hasDisplayQuote(instrument);
    return _DataTile(
      selected: selected,
      onTap: onTap,
      leading: _IconBadge(
        icon: hasQuote ? Icons.show_chart_rounded : Icons.hourglass_empty,
        color: !hasQuote
            ? MetaServerColors.ink.withValues(alpha: 0.42)
            : instrument.changeRate >= 0
                ? MetaServerColors.rise
                : MetaServerColors.fall,
      ),
      title: instrument.name,
      subtitle:
          '${instrument.market} · ${instrument.symbol} · ${instrument.sector}',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _priceLabel(instrument),
            style: TextStyle(
              color: hasQuote
                  ? MetaServerColors.ink
                  : MetaServerColors.ink.withValues(alpha: 0.54),
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          hasQuote
              ? _ChangeText(value: instrument.changeRate)
              : Text(
                  'KIS 미갱신',
                  style: TextStyle(
                    color: MetaServerColors.ink.withValues(alpha: 0.48),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ],
      ),
      actions: [
        _MiniAction(
          label: '매수',
          icon: Icons.add,
          onTap: () => onOrder(instrument, _TradeSide.buy),
          color: MetaServerColors.buy,
        ),
        _MiniAction(
          label: '매도',
          icon: Icons.remove,
          onTap: () => onOrder(instrument, _TradeSide.sell),
          color: MetaServerColors.sell,
        ),
        _MiniAction(
          label: '삭제',
          icon: Icons.delete_outline_rounded,
          onTap: onRemove,
        ),
      ],
    );
  }
}

class _DataTile extends StatelessWidget {
  const _DataTile({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.actions = const [],
    this.selected = false,
    this.onTap,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final Widget trailing;
  final List<Widget> actions;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? MetaServerColors.mint.withValues(alpha: 0.12)
            : MetaServerColors.canvas,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: selected ? MetaServerColors.cyan : MetaServerColors.line,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    leading,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: MetaServerColors.ink.withValues(
                                alpha: 0.58,
                              ),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    trailing,
                  ],
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.color,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 17),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(74, 38),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          foregroundColor: color,
        ),
      ),
    );
  }
}

class _SelectedInstrumentHeader extends StatelessWidget {
  const _SelectedInstrumentHeader({required this.instrument});

  final _Instrument instrument;

  @override
  Widget build(BuildContext context) {
    final hasQuote = _hasDisplayQuote(instrument);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MetaServerColors.ink,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          _IconBadge(
            icon: hasQuote ? Icons.insights_rounded : Icons.hourglass_empty,
            color: !hasQuote
                ? Colors.white.withValues(alpha: 0.58)
                : instrument.changeRate >= 0
                    ? MetaServerColors.riseOnDark
                    : MetaServerColors.fallOnDark,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  instrument.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${instrument.market} · ${instrument.symbol}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.64),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _priceLabel(instrument),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              hasQuote
                  ? _ChangeText(value: instrument.changeRate, onDark: true)
                  : Text(
                      'KIS 미갱신',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.64),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.values, required this.positive});

  final List<double> values;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SparklinePainter(
        values: values,
        color: positive ? MetaServerColors.rise : MetaServerColors.fall,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = MetaServerColors.line
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (values.length < 2) return;
    final minValue = values.reduce((a, b) => a < b ? a : b);
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    final range = maxValue - minValue == 0 ? 1 : maxValue - minValue;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height - ((values[i] - minValue) / range * size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.values != values || oldDelegate.color != color;
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({
    required this.order,
    required this.working,
    this.onAmend,
    this.onCancel,
  });

  final KisOrderActivityItem order;
  final bool working;
  final VoidCallback? onAmend;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final sideText = order.isBuy ? '매수' : '매도';
    final price = order.price > 0 ? order.price : order.averagePrice;
    final quantitySuffix =
        order.isCrypto ? _cryptoBaseSymbol(order.symbol) : '주';
    final quantityPrecision = order.isCrypto ? 8 : 2;
    return _DataTile(
      leading: _IconBadge(
        icon: order.isBuy ? Icons.add_chart_rounded : Icons.sell_outlined,
        color: order.isBuy ? MetaServerColors.buy : MetaServerColors.sell,
      ),
      title: order.name,
      subtitle:
          '${order.symbol} · $sideText · ${order.status}${_orderNoSuffix(order.orderNo)}',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_formatQuantity(order.filledQuantity, decimalPlaces: quantityPrecision)}/${_formatQuantity(order.quantity, decimalPlaces: quantityPrecision)}$quantitySuffix',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            price > 0 ? _won(price) : '--',
            style: TextStyle(
              color: MetaServerColors.ink.withValues(alpha: 0.62),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      actions: [
        if (working)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else ...[
          if (onAmend != null)
            _MiniAction(
              label: '정정',
              icon: Icons.edit_rounded,
              onTap: onAmend!,
            ),
          if (onCancel != null)
            _MiniAction(
              label: '취소',
              icon: Icons.delete_outline_rounded,
              onTap: onCancel!,
            ),
        ],
      ],
    );
  }
}

class _ExecutionTile extends StatelessWidget {
  const _ExecutionTile({required this.execution});

  final KisOrderActivityItem execution;

  @override
  Widget build(BuildContext context) {
    final sideText = execution.isBuy ? '매수' : '매도';
    final executionPrice =
        execution.averagePrice > 0 ? execution.averagePrice : execution.price;
    final quantitySuffix =
        execution.isCrypto ? _cryptoBaseSymbol(execution.symbol) : '주';
    final quantityPrecision = execution.isCrypto ? 8 : 2;
    return _DataTile(
      leading: _IconBadge(
        icon: Icons.done_all_rounded,
        color: execution.isBuy ? MetaServerColors.buy : MetaServerColors.sell,
      ),
      title: execution.name,
      subtitle:
          '${execution.symbol} · $sideText · ${_formatOrderDateTime(execution.orderDate, execution.orderTime)}',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_formatQuantity(execution.filledQuantity, decimalPlaces: quantityPrecision)}$quantitySuffix',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            executionPrice > 0 ? _won(executionPrice) : '--',
            style: TextStyle(
              color: MetaServerColors.ink.withValues(alpha: 0.62),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChangeText extends StatelessWidget {
  const _ChangeText({required this.value, this.onDark = false});

  final double value;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final positive = value >= 0;
    final color = positive
        ? (onDark ? MetaServerColors.riseOnDark : MetaServerColors.rise)
        : (onDark ? MetaServerColors.fallOnDark : MetaServerColors.fall);
    return Text(
      '${positive ? '+' : ''}${value.toStringAsFixed(2)}%',
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w900),
    );
  }
}

class _MarketStatusRow extends StatelessWidget {
  const _MarketStatusRow({
    required this.label,
    required this.value,
    required this.change,
  });

  final String label;
  final String value;
  final String change;

  @override
  Widget build(BuildContext context) {
    final positive = !change.startsWith('-');
    return _ReviewRow(
      label: label,
      value: '$value  $change',
      valueColor: change == '--'
          ? MetaServerColors.ink.withValues(alpha: 0.62)
          : positive
              ? MetaServerColors.rise
              : MetaServerColors.fall,
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.checked});

  final String label;
  final bool checked;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(
            checked
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            color: checked ? MetaServerColors.green : MetaServerColors.amber,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: MetaServerColors.ink.withValues(alpha: 0.62),
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 7),
        child,
      ],
    );
  }
}

class _SelectLikeBox extends StatelessWidget {
  const _SelectLikeBox({
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
      padding: const EdgeInsets.all(12),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: MetaServerColors.ink.withValues(alpha: 0.58),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.expand_more_rounded),
        ],
      ),
    );
  }
}

class _OrderTypeSwitch extends StatelessWidget {
  const _OrderTypeSwitch({required this.marketOrder, required this.onChanged});

  final bool marketOrder;
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
          const Icon(Icons.tune_rounded, color: MetaServerColors.cyan),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '시장가 주문',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          Switch(value: marketOrder, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.controller,
    required this.suffix,
    required this.onChanged,
    this.enabled = true,
    this.allowDecimal = false,
  });

  final String label;
  final TextEditingController controller;
  final String suffix;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final bool allowDecimal;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      keyboardType: TextInputType.numberWithOptions(decimal: allowDecimal),
      inputFormatters: allowDecimal
          ? const [DecimalThousandsSeparatorInputFormatter()]
          : const [ThousandsSeparatorInputFormatter()],
      decoration: InputDecoration(labelText: label, suffixText: suffix),
      textAlign: TextAlign.right,
      style: const TextStyle(fontWeight: FontWeight.w900),
    );
  }
}

class _EstimateBox extends StatelessWidget {
  const _EstimateBox({required this.rows});

  final List<_Metric> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MetaServerColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            _ReviewRow(label: rows[i].label, value: rows[i].value),
            if (i != rows.length - 1)
              const Divider(height: 18, color: MetaServerColors.line),
          ],
        ],
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: MetaServerColors.ink.withValues(alpha: 0.58),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? MetaServerColors.ink,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({
    required this.connected,
    required this.loading,
    this.message,
  });

  final bool connected;
  final bool loading;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final color = connected ? MetaServerColors.green : MetaServerColors.danger;
    final text = loading
        ? 'KIS 계좌 연결 확인 중'
        : connected
            ? 'KIS 계좌 연결 완료'
            : (message ?? 'KIS 계좌 연결 설정을 확인해 주세요');
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(
            connected
                ? Icons.check_circle_rounded
                : Icons.error_outline_rounded,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

class _CredentialRow extends StatelessWidget {
  const _CredentialRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.status,
  });

  final IconData icon;
  final String title;
  final String value;
  final String status;

  @override
  Widget build(BuildContext context) {
    return _SelectLikeBox(
      icon: icon,
      title: '$title · $status',
      subtitle: value,
    );
  }
}

class _LimitRow extends StatelessWidget {
  const _LimitRow({
    required this.label,
    required this.value,
    required this.enabled,
  });

  final String label;
  final String value;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return _ReviewRow(
      label: label,
      value: value,
      valueColor: enabled
          ? MetaServerColors.green
          : MetaServerColors.ink.withValues(alpha: 0.5),
    );
  }
}

class _Metric {
  const _Metric(this.label, this.value);

  final String label;
  final String value;
}

class _WatchlistGroup {
  const _WatchlistGroup({
    required this.id,
    required this.assetClass,
    required this.name,
    required this.instruments,
  });

  final String id;
  final _AssetClass assetClass;
  final String name;
  final List<_Instrument> instruments;

  static List<_WatchlistGroup> fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final rawInstruments = json['instruments'];
    if (id is! String ||
        id.trim().isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        rawInstruments is! List) {
      return const [];
    }
    final instruments = [
      for (final item in rawInstruments)
        if (item is Map) _Instrument.fromJson(Map<String, Object?>.from(item)),
    ].whereType<_Instrument>().toList();

    final assetClassValue = json['asset_class'];
    if (assetClassValue is String && assetClassValue.trim().isNotEmpty) {
      final assetClass = _assetClassFromStorage(assetClassValue);
      final filtered = [
        for (final instrument in instruments)
          if (instrument.assetClass == assetClass) instrument,
      ];
      return [
        _WatchlistGroup(
          id: id,
          assetClass: assetClass,
          name: name,
          instruments: filtered,
        ),
      ];
    }

    return [
      for (final assetClass in _AssetClass.values)
        if (instruments
            .any((instrument) => instrument.assetClass == assetClass))
          _WatchlistGroup(
            id: _assetScopedWatchlistGroupId(id, assetClass),
            assetClass: assetClass,
            name: name,
            instruments: [
              for (final instrument in instruments)
                if (instrument.assetClass == assetClass) instrument,
            ],
          ),
    ];
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'asset_class': assetClass.storageValue,
      'name': name,
      'instruments':
          instruments.map((instrument) => instrument.toJson()).toList(),
    };
  }

  int assetCount(_AssetClass assetClass) {
    return instruments
        .where((instrument) => instrument.assetClass == assetClass)
        .length;
  }

  _WatchlistGroup copyWith({
    String? id,
    _AssetClass? assetClass,
    String? name,
    List<_Instrument>? instruments,
  }) {
    return _WatchlistGroup(
      id: id ?? this.id,
      assetClass: assetClass ?? this.assetClass,
      name: name ?? this.name,
      instruments: instruments ?? this.instruments,
    );
  }
}

class _Instrument {
  const _Instrument({
    this.assetClass = _AssetClass.domesticStock,
    required this.market,
    required this.symbol,
    required this.name,
    required this.sector,
    required this.price,
    required this.changeRate,
    required this.open,
    required this.high,
    required this.low,
    required this.tradeAmount,
    required this.chart,
    this.hasLiveQuote = false,
  });

  final _AssetClass assetClass;
  final String market;
  final String symbol;
  final String name;
  final String sector;
  final double price;
  final double changeRate;
  final double open;
  final double high;
  final double low;
  final double tradeAmount;
  final List<double> chart;
  final bool hasLiveQuote;

  String get assetKey => _assetKey(assetClass, market, symbol);

  static _Instrument? fromJson(Map<String, Object?> json) {
    final market = json['market'];
    final assetClass = _assetClassFromStorage(json['assetClass']);
    final symbol = json['symbol'];
    final name = json['name'];
    final sector = json['sector'];
    final price = _jsonDouble(json['price']);
    final changeRate = _jsonDouble(json['changeRate']);
    final open = _jsonDouble(json['open']);
    final high = _jsonDouble(json['high']);
    final low = _jsonDouble(json['low']);
    final tradeAmount = _jsonDouble(json['tradeAmount']);
    final chart = _jsonDoubleList(json['chart']);
    if (market is! String ||
        symbol is! String ||
        name is! String ||
        sector is! String ||
        price == null ||
        changeRate == null ||
        open == null ||
        high == null ||
        low == null ||
        tradeAmount == null ||
        chart.isEmpty) {
      return null;
    }
    return _Instrument(
      assetClass: assetClass,
      market: market,
      symbol: symbol,
      name: name,
      sector: sector,
      price: price,
      changeRate: changeRate,
      open: open,
      high: high,
      low: low,
      tradeAmount: tradeAmount,
      chart: chart,
      hasLiveQuote: false,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'market': market,
      'assetClass': assetClass.storageValue,
      'symbol': symbol,
      'name': name,
      'sector': sector,
      'price': price,
      'changeRate': changeRate,
      'open': open,
      'high': high,
      'low': low,
      'tradeAmount': tradeAmount,
      'chart': chart,
      'hasLiveQuote': false,
    };
  }

  _Instrument copyWith({
    _AssetClass? assetClass,
    double? price,
    double? changeRate,
    double? open,
    double? high,
    double? low,
    double? tradeAmount,
    bool? hasLiveQuote,
  }) {
    final nextPrice = price ?? this.price;
    final nextChart = price == null
        ? chart
        : [if (chart.length > 1) ...chart.skip(1), nextPrice / 1000];
    return _Instrument(
      assetClass: assetClass ?? this.assetClass,
      market: market,
      symbol: symbol,
      name: name,
      sector: sector,
      price: nextPrice,
      changeRate: changeRate ?? this.changeRate,
      open: open ?? this.open,
      high: high ?? this.high,
      low: low ?? this.low,
      tradeAmount: tradeAmount ?? this.tradeAmount,
      chart: nextChart,
      hasLiveQuote: hasLiveQuote ?? this.hasLiveQuote,
    );
  }
}

double? _jsonDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

List<double> _jsonDoubleList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (_jsonDouble(item) != null) _jsonDouble(item)!,
  ];
}

class _StockCatalogItem {
  const _StockCatalogItem({
    this.assetClass = _AssetClass.domesticStock,
    required this.market,
    required this.symbol,
    required this.name,
    required this.sector,
    this.aliases = const [],
  });

  final _AssetClass assetClass;
  final String market;
  final String symbol;
  final String name;
  final String sector;
  final List<String> aliases;

  bool matches(String query) {
    final normalizedSymbol =
        _normalizeAssetSymbol(query, assetClass).toLowerCase();
    if (normalizedSymbol.isNotEmpty &&
        symbol.toLowerCase().contains(normalizedSymbol)) {
      return true;
    }
    final words = [name, symbol, market, sector, ...aliases];
    return words.any((word) => word.toLowerCase().contains(query));
  }
}

_StockCatalogItem? _stockCatalogItemBySymbol(
  String symbol, {
  _AssetClass? assetClass,
}) {
  for (final item in _stockCatalog) {
    if (item.symbol == symbol &&
        (assetClass == null || item.assetClass == assetClass)) {
      return item;
    }
  }
  return null;
}

const _popularStockSymbols = [
  '005930',
  '000660',
  '035420',
  '247540',
  '005380',
  '035720',
];

const _popularOverseasSymbols = [
  'AAPL',
  'MSFT',
  'NVDA',
  'TSLA',
  'GOOGL',
  'AMZN'
];
const _popularCryptoSymbols = ['KRW-BTC', 'KRW-ETH', 'KRW-SOL', 'KRW-XRP'];

List<_StockCatalogItem> _popularCatalogItems(_AssetClass assetClass) {
  final symbols = switch (assetClass) {
    _AssetClass.domesticStock => _popularStockSymbols,
    _AssetClass.overseasStock => _popularOverseasSymbols,
    _AssetClass.crypto => _popularCryptoSymbols,
  };
  return [
    for (final symbol in symbols)
      if (_stockCatalogItemBySymbol(symbol, assetClass: assetClass) != null)
        _stockCatalogItemBySymbol(symbol, assetClass: assetClass)!,
  ];
}

const _stockCatalog = [
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '005930',
    name: '삼성전자',
    sector: '반도체',
    aliases: ['삼전', 'samsung'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '000660',
    name: 'SK하이닉스',
    sector: '반도체',
    aliases: ['하이닉스', 'hynix', 'sk hynix'],
  ),
  _StockCatalogItem(
    market: 'KOSDAQ',
    symbol: '247540',
    name: '에코프로비엠',
    sector: '2차전지',
    aliases: ['ecopro bm', '에코비엠'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '035420',
    name: 'NAVER',
    sector: '인터넷',
    aliases: ['네이버', 'naver'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '005380',
    name: '현대차',
    sector: '자동차',
    aliases: ['현대자동차', 'hyundai'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '035720',
    name: '카카오',
    sector: '인터넷',
    aliases: ['kakao'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '068270',
    name: '셀트리온',
    sector: '바이오',
    aliases: ['celltrion'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '207940',
    name: '삼성바이오로직스',
    sector: '바이오',
    aliases: ['삼바', 'samsung biologics'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '005490',
    name: 'POSCO홀딩스',
    sector: '철강',
    aliases: ['포스코홀딩스', 'posco'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '051910',
    name: 'LG화학',
    sector: '화학',
    aliases: ['lg chem'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '373220',
    name: 'LG에너지솔루션',
    sector: '2차전지',
    aliases: ['lg엔솔', 'lges'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '000270',
    name: '기아',
    sector: '자동차',
    aliases: ['kia'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '105560',
    name: 'KB금융',
    sector: '금융',
    aliases: ['kb'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '055550',
    name: '신한지주',
    sector: '금융',
    aliases: ['신한금융'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '012330',
    name: '현대모비스',
    sector: '자동차부품',
    aliases: ['모비스'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '096770',
    name: 'SK이노베이션',
    sector: '에너지',
    aliases: ['sk이노'],
  ),
  _StockCatalogItem(
    market: 'KOSPI',
    symbol: '028260',
    name: '삼성물산',
    sector: '상사',
  ),
  _StockCatalogItem(
    market: 'KOSDAQ',
    symbol: '086520',
    name: '에코프로',
    sector: '2차전지',
    aliases: ['ecopro'],
  ),
  _StockCatalogItem(
    market: 'KOSDAQ',
    symbol: '091990',
    name: '셀트리온헬스케어',
    sector: '바이오',
  ),
  _StockCatalogItem(
    market: 'ETF',
    symbol: '069500',
    name: 'KODEX 200',
    sector: 'ETF',
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.overseasStock,
    market: 'NASDAQ',
    symbol: 'AAPL',
    name: 'Apple',
    sector: 'Technology',
    aliases: ['apple', 'iphone'],
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.overseasStock,
    market: 'NASDAQ',
    symbol: 'MSFT',
    name: 'Microsoft',
    sector: 'Technology',
    aliases: ['microsoft'],
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.overseasStock,
    market: 'NASDAQ',
    symbol: 'NVDA',
    name: 'NVIDIA',
    sector: 'Semiconductor',
    aliases: ['nvidia'],
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.overseasStock,
    market: 'NASDAQ',
    symbol: 'TSLA',
    name: 'Tesla',
    sector: 'Automotive',
    aliases: ['tesla'],
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.overseasStock,
    market: 'NASDAQ',
    symbol: 'GOOGL',
    name: 'Alphabet',
    sector: 'Communication Services',
    aliases: ['google', 'alphabet'],
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.overseasStock,
    market: 'NASDAQ',
    symbol: 'AMZN',
    name: 'Amazon',
    sector: 'Consumer Discretionary',
    aliases: ['amazon'],
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.overseasStock,
    market: 'NASDAQ',
    symbol: 'META',
    name: 'Meta Platforms',
    sector: 'Communication Services',
    aliases: ['meta', 'facebook'],
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.overseasStock,
    market: 'NYSE',
    symbol: 'BRK.B',
    name: 'Berkshire Hathaway',
    sector: 'Financials',
    aliases: ['berkshire', 'brk'],
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.crypto,
    market: 'UPBIT',
    symbol: 'KRW-BTC',
    name: 'Bitcoin',
    sector: 'Crypto',
    aliases: ['btc', 'bitcoin'],
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.crypto,
    market: 'UPBIT',
    symbol: 'KRW-ETH',
    name: 'Ethereum',
    sector: 'Crypto',
    aliases: ['eth', 'ethereum'],
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.crypto,
    market: 'UPBIT',
    symbol: 'KRW-SOL',
    name: 'Solana',
    sector: 'Crypto',
    aliases: ['sol', 'solana'],
  ),
  _StockCatalogItem(
    assetClass: _AssetClass.crypto,
    market: 'UPBIT',
    symbol: 'KRW-XRP',
    name: 'XRP',
    sector: 'Crypto',
    aliases: ['xrp', 'ripple'],
  ),
];

const _defaultInstruments = [
  _Instrument(
    market: 'KOSPI',
    symbol: '005930',
    name: '삼성전자',
    sector: '반도체',
    price: 268500,
    changeRate: -1.10,
    open: 260000,
    high: 270000,
    low: 260000,
    tradeAmount: 6856898737478,
    chart: [260, 263, 265, 267, 270, 269, 268.5],
  ),
  _Instrument(
    market: 'KOSPI',
    symbol: '000660',
    name: 'SK하이닉스',
    sector: '반도체',
    price: 182600,
    changeRate: 2.18,
    open: 179000,
    high: 184200,
    low: 178400,
    tradeAmount: 512200000000,
    chart: [177, 179, 178.4, 180.2, 181.5, 182.1, 182.6],
  ),
  _Instrument(
    market: 'KOSDAQ',
    symbol: '247540',
    name: '에코프로비엠',
    sector: '2차전지',
    price: 198400,
    changeRate: -1.26,
    open: 201000,
    high: 203500,
    low: 197800,
    tradeAmount: 184600000000,
    chart: [202, 201.5, 200.2, 199.7, 198.1, 198.9, 198.4],
  ),
  _Instrument(
    market: 'KOSPI',
    symbol: '035420',
    name: 'NAVER',
    sector: '인터넷',
    price: 214500,
    changeRate: 0.42,
    open: 213000,
    high: 216000,
    low: 212500,
    tradeAmount: 92400000000,
    chart: [212, 213.5, 213, 214.2, 214.8, 214.1, 214.5],
  ),
  _Instrument(
    assetClass: _AssetClass.overseasStock,
    market: 'NASDAQ',
    symbol: 'AAPL',
    name: 'Apple',
    sector: 'Technology',
    price: 182.4,
    changeRate: 0.64,
    open: 181.2,
    high: 183.1,
    low: 180.8,
    tradeAmount: 5240000000,
    chart: [178, 179.5, 180.3, 181.1, 182.0, 181.7, 182.4],
  ),
  _Instrument(
    assetClass: _AssetClass.overseasStock,
    market: 'NASDAQ',
    symbol: 'NVDA',
    name: 'NVIDIA',
    sector: 'Semiconductor',
    price: 913.6,
    changeRate: 1.92,
    open: 898.0,
    high: 918.3,
    low: 892.4,
    tradeAmount: 18300000000,
    chart: [890, 895, 902, 908, 915, 910, 913.6],
  ),
  _Instrument(
    assetClass: _AssetClass.crypto,
    market: 'UPBIT',
    symbol: 'KRW-BTC',
    name: 'Bitcoin',
    sector: 'Crypto',
    price: 92840000,
    changeRate: 0.84,
    open: 92000000,
    high: 93400000,
    low: 91500000,
    tradeAmount: 284000000000,
    chart: [91500, 91820, 92100, 92500, 93000, 92750, 92840],
  ),
  _Instrument(
    assetClass: _AssetClass.crypto,
    market: 'UPBIT',
    symbol: 'KRW-ETH',
    name: 'Ethereum',
    sector: 'Crypto',
    price: 4380000,
    changeRate: -0.32,
    open: 4395000,
    high: 4430000,
    low: 4340000,
    tradeAmount: 76000000000,
    chart: [4400, 4390, 4410, 4385, 4370, 4388, 4380],
  ),
];

_Instrument _defaultInstrumentForAssetClass(_AssetClass assetClass) {
  return _defaultInstruments.firstWhere(
    (instrument) => instrument.assetClass == assetClass,
    orElse: () => _defaultInstruments.first,
  );
}

_Instrument _instrumentForHolding(
  List<_Instrument> instruments,
  KisHolding holding,
) {
  final assetClass = _assetClassFromApi(holding.assetClass);
  for (final instrument in instruments) {
    if (instrument.assetClass == assetClass &&
        instrument.symbol == holding.symbol) {
      return instrument.copyWith(
        price: holding.currentPrice > 0 ? holding.currentPrice : null,
        changeRate: holding.profitLossRate,
        hasLiveQuote: holding.currentPrice > 0 ? true : null,
      );
    }
  }

  final catalogItem = _stockCatalogItemBySymbol(
    holding.symbol,
    assetClass: assetClass,
  );
  final price = holding.currentPrice > 0
      ? holding.currentPrice
      : holding.quantity > 0
          ? holding.evaluationAmount / holding.quantity
          : 0.0;
  return _Instrument(
    assetClass: assetClass,
    market: holding.market.isNotEmpty
        ? holding.market
        : (catalogItem?.market ?? _defaultMarketForAssetClass(assetClass)),
    symbol: holding.symbol,
    name: holding.name.isNotEmpty
        ? holding.name
        : (catalogItem?.name ?? holding.symbol),
    sector: catalogItem?.sector ?? '보유종목',
    price: price,
    changeRate: holding.profitLossRate,
    open: price,
    high: price,
    low: price,
    tradeAmount: 0,
    chart: [if (price > 0) price / 1000 else 0],
    hasLiveQuote: price > 0,
  );
}

KisHolding _kisHoldingFromUpbit(UpbitHolding holding) {
  return KisHolding(
    symbol:
        holding.market.isNotEmpty ? holding.market : 'KRW-${holding.symbol}',
    name: holding.name.isNotEmpty ? holding.name : holding.symbol,
    quantity: holding.quantity,
    assetClass: 'crypto',
    market: 'UPBIT',
    currency: holding.currency.isNotEmpty ? holding.currency : 'KRW',
    orderableQuantity: holding.orderableQuantity,
    averagePrice: holding.averagePrice,
    currentPrice: holding.currentPrice,
    purchaseAmount: holding.purchaseAmount,
    evaluationAmount: holding.evaluationAmount,
    profitLoss: holding.profitLoss,
    profitLossRate: holding.profitLossRate,
  );
}

UpbitHolding? _upbitHoldingForInstrument(
  UpbitPortfolio? portfolio,
  _Instrument instrument,
) {
  if (portfolio == null) return null;
  for (final holding in portfolio.holdings) {
    if (holding.market.toUpperCase() == instrument.symbol.toUpperCase()) {
      return holding;
    }
  }
  return null;
}

String _won(num value) {
  return '${_comma(value.round())}원';
}

String _moneyByCurrency(num value, String currency) {
  final normalized = currency.trim().toUpperCase();
  if (normalized == 'USD') {
    return '\$${_groupedDecimal(value, decimalPlaces: 2)}';
  }
  if (normalized == 'JPY') {
    return '¥${_groupedDecimal(value, decimalPlaces: 0)}';
  }
  if (normalized == 'CNY') {
    return '¥${_groupedDecimal(value, decimalPlaces: 2)}';
  }
  if (normalized == 'HKD') {
    return 'HK\$${_groupedDecimal(value, decimalPlaces: 2)}';
  }
  return _won(value);
}

String _signedWon(num value) {
  if (value > 0) return '+${_won(value)}';
  if (value < 0) return '-${_won(value.abs())}';
  return _won(0);
}

String _signedPercent(num value) {
  final formatted = '${value.abs().toStringAsFixed(2)}%';
  if (value > 0) return '+$formatted';
  if (value < 0) return '-$formatted';
  return formatted;
}

String _marketValue(num? value) {
  if (value == null) return '--';
  return _groupedDecimal(value, decimalPlaces: 2);
}

String _marketChange(num? value) {
  if (value == null) return '--';
  return _signedPercent(value);
}

String _formatQuantity(num value, {int decimalPlaces = 8}) {
  if (value == value.roundToDouble()) return _comma(value.round());
  final fixed = value.toStringAsFixed(decimalPlaces);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

String _formatOrderTime(String? value) {
  final digits = value?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
  if (digits.length >= 6) {
    return '${digits.substring(0, 2)}:${digits.substring(2, 4)}:${digits.substring(4, 6)}';
  }
  return value?.trim().isNotEmpty == true ? value!.trim() : '--';
}

String _formatOrderDateTime(String? date, String? time) {
  final dateDigits = date?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
  final displayTime = _formatOrderTime(time);
  if (dateDigits.length >= 8) {
    return '${dateDigits.substring(4, 6)}.${dateDigits.substring(6, 8)} $displayTime';
  }
  return displayTime;
}

String _activityEmptyMessage(int days) {
  if (days == 0) return '저장된 체결 내역이 없습니다.';
  if (days <= 1) return '오늘 조회된 체결 내역이 없습니다.';
  return '최근 $days일 체결 내역이 없습니다.';
}

List<KisOrderActivityItem> _mergeExecutions(
  Iterable<KisOrderActivityItem> existing,
  Iterable<KisOrderActivityItem> incoming,
) {
  final byKey = <String, KisOrderActivityItem>{};
  for (final item in existing) {
    byKey[_executionCacheKey(item)] = item;
  }
  for (final item in incoming) {
    byKey[_executionCacheKey(item)] = item;
  }
  return _sortedExecutions(byKey.values);
}

List<KisOrderActivityItem> _sortedExecutions(
  Iterable<KisOrderActivityItem> items,
) {
  final sorted = List<KisOrderActivityItem>.of(items);
  sorted.sort((a, b) => _executionSortKey(b).compareTo(_executionSortKey(a)));
  return sorted;
}

String _executionSortKey(KisOrderActivityItem item) {
  final orderDate = item.orderDate ?? '';
  final orderTime = item.orderTime ?? '';
  final orderNo = item.orderNo ?? '';
  return '$orderDate$orderTime$orderNo${item.symbol}${item.filledQuantity}';
}

String _executionCacheKey(KisOrderActivityItem item) {
  final orderNo = item.orderNo?.trim() ?? '';
  if (orderNo.isNotEmpty) {
    return [
      item.broker,
      item.market,
      item.symbol,
      orderNo,
      item.orderDate ?? '',
      item.orderTime ?? '',
      item.filledQuantity.toString(),
    ].join('|');
  }
  return [
    item.broker,
    item.market,
    item.symbol,
    item.side,
    item.orderDate ?? '',
    item.orderTime ?? '',
    item.filledQuantity.toString(),
    item.averagePrice.toString(),
  ].join('|');
}

DateTime? _executionDate(KisOrderActivityItem item) {
  final digits = item.orderDate?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
  if (digits.length < 8) return null;
  final year = int.tryParse(digits.substring(0, 4));
  final month = int.tryParse(digits.substring(4, 6));
  final day = int.tryParse(digits.substring(6, 8));
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day);
}

String _orderNoSuffix(String? orderNo) {
  if (orderNo == null || orderNo.trim().isEmpty) return '';
  return ' · 주문번호 ${orderNo.trim()}';
}

bool _hasDisplayQuote(_Instrument instrument) {
  return instrument.price > 0;
}

bool _hasLiveQuote(_Instrument instrument) {
  return instrument.hasLiveQuote && instrument.price > 0;
}

bool _isDomesticExtendedSessionNow() {
  final now = _nowInKst();
  return _isKoreanWeekday(now) &&
      _minutesSinceMidnight(now) >= 8 * 60 &&
      _minutesSinceMidnight(now) <= 20 * 60;
}

DateTime _nowInKst() {
  return DateTime.now().toUtc().add(const Duration(hours: 9));
}

bool _isKoreanWeekday(DateTime value) {
  return value.weekday >= DateTime.monday && value.weekday <= DateTime.friday;
}

int _minutesSinceMidnight(DateTime value) {
  return value.hour * 60 + value.minute;
}

String _priceCurrencySuffix(_Instrument instrument) {
  return switch (instrument.assetClass) {
    _AssetClass.overseasStock => 'USD',
    _AssetClass.crypto => instrument.symbol.startsWith('USDT-')
        ? 'USDT'
        : instrument.symbol.startsWith('BTC-')
            ? 'BTC'
            : '원',
    _AssetClass.domesticStock => '원',
  };
}

String _cryptoBaseSymbol(String market) {
  final parts = market.split('-');
  return parts.length >= 2 ? parts[1] : market;
}

String _kisEnvironmentLabel(String? environment) {
  return switch (environment) {
    'live' => '실전투자',
    'paper' => '모의투자',
    _ => '투자',
  };
}

String _assetMoney(_Instrument instrument, num value) {
  if (instrument.assetClass == _AssetClass.overseasStock) {
    return '\$${_groupedDecimal(value, decimalPlaces: 2)}';
  }
  if (instrument.assetClass == _AssetClass.crypto &&
      !instrument.symbol.startsWith('KRW-')) {
    return '${_groupedDecimal(value, decimalPlaces: 4)} ${_priceCurrencySuffix(instrument)}';
  }
  return _won(value);
}

String _groupedDecimal(num value, {int decimalPlaces = 2}) {
  final negative = value < 0;
  final fixed = value.abs().toStringAsFixed(decimalPlaces);
  final parts = fixed.split('.');
  final whole = int.tryParse(parts.first) ?? 0;
  final decimal = parts.length > 1 ? '.${parts[1]}' : '';
  return '${negative ? '-' : ''}${_comma(whole)}$decimal';
}

String _priceLabel(_Instrument instrument) {
  return _hasDisplayQuote(instrument)
      ? _assetMoney(instrument, instrument.price)
      : '조회 대기';
}

String _quoteMetric(_Instrument instrument, num value) {
  return _hasDisplayQuote(instrument) && value > 0
      ? _assetMoney(instrument, value)
      : '--';
}

String _comma(num value) {
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

String _compact(num value) {
  if (value >= 1000000000000) {
    return '${(value / 1000000000000).toStringAsFixed(1)}조';
  }
  if (value >= 100000000) {
    return '${(value / 100000000).toStringAsFixed(0)}억';
  }
  return _comma(value.round());
}
