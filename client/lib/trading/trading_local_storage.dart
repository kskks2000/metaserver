import 'trading_local_storage_stub.dart'
    if (dart.library.html) 'trading_local_storage_web.dart' as storage;

String? loadTradingLocalValue(String key) => storage.loadTradingLocalValue(key);

void saveTradingLocalValue(String key, String value) {
  storage.saveTradingLocalValue(key, value);
}
