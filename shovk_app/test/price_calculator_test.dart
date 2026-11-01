import 'package:flutter_test/flutter_test.dart';
import 'package:shovk_app/core/price_calculator.dart';

void main() {
  test('цена считается так же, как на бэкенде', () {
    const p = PriceParams(rate: 5.945, commissionPct: 10, shippingPerKg: 320);
    final b = calcPrice(68, 0.5, p);
    expect(b.goods, 405);
    expect(b.commission, 41);
    expect(b.shipping, 160);
    expect(b.total, 606);
  });
}
