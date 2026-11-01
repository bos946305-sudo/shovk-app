import '../core/config.dart';
import '../core/price_calculator.dart';

class SkuGroup {
  const SkuGroup(this.name, this.values);

  final String name;
  final List<String> values;

  Map<String, dynamic> toJson() => {'name': name, 'values': values};

  factory SkuGroup.fromJson(Map<String, dynamic> j) =>
      SkuGroup(j['name'] as String, (j['values'] as List<dynamic>).map((e) => e.toString()).toList());
}

/// Конкретная комбинация вариантов (цвет + размер) с собственной ценой и наличием.
class Sku {
  const Sku(this.props, this.priceCny, {this.inStock = true});

  final Map<String, String> props;
  final double priceCny;
  final bool inStock;

  Map<String, dynamic> toJson() => {'props': props, 'price_cny': priceCny, 'in_stock': inStock};

  factory Sku.fromJson(Map<String, dynamic> j) => Sku(
        Map<String, String>.from(j['props'] as Map),
        (j['price_cny'] as num).toDouble(),
        inStock: (j['in_stock'] as bool?) ?? true,
      );
}

class Product {
  const Product({
    required this.id,
    required this.platform,
    required this.title,
    required this.category,
    required this.images,
    required this.basePriceCny,
    required this.weightKg,
    required this.pricing,
    this.groups = const [],
    this.skus = const [],
  });

  final String id; // для реальных товаров "platform:item_id", например "taobao:123456789012"
  final String platform;
  final String title;
  final String category;
  final List<String> images;
  final double basePriceCny;
  final double weightKg;
  final PriceParams pricing;
  final List<SkuGroup> groups;
  final List<Sku> skus;

  String get platformLabel => switch (platform) {
        '1688' => '1688',
        'pdd' => 'Pinduoduo',
        _ => 'Taobao',
      };

  /// Ссылка для «Поделиться» (открывает приложение на этом товаре). Только для реальных товаров.
  String? get shareUrl {
    final m = RegExp(r'^(taobao|1688|pdd):(\d+)$').firstMatch(id);
    return m == null ? null : 'https://${AppConfig.publicHost}/item/${m.group(1)}/${m.group(2)}';
  }

  double get minCny => skus.isEmpty ? basePriceCny : skus.map((s) => s.priceCny).reduce((a, b) => a < b ? a : b);

  Map<String, String> get defaultSelection {
    for (final s in skus) {
      if (s.inStock) return Map<String, String>.of(s.props);
    }
    return {for (final g in groups) g.name: g.values.first};
  }

  Map<String, String> effectiveSelection(Map<String, String>? picked) => {...defaultSelection, ...?picked};

  bool _matches(Sku s, Map<String, String> sel) => sel.entries.every((e) => s.props[e.key] == e.value);

  Sku? skuFor(Map<String, String> sel) {
    for (final s in skus) {
      if (_matches(s, sel)) return s;
    }
    return null;
  }

  double cnyFor(Map<String, String> sel) => skuFor(sel)?.priceCny ?? basePriceCny;

  bool isInStock(Map<String, String> sel) {
    if (skus.isEmpty) return true;
    final s = skuFor(sel);
    return s != null && s.inStock;
  }

  /// Можно ли выбрать [value] в группе [group] при остальных текущих выборах.
  bool isOptionAvailable(String group, String value, Map<String, String> sel) {
    if (skus.isEmpty) return true;
    final test = {...sel, group: value};
    return skus.any((s) => s.inStock && _matches(s, test));
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'platform': platform,
        'title': title,
        'category': category,
        'images': images,
        'base_price_cny': basePriceCny,
        'weight_kg': weightKg,
        'pricing': pricing.toJson(),
        'groups': [for (final g in groups) g.toJson()],
        'skus': [for (final s in skus) s.toJson()],
      };

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'] as String,
        platform: j['platform'] as String,
        title: j['title'] as String,
        category: j['category'] as String,
        images: (j['images'] as List<dynamic>).map((e) => e.toString()).toList(),
        basePriceCny: (j['base_price_cny'] as num).toDouble(),
        weightKg: (j['weight_kg'] as num).toDouble(),
        pricing: PriceParams.fromJson(j['pricing'] as Map<String, dynamic>),
        groups: [for (final g in j['groups'] as List<dynamic>) SkuGroup.fromJson(g as Map<String, dynamic>)],
        skus: [for (final s in j['skus'] as List<dynamic>) Sku.fromJson(s as Map<String, dynamic>)],
      );

  /// Ответ бэкенда GET /api/v1/item. Поля options/skus бэкенд пока не отдаёт (появятся вместе с SKU-парсингом).
  factory Product.fromApi(Map<String, dynamic> j) {
    final price = j['price'] as Map<String, dynamic>;
    final options = (j['options'] as List<dynamic>?) ?? const <dynamic>[];
    final skus = (j['skus'] as List<dynamic>?) ?? const <dynamic>[];
    return Product(
      id: '${j['platform']}:${j['item_id']}',
      platform: j['platform'] as String,
      title: j['title'] as String,
      category: 'З посилання',
      images: ((j['images'] as List<dynamic>?) ?? const <dynamic>[]).map((e) => e.toString()).toList(),
      basePriceCny: (price['cny'] as num).toDouble(),
      weightKg: (j['weight_kg'] as num).toDouble(),
      pricing: PriceParams(
        rate: (price['rate'] as num).toDouble(),
        commissionPct: ((price['commission_pct'] as num?) ?? 10).toDouble(),
        shippingPerKg: ((price['shipping_uah_per_kg'] as num?) ?? 320).toDouble(),
      ),
      groups: [for (final o in options) SkuGroup.fromJson(o as Map<String, dynamic>)],
      skus: [for (final s in skus) Sku.fromJson(s as Map<String, dynamic>)],
    );
  }
}

class CartLine {
  const CartLine({required this.product, required this.selection, required this.qty});

  final Product product;
  final Map<String, String> selection;
  final int qty;

  String get key =>
      '${product.id}|${(selection.entries.map((e) => '${e.key}=${e.value}').toList()..sort()).join(';')}';
  double get unitCny => product.cnyFor(selection);
  int get unitUah => calcPrice(unitCny, product.weightKg, product.pricing).total;
  int get totalUah => unitUah * qty;

  CartLine copyWith({int? qty}) => CartLine(product: product, selection: selection, qty: qty ?? this.qty);

  Map<String, dynamic> toJson() => {'product': product.toJson(), 'selection': selection, 'qty': qty};

  factory CartLine.fromJson(Map<String, dynamic> j) => CartLine(
        product: Product.fromJson(j['product'] as Map<String, dynamic>),
        selection: Map<String, String>.from(j['selection'] as Map),
        qty: (j['qty'] as num).toInt(),
      );
}

/// status: -1 ждёт оплаты, 0..7 индекс в kOrderSteps.
class Order {
  const Order({required this.id, required this.title, required this.totalUah, required this.status});

  final String id;
  final String title;
  final int totalUah;
  final int status;

  bool get awaitingPayment => status < 0;

  Order copyWith({int? status}) => Order(id: id, title: title, totalUah: totalUah, status: status ?? this.status);

  factory Order.fromApi(Map<String, dynamic> j) => Order(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        totalUah: (j['total_uah'] as num).toInt(),
        status: (j['status'] as num).toInt(),
      );
}

/// Результат оформления: заказ и ссылка на оплату (null: оплата прошла сразу, как в демо-режиме).
class PaymentSession {
  const PaymentSession(this.order, this.paymentUrl);

  final Order order;
  final String? paymentUrl;
}

class CheckoutData {
  const CheckoutData({
    required this.lines,
    required this.totalUah,
    required this.fio,
    required this.phone,
    required this.city,
    required this.branch,
  });

  final List<CartLine> lines;
  final int totalUah;
  final String fio;
  final String phone;
  final String city;
  final String branch;
}
