---
id: path.xcode-device-support
kind: path
title: Xcode DeviceSupport — символы подключённых устройств
summary: Символы системы iPhone, iPad и Apple Watch для отладки. Старые версии удалять безопасно: Xcode скопирует нужные при следующем подключении устройства.
verdict: safe
aliases: [iOS DeviceSupport, watchOS DeviceSupport, device support, символы устройств, поддержка устройств xcode]
keywords: [xcode, iphone, ipad, apple watch, отладка, символы, версия ios, обновление ios, разработка, подключение устройства]
paths: [~/Library/Developer/Xcode/iOS DeviceSupport, ~/Library/Developer/Xcode/watchOS DeviceSupport]
related: [app.xcode, path.xcode-deriveddata, path.coresimulator]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://developer.apple.com/documentation/xcode/acquiring-operating-system-symbol-information, https://developer.apple.com/forums/thread/664896]
---
## Что это
В папках iOS DeviceSupport и watchOS DeviceSupport внутри Library/Developer/Xcode Xcode хранит символы системных библиотек устройств: отдельная подпапка на каждую модель и версию системы, которые вы подключали к Mac. Они нужны для отладки на реальном устройстве и для разбора отчётов о сбоях. По документации Apple, Xcode сам копирует эти данные с каждого подключённого устройства. Для tvOS и visionOS существуют такие же папки.

## Норма
Одна версия системы может занимать несколько гигабайт, поэтому у разработчика с несколькими устройствами эта папка заметно растёт.

## Почему растёт
Каждое обновление системы на подключённом устройстве добавляет новую подпапку, а старые Xcode не удаляет.

## Что делать
Закройте Xcode и удалите подпапки старых версий системы (найти их можно во вкладке «Диск» в SpotlessMac или в Finder): файлы уйдут в Корзину. Нужные символы Xcode скопирует заново при следующем подключении устройства. Первое подключение после очистки займёт больше времени.

## Чего не делать
Не удаляйте символы версии, по которой собираетесь разбирать отчёты о сбоях, если устройства с этой версией у вас уже нет: как поясняют на форуме разработчиков Apple, такие символы появляются только после подключения устройства с этой версией системы. Не удаляйте папки во время отладки на устройстве. Не путайте их с симуляторами (CoreSimulator) и с архивами Xcode: архивы с собранными приложениями сами не восстановятся.
