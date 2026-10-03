---
id: app.xcode
kind: app
title: Xcode — память, симуляторы и место на диске
summary: Xcode занимает память при индексации, сборке и работе симуляторов, а на диске — DerivedData и симуляторы. Ненужное можно убрать в Settings.
verdict: caution
aliases: [Xcode, иксайд, иксбкод, симулятор, симуляторы, iOS симулятор]
keywords: [разработка, индексация, память, оперативка, ram, диск, место, симулятор, runtime, тормозит]
bundles: [com.apple.dt.Xcode]
related: [path.xcode-deriveddata, path.xcode-device-support, path.coresimulator, proc.dev-runtimes]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components, https://developer.apple.com/documentation/xcode-release-notes/xcode-15_2-release-notes, https://developer.apple.com/documentation/xcode-release-notes/xcode-16_2-release-notes, https://developer.apple.com/documentation/xcode]
---
## Что это
Среда разработки Apple для приложений на iPhone, Mac и других платформах. Она индексирует проекты, собирает их и запускает симуляторы устройств, поэтому нагружает память и процессор, а на диске оставляет много служебных данных.

## Норма
Заметный расход памяти при открытом большом проекте, во время индексации и сборки, а также пока запущены симуляторы. На диске накапливаются промежуточные файлы сборок, данные для подключённых устройств и симуляторы.

## Почему растёт
Открыто несколько проектов или окон, идёт сборка, работает несколько симуляторов сразу. Место занимают среды выполнения симуляторов для разных версий систем и платформ: они занимают много места, а старые остаются, пока вы их не удалите.

## Что делать
Закройте Xcode и симуляторы, когда не работаете. Для места откройте «Xcode → Settings → Components» (в Xcode 15 этот раздел называется «Platforms»): в «Other Installed Platforms» видны среды выполнения симуляторов и сколько места можно освободить; чтобы убрать ненужную, нажмите кнопку информации рядом с ней и выберите «Delete». О папках DerivedData, DeviceSupport и данных симуляторов см. связанные статьи; убирать их можно во вкладке «Диск» в SpotlessMac, пока Xcode закрыт.

## Чего не делать
Не удаляйте среду выполнения симулятора, которая нужна вам для работы: её придётся скачивать заново. Не удаляйте файлы во время сборки и не трогайте архивы собранных приложений (Archives): их Xcode не пересоздаст.
