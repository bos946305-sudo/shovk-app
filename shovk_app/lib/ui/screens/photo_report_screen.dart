import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_providers.dart';
import '../widgets/product_widgets.dart';
import '../widgets/state_widgets.dart';

/// Фотозвіт зі складу в Гуанчжоу: сітка фото (вантажаться лениво, кешуються), нажатие открывает фото на весь экран.
class PhotoReportScreen extends ConsumerWidget {
  const PhotoReportScreen({super.key, required this.orderId});

  final String orderId;

  void _open(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(8),
        child: InteractiveViewer(child: ProductImage(url, cacheWidth: 1400, fit: BoxFit.contain)),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photos = ref.watch(qcPhotosProvider(orderId));
    return Scaffold(
      appBar: AppBar(title: const Text('Фотозвіт зі складу')),
      body: AsyncBody<List<String>>(
        value: photos,
        skeleton: const PhotoGridSkeleton(),
        onRetry: () => ref.invalidate(qcPhotosProvider(orderId)),
        data: (urls) => urls.isEmpty
            ? const Center(child: Text('Фото ще не готові'))
            : GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: urls.length,
                itemBuilder: (context, i) => GestureDetector(
                  onTap: () => _open(context, urls[i]),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ProductImage(urls[i], cacheWidth: 500),
                  ),
                ),
              ),
      ),
    );
  }
}
