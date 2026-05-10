import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:metaserver_client/core/api_client.dart';
import 'package:metaserver_client/firebase_options.dart';

void main() {
  test('uses the metaserver Firebase project', () {
    expect(DefaultFirebaseOptions.android.projectId, 'metaserver-6dc49');
    expect(DefaultFirebaseOptions.android.appId, startsWith('1:422872519301:'));
    expect(DefaultFirebaseOptions.web.projectId, 'metaserver-6dc49');
  });

  test('uses the host loopback address for Android emulators by default', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    expect(defaultApiBaseUrl, 'http://10.0.2.2:8000/api/v1');
  });

  test('uses the production API for installed Android release builds', () {
    expect(
      platformDefaultApiBaseUrl(
        isWeb: false,
        targetPlatform: TargetPlatform.android,
        debugMode: false,
        webHost: '',
      ),
      productionApiBaseUrl,
    );
  });
}
