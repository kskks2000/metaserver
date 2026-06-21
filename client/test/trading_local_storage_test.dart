import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import 'package:metaserver_client/trading/trading_local_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('metaserver/trading_local_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, String> values;

  setUp(() {
    values = {};
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'loadAll':
          return values;
        case 'save':
          final arguments = Map<String, Object?>.from(call.arguments as Map);
          values[arguments['key']! as String] = arguments['value']! as String;
          return null;
        default:
          throw MissingPluginException();
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('loads existing mobile trading storage values', () async {
    values['metaserver.trading.watchlist.groups.v1'] = '[{"id":"crypto"}]';

    await initializeTradingLocalStorage();

    expect(
      loadTradingLocalValue('metaserver.trading.watchlist.groups.v1'),
      '[{"id":"crypto"}]',
    );
  });

  test('saves mobile trading storage values for immediate restore', () async {
    await initializeTradingLocalStorage();

    saveTradingLocalValue('metaserver.trading.watchlist.groups.v1', 'xrp');

    expect(
      loadTradingLocalValue('metaserver.trading.watchlist.groups.v1'),
      'xrp',
    );
  });

  test('writes mobile trading storage values through native channel', () async {
    await initializeTradingLocalStorage();

    saveTradingLocalValue('metaserver.trading.watchlist.groups.v1', 'xrp');
    await Future<void>.delayed(Duration.zero);

    expect(values['metaserver.trading.watchlist.groups.v1'], 'xrp');
  });
}
