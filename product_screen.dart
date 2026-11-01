import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/price_calculator.dart';
import '../../data/models.dart';
import '../../services/analytics.dart';
import '../../state/app_providers.dart';
import '../../state/cart_state.dart';
import '../widgets/product_widgets.dart';
import '../widgets/state_widgets.dart';

/// Товар из каталога (данные уже загружены).
class ProductScreen extends StatelessWidget {
  const ProductScreen({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(product.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ProductBody(product: product),
    );
  }
}

/// Товар по ссылке: сначала скелетон, потом данные с бэкенда (или ошибка с кнопкой «Повторити»).
/// Сюда же ведут deep links вида https://домен/item/123456.
class ProductLoaderScreen extends ConsumerWidget {
  const ProductLoaderScreen({super.key, required this.refText});

  final String refText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(productByRefProvider(refText));
    return Scaffold(
      appBar: AppBar(title: const Text('Товар за посиланням')),
      body: AsyncBody<Product>(
        value: value,
        skeleton: const ProductSkeleton(),
        onRetry: () => ref.invalidate(productByRefProvider(refText)),
        data: (p) => ProductBody(product: p),
      ),
    );
  }
}

class ProductBody extends ConsumerStatefulWidget {
  const ProductBody({super.key, required this.product});

  final Product product;

  @override
  ConsumerState<ProductBody> createState() => _ProductBodyState();
}

class _ProductBodyState extends ConsumerState<ProductBody> {
  @override
  void initState() {
    super.initState();
    Analytics.log('view_item', {'item_id': widget.product.id});
  }

  void _add(Map<String, String> selection, double cny) {
    final product = widget.product;
    ref.read(cartProvider.notifier).add(product, selection);
    Analytics.log('add_to_cart', {'item_id': product.id, 'value': cny});
    // Всё нужное берём до показа снекбара: после ухода с экрана context уже недействителен.
    final navigator = Navigator.of(context);
    final tab = ref.read(tabIndexProvider.notifier);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Додано в кошик'),
      action: SnackBarAction(
        label: 'Кошик',
        onPressed: () {
          tab.state = 1;
          navigator.popUntil((r) => r.isFirst);
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final picked = ref.watch(skuSelectionProvider.select((m) => m[product.id]));
    final selection = product.effectiveSelection(picked);
    final cny = product.cnyFor(selection);
    final breakdown = calcPrice(cny, product.weightKg, product.pricing); // пересчёт мгновенный, без запросов
    final inStock = product.isInStock(selection);
    final theme = Theme.of(context);
    final shareUrl = product.shareUrl;

    return Column(children: [
      Expanded(
        child: ListView(children: [
          ImageCarousel(images: product.images),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(product.title, style: theme.textTheme.titleLarge)),
                if (shareUrl != null)
                  IconButton(
                    tooltip: 'Поділитися',
                    icon: const Icon(Icons.share),
                    onPressed: () => Share.share('${product.title}\n$shareUrl'),
                  ),
              ]),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Text(
                  formatUah(breakdown.total),
                  key: ValueKey<int>(breakdown.total),
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w800, color: theme.colorScheme.primary),
                ),
              ),
              Text('з доставкою в Україну', style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              SkuChips(product: product, selection: selection),
              PriceBreakdownTable(product: product, cny: cny, breakdown: breakdown),
              const SizedBox(height: 8),
              Text(
                'Склад у Гуанчжоу перевірить товар і зробить фото. Якщо фактична вага більша, попросимо доплатити різницю.',
                style: theme.textTheme.bodySmall,
              ),
            ]),
          ),
        ]),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: inStock ? () => _add(selection, cny) : null,
              child: Text(inStock ? 'Додати в кошик' : 'Немає в наявності'),
            ),
          ),
        ),
      ),
    ]);
  }
}
