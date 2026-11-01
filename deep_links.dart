import 'dart:async';

import 'package:app_links/app_links.dart';

enum DeepLinkKind { item, payReturn }

class DeepLink {
  const DeepLink(this.kind, this.value);

  final DeepLinkKind kind;

  /// item: "taobao:123456789" (платформа:ID), payReturn: номер заказа.
  final String value;
}

const _platforms = ['taobao', '1688', 'pdd'];

/// Понимает ссылки:
///   https://домен/item/123456            (платформа taobao, или ?p=1688)
///   https://домен/item/1688/123456
///   shovk://item/1688/123456
///   https://домен/pay/return?order=CN-XXXX   и   shovk://pay/return?order=CN-XXXX
DeepLink? parseDeepLink(Uri uri) {
  final isWeb = uri.scheme == 'http' || uri.scheme == 'https';
  // В ссылке shovk://item/123 слово «item» попадает в host, а не в path.
  final segs = <String>[if (!isWeb && uri.host.isNotEmpty) uri.host, ...uri.pathSegments]
      .where((s) => s.isNotEmpty)
      .toList();
  if (segs.length < 2) return null;
  final digits = RegExp(r'^\d+$');

  if (segs[0] == 'item') {
    if (segs.length == 2 && digits.hasMatch(segs[1])) {
      final p = uri.queryParameters['p'];
      return DeepLink(DeepLinkKind.item, '${_platforms.contains(p) ? p : 'taobao'}:${segs[1]}');
    }
    if (segs.length >= 3 && _platforms.contains(segs[1]) && digits.hasMatch(segs[2])) {
      return DeepLink(DeepLinkKind.item, '${segs[1]}:${segs[2]}');
    }
  }
  if (segs[0] == 'pay' && segs[1] == 'return') {
    final order = uri.queryParameters['order'];
    if (order != null && RegExp(r'^[A-Z0-9-]{3,32}$').hasMatch(order)) {
      return DeepLink(DeepLinkKind.payReturn, order);
    }
  }
  return null;
}

class DeepLinkService {
  DeepLinkService(this.onLink);

  final void Function(DeepLink link) onLink;
  StreamSubscription<Uri>? _sub;
  String? _lastUri;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> start() async {
    final links = AppLinks();
    _sub = links.uriLinkStream.listen(_handle);
    final initial = await links.getInitialLink(); // приложение было закрыто и открылось по ссылке
    if (initial != null) _handle(initial);
  }

  void _handle(Uri uri) {
    final now = DateTime.now();
    // Первую ссылку плагин может отдать и в потоке, и через getInitialLink: гасим дубль.
    if (uri.toString() == _lastUri && now.difference(_lastAt).inSeconds < 2) return;
    _lastUri = uri.toString();
    _lastAt = now;
    final link = parseDeepLink(uri);
    if (link != null) onLink(link);
  }

  void dispose() {
    _sub?.cancel();
  }
}
