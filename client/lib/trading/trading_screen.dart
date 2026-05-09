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

const _watchlistStorageKey = 'metaserver.trading.watchlist.custom.v1';
const _watchlistGroupsStorageKey = 'metaserver.trading.watchlist.groups.v1';
const _defaultWatchlistGroupId = 'default';

class TradingScreen extends ConsumerStatefulWidget {
  const TradingScreen({super.key});

  @override
  ConsumerState<TradingScreen> createState() => _TradingScreenState();
}

class _TradingScreenState extends ConsumerState<TradingScreen> {
  int _tabIndex = 0;
  _TradeSide _tradeSide = _TradeSide.buy;
  late List<_WatchlistGroup> _watchlistGroups;
  late String _selectedGroupId;
  late List<_Instrument> _instruments;
  late _Instrument _selectedInstrument;
  late Future<KisPortfolio> _portfolioFuture;
  KisPortfolio? _cachedPortfolio;
  late Future<KisConnectionStatus> _kisStatusFuture;
  KisConnectionStatus? _cachedKisStatus;
  bool _quoteLoading = false;

  @override
  void initState() {
    super.initState();
    _watchlistGroups = _restoreWatchlistGroups();
    _selectedGroupId = _watchlistGroups.first.id;
    _instruments = List<_Instrument>.of(_watchlistGroups.first.instruments);
    _selectedInstrument = _instruments.first;
    _portfolioFuture = _loadPortfolio();
    _kisStatusFuture = _loadKisStatus();
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
                _WatchlistGroup.fromJson(Map<String, Object?>.from(item)),
          ].whereType<_WatchlistGroup>().toList();
          if (groups.isNotEmpty) return groups;
        }
      } catch (_) {
        // Fall through to the legacy watchlist migration path.
      }
    }

    return [
      _WatchlistGroup(
        id: _defaultWatchlistGroupId,
        name: '기본',
        instruments: _restoreLegacyWatchlistInstruments(),
      ),
    ];
  }

  List<_Instrument> _restoreLegacyWatchlistInstruments() {
    final instruments = List<_Instrument>.of(_defaultInstruments);
    final saved = loadTradingLocalValue(_watchlistStorageKey);
    if (saved == null || saved.trim().isEmpty) return instruments;

    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List) return instruments;
      final defaultSymbols =
          _defaultInstruments.map((instrument) => instrument.symbol).toSet();
      for (final item in decoded) {
        if (item is! Map) continue;
        final instrument = _Instrument.fromJson(
          Map<String, Object?>.from(item),
        );
        if (instrument == null) continue;
        final alreadyListed = instruments.any(
          (current) => current.symbol == instrument.symbol,
        );
        if (!alreadyListed && !defaultSymbols.contains(instrument.symbol)) {
          instruments.add(instrument);
        }
      }
    } catch (_) {
      // Ignore malformed local watchlist data and keep the built-in list.
    }
    return instruments;
  }

  _WatchlistGroup get _selectedGroup {
    return _watchlistGroups.firstWhere(
      (group) => group.id == _selectedGroupId,
      orElse: () => _watchlistGroups.first,
    );
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
          group.copyWith(instruments: List<_Instrument>.of(instruments))
        else
          group,
    ];
  }

  void _selectWatchlistGroup(String groupId) {
    final group = _watchlistGroups.firstWhere(
      (item) => item.id == groupId,
      orElse: () => _selectedGroup,
    );
    setState(() {
      _selectedGroupId = group.id;
      _instruments = List<_Instrument>.of(group.instruments);
      if (!_instruments.any(
        (instrument) => instrument.symbol == _selectedInstrument.symbol,
      )) {
        _selectedInstrument = _instruments.first;
      }
    });
    Future.microtask(() => _refreshWatchlistQuotes(showMessage: false));
  }

  void _openOrder(_Instrument instrument, _TradeSide side) {
    setState(() {
      _selectedInstrument = instrument;
      _tradeSide = side;
      _tabIndex = 2;
    });
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

  Future<KisConnectionStatus> _loadKisStatus() async {
    final status = await ref.read(tradingRepositoryProvider).loadKisStatus();
    if (mounted) {
      setState(() {
        _cachedKisStatus = status;
      });
    }
    return status;
  }

  Future<void> _refreshTradingData() async {
    setState(() {
      _portfolioFuture = _loadPortfolio();
      _kisStatusFuture = _loadKisStatus();
    });
    await _refreshWatchlistQuotes();
  }

  Future<void> _refreshSelectedQuote({bool showMessage = true}) async {
    if (_quoteLoading) return;
    setState(() => _quoteLoading = true);
    try {
      final quote = await ref
          .read(tradingRepositoryProvider)
          .loadQuote(_selectedInstrument.symbol);
      if (!mounted) return;
      final updated = _mergeQuote(_selectedInstrument, quote);
      setState(() {
        _selectedInstrument = updated;
        _replaceSelectedGroupInstruments([
          for (final instrument in _instruments)
            if (instrument.symbol == updated.symbol) updated else instrument,
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
      final message = isRecoverableApiFailure(error)
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
    final instrumentsSnapshot = List<_Instrument>.of(_instruments);
    final refreshedInstruments = List<_Instrument>.of(instrumentsSnapshot);
    var refreshedSelectedInstrument = _selectedInstrument;
    try {
      final repository = ref.read(tradingRepositoryProvider);
      for (var index = 0; index < instrumentsSnapshot.length; index++) {
        final instrument = instrumentsSnapshot[index];
        try {
          final quote = await repository.loadQuote(instrument.symbol);
          if (!mounted) return;
          final updated = _mergeQuote(instrument, quote);
          refreshedCount += 1;
          refreshedInstruments[index] = updated;
          if (refreshedSelectedInstrument.symbol == updated.symbol) {
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
      final message = isRecoverableApiFailure(error)
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
        existingSymbols: _instruments.map((item) => item.symbol).toSet(),
      ),
    );
    if (draft == null || !mounted) return;

    setState(() => _quoteLoading = true);
    DomesticStockQuote? quote;
    try {
      quote = await ref.read(tradingRepositoryProvider).loadQuote(draft.symbol);
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
                  (group) => group.name.toLowerCase() == value.toLowerCase(),
                );
                if (duplicated) {
                  setDialogState(() => validationError = '이미 있는 그룹명입니다.');
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
        name: groupName,
        instruments: [_selectedInstrument],
      );
      setState(() {
        _watchlistGroups = [..._watchlistGroups, newGroup];
        _selectedGroupId = newGroup.id;
        _instruments = List<_Instrument>.of(newGroup.instruments);
      });
      _saveWatchlistGroups();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$groupName 그룹을 만들고 현재 종목을 담았습니다.')),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _deleteSelectedGroup() async {
    if (_watchlistGroups.length <= 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('마지막 그룹은 삭제할 수 없습니다.')));
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
    final nextGroup = remaining.first;
    setState(() {
      _watchlistGroups = remaining;
      _selectedGroupId = nextGroup.id;
      _instruments = List<_Instrument>.of(nextGroup.instruments);
      _selectedInstrument = _instruments.first;
    });
    _saveWatchlistGroups();
  }

  void _removeInstrumentFromSelectedGroup(_Instrument instrument) {
    if (_instruments.length <= 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('그룹에는 최소 1개 종목이 필요합니다.')));
      return;
    }
    final nextInstruments = [
      for (final item in _instruments)
        if (item.symbol != instrument.symbol) item,
    ];
    setState(() {
      _replaceSelectedGroupInstruments(nextInstruments);
      if (_selectedInstrument.symbol == instrument.symbol) {
        _selectedInstrument = nextInstruments.first;
      }
    });
    _saveWatchlistGroups();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${instrument.name} 종목을 그룹에서 삭제했습니다.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      _TradingHomeTab(
        instruments: _instruments,
        portfolioFuture: _portfolioFuture,
        cachedPortfolio: _cachedPortfolio,
        onOrder: _openOrder,
      ),
      _MarketTab(
        groups: _watchlistGroups,
        selectedGroupId: _selectedGroupId,
        instruments: _instruments,
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
  final catalogItem = _stockCatalogItemBySymbol(draft.symbol);
  return _Instrument(
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
    required this.market,
    required this.symbol,
    required this.name,
    required this.sector,
  });

  final String market;
  final String symbol;
  final String name;
  final String sector;
}

String _normalizeStockSymbol(String value) {
  return value.replaceAll(RegExp(r'[^0-9]'), '');
}

class _AddInstrumentDialog extends ConsumerStatefulWidget {
  const _AddInstrumentDialog({required this.existingSymbols});

  final Set<String> existingSymbols;

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
  var _market = 'KOSPI';
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
      final results = await ref
          .read(tradingRepositoryProvider)
          .searchDomesticStocks(query, limit: 60);
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
        _searchError = 'KOSPI/KOSDAQ 전체 검색을 불러오지 못했습니다.';
      });
    }
  }

  List<DomesticStockSearchResult> _localCatalogResults(String query) {
    final normalizedQuery = query.trim().toLowerCase();
    final items = normalizedQuery.isEmpty
        ? _popularStockCatalogItems
        : _stockCatalog.where((item) => item.matches(normalizedQuery)).toList();
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
    final searchSymbol = _normalizeStockSymbol(_searchController.text);
    final exactSearchMatch = _searchResults.where(
      (item) => item.symbol == searchSymbol,
    );
    if (_symbolController.text.trim().isEmpty && searchSymbol.length == 6) {
      _symbolController.text = searchSymbol;
      if (exactSearchMatch.isNotEmpty) {
        final item = exactSearchMatch.first;
        _market = item.market;
        _nameController.text = item.name;
        _sectorController.text = item.sector;
      }
    }

    final symbol = _normalizeStockSymbol(_symbolController.text);
    if (symbol.length != 6) {
      setState(() => _validationError = '국내주식 종목코드 6자리를 입력해 주세요.');
      return;
    }
    if (widget.existingSymbols.contains(symbol)) {
      setState(() => _validationError = '이미 관심종목에 추가된 종목입니다.');
      return;
    }

    final searchItem = _selectedItem?.symbol == symbol ? _selectedItem : null;
    final catalogItem = _stockCatalogItemBySymbol(symbol);
    Navigator.of(context).pop(
      _InstrumentDraft(
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
                          'KOSPI/KOSDAQ 전체에서 종목명 또는 코드로 선택',
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
                  hintText: '예: 하이닉스, 삼성전자, 005930',
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
                  for (final item in _popularStockCatalogItems.take(6))
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
                      items: _searchResults,
                      selectedSymbol: _selectedItem?.symbol,
                      existingSymbols: widget.existingSymbols,
                      searching: _searching,
                      errorMessage: _searchError,
                      onSelected: _selectItem,
                    );
                    final form = _ManualInstrumentForm(
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
    required this.items,
    required this.selectedSymbol,
    required this.existingSymbols,
    required this.searching,
    required this.errorMessage,
    required this.onSelected,
  });

  final List<DomesticStockSearchResult> items;
  final String? selectedSymbol;
  final Set<String> existingSymbols;
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
                    ? 'KOSPI/KOSDAQ 전체 종목 검색 중입니다.'
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
              item: item,
              selected: item.symbol == selectedSymbol,
              alreadyAdded: existingSymbols.contains(item.symbol),
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
    required this.item,
    required this.selected,
    required this.alreadyAdded,
    required this.onTap,
  });

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
          subtitle: Text('${item.market} · ${item.symbol} · ${item.sector}'),
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
    required this.market,
    required this.symbolController,
    required this.nameController,
    required this.sectorController,
    required this.validationError,
    required this.onMarketChanged,
    required this.onChanged,
  });

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
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '종목코드',
              hintText: '005930',
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
            items: const [
              DropdownMenuItem(value: 'KOSPI', child: Text('KOSPI')),
              DropdownMenuItem(value: 'KOSDAQ', child: Text('KOSDAQ')),
              DropdownMenuItem(value: 'ETF', child: Text('ETF')),
              DropdownMenuItem(value: 'ETN', child: Text('ETN')),
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
    required this.onOrder,
  });

  final List<_Instrument> instruments;
  final Future<KisPortfolio> portfolioFuture;
  final KisPortfolio? cachedPortfolio;
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
              LayoutBuilder(
                builder: (context, constraints) {
                  final holdingsPanel = _HoldingsPanel(
                    portfolio: portfolio,
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
                        const Expanded(flex: 4, child: _RiskAndMarketPanel()),
                      ],
                    );
                  }

                  return Column(
                    children: [
                      holdingsPanel,
                      const SizedBox(height: 16),
                      const _RiskAndMarketPanel(),
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
    required this.onSideChanged,
  });

  final _Instrument instrument;
  final _TradeSide initialSide;
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

  @override
  void initState() {
    super.initState();
    _side = widget.initialSide;
    _quantityController = TextEditingController(text: '1');
    _priceController = TextEditingController(
      text: _orderPriceText(widget.instrument),
    );
  }

  @override
  void didUpdateWidget(covariant _OrderTicketTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextPriceText = _orderPriceText(widget.instrument);
    final previousPriceText = removeNumberGrouping(
      _orderPriceText(oldWidget.instrument),
    );
    final currentPriceText = removeNumberGrouping(_priceController.text);
    if (oldWidget.instrument.symbol != widget.instrument.symbol) {
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
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final quantity =
        int.tryParse(removeNumberGrouping(_quantityController.text)) ?? 0;
    final livePrice = _hasLiveQuote(widget.instrument);
    final price = _marketOrder
        ? (livePrice ? widget.instrument.price : 0.0)
        : double.tryParse(removeNumberGrouping(_priceController.text)) ?? 0;
    final estimated = quantity * price;
    final validationMessage = _orderValidationMessage(
      quantity: quantity,
      price: price,
      livePrice: livePrice,
    );
    final canSubmit = validationMessage == null && !_submitting;
    final sideColor = _side == _TradeSide.buy
        ? MetaServerColors.green
        : MetaServerColors.danger;

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
                    foregroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return Colors.white;
                      }
                      return MetaServerColors.ink;
                    }),
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      if (!states.contains(WidgetState.selected)) {
                        return Colors.white;
                      }
                      return _side == _TradeSide.buy
                          ? MetaServerColors.green
                          : MetaServerColors.danger;
                    }),
                  ),
                ),
                const SizedBox(height: 14),
                _FieldLabel(
                  label: '계좌',
                  child: _SelectLikeBox(
                    icon: Icons.account_balance_wallet_outlined,
                    title: 'KIS 실전투자 계좌',
                    subtitle: '주문가능 ${_won(4382000)}',
                  ),
                ),
                const SizedBox(height: 12),
                _OrderTypeSwitch(
                  marketOrder: _marketOrder,
                  onChanged: (value) => setState(() => _marketOrder = value),
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
                        suffix: '원',
                        enabled: !_marketOrder,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _EstimateBox(
                  rows: [
                    _Metric('예상 주문금액', _won(estimated)),
                    _Metric('수수료/세금', _won(estimated * 0.0015)),
                    _Metric('주문 후 예수금', _won(4382000 - estimated)),
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
                        : (_side == _TradeSide.buy ? '매수 주문 확인' : '매도 주문 확인'),
                  ),
                  style: ElevatedButton.styleFrom(backgroundColor: sideColor),
                ),
              ],
            ),
          );

          final guide = _Panel(
            title: '주문 전 점검',
            icon: Icons.verified_user_outlined,
            child: Column(
              children: [
                _CheckRow(label: '실시간 시세 기준 가격 확인', checked: livePrice),
                const _CheckRow(label: '계좌 연결 및 토큰 유효성 확인', checked: true),
                const _CheckRow(label: '일 주문 한도와 손실 한도 확인', checked: true),
                const _CheckRow(label: '실거래 전 투자위험 고지 동의 필요', checked: false),
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

          return Column(children: [ticket, const SizedBox(height: 16), guide]);
        },
      ),
    );
  }

  void _showOrderReview(BuildContext context, num estimated) {
    final sideText = _side == _TradeSide.buy ? '매수' : '매도';
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$sideText 주문 확인',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 14),
              _ReviewRow(
                label: '종목',
                value: '${widget.instrument.name} ${widget.instrument.symbol}',
              ),
              _ReviewRow(label: '구분', value: sideText),
              _ReviewRow(label: '주문금액', value: _won(estimated)),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _submitOrder();
                },
                icon: const Icon(Icons.lock_outline_rounded),
                label: const Text('KIS로 주문 전송'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _submitOrder() async {
    final quantity =
        int.tryParse(removeNumberGrouping(_quantityController.text)) ?? 0;
    final limitPrice = _marketOrder
        ? null
        : int.tryParse(removeNumberGrouping(_priceController.text));
    final orderPrice =
        _marketOrder ? widget.instrument.price : (limitPrice ?? 0).toDouble();
    final validationMessage = _orderValidationMessage(
      quantity: quantity,
      price: orderPrice,
      livePrice: _hasLiveQuote(widget.instrument),
    );
    if (validationMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(validationMessage)));
      return;
    }
    setState(() => _submitting = true);
    try {
      final result = await ref.read(tradingRepositoryProvider).placeOrder(
            DomesticStockOrderDraft(
              side: _side == _TradeSide.buy ? 'buy' : 'sell',
              symbol: widget.instrument.symbol,
              quantity: quantity,
              orderKind: _marketOrder ? 'market' : 'limit',
              price: limitPrice,
            ),
          );
      if (!mounted) return;
      final orderNo = result.brokerOrderNo ?? result.trId;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('KIS 주문이 접수되었습니다. 주문번호: $orderNo')),
      );
    } catch (error) {
      if (!mounted) return;
      final detail = apiFailureMessage(error);
      final message = detail != null
          ? 'KIS 주문 전송 실패: $detail'
          : isRecoverableApiFailure(error)
              ? 'KIS 주문 전송에 실패했습니다. 키, 계좌, 실전주문 허용 설정을 확인해 주세요.'
              : error.toString();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _orderPriceText(_Instrument instrument) {
    return _hasDisplayQuote(instrument)
        ? formatIntegerInputText(instrument.price.toStringAsFixed(0))
        : '';
  }

  void _setPriceText(String value) {
    _priceController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  String? _orderValidationMessage({
    required int quantity,
    required double price,
    required bool livePrice,
  }) {
    if (quantity <= 0) return '수량을 1주 이상 입력해 주세요.';
    if (_marketOrder) {
      return livePrice ? null : '시장가 주문은 현재가 조회 후 전송할 수 있습니다.';
    }
    if (price <= 0) return '지정가를 입력해 주세요.';
    if (!livePrice) return '현재가 조회 후 주문 가격을 다시 확인해 주세요.';

    final referencePrice = widget.instrument.price;
    final lowerLimit = referencePrice * 0.7;
    final upperLimit = referencePrice * 1.3;
    if (price < lowerLimit || price > upperLimit) {
      return '지정가가 현재가 기준 허용 범위를 벗어났습니다. 현재가 ${_won(referencePrice)} 근처 가격으로 다시 확인해 주세요.';
    }
    return null;
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

class _ActivityTab extends StatelessWidget {
  const _ActivityTab();

  @override
  Widget build(BuildContext context) {
    return _ScreenScroll(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final openOrders = _Panel(
            title: '미체결 주문',
            icon: Icons.pending_actions_outlined,
            child: Column(
              children: [
                for (final order in _openOrders) _OrderTile(order: order),
              ],
            ),
          );
          final executions = _Panel(
            title: '체결 내역',
            icon: Icons.fact_check_outlined,
            child: Column(
              children: [
                for (final execution in _executions)
                  _ExecutionTile(execution: execution),
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
                      label: '시간외 주문',
                      value: '꺼짐',
                      enabled: false,
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
            runSpacing: 12,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    accountLabel.isEmpty
                        ? 'KIS 실전투자 계좌'
                        : 'KIS 실전투자 계좌 $accountLabel',
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
              const _EnvironmentBadge(),
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

class _HoldingsPanel extends StatelessWidget {
  const _HoldingsPanel({
    required this.portfolio,
    required this.loading,
    required this.errorMessage,
    required this.instruments,
    required this.onOrder,
  });

  final KisPortfolio? portfolio;
  final bool loading;
  final String? errorMessage;
  final List<_Instrument> instruments;
  final void Function(_Instrument instrument, _TradeSide side) onOrder;

  @override
  Widget build(BuildContext context) {
    final holdings = portfolio?.holdings ?? const <KisHolding>[];
    return _Panel(
      title: '보유 종목',
      icon: Icons.pie_chart_outline_rounded,
      child: Column(
        children: [
          if (loading)
            const _PanelStateMessage(
              icon: Icons.sync_rounded,
              message: 'KIS 계좌 보유종목을 조회 중입니다.',
            )
          else if (errorMessage != null)
            _PanelStateMessage(
              icon: Icons.error_outline_rounded,
              message: errorMessage!,
              danger: true,
            )
          else if (holdings.isEmpty)
            const _PanelStateMessage(
              icon: Icons.inventory_2_outlined,
              message: '현재 계좌에 보유 중인 국내주식이 없습니다.',
            )
          else
            for (final holding in holdings)
              _HoldingTile(
                holding: holding,
                instrument: _instrumentForHolding(instruments, holding),
                onOrder: onOrder,
              ),
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
  const _RiskAndMarketPanel();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        _Panel(
          title: '시장 상태',
          icon: Icons.timeline_rounded,
          child: Column(
            children: [
              _MarketStatusRow(
                label: 'KOSPI',
                value: '2,742.18',
                change: '+0.84%',
              ),
              _MarketStatusRow(
                label: 'KOSDAQ',
                value: '873.42',
                change: '-0.18%',
              ),
              _MarketStatusRow(
                label: 'USD/KRW',
                value: '1,362.50',
                change: '+0.11%',
              ),
            ],
          ),
        ),
        SizedBox(height: 16),
        _Panel(
          title: '리스크 가드',
          icon: Icons.security_rounded,
          child: Column(
            children: [
              _CheckRow(label: '실전투자 모드', checked: true),
              _CheckRow(label: '실전주문 허용', checked: true),
              _CheckRow(label: '일 손실 한도 설정', checked: true),
            ],
          ),
        ),
      ],
    );
  }
}

class _WatchlistPanel extends StatelessWidget {
  const _WatchlistPanel({
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
          _WatchlistGroupBar(
            groups: groups,
            selectedGroupId: selectedGroupId,
            onSelected: onGroupSelected,
          ),
          const SizedBox(height: 14),
          for (final instrument in instruments)
            _InstrumentTile(
              instrument: instrument,
              selected: instrument.symbol == selectedInstrument.symbol,
              onTap: () => onSelected(instrument),
              onOrder: onOrder,
              onRemove: () => onRemoveInstrument(instrument),
            ),
        ],
      ),
    );
  }
}

class _WatchlistGroupBar extends StatelessWidget {
  const _WatchlistGroupBar({
    required this.groups,
    required this.selectedGroupId,
    required this.onSelected,
  });

  final List<_WatchlistGroup> groups;
  final String selectedGroupId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: groups.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final group = groups[index];
          final selected = group.id == selectedGroupId;
          return ChoiceChip(
            selected: selected,
            onSelected: (_) => onSelected(group.id),
            avatar: Icon(
              selected ? Icons.folder_rounded : Icons.folder_outlined,
              size: 18,
            ),
            label: Text('${group.name} ${group.instruments.length}'),
            labelStyle: TextStyle(
              color: selected ? Colors.white : MetaServerColors.ink,
              fontWeight: FontWeight.w900,
            ),
            selectedColor: MetaServerColors.green,
            backgroundColor: MetaServerColors.canvas,
            side: BorderSide(
              color: selected ? MetaServerColors.green : MetaServerColors.line,
            ),
          );
        },
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
                    backgroundColor: MetaServerColors.green,
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
                    foregroundColor: MetaServerColors.danger,
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
  const _EnvironmentBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: MetaServerColors.mint.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: MetaServerColors.mint.withValues(alpha: 0.24),
        ),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.science_outlined, size: 18, color: MetaServerColors.mint),
          SizedBox(width: 7),
          Text(
            '실전투자',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
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
            ? MetaServerColors.mint
            : const Color(0xFFFF8A8A);
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
    return _DataTile(
      leading: _IconBadge(
        icon: Icons.business_center_outlined,
        color: MetaServerColors.green,
      ),
      title: holding.name,
      subtitle:
          '${holding.symbol} · $quantity주 · 평균 ${_won(holding.averagePrice)}',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _won(evaluationAmount),
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
        ),
        _MiniAction(
          label: '매도',
          icon: Icons.remove,
          onTap: () => onOrder(instrument, _TradeSide.sell),
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
                ? MetaServerColors.green
                : MetaServerColors.danger,
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
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

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
                    ? MetaServerColors.mint
                    : const Color(0xFFFF8A8A),
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
        color: positive ? MetaServerColors.green : MetaServerColors.danger,
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
  const _OrderTile({required this.order});

  final _Order order;

  @override
  Widget build(BuildContext context) {
    return _DataTile(
      leading: _IconBadge(
        icon: order.side == _TradeSide.buy
            ? Icons.add_chart_rounded
            : Icons.sell_outlined,
        color: order.side == _TradeSide.buy
            ? MetaServerColors.green
            : MetaServerColors.danger,
      ),
      title: order.name,
      subtitle:
          '${order.symbol} · ${order.side == _TradeSide.buy ? '매수' : '매도'} · ${order.status}',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${order.filled}/${order.quantity}주',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            _won(order.price),
            style: TextStyle(
              color: MetaServerColors.ink.withValues(alpha: 0.62),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      actions: [
        _MiniAction(label: '정정', icon: Icons.edit_outlined, onTap: () {}),
        _MiniAction(label: '취소', icon: Icons.close_rounded, onTap: () {}),
      ],
    );
  }
}

class _ExecutionTile extends StatelessWidget {
  const _ExecutionTile({required this.execution});

  final _Execution execution;

  @override
  Widget build(BuildContext context) {
    return _DataTile(
      leading: _IconBadge(
        icon: Icons.done_all_rounded,
        color: execution.side == _TradeSide.buy
            ? MetaServerColors.green
            : MetaServerColors.danger,
      ),
      title: execution.name,
      subtitle:
          '${execution.symbol} · ${execution.side == _TradeSide.buy ? '매수' : '매도'} · ${execution.time}',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${execution.quantity}주',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            _won(execution.price),
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
        ? (onDark ? MetaServerColors.mint : MetaServerColors.green)
        : (onDark ? const Color(0xFFFF8A8A) : MetaServerColors.danger);
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
      valueColor: positive ? MetaServerColors.green : MetaServerColors.danger,
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
  });

  final String label;
  final TextEditingController controller;
  final String suffix;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      keyboardType: const TextInputType.numberWithOptions(decimal: false),
      inputFormatters: const [ThousandsSeparatorInputFormatter()],
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
            ? 'KIS 실전투자 계좌 연결 완료'
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
    required this.name,
    required this.instruments,
  });

  final String id;
  final String name;
  final List<_Instrument> instruments;

  static _WatchlistGroup? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final rawInstruments = json['instruments'];
    if (id is! String ||
        id.trim().isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        rawInstruments is! List) {
      return null;
    }
    final instruments = [
      for (final item in rawInstruments)
        if (item is Map) _Instrument.fromJson(Map<String, Object?>.from(item)),
    ].whereType<_Instrument>().toList();
    if (instruments.isEmpty) return null;
    return _WatchlistGroup(id: id, name: name, instruments: instruments);
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'instruments':
          instruments.map((instrument) => instrument.toJson()).toList(),
    };
  }

  _WatchlistGroup copyWith({String? name, List<_Instrument>? instruments}) {
    return _WatchlistGroup(
      id: id,
      name: name ?? this.name,
      instruments: instruments ?? this.instruments,
    );
  }
}

class _Instrument {
  const _Instrument({
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

  static _Instrument? fromJson(Map<String, Object?> json) {
    final market = json['market'];
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

class _Order {
  const _Order({
    required this.symbol,
    required this.name,
    required this.side,
    required this.quantity,
    required this.filled,
    required this.price,
    required this.status,
  });

  final String symbol;
  final String name;
  final _TradeSide side;
  final int quantity;
  final int filled;
  final double price;
  final String status;
}

class _Execution {
  const _Execution({
    required this.symbol,
    required this.name,
    required this.side,
    required this.quantity,
    required this.price,
    required this.time,
  });

  final String symbol;
  final String name;
  final _TradeSide side;
  final int quantity;
  final double price;
  final String time;
}

class _StockCatalogItem {
  const _StockCatalogItem({
    required this.market,
    required this.symbol,
    required this.name,
    required this.sector,
    this.aliases = const [],
  });

  final String market;
  final String symbol;
  final String name;
  final String sector;
  final List<String> aliases;

  bool matches(String query) {
    final normalizedSymbol = _normalizeStockSymbol(query);
    if (normalizedSymbol.isNotEmpty && symbol.contains(normalizedSymbol)) {
      return true;
    }
    final words = [name, symbol, market, sector, ...aliases];
    return words.any((word) => word.toLowerCase().contains(query));
  }
}

_StockCatalogItem? _stockCatalogItemBySymbol(String symbol) {
  for (final item in _stockCatalog) {
    if (item.symbol == symbol) return item;
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

final _popularStockCatalogItems = [
  for (final symbol in _popularStockSymbols)
    if (_stockCatalogItemBySymbol(symbol) != null)
      _stockCatalogItemBySymbol(symbol)!,
];

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
];

const _openOrders = [
  _Order(
    symbol: '005930',
    name: '삼성전자',
    side: _TradeSide.buy,
    quantity: 10,
    filled: 4,
    price: 74100,
    status: '부분체결',
  ),
  _Order(
    symbol: '247540',
    name: '에코프로비엠',
    side: _TradeSide.sell,
    quantity: 3,
    filled: 0,
    price: 201000,
    status: '접수',
  ),
];

const _executions = [
  _Execution(
    symbol: '000660',
    name: 'SK하이닉스',
    side: _TradeSide.buy,
    quantity: 2,
    price: 181800,
    time: '09:34:18',
  ),
  _Execution(
    symbol: '005930',
    name: '삼성전자',
    side: _TradeSide.buy,
    quantity: 4,
    price: 74100,
    time: '09:41:02',
  ),
  _Execution(
    symbol: '035420',
    name: 'NAVER',
    side: _TradeSide.sell,
    quantity: 1,
    price: 215000,
    time: '10:12:44',
  ),
];

_Instrument _instrumentForHolding(
  List<_Instrument> instruments,
  KisHolding holding,
) {
  for (final instrument in instruments) {
    if (instrument.symbol == holding.symbol) {
      return instrument.copyWith(
        price: holding.currentPrice > 0 ? holding.currentPrice : null,
        changeRate: holding.profitLossRate,
        hasLiveQuote: holding.currentPrice > 0 ? true : null,
      );
    }
  }

  final catalogItem = _stockCatalogItemBySymbol(holding.symbol);
  final price = holding.currentPrice > 0
      ? holding.currentPrice
      : holding.quantity > 0
          ? holding.evaluationAmount / holding.quantity
          : 0.0;
  return _Instrument(
    market: catalogItem?.market ?? 'KOSPI',
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

String _won(num value) {
  return '${_comma(value.round())}원';
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

String _formatQuantity(num value) {
  if (value == value.roundToDouble()) return _comma(value.round());
  return value.toStringAsFixed(2);
}

bool _hasDisplayQuote(_Instrument instrument) {
  return instrument.price > 0;
}

bool _hasLiveQuote(_Instrument instrument) {
  return instrument.hasLiveQuote && instrument.price > 0;
}

String _priceLabel(_Instrument instrument) {
  return _hasDisplayQuote(instrument) ? _won(instrument.price) : '조회 대기';
}

String _quoteMetric(_Instrument instrument, num value) {
  return _hasDisplayQuote(instrument) && value > 0 ? _won(value) : '--';
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
