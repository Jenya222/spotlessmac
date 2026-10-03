---
id: app.telegram
kind: app
title: Telegram — кэш медиа и автоочистка
summary: Telegram накапливает кэш фото и видео из чатов. Его можно чистить и настроить автоудаление: файлы из облачных чатов скачаются снова.
verdict: safe
aliases: [Telegram, телеграм, телега, телеграмм, Telegram Lite, Telegram Desktop]
keywords: [кэш, медиа, фото, видео, файлы, место, диск, чистка, чаты, хранилище, использование памяти, занимает много]
bundles: [ru.keepcoder.Telegram, org.telegram.desktop, com.tdesktop.Telegram]
related: [path.user-caches, guide.optimize-storage, guide.large-media]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://telegram.org/faq, https://telegram.org/blog/hidden-media-zero-storage-profile-pics, https://telegram.org/blog/cache-and-stickers, https://translations.telegram.org/en/macos/settings/, https://translations.telegram.org/ru/macos/settings/, https://raw.githubusercontent.com/telegramdesktop/tdesktop/dev/Telegram/Resources/langs/lang.strings]
---
## Что это
Мессенджер Telegram. Фото, видео и файлы из чатов он сохраняет на диск Mac как кэш. У Telegram для Mac два официальных приложения: Telegram для macOS и Telegram Desktop (версия из Mac App Store называется Telegram Lite).

## Норма
Кэш растёт по мере того, как вы листаете чаты и каналы: чем больше медиа вы открываете, тем больше он занимает. При активной переписке в группах и каналах его объём может стать большим.

## Почему растёт
Telegram сохраняет в кэш то, что вы открывали или скачивали из личных чатов, групп и каналов: фото, видео и файлы.

## Что делать
В Telegram для macOS откройте «Данные и память → Использование памяти» (в английской версии «Data and Storage → Storage Usage»). Там можно очистить кэш по типам файлов, а параметр «Keep Media» (по-русски «Хранить файлы») удаляет из кэша файлы, к которым вы давно не обращались: срок задаёте вы. В Telegram Desktop такого экрана нет: откройте «Settings → Advanced → Manage local storage» (подписи в английском интерфейсе). На экране «Local storage» есть кнопка «Clear all» и ограничение «Clear files older than». По словам Telegram, файлы из облачных чатов снова скачиваются из облака, когда вы их открываете.

## Чего не делать
Не удаляйте файлы из папки данных Telegram вручную через Finder: используйте очистку в настройках. Секретные чаты хранятся только на устройствах, а не в облаке, поэтому их файлы заново из облака не скачать. Если файл нужен надолго, сохраните его в другое место заранее.
