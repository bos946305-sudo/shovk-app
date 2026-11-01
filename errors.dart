/// Ошибка обращения к бэкенду. [retryable]: есть ли смысл показывать кнопку «Повторити».
class ApiException implements Exception {
  const ApiException(this.message, {this.retryable = true});
  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

String errorText(Object error) =>
    error is ApiException ? error.message : 'Щось пішло не так. Спробуйте ще раз.';

bool canRetry(Object error) => error is! ApiException || error.retryable;
