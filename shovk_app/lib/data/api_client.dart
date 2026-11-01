import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/errors.dart';
import '../services/token_storage.dart';

/// HTTP-клиент бэкенда. При первом запросе сам получает гостевой JWT и хранит его в защищённом хранилище.
class ShovkApiClient {
  ShovkApiClient(this._tokens, {http.Client? client}) : _client = client ?? http.Client();

  final TokenStorage _tokens;
  final http.Client _client;
  String? _jwt;

  Future<dynamic> get(String path, {Map<String, String>? query}) => _send('GET', path, query: query);

  Future<dynamic> post(String path, {Object? body}) => _send('POST', path, body: body);

  /// Товар по ссылке, ID или "platform:id".
  Future<Map<String, dynamic>> getItem(String ref) async {
    final m = RegExp(r'^(taobao|1688|pdd):(\d+)$').firstMatch(ref);
    final query = m == null ? {'ref': ref} : {'ref': m.group(2)!, 'platform': m.group(1)!};
    return await get('/api/v1/item', query: query) as Map<String, dynamic>;
  }

  Future<String> _token() async {
    final saved = _jwt ?? await _tokens.readJwt();
    if (saved != null) {
      _jwt = saved;
      return saved;
    }
    final res = await _send('POST', '/api/v1/auth/guest', auth: false) as Map<String, dynamic>;
    final token = res['token'] as String;
    await _tokens.saveJwt(token);
    _jwt = token;
    return token;
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool auth = true,
    bool retry = true,
  }) async {
    final uri = Uri.parse('${AppConfig.apiBase}$path').replace(queryParameters: query);
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (auth) 'Authorization': 'Bearer ${await _token()}',
        if (!auth && AppConfig.appToken.isNotEmpty) 'X-App-Token': AppConfig.appToken,
      };
      final request = method == 'GET'
          ? _client.get(uri, headers: headers)
          : _client.post(uri, headers: headers, body: jsonEncode(body ?? <String, dynamic>{}));
      final res = await request.timeout(const Duration(seconds: 20));
      if (res.statusCode == 401 && auth && retry) {
        // токен просрочен или недействителен: получаем новый гостевой и повторяем запрос один раз
        _jwt = null;
        await _tokens.clear();
        return _send(method, path, query: query, body: body, retry: false);
      }
      if (res.statusCode >= 200 && res.statusCode < 300) return jsonDecode(utf8.decode(res.bodyBytes));
      throw _fromStatus(res.statusCode);
    } on TimeoutException {
      throw const ApiException('Сервер не відповів вчасно. Перевірте з’єднання.');
    } on http.ClientException {
      throw const ApiException('Немає з’єднання з сервером. Перевірте інтернет.');
    }
  }

  ApiException _fromStatus(int code) {
    if (code == 400) {
      return const ApiException('Не вдалося обробити запит. Перевірте дані або посилання на товар.', retryable: false);
    }
    if (code == 401) return const ApiException('Немає доступу до сервера. Спробуйте пізніше.', retryable: false);
    if (code == 404) return const ApiException('Не знайдено.', retryable: false);
    if (code == 503) return const ApiException('Оплата тимчасово недоступна. Спробуйте пізніше.');
    return const ApiException('Сервер тимчасово недоступний. Спробуйте ще раз.');
  }
}
