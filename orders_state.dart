import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import 'app_providers.dart';

class OrdersNotifier extends AsyncNotifier<List<Order>> {
  @override
  Future<List<Order>> build() => ref.read(repositoryProvider).orders();

  /// Создаёт заказ. paymentUrl == null значит, что оплата прошла сразу (демо-режим).
  Future<PaymentSession> place(CheckoutData data) async {
    final current = await future;
    final session = await ref.read(repositoryProvider).createOrder(data);
    state = AsyncData([session.order, ...current]);
    return session;
  }

  /// Подтягивает свежий статус одного заказа (после оплаты или по нажатию на пуш).
  Future<void> refreshOne(String id) async {
    final fresh = await ref.read(repositoryProvider).order(id);
    final current = state.valueOrNull ?? await future;
    final exists = current.any((o) => o.id == id);
    state = AsyncData(exists ? [for (final o in current) o.id == id ? fresh : o] : [fresh, ...current]);
  }

  Future<void> advance(String id) async {
    final current = await future;
    final updated = await ref.read(repositoryProvider).advanceOrder(id);
    state = AsyncData([for (final o in current) o.id == id ? updated : o]);
  }
}

final ordersProvider = AsyncNotifierProvider<OrdersNotifier, List<Order>>(OrdersNotifier.new);
