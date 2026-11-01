import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../data/api_client.dart';
import '../data/http_repository.dart';
import '../data/mock_repository.dart';
import '../data/models.dart';
import '../data/repository.dart';
import '../services/token_storage.dart';

/// Переопределяется в main.dart после чтения SharedPreferences.
final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError('prefsProvider не переопределён'));

final tokenStorageProvider = Provider<TokenStorage>((ref) => const TokenStorage());

final repositoryProvider = Provider<ShovkRepository>((ref) {
  final demo = MockRepository();
  if (AppConfig.useMock) return demo;
  return HttpRepository(ShovkApiClient(ref.read(tokenStorageProvider)), demo);
});

final tabIndexProvider = StateProvider<int>((ref) => 0);
final catalogQueryProvider = StateProvider<String>((ref) => '');
final categoryProvider = StateProvider<String>((ref) => 'Усе');

final catalogProvider = FutureProvider<List<Product>>((ref) {
  final query = ref.watch(catalogQueryProvider);
  final category = ref.watch(categoryProvider);
  return ref.watch(repositoryProvider).search(query, category: category);
});

final productByRefProvider = FutureProvider.family<Product, String>((ref, text) {
  return ref.watch(repositoryProvider).productByRef(text);
});

final qcPhotosProvider = FutureProvider.family<List<String>, String>((ref, orderId) {
  return ref.watch(repositoryProvider).qcPhotos(orderId);
});

/// Выбранные варианты по товарам: {productId: {группа: значение}}. Хранит только то, что пользователь выбрал сам.
class SkuSelectionNotifier extends Notifier<Map<String, Map<String, String>>> {
  @override
  Map<String, Map<String, String>> build() => {};

  void pick(String productId, String group, String value) {
    final current = Map<String, String>.of(state[productId] ?? const <String, String>{});
    current[group] = value;
    state = {...state, productId: current};
  }
}

final skuSelectionProvider =
    NotifierProvider<SkuSelectionNotifier, Map<String, Map<String, String>>>(SkuSelectionNotifier.new);
