import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';

/// Push-уведомления (FCM): запрос разрешения, регистрация токена на бэкенде, обработка нажатий.
class PushService {
  PushService({required this.registerToken, required this.onOpenOrder, required this.onForeground});

  final Future<void> Function(String token) registerToken;
  final void Function(String orderId) onOpenOrder;
  final void Function(String title, String body) onForeground;
  final List<StreamSubscription<dynamic>> _subs = [];

  Future<void> init() async {
    final fm = FirebaseMessaging.instance;
    final settings = await fm.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) return;

    await fm.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
    final token = await fm.getToken();
    if (token != null) await registerToken(token);

    _subs.add(fm.onTokenRefresh.listen(registerToken));
    _subs.add(FirebaseMessaging.onMessage.listen((m) {
      final n = m.notification;
      if (n != null) onForeground(n.title ?? '', n.body ?? '');
    }));
    _subs.add(FirebaseMessaging.onMessageOpenedApp.listen(_open));

    final initial = await fm.getInitialMessage(); // приложение было закрыто и открылось по нажатию на пуш
    if (initial != null) _open(initial);
  }

  void _open(RemoteMessage m) {
    final id = m.data['order_id'];
    if (id is String && id.isNotEmpty) onOpenOrder(id);
  }

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
  }
}
