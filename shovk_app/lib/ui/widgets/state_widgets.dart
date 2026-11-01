import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';

/// Серый пульсирующий блок-заглушка вместо белого экрана или спиннера.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height, this.radius = 8});

  final double? width;
  final double? height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  late final Animation<double> _opacity =
      Tween<double>(begin: 0.4, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: const Color.fromRGBO(128, 128, 128, 0.28),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

class ProductCardSkeleton extends StatelessWidget {
  const ProductCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Skeleton(radius: 12)),
      SizedBox(height: 8),
      Skeleton(height: 14),
      SizedBox(height: 6),
      Skeleton(width: 80, height: 14),
    ]);
  }
}

class ProductSkeleton extends StatelessWidget {
  const ProductSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(physics: const NeverScrollableScrollPhysics(), children: const [
      AspectRatio(aspectRatio: 1, child: Skeleton(radius: 0)),
      Padding(
        padding: EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Skeleton(height: 22),
          SizedBox(height: 12),
          Skeleton(width: 140, height: 28),
          SizedBox(height: 24),
          Skeleton(height: 40),
          SizedBox(height: 12),
          Skeleton(height: 40),
        ]),
      ),
    ]);
  }
}

class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.count = 3, this.height = 110});

  final int count;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: count,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Skeleton(height: height, radius: 12),
      ),
    );
  }
}

class PhotoGridSkeleton extends StatelessWidget {
  const PhotoGridSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: 6,
      itemBuilder: (context, i) => const Skeleton(radius: 8),
    );
  }
}

/// Сообщение об ошибке с кнопкой «Повторити» (нет интернета, сервер не ответил).
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.wifi_off_rounded, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Повторити')),
          ],
        ]),
      ),
    );
  }
}

/// Единый показ загрузки (скелетон), ошибки (кнопка «Повторити») и данных.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({
    super.key,
    required this.value,
    required this.data,
    required this.skeleton,
    required this.onRetry,
  });

  final AsyncValue<T> value;
  final Widget Function(T value) data;
  final Widget skeleton;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: false,
      loading: () => skeleton,
      error: (e, _) => ErrorRetry(message: errorText(e), onRetry: canRetry(e) ? onRetry : null),
      data: data,
    );
  }
}
