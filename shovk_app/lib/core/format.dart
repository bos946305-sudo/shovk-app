String formatUah(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('\u202F');
    b.write(s[i]);
  }
  return '$b ₴';
}

String formatCny(double v) => '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)} ¥';

String formatRate(double v) => v.toStringAsFixed(2).replaceAll('.', ',');

/// Похоже ли введённое на ссылку на товар или его ID.
bool looksLikeLink(String s) {
  final t = s.trim().toLowerCase();
  const hosts = ['taobao.com', 'tmall.com', '1688.com', 'yangkeduo.com', 'pinduoduo.com'];
  return hosts.any((h) => t.contains(h)) || RegExp(r'^\d{6,}$').hasMatch(t);
}
