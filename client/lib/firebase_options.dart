import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for this platform. '
          'Run `flutterfire configure --platforms=ios,macos` to add it.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCe1ePhQ2gO6G5SNQMJTR4914DTHmz-x4Y',
    appId: '1:422872519301:web:ef1bdc141a758727818fec',
    messagingSenderId: '422872519301',
    projectId: 'metaserver-6dc49',
    authDomain: 'metaserver-6dc49.firebaseapp.com',
    storageBucket: 'metaserver-6dc49.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDwuiDS3itPPxMh0J0w39KjvWqOeVxqjYg',
    appId: '1:422872519301:android:cfda502960e2055f818fec',
    messagingSenderId: '422872519301',
    projectId: 'metaserver-6dc49',
    storageBucket: 'metaserver-6dc49.firebasestorage.app',
  );
}
