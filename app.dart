import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/analytics.dart';
import '../services/deep_links.dart';
import '../services/push_service.dart';
import '../state/app_providers.dart';
import '../state/orders_state.dart';
import 'screens/order_detail_screen.dart';
import 'screens/payment_result_screen.dart';
import 'screens/product_screen.dart';
import 'shell.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

ThemeData buildTheme(Brightness brightness) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2447F5), brightness: brightness),
  );
}

class ShovkApp extends ConsumerStatefulWidget {
  const ShovkApp({super.key});

  @override
  ConsumerState<ShovkApp> createState() => _ShovkAppState();
}

class _ShovkAppState extends ConsumerState<ShovkApp> {
  DeepLinkService? _links;
  PushService? _push;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startServices());
  }

  Future<void> _startServices() async {
    _links = DeepLinkService(_onLink);
    try {
      await _links!.start();
    } catch (e) {
      debugPrint('deep links: $e');
    }
    if (Analytics.enabled) {
      // push работает только если Firebase настроен (USE_FIREBASE=true)
      _push = PushService(
        registerToken: (token) => ref.read(repositoryProvider).registerDevice(token),
        onOpenOrder: _openOrder,
        onForeground: (title, body) =>
            messengerKey.currentState?.showSnackBar(SnackBar(content: Text('$title\n$body'))),
      );
      try {
        await _push!.init();
      } catch (e) {
        debugPrint('push: $e');
      }
    }
  }

  void _openOrder(String id) {
    ref.read(tabIndexProvider.notifier).state = 2;
    ref.invalidate(ordersProvider);
    navigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => OrderDetailScreen(orderId: id)));
  }

  void _onLink(DeepLink link) {
    switch (link.kind) {
      case DeepLinkKind.item:
        Analytics.log('deep_link_item', {'item_id': link.value});
        navigatorKey.currentState
            ?.push(MaterialPageRoute<void>(builder: (_) => ProductLoaderScreen(refText: link.value)));
      case DeepLinkKind.payReturn:
        // Возврат со страницы оплаты: показываем результат. Подтверждает платёж только сервер.
        ref.read(tabIndexProvider.notifier).state = 2;
        navigatorKey.currentState?.popUntil((r) => r.isFirst);
        navigatorKey.currentState
            ?.push(MaterialPageRoute<void>(builder: (_) => PaymentResultScreen(orderId: link.value)));
    }
  }

  @override
  void dispose() {
    _links?.dispose();
    _push?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Шовк',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      locale: const Locale('uk'),
      supportedLocales: const [Locale('uk'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const AppShell(),
    );
  }
}
