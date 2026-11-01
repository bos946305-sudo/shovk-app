import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// События воронки: view_item, add_to_cart, begin_checkout, payment_started, purchase.
/// По ним в Firebase Analytics видно, на каком шаге клиент уходит. В Sentry те же события
/// попадают в «хлебные крошки» и помогают понять, что делал пользователь перед сбоем.
class Analytics {
  Analytics._();

  /// true, если Firebase инициализирован (см. main.dart).
  static bool enabled = false;

  static void log(String name, [Map<String, Object> params = const {}]) {
    Sentry.addBreadcrumb(Breadcrumb(message: name, category: 'funnel', data: Map<String, dynamic>.of(params)));
    if (enabled) {
      FirebaseAnalytics.instance.logEvent(name: name, parameters: params).catchError((Object _) {});
    }
  }
}
