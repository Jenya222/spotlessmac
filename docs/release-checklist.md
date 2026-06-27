# Release Checklist

## 1. Apple Developer Account

Требуется платный аккаунт Apple Developer ($99/год).
Без него нотаризация невозможна и пользователи получат "приложение повреждено".

## 2. Team ID

Открой: https://developer.apple.com/account → Membership Details → **Team ID** (10 символов, например `AB12CD34EF`).

Вставить в:
- `ExportOptions.plist` → `<string>TODO_YOUR_10_CHAR_TEAM_ID</string>`
- `scripts/build-release.sh` → `TEAM_ID="TODO_10_CHARS"`

## 3. Developer ID Application (сертификат)

Создать на: https://developer.apple.com/account → Certificates → Developer ID Application.

После создания он появится в Keychain Access. Полное имя вида:
```
Developer ID Application: Evgeniy Bespalov (AB12CD34EF)
```

Или найти через терминал:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Вставить в `scripts/build-release.sh`:
```bash
DEVELOPER_ID_APP="Developer ID Application: Evgeniy Bespalov (AB12CD34EF)"
```

## 4. Notarytool credentials (один раз перед первым релизом)

```bash
xcrun notarytool store-credentials "spotlessmac-notary" \
  --apple-id "your@apple.id" \
  --team-id "AB12CD34EF" \
  --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password: appleid.apple.com → Sign-In and Security → App-Specific Passwords
```

## 5. Ed25519 keypair для лицензий (один раз)

```bash
openssl genpkey -algorithm ed25519 -out license_private.pem
openssl pkey -in license_private.pem -pubout -out license_public.pem
openssl pkey -in license_public.pem -pubin -outform DER | tail -c 32 | xxd -i
```

Вывод `xxd -i` вставить в `SpotlessMac/Licensing/LicenseValidator.swift` → `publicKeyBytes`.

`license_private.pem` хранить только локально (в .gitignore).

## 6. Store URL (Lemon Squeezy или Gumroad)

После создания продукта в MoR вставить ссылку в `SpotlessMac/App/ActivationView.swift`:
```swift
URL(string: "https://your-store.lemonsqueezy.com/buy/...")
```

## 7. Финальная сборка

```bash
bash scripts/build-release.sh
```

## 8. Проверка после сборки

```bash
spctl --assess --type exec --verbose SpotlessMac.app
xcrun stapler validate SpotlessMac.app
codesign -d --entitlements :- SpotlessMac.app
```
