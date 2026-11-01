import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../services/analytics.dart';
import '../../state/app_providers.dart';
import '../../state/orders_state.dart';
import 'order_detail_screen.dart';

/// Результат оплаты. Открывается после ухода на страницу банка и по ссылке shovk://pay/return?order=...
/// Статус «Оплачено» ставит сервер после подтверждения платежа банком, экран лишь опрашивает сервер.
class PaymentResultScreen extends ConsumerStatefulWidget {
  const PaymentResultScreen({super.key, required this.orderId});

  final String orderId;

  @override
  ConsumerState<PaymentResultScreen> createState() => _PaymentResultScreenState();
}

class _PaymentResultScreenState extends ConsumerState<PaymentResultScreen> {
  Timer? _timer;
  int _tries = 0;
  bool _gaveUp = false;
  bool _logged = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _tries = 0;
    _gaveUp = false;
    _timer?.cancel();
    _check();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Order? _find() {
    final list = ref.read(ordersProvider).valueOrNull;
    if (list == null) return null;
    for (final o in list) {
      if (o.id == widget.orderId) return o;
    }
    return null;
  }

  void _finish(Order order) {
    _timer?.cancel();
    if (!_logged) {
      _logged = true;
      Analytics.log('purchase', {'order_id': order.id, 'value': order.totalUah});
    }
    if (mounted) setState(() {});
  }

  Future<void> _check() async {
    if (!mounted) return;
    final known = _find();
    if (known != null && !known.awaitingPayment) {
      _finish(known);
      return;
    }
    if (_tries++ >= 20) {
      _timer?.cancel();
      setState(() => _gaveUp = true);
      return;
    }
    try {
      await ref.read(ordersProvider.notifier).refreshOne(widget.orderId);
    } catch (_) {}
    if (!mounted) return;
    final fresh = _find();
    if (fresh != null && !fresh.awaitingPayment) _finish(fresh);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(ordersProvider);
    final order = _find();
    final paid = order != null && !order.awaitingPayment;
    final scheme = Theme.of(context).colorScheme;

    Widget body;
    if (paid) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.check_circle, size: 72, color: scheme.primary),
        const SizedBox(height: 16),
        Text('Оплачено', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text('Замовлення ${widget.orderId} прийнято. Ми сповістимо вас на кожному етапі.', textAlign: TextAlign.center),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => OrderDetailScreen(orderId: widget.orderId)),
          ),
          child: const Text('Відстежити замовлення'),
        ),
      ]);
    } else if (_gaveUp) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.hourglass_empty, size: 56, color: scheme.outline),
        const SizedBox(height: 16),
        const Text(
          'Оплату ще не підтверджено. Якщо ви вже заплатили, зачекайте хвилину і перевірте ще раз.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: () {
          setState(() => _gaveUp = false);
          _start();
        }, child: const Text('Перевірити ще раз')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('До замовлень')),
      ]);
    } else {
      body = const Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Чекаємо підтвердження оплати від банку…'),
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Оплата')),
      body: Center(child: Padding(padding: const EdgeInsets.all(24), child: body)),
    );
  }
}
