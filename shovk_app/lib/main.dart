import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/config.dart';
import 'services/analytics.dart';
import 'state/app_providers.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Лимиты оперативной памяти под картинки: на недорогих телефонах без них возможны вылеты.
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSizeBytes = 80 * 1024 * 1024; // 80 МБ декодированных изображений
  imageCache.maximumSize = 150; // не более 150 картинок

  final prefs = await SharedPreferences.getInstance();

  if (AppConfig.useFirebase) {
    try {
      await Firebase.initializeApp();
      Analytics.enabled = true;
    } catch (e) {
      debugPrint('Firebase выключен: $e');
    }
  }

  Future<void> start() async {
    runApp(ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs)],
      child: const ShovkApp(),
    ));
  }

  if (AppConfig.sentryDsn.isNotEmpty) {
    // Sentry сам ловит необработанные ошибки Flutter и Dart.
    await SentryFlutter.init((options) {
      options.dsn = AppConfig.sentryDsn;
      options.tracesSampleRate = 0.2;
    }, appRunner: start);
  } else {
    await start();
  }
}
