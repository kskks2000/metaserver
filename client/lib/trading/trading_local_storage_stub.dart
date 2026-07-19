import 'dart:async';

import 'package:flutter/services.dart';

const _channel = MethodChannel('metaserver/trading_local_storage');
final Map<String, String> _cachedValues = {};

Future<void> initializeTradingLocalStorage() async {
  try {
    final values = await _channel.invokeMapMethod<String, String>('loadAll');
    _cachedValues
      ..clear()
      ..addAll(values ?? const {});
  } on MissingPluginException {
    // Non-Android platforms without a native handler keep an in-memory fallback.
  }
}

String? loadTradingLocalValue(String key) {
  return _cachedValues[key];
}

void saveTradingLocalValue(String key, String value) {
  _cachedValues[key] = value;
  unawaited(
    _channel.invokeMethod<void>(
        'save', {'key': key, 'value': value}).catchError((_) {}),
  );
}
