import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/price_calculator.dart';
import '../../data/models.dart';
import '../../state/app_providers.dart';
import 'state_widgets.dart';

/// Дисковый кэш картинок: фото не скачиваются повторно, старые удаляются сами.
final imageCacheManager = CacheManager(
  Config('shovkImages', stalePeriod: const Duration(days: 14), maxNrOfCacheObjects: 300),
);

/// Картинка с кэшем на диске. [cacheWidth] ограничивает размер в памяти: 10–20 тяжёлых фото не перегружают телефон.
class ProductImage extends StatelessWidget {
  const ProductImage(this.url, {super.key, this.cacheWidth = 500, this.fit = BoxFit.cover});

  final String url;
  final int cacheWidth;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: url,
      cacheManager: imageCacheManager,
      memCacheWidth: cacheWidth,
      fit: fit,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (context, url) => const Skeleton(radius: 0),
      errorWidget: (context, url, error) => const Center(child: Icon(Icons.image_not_supported_outlined)),
    );
  }
}

class ProductCard extends StatelessWidget {
  const ProductCard({super.key, required this.product, required this.onTap});

  final Product product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final price = calcPrice(product.minCny, product.weightKg, product.pricing).total;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: double.infinity,
              child: product.images.isEmpty
                  ? const Center(child: Icon(Icons.image_outlined))
                  : ProductImage(product.images.first, cacheWidth: 420),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(product.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        Text('від ${formatUah(price)}', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary)),
      ]),
    );
  }
}

/// Галерея фото товара. PageView.builder создаёт страницы лениво, только когда до них долистали.
class ImageCarousel extends StatefulWidget {
  const ImageCarousel({super.key, required this.images});

  final List<String> images;

  @override
  State<ImageCarousel> createState() => _ImageCarouselState();
}

class _ImageCarouselState extends State<ImageCarousel> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      AspectRatio(
        aspectRatio: 1,
        child: images.isEmpty
            ? const Center(child: Icon(Icons.image_outlined, size: 64))
            : PageView.builder(
                itemCount: images.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) => ProductImage(images[i], cacheWidth: 900),
              ),
      ),
      if (images.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < images.length; i++)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == _page ? scheme.primary : scheme.outlineVariant,
                ),
              ),
          ]),
        ),
    ]);
  }
}

/// Чипсы вариантов (цвет, размер...). Нет в наличии: чип отключён. Цена пересчитывается сразу.
class SkuChips extends ConsumerWidget {
  const SkuChips({super.key, required this.product, required this.selection});

  final Product product;
  final Map<String, String> selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final g in product.groups) ...[
        Text(g.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final v in g.values)
            ChoiceChip(
              label: Text(v),
              selected: selection[g.name] == v,
              onSelected: product.isOptionAvailable(g.name, v, selection)
                  ? (_) => ref.read(skuSelectionProvider.notifier).pick(product.id, g.name, v)
                  : null,
            ),
        ]),
        const SizedBox(height: 16),
      ],
    ]);
  }
}

class PriceBreakdownTable extends StatelessWidget {
  const PriceBreakdownTable({super.key, required this.product, required this.cny, required this.breakdown});

  final Product product;
  final double cny;
  final PriceBreakdown breakdown;

  @override
  Widget build(BuildContext context) {
    final p = product.pricing;
    final rows = <List<String>>[
      ['Ціна на ${product.platformLabel}', formatCny(cny)],
      ['Товар за курсом ${formatRate(p.rate)} ₴ за ¥', formatUah(breakdown.goods)],
      ['Комісія сервісу ${p.commissionPct.toStringAsFixed(0)} %', formatUah(breakdown.commission)],
      [
        'Авіадоставка, близько ${product.weightKg.toStringAsFixed(2).replaceAll('.', ',')} кг',
        formatUah(breakdown.shipping),
      ],
    ];
    return Column(children: [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(child: Text(r[0])),
            Text(r[1], style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
        ),
    ]);
  }
}
