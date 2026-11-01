import '../core/config.dart';
import '../core/errors.dart';
import '../core/price_calculator.dart';
import 'models.dart';
import 'repository.dart';

const _pricing = PriceParams(rate: 5.945, commissionPct: 10, shippingPerKg: 320);

List<String> _imgs(String seed) => [for (var i = 1; i <= 3; i++) 'https://picsum.photos/seed/$seed$i/700/700'];

/// Все комбинации вариантов с ценой base + доплата и наличием.
List<Sku> _skus(
  List<SkuGroup> groups,
  double base, {
  double Function(Map<String, String>)? extra,
  bool Function(Map<String, String>)? stock,
}) {
  var combos = <Map<String, String>>[{}];
  for (final g in groups) {
    combos = [
      for (final c in combos)
        for (final v in g.values) {...c, g.name: v},
    ];
  }
  return [
    for (final c in combos) Sku(c, base + (extra?.call(c) ?? 0.0), inStock: stock?.call(c) ?? true),
  ];
}

Product _p(
  String id,
  String title,
  String category,
  double cny,
  double kg,
  List<SkuGroup> groups, {
  double Function(Map<String, String>)? extra,
  bool Function(Map<String, String>)? stock,
}) {
  return Product(
    id: id,
    platform: 'taobao',
    title: title,
    category: category,
    images: _imgs(id),
    basePriceCny: cny,
    weightKg: kg,
    pricing: _pricing,
    groups: groups,
    skus: _skus(groups, cny, extra: extra, stock: stock),
  );
}

List<Product> _buildCatalog() => [
      _p('m1', 'Фетровий капелюх унісекс', 'Аксесуари', 68, 0.35,
          const [SkuGroup('Колір', ['Чорний', 'Бежевий', 'Сірий']), SkuGroup('Розмір', ['56', '58', '60'])],
          extra: (c) => c['Колір'] == 'Бежевий' ? 6.0 : 0.0),
      _p('m2', 'Бездротові навушники TWS', 'Електроніка', 95, 0.2,
          const [SkuGroup('Колір', ['Білий', 'Чорний']), SkuGroup('Комплектація', ['Базова', 'З кейсом-павербанком'])],
          extra: (c) => c['Комплектація'] == 'Базова' ? 0.0 : 25.0),
      _p('m3', 'Кросівки сітчасті літні', 'Взуття', 182, 0.9,
          const [SkuGroup('Колір', ['Білий', 'Синій']), SkuGroup('Розмір', ['40', '41', '42', '43', '44'])],
          extra: (c) => c['Розмір'] == '44' ? 12.0 : 0.0,
          stock: (c) => !(c['Колір'] == 'Синій' && c['Розмір'] == '44')),
      _p('m4', 'Рюкзак водостійкий 25 л', 'Сумки', 120, 0.8, const [SkuGroup('Колір', ['Чорний', 'Хакі'])]),
      _p('m5', 'Нічник-проєктор зоряного неба', 'Дім', 54, 0.45,
          const [SkuGroup('Комплектація', ['Базова', 'З пультом'])],
          extra: (c) => c['Комплектація'] == 'Базова' ? 0.0 : 15.0),
      _p('m6', 'Куртка-бомбер осіння', 'Одяг', 230, 0.85,
          const [SkuGroup('Колір', ['Оливковий', 'Чорний']), SkuGroup('Розмір', ['S', 'M', 'L', 'XL'])],
          extra: (c) => c['Розмір'] == 'XL' ? 18.0 : 0.0),
      _p('m7', 'Термокухоль 500 мл зі сталі', 'Дім', 46, 0.5, const [SkuGroup('Колір', ['Сталевий', 'Чорний', 'Зелений'])]),
      _p('m8', 'Смарт-годинник із трекером сну', 'Електроніка', 210, 0.15,
          const [SkuGroup('Колір', ['Чорний', 'Сріблястий'])]),
    ];

/// Демонстраційні дані: ничего не отправляется в сеть (кроме картинок-заглушок).
class MockRepository implements ShovkRepository {
  MockRepository() : _catalog = _buildCatalog();

  final List<Product> _catalog;
  final List<Order> _orders = [
    const Order(id: 'CN-1042', title: 'Бездротові навушники TWS', totalUah: 686, status: 4),
  ];
  int _seq = 1043;

  Future<void> _delay() => Future<void>.delayed(const Duration(milliseconds: 700));

  @override
  Future<List<Product>> search(String query, {String category = 'Усе'}) async {
    await _delay();
    final q = query.trim().toLowerCase();
    // демо: введіть «помилка», щоб побачити екран помилки з кнопкою «Повторити»
    if (q == 'помилка') throw const ApiException('Не вдалося завантажити каталог. Перевірте інтернет.');
    return _catalog
        .where((p) => (category == 'Усе' || p.category == category) && p.title.toLowerCase().contains(q))
        .toList();
  }

  @override
  Future<Product> productByRef(String ref) async {
    await _delay();
    return _catalog[ref.hashCode.abs() % _catalog.length]; // демо: будь-яке посилання відкриває якийсь товар
  }

  @override
  Future<List<Order>> orders() async {
    await _delay();
    return List<Order>.of(_orders);
  }

  @override
  Future<Order> order(String id) async {
    final i = _orders.indexWhere((o) => o.id == id);
    if (i == -1) throw const ApiException('Замовлення не знайдено', retryable: false);
    return _orders[i];
  }

  @override
  Future<PaymentSession> createOrder(CheckoutData data) async {
    await _delay();
    final title = data.lines.map((l) => l.product.title).join(', ');
    final order = Order(id: 'CN-${_seq++}', title: title, totalUah: data.totalUah, status: 0);
    _orders.insert(0, order);
    return PaymentSession(order, null); // демо: оплата проходить одразу
  }

  @override
  Future<String?> paymentUrl(String orderId) async => null;

  @override
  Future<Order> advanceOrder(String id) async {
    final i = _orders.indexWhere((o) => o.id == id);
    if (i == -1) throw const ApiException('Замовлення не знайдено', retryable: false);
    final o = _orders[i];
    if (o.status < kOrderSteps.length - 1) _orders[i] = o.copyWith(status: o.status + 1);
    return _orders[i];
  }

  @override
  Future<List<String>> qcPhotos(String orderId) async {
    await _delay();
    return List<String>.generate(6, (i) => 'https://picsum.photos/seed/qc-$orderId-$i/900/900');
  }

  @override
  Future<void> registerDevice(String token) async {}
}
