"""
Готовит Android-часть проекта (папку android/, созданную командой `flutter create`):
разрешения INTERNET и POST_NOTIFICATIONS, deep links, minSdk 23, имя приложения и applicationId.
Запуск из корня проекта: python3 tools/prepare_android.py
Переменные: PUBLIC_HOST (домен для ссылок), APP_ID (по умолчанию ua.shovk.app).
"""
import os
import re
import sys
from pathlib import Path

HOST = os.environ.get("PUBLIC_HOST", "api.example.com")
APP_ID = os.environ.get("APP_ID", "ua.shovk.app")
APP = Path("android/app")


def fail(msg: str) -> None:
    sys.exit("prepare_android: " + msg)


# ---- AndroidManifest.xml
manifest = APP / "src/main/AndroidManifest.xml"
if not manifest.exists():
    fail("нет файла " + str(manifest))
s = manifest.read_text(encoding="utf-8")

if "android.permission.INTERNET" not in s:
    perms = (
        '\n    <uses-permission android:name="android.permission.INTERNET"/>'
        '\n    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>'
    )
    s, n = re.subn(r"<manifest[^>]*>", lambda m: m.group(0) + perms, s, count=1)
    if n != 1:
        fail("не найден тег <manifest>")

s = re.sub(r'android:label="[^"]*"', 'android:label="Шовк"', s, count=1)

if "flutter_deeplinking_enabled" not in s:
    links = f"""
            <meta-data android:name="flutter_deeplinking_enabled" android:value="false"/>
            <intent-filter android:autoVerify="true">
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="https" android:host="{HOST}" android:pathPrefix="/item"/>
                <data android:scheme="https" android:host="{HOST}" android:pathPrefix="/pay/return"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="shovk"/>
            </intent-filter>
        </activity>"""
    s, n = re.subn(r"</activity>", lambda m: links, s, count=1)
    if n != 1:
        fail("не найден тег </activity>")
manifest.write_text(s, encoding="utf-8")

# ---- build.gradle(.kts): minSdk 23 и applicationId
gradle = next((APP / n for n in ("build.gradle.kts", "build.gradle") if (APP / n).exists()), None)
if gradle is None:
    fail("не найден android/app/build.gradle")
t = gradle.read_text(encoding="utf-8")
t = re.sub(r"minSdk(Version)?(\s*=\s*|\s+)flutter\.minSdkVersion", lambda m: f"minSdk{m.group(1) or ''}{m.group(2)}23", t)
t = re.sub(r'applicationId(\s*=\s*|\s+)"[^"]+"', lambda m: f'applicationId{m.group(1)}"{APP_ID}"', t)
gradle.write_text(t, encoding="utf-8")

if not re.search(r"minSdk(Version)?(\s*=\s*|\s+)23\b", t):
    print("ВНИМАНИЕ: minSdk не удалось выставить в 23, проверьте build.gradle вручную")
if APP_ID not in t:
    print("ВНИМАНИЕ: applicationId не заменён, проверьте build.gradle вручную")
print(f"Android подготовлен: applicationId={APP_ID}, домен ссылок={HOST}")
