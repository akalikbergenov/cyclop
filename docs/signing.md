# Подпись и нотаризация

Релиз подписывается сертификатом Developer ID и нотаризуется у Apple. Тогда
приложение открывается с первого раза, без «Открыть всё равно», а подменённый
файл внутри бандла не запускается вовсе (#20). Делает это раннер в
`release.yml`; ему нужны пять секретов. Как их получить — ниже, один раз.

Локальная сборка (`Scripts/bundle.sh`) остаётся ad-hoc и ничего из этого не
требует.

## 1. Сертификат Developer ID Application

Xcode не нужен, хватает Command Line Tools и Связки ключей.

1. **Запрос сертификата.** Связка ключей → меню Связка ключей → Ассистент
   сертификации → Запросить сертификат у бюро сертификации. Почта аккаунта
   разработчика, имя любое, «Сохранён на диск». Закрытый ключ при этом ложится
   в связку ключей login — он и есть половина сертификата, экспортировать
   потом придётся именно из этой связки.
2. **Выпуск.** [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list)
   → «+» → **Developer ID Application** (не Installer, не Mac App
   Distribution) → загрузить запрос → скачать `.cer` → двойной клик, чтобы он
   лёг в login.
3. **Проверка.**
   ```sh
   security find-identity -v -p codesigning
   ```
   Должна быть строка `"Developer ID Application: Имя (TEAMID)"`. Если
   сертификат виден, но помечен как невалидный, не хватает промежуточного
   сертификата Apple: скачать **Developer ID - G2** с
   [apple.com/certificateauthority](https://www.apple.com/certificateauthority/)
   и тоже открыть двойным кликом.

## 2. Экспорт для раннера

Связка ключей → Мои сертификаты → правой кнопкой по «Developer ID
Application: …» → Экспортировать → формат `.p12`, придумать пароль. Файл
содержит и сертификат, и закрытый ключ: после загрузки в секреты удалить.

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12
gh secret set DEVELOPER_ID_P12_PASSWORD      # спросит пароль от .p12
```

## 3. Ключ нотаризации

[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Пользователи
и доступ → Интеграции → App Store Connect API → Team Keys → «+». Имя любое,
роль **Developer** — большего нотаризации не нужно. Записать **Key ID** и
**Issuer ID** (сверху страницы), скачать `.p8` — Apple отдаёт его **один
раз**, второй раз не скачать.

```sh
gh secret set NOTARY_KEY_ID                  # Key ID
gh secret set NOTARY_ISSUER_ID               # Issuer ID
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8
```

## 4. Проверить локально до первого релиза

Один раз положить ключ в связку ключей под именем профиля, чтобы не держать
его в окружении:

```sh
xcrun notarytool store-credentials cyclop \
    --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer 00000000-0000-0000-0000-000000000000
```

Потом собрать релизный образ так же, как это сделает раннер:

```sh
CODESIGN_IDENTITY="Developer ID Application: Имя (TEAMID)" \
NOTARIZE=1 NOTARY_PROFILE=cyclop \
./Scripts/dmg.sh
```

Скрипт нотаризует приложение, потом образ, скрепляет билеты к обоим и в
конце сам спрашивает Gatekeeper. Если он дошёл до «готово», образ откроется
на любом Mac с первого раза. Проверить всё равно стоит на машине, где Cyclop
ещё не запускали: разница между «у меня работает» и «у него открылось» — и
есть суть проверки (#20).

## Что где лежит

| Секрет | Что это |
|---|---|
| `DEVELOPER_ID_P12` | сертификат с ключом, base64 |
| `DEVELOPER_ID_P12_PASSWORD` | пароль от него |
| `NOTARY_KEY_ID` | Key ID ключа App Store Connect |
| `NOTARY_ISSUER_ID` | Issuer ID команды |
| `NOTARY_KEY_P8` | сам ключ `.p8`, base64 |

Без первых двух раннер собирает ad-hoc и релиз по тегу не выпускает; пробный
прогон (ручной запуск `release.yml`) работает и без них.

Сертификат Developer ID действует пять лет, ключ App Store Connect не
истекает, пока его не отозвать. Оба можно отозвать на тех же страницах, где
выпускали, — это единственное, что надо сделать, если секреты утекли.
