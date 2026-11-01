# Шовк: Flutter-клиент

Демо-режим работает сразу, без бэкенда. Экраны: каталог и поиск, карточка товара с вариантами (чипсы) и мгновенным пересчётом цены, корзина (сохраняется на устройстве), оформление и оплата, заказы с таймлайном из 8 статусов, фотоотчёт со склада.

## Запуск

Нужен готовый APK без установки Flutter: см. README_APK.md (сборка на GitHub).

```bash
flutter create shovk_app --platforms=android,ios
cd shovk_app
# из архива скопируйте поверх: lib/, test/, pubspec.yaml; удалите test/widget_test.dart
flutter pub get
flutter run
```

Название проекта должно быть `shovk_app` (на него ссылается тест). В демо-режиме введите в поиске «помилка», чтобы увидеть экран ошибки с кнопкой «Повторити».

## Режим с вашим бэкенд-сервером

```bash
flutter run --dart-define=USE_MOCK=false \
  --dart-define=API_BASE=http://10.0.2.2:8000 \
  --dart-define=APP_TOKEN=<тот же, что APP_TOKEN на сервере> \
  --dart-define=PUBLIC_HOST=api.ваш-домен.ua
```

Реально работает с бэкендом: товар по ссылке, заказы, оплата, статусы, фотоотчёт, регистрация устройства для push. Каталог и поиск на главной пока демонстрационные (на бэкенде их нет), поэтому в этом режиме заказ оформляется из товаров, добавленных по ссылке: вставьте ссылку Taobao, 1688 или Pinduoduo в строку поиска.

Другие параметры: `SENTRY_DSN=...`, `USE_FIREBASE=true` (после настройки Firebase).

## Структура

```
lib/core       калькулятор цены, форматирование, ошибки, настройки
lib/data       модели, запросы к бэкенду (api_client), репозитории (бэкенд и демо)
lib/state      Riverpod: каталог, корзина (с сохранением), заказы
lib/services   защищённое хранилище JWT, аналитика воронки, push, deep links
lib/ui         экраны и виджеты (скелетоны, ошибка с повтором, галерея, таймлайн)
```

## Настройка по пунктам

**Оплата (Monobank / LiqPay, Apple Pay, Google Pay).** Приложение не знает ключей эквайринга. Оно просит сервер создать заказ, получает ссылку на оплату и открывает её в браузере: на странице банка доступны карта, Apple Pay и Google Pay. После оплаты банк вызывает webhook сервера, и только сервер ставит статус «Оплачено». Возврат в приложение идёт по ссылке `shovk://pay/return?order=...`, экран оплаты опрашивает сервер. Настройка ключей и webhook описана в README бэкенда.

**Deep links (`https://домен/item/...`).** В `android/app/src/main/AndroidManifest.xml` добавьте:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<!-- внутри <activity android:name=".MainActivity" ...> -->
<meta-data android:name="flutter_deeplinking_enabled" android:value="false"/>
<intent-filter android:autoVerify="true">
  <action android:name="android.intent.action.VIEW"/>
  <category android:name="android.intent.category.DEFAULT"/>
  <category android:name="android.intent.category.BROWSABLE"/>
  <data android:scheme="https" android:host="api.ваш-домен.ua" android:pathPrefix="/item"/>
  <data android:scheme="https" android:host="api.ваш-домен.ua" android:pathPrefix="/pay/return"/>
</intent-filter>
<intent-filter>
  <action android:name="android.intent.action.VIEW"/>
  <category android:name="android.intent.category.DEFAULT"/>
  <category android:name="android.intent.category.BROWSABLE"/>
  <data android:scheme="shovk"/>
</intent-filter>
```

В `ios/Runner/Info.plist`: ключ `FlutterDeepLinkingEnabled` со значением `false` и `CFBundleURLTypes` со схемой `shovk`. В Xcode (Signing & Capabilities) добавьте Associated Domains: `applinks:api.ваш-домен.ua`. Сервер уже отдаёт `/.well-known/assetlinks.json` и `/.well-known/apple-app-site-association` (заполните `ANDROID_SHA256` и `IOS_APP_ID` в `.env`).

**Push (Firebase Cloud Messaging).** `dart pub global activate flutterfire_cli`, затем `flutterfire configure`. Для iOS загрузите ключ APNs в Firebase и включите в Xcode Push Notifications и Background Modes (Remote notifications). Запускайте с `USE_FIREBASE=true`. Сервер шлёт пуши при смене статуса: оплата получена, товар выкуплен, фотоотчёт готов, посылка прошла таможню, прибыло в отделение.

**Токены.** Гостевой JWT хранится только в `flutter_secure_storage` (iOS Keychain, Android Keystore). Ключей доступа к платёжным системам и RapidAPI в приложении нет. Если Android-сборка просит, поставьте `minSdk = 23` в `android/app/build.gradle`.

**Ошибки и аналитика.** Sentry: передайте `SENTRY_DSN`. События воронки (`view_item`, `add_to_cart`, `begin_checkout`, `payment_started`, `purchase`) уходят в Firebase Analytics при `USE_FIREBASE=true` и в «хлебные крошки» Sentry.

## Важно

Код написан без возможности скомпилировать его в среде разработки: Flutter SDK там нет. Сначала выполните `flutter analyze`; если появятся ошибки, пришлите их, и я исправлю. Платежи, push и deep links нужно проверять на реальных устройствах и в тестовом режиме Monobank и LiqPay.
