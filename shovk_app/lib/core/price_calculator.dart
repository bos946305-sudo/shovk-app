/// Параметры тарифа. Приходят с бэкенда, чтобы цена в приложении и на сервере считалась одинаково.
class PriceParams {
  const PriceParams({required this.rate, required this.commissionPct, required this.shippingPerKg});

  final double rate; // грн за 1 ¥, уже с запасом на спред
  final double commissionPct; // комиссия сервиса, %
  final double shippingPerKg; // грн за кг

  Map<String, dynamic> toJson() => {'rate': rate, 'commission_pct': commissionPct, 'shipping_per_kg': shippingPerKg};

  factory PriceParams.fromJson(Map<String, dynamic> j) => PriceParams(
        rate: (j['rate'] as num).toDouble(),
        commissionPct: (j['commission_pct'] as num).toDouble(),
        shippingPerKg: (j['shipping_per_kg'] as num).toDouble(),
      );
}

class PriceBreakdown {
  const PriceBreakdown({required this.goods, required this.commission, required this.shipping});

  final int goods;
  final int commission;
  final int shipping;

  int get total => goods + commission + shipping;
}

/// Калькулятор цены в гривнах. Формула совпадает с бэкендом (price_block в main.py).
PriceBreakdown calcPrice(double cny, double weightKg, PriceParams p) {
  return PriceBreakdown(
    goods: (cny * p.rate).ceil(),
    commission: (cny * p.rate * p.commissionPct / 100).ceil(),
    shipping: (weightKg * p.shippingPerKg).ceil(),
  );
}
