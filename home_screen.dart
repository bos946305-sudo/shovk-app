import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../state/app_providers.dart';
import '../widgets/product_widgets.dart';
import '../widgets/state_widgets.dart';
import 'product_screen.dart';

const _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: 2,
  mainAxisSpacing: 16,
  crossAxisSpacing: 12,
  childAspectRatio: 0.66,
);

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String text) {
    final q = text.trim();
    if (looksLikeLink(q)) {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProductLoaderScreen(refText: q)));
    } else {
      ref.read(catalogQueryProvider.notifier).state = q;
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    _controller.text = text;
    _submit(text);
  }

  Future<void> _refresh() async {
    ref.invalidate(catalogProvider);
    try {
      await ref.read(catalogProvider.future);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(catalogProvider);
    final category = ref.watch(categoryProvider);
    final theme = Theme.of(context);

    // Список товаров: SliverGrid строит только карточки, которые видны на экране.
    final Widget products = catalog.when(
      skipLoadingOnRefresh: false,
      loading: () => SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        sliver: SliverGrid(
          gridDelegate: _gridDelegate,
          delegate: SliverChildBuilderDelegate((context, i) => const ProductCardSkeleton(), childCount: 6),
        ),
      ),
      error: (e, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 48),
          child: ErrorRetry(
            message: errorText(e),
            onRetry: canRetry(e) ? () => ref.invalidate(catalogProvider) : null,
          ),
        ),
      ),
      data: (items) => items.isEmpty
          ? const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: Text('Нічого не знайдено. Спробуйте інше слово або вставте посилання на товар.',
                      textAlign: TextAlign.center),
                ),
              ),
            )
          : SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverGrid(
                gridDelegate: _gridDelegate,
                delegate: SliverChildBuilderDelegate(
                  (context, i) => ProductCard(
                    product: items[i],
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => ProductScreen(product: items[i]))),
                  ),
                  childCount: items.length,
                ),
              ),
            ),
    );

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Шовк', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text('Товари з Taobao і 1688 гривнями. Заберете в Новій пошті за 10–14 днів.',
                        style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.search,
                      onSubmitted: _submit,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: IconButton(
                          tooltip: 'Вставити посилання',
                          icon: const Icon(Icons.content_paste),
                          onPressed: _paste,
                        ),
                        hintText: 'Назва товару або посилання',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 40,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: kCategories.length,
                        separatorBuilder: (context, i) => const SizedBox(width: 8),
                        itemBuilder: (context, i) => ChoiceChip(
                          label: Text(kCategories[i]),
                          selected: category == kCategories[i],
                          onSelected: (_) => ref.read(categoryProvider.notifier).state = kCategories[i],
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
              products,
            ],
          ),
        ),
      ),
    );
  }
}
