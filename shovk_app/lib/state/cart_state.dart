import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import 'app_providers.dart';

const _cartKey = 'cart_v1';

/// Корзина. Каждое изменение сразу сохраняется на устройстве (SharedPreferences),
/// поэтому корзина переживает закрытие приложения и работает без интернета.
class CartNotifier extends Notifier<List<CartLine>> {
  @override
  List<CartLine> build() {
    try {
      final raw = ref.read(prefsProvider).getString(_cartKey);
      if (raw == null) return [];
      return [for (final j in jsonDecode(raw) as List<dynamic>) CartLine.fromJson(j as Map<String, dynamic>)];
    } catch (_) {
      return []; // повреждённые данные не должны ломать запуск
    }
  }

  void _set(List<CartLine> lines) {
    state = lines;
    ref.read(prefsProvider).setString(_cartKey, jsonEncode([for (final l in lines) l.toJson()]));
  }

  void add(Product product, Map<String, String> selection) {
    final line = CartLine(product: product, selection: Map<String, String>.of(selection), qty: 1);
    final i = state.indexWhere((l) => l.key == line.key);
    if (i == -1) {
      _set([...state, line]);
    } else {
      _set([for (var k = 0; k < state.length; k++) k == i ? state[k].copyWith(qty: state[k].qty + 1) : state[k]]);
    }
  }

  void setQty(String key, int qty) {
    if (qty <= 0) {
      remove(key);
      return;
    }
    _set([for (final l in state) l.key == key ? l.copyWith(qty: qty) : l]);
  }

  void remove(String key) => _set(state.where((l) => l.key != key).toList());

  void clear() => _set(<CartLine>[]);
}

final cartProvider = NotifierProvider<CartNotifier, List<CartLine>>(CartNotifier.new);

/// Итог корзины пересчитывается сам при любом изменении количества или варианта.
final cartTotalProvider = Provider<int>((ref) {
  return ref.watch(cartProvider).fold<int>(0, (sum, l) => sum + l.totalUah);
});
