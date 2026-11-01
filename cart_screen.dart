import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import '../../services/analytics.dart';
import '../../state/app_providers.dart';
import '../../state/cart_state.dart';
import '../../state/orders_state.dart';
import '../widgets/product_widgets.dart';
import 'payment_result_screen.dart';

class CartScreen extends ConsumerStatefulWidget {
  const CartScreen({super.key});

  @override
  ConsumerState<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends ConsumerState<CartScreen> {
  final _fio = TextEditingController();
  final _phone = TextEditingController();
  final _branch = TextEditingController();
  String _city = kCities.first;
  bool _paying = false;

  @override
  void dispose() {
    _fio.dispose();
    _phone.dispose();
    _branch.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pay(List<CartLine> lines, int total) async {
    if (_fio.text.trim().length < 5) {
      _toast('Вкажіть ПІБ отримувача');
      return;
    }
    if (_phone.text.replaceAll(RegExp(r'\D'), '').length < 10) {
      _toast('Вкажіть номер телефону');
      return;
    }
    if (_branch.text.trim().isEmpty) {
      _toast('Вкажіть номер відділення Нової пошти');
      return;
    }
    setState(() => _paying = true);
    try {
      Analytics.log('begin_checkout', {'value': total, 'items': lines.length});
      final data = CheckoutData(
        lines: lines,
        totalUah: total,
        fio: _fio.text.trim(),
        phone: _phone.text.trim(),
        city: _city,
        branch: 'Відділення №${_branch.text.trim()}',
      );
      final session = await ref.read(ordersProvider.notifier).place(data);
      ref.read(cartProvider.notifier).clear();
      final url = session.paymentUrl;
      if (url == null) {
        // демо-режим: оплата проходить одразу
        Analytics.log('purchase', {'order_id': session.order.id, 'value': total});
        ref.read(tabIndexProvider.notifier).state = 2;
        _toast('Оплату прийнято (демо). Замовлення створено.');
      } else {
        Analytics.log('payment_started', {'order_id': session.order.id, 'value': total});
        await _openPayment(url, session.order.id);
      }
    } catch (e) {
      _toast(errorText(e));
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  /// Открывает страницу оплаты Monobank / LiqPay в браузере (там доступны карта, Apple Pay, Google Pay).
  Future<void> _openPayment(String url, String orderId) async {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!mounted) return;
    ref.read(tabIndexProvider.notifier).state = 2;
    if (!ok) {
      _toast('Не вдалося відкрити сторінку оплати. Замовлення збережено, його можна оплатити у «Замовленнях».');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PaymentResultScreen(orderId: orderId)));
  }

  @override
  Widget build(BuildContext context) {
    final lines = ref.watch(cartProvider);
    final total = ref.watch(cartTotalProvider);
    final scheme = Theme.of(context).colorScheme;

    if (lines.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Кошик')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Кошик порожній'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => ref.read(tabIndexProvider.notifier).state = 0,
              child: const Text('Перейти до товарів'),
            ),
          ]),
        ),
      );
    }

    final overLimit = total / AppConfig.eurUah > AppConfig.customsLimitEur;
    return Scaffold(
      appBar: AppBar(title: const Text('Кошик')),
      body: CustomScrollView(slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => CartLineTile(line: lines[i]),
            childCount: lines.length,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Разом', style: TextStyle(fontSize: 18)),
                Text(formatUah(total), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 12),
              if (overLimit)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Сума понад €${AppConfig.customsLimitEur.toStringAsFixed(0)}: посилка може підлягати розмитненню, податки сплачуються окремо.',
                    style: TextStyle(color: scheme.onTertiaryContainer),
                  ),
                ),
              const Text('Отримувач', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _fio,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'ПІБ', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Телефон, +380…', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              const Text('Нова пошта', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final c in kCities)
                  ChoiceChip(label: Text(c), selected: _city == c, onSelected: (_) => setState(() => _city = c)),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: _branch,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Номер відділення', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _paying ? null : () => _pay(lines, total),
                  child: _paying
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text('Сплатити ${formatUah(total)}'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Оплата карткою, Apple Pay або Google Pay на сторінці банку. Підсумкову суму перевіряє сервер.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class CartLineTile extends ConsumerWidget {
  const CartLineTile({super.key, required this.line});

  final CartLine line;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.read(cartProvider.notifier);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 72,
            height: 72,
            child: line.product.images.isEmpty
                ? const Icon(Icons.image_outlined)
                : ProductImage(line.product.images.first, cacheWidth: 200),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(line.product.title, maxLines: 2, overflow: TextOverflow.ellipsis)),
              IconButton(
                tooltip: 'Видалити',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                onPressed: () => cart.remove(line.key),
              ),
            ]),
            if (line.selection.isNotEmpty) Text(line.selection.values.join(', '), style: theme.textTheme.bodySmall),
            Row(children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => cart.setQty(line.key, line.qty - 1),
              ),
              Text('${line.qty}'),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => cart.setQty(line.key, line.qty + 1),
              ),
              const Spacer(),
              Text(formatUah(line.totalUah), style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          ]),
        ),
      ]),
    );
  }
}
