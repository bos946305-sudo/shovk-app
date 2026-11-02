/// Настройки приложения. Меняются при запуске через --dart-define, например:
/// flutter run --dart-define=USE_MOCK=false --dart-define=API_BASE=http://10.0.2.2:8000
class AppConfig {
  AppConfig._();

  /// true: данные демонстрационные, бэкенд не нужен.
static const bool useMock = bool.fromEnvironment('USE_MOCK', defaultValue: false);

  /// Адрес бэкенда. 10.0.2.2 — ваш компьютер, если смотреть из Android-эмулятора.
static const String apiBase = String.fromEnvironment('API_BASE', defaultValue: 'https://shovk-app.onrender.com');

  /// Тот же, что APP_TOKEN на бэкенде. Нужен только чтобы получить гостевой JWT.
  static const String appToken = String.fromEnvironment('APP_TOKEN');

  /// Домен для ссылок «поделиться» и deep links (тот же, что PUBLIC_URL на бэкенде, без https://).
  static const String publicHost = String.fromEnvironment('PUBLIC_HOST', defaultValue: 'api.example.com');

  static const String sentryDsn = String.fromEnvironment('SENTRY_DSN');

  /// Включайте после настройки Firebase (push и аналитика).
  static const bool useFirebase = bool.fromEnvironment('USE_FIREBASE', defaultValue: false);

  /// Для предупреждения о растаможке. Сейчас лимит без налогов 150 евро; правила меняются, следите за законом.
  static const double eurUah = 48.0;
  static const double customsLimitEur = 150.0;
}

const List<String> kCategories = ['Усе', 'Одяг', 'Взуття', 'Аксесуари', 'Електроніка', 'Дім', 'Сумки'];
const List<String> kCities = ['Київ', 'Львів', 'Одеса', 'Харків', 'Дніпро'];

/// Статусы заказа по порядку (индекс = status в заказе, -1 = ждёт оплаты).
const List<String> kOrderSteps = [
  'Оплачено',
  'Викуплено у продавця',
  'Прибуло на склад у Гуанчжоу',
  'Перевірено (QC, фото)',
  'В дорозі до України',
  'На митниці',
  'Передано в Нову пошту',
  'Прибуло у відділення',
];

/// С этого статуса доступен фотоотчёт со склада.
const int kQcStep = 3;
