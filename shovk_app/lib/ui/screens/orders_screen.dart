import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/orders_state.dart';
import '../widgets/state_widgets.dart';
import 'order_detail_screen.dart';

class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(ordersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Мої замовлення')),
      body: AsyncBody<List<Order>>(
        value: orders,
        skeleton: const ListSkeleton(),
        onRetry: () => ref.invalidate(ordersProvider),
        data: (list) => list.isEmpty
            ? const Center(child: Text('Замовлень поки немає'))
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(ordersProvider);
                  try {
                    await ref.read(ordersProvider.future);
                  } catch (_) {}
                },
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  itemCount: list.length,
                  itemBuilder: (context, i) => OrderCard(order: list[i]),
                ),
              ),
      ),
    );
  }
}

class OrderCard extends StatelessWidget {
  const OrderCard({super.key, required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final label = order.awaitingPayment ? 'Очікує оплати' : kOrderSteps[order.status];
    final progress = order.awaitingPayment ? 0.0 : (order.status + 1) / kOrderSteps.length;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => OrderDetailScreen(orderId: order.id))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(order.id, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(formatUah(order.totalUah), style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 4),
            Text(order.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}
