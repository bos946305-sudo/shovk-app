import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/app_providers.dart';
import '../../state/orders_state.dart';
import '../widgets/order_timeline.dart';
import '../widgets/state_widgets.dart';
import 'payment_result_screen.dart';
import 'photo_report_screen.dart';

class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(ordersProvider);
    return Scaffold(
      appBar: AppBar(title: Text(orderId)),
      body: AsyncBody<List<Order>>(
        value: orders,
        skeleton: const ListSkeleton(count: 4, height: 60),
        onRetry: () => ref.invalidate(ordersProvider),
        data: (list) {
          final i = list.indexWhere((o) => o.id == orderId);
          if (i == -1) return const Center(child: Text('Замовлення не знайдено'));
          return _OrderView(order: list[i]);
        },
      ),
    );
  }
}

class _OrderView extends ConsumerWidget {
  const _OrderView({required this.order});

  final Order order;

  Future<void> _payAgain(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final url = await ref.read(repositoryProvider).paymentUrl(order.id);
      if (url == null) return;
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PaymentResultScreen(orderId: order.id)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasPhotos = order.status >= kQcStep;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(order.title, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text('Сума: ${formatUah(order.totalUah)}'),
      const SizedBox(height: 24),
      OrderTimeline(status: order.status),
      const SizedBox(height: 8),
      if (order.awaitingPayment) ...[
        FilledButton(onPressed: () => _payAgain(context, ref), child: const Text('Сплатити')),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => PaymentResultScreen(orderId: order.id))),
          child: const Text('Перевірити оплату'),
        ),
      ] else
        OutlinedButton.icon(
          onPressed: hasPhotos
              ? () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => PhotoReportScreen(orderId: order.id)))
              : null,
          icon: const Icon(Icons.photo_library_outlined),
          label: Text(hasPhotos ? 'Фотозвіт зі складу' : 'Фотозвіт буде після перевірки на складі'),
        ),
      if (AppConfig.useMock && !order.awaitingPayment && order.status < kOrderSteps.length - 1)
        TextButton(
          onPressed: () => ref.read(ordersProvider.notifier).advance(order.id),
          child: const Text('Демо: наступний статус'),
        ),
    ]);
  }
}
