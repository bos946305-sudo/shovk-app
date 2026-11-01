import 'package:flutter/material.dart';

import '../../core/config.dart';

/// Вертикальный таймлайн статусов заказа. [status] = -1: ждёт оплаты, все шаги впереди.
class OrderTimeline extends StatelessWidget {
  const OrderTimeline({super.key, required this.status});

  final int status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      for (var i = 0; i < kOrderSteps.length; i++)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: 32,
              child: Column(children: [
                _Dot(done: i <= status),
                if (i < kOrderSteps.length - 1)
                  Expanded(child: Container(width: 2, color: i < status ? scheme.primary : scheme.outlineVariant)),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Text(
                  kOrderSteps[i],
                  style: TextStyle(
                    fontWeight: i == status ? FontWeight.w700 : FontWeight.w400,
                    color: i <= status ? null : scheme.outline,
                  ),
                ),
              ),
            ),
          ]),
        ),
    ]);
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.done});

  final bool done;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? scheme.primary : scheme.surface,
        border: Border.all(color: done ? scheme.primary : scheme.outline, width: 2),
      ),
      child: done ? Icon(Icons.check, size: 12, color: scheme.onPrimary) : null,
    );
  }
}
