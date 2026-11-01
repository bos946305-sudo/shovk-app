import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import 'api_client.dart';
import 'models.dart';
import 'repository.dart';

/// Работает с вашим бэкенд-сервером. Каталог и поиск на бэкенде ещё не реализованы, поэтому берутся из демо.
class HttpRepository implements ShovkRepository {
  HttpRepository(this._api, this._demo);

  final ShovkApiClient _api;
  final ShovkRepository _demo;

  static final _realId = RegExp(r'^(taobao|1688|pdd):\d+$');

  @override
  Future<Product> productByRef(String ref) async => Product.fromApi(await _api.getItem(ref));

  @override
  Future<List<Product>> search(String query, {String category = 'Усе'}) => _demo.search(query, category: category);

  @override
  Future<List<Order>> orders() async {
    final list = await _api.get('/api/v1/orders') as List<dynamic>;
    return [for (final j in list) Order.fromApi(j as Map<String, dynamic>)];
  }

  @override
  Future<Order> order(String id) async => Order.fromApi(await _api.get('/api/v1/orders/$id') as Map<String, dynamic>);

  @override
  Future<PaymentSession> createOrder(CheckoutData data) async {
    if (data.lines.any((l) => !_realId.hasMatch(l.product.id))) {
      throw const ApiException(
        'Замовлення можна оформити лише з товарів, доданих за посиланням (демо-каталог не продається).',
        retryable: false,
      );
    }
    final res = await _api.post('/api/v1/orders', body: {
      'items': [
        for (final l in data.lines) {'ref': l.product.id, 'qty': l.qty, 'selection': l.selection},
      ],
      'recipient': {'fio': data.fio, 'phone': data.phone, 'city': data.city, 'branch': data.branch},
    }) as Map<String, dynamic>;
    return PaymentSession(Order.fromApi(res['order'] as Map<String, dynamic>), res['payment_url'] as String?);
  }

  @override
  Future<String?> paymentUrl(String orderId) async {
    final res = await _api.post('/api/v1/orders/$orderId/pay') as Map<String, dynamic>;
    return res['payment_url'] as String?;
  }

  @override
  Future<Order> advanceOrder(String id) =>
      throw const ApiException('Статуси змінює оператор через адмін-запит.', retryable: false);

  @override
  Future<List<String>> qcPhotos(String orderId) async {
    final list = await _api.get('/api/v1/orders/$orderId/photos') as List<dynamic>;
    return list.map((e) => e.toString()).toList();
  }

  @override
  Future<void> registerDevice(String token) async {
    await _api.post('/api/v1/devices', body: {'token': token, 'platform': defaultTargetPlatform.name});
  }
}
