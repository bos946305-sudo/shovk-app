import 'models.dart';

/// Единая точка доступа к данным. UI знает только этот интерфейс:
/// MockRepository (демо) или HttpRepository (бэкенд) подставляются в state/app_providers.dart.
abstract class ShovkRepository {
  Future<List<Product>> search(String query, {String category = 'Усе'});
  Future<Product> productByRef(String ref);
  Future<List<Order>> orders();
  Future<Order> order(String id);
  Future<PaymentSession> createOrder(CheckoutData data);
  Future<String?> paymentUrl(String orderId);
  Future<Order> advanceOrder(String id); // только демо
  Future<List<String>> qcPhotos(String orderId);
  Future<void> registerDevice(String token);
}
