---
id: app.electron
kind: app
title: Slack, Discord, VS Code, Cursor и Teams — почему они прожорливы
summary: Slack, Discord, VS Code и Cursor — это встроенный браузер Chromium, поэтому они прожорливы. Закрывайте их полностью, кэш пересоздастся.
verdict: safe
aliases: [Slack, Discord, дискорд, Microsoft Teams, тимс, Visual Studio Code, VS Code, vscode, Cursor, электрон, electron]
keywords: [память, оперативка, процессор, cpu, helper, renderer, чат, мессенджер, редактор, тормозит, фон, кэш, грузит]
bundles: [com.tinyspeck.slackmacgap, com.hnc.Discord, com.microsoft.teams2, com.microsoft.VSCode, com.todesktop.230313mzl4w4u92]
related: [path.user-caches, guide.memory-pressure, guide.login-items]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://www.electronjs.org/docs/latest/, https://www.electronjs.org/docs/latest/tutorial/process-model, https://www.electronjs.org/apps, https://code.visualstudio.com/docs/supporting/FAQ, https://cursor.com/docs/configuration/migrations/vscode, https://forum.cursor.com/t/cursor-bundle-identifier/779, https://support.apple.com/ru-ru/guide/mac-help/mchl834d18c2/mac, https://learn.microsoft.com/en-us/microsoftteams/troubleshoot/teams-administration/clear-teams-cache]
---
## Что это
Slack, Discord, Visual Studio Code и Cursor построены на Electron: этот каркас встраивает в каждую программу браузерный движок Chromium. Cursor основан на кодовой базе VS Code. Каждая такая программа приносит с собой свой браузер и работает в нескольких процессах: главном, по одному на окно и вспомогательных. Новая версия Microsoft Teams ушла от Electron, но советы ниже подходят и ей.

## Норма
Эти программы занимают заметный объём памяти и состоят из нескольких процессов (helper, renderer) даже в простое. Чем больше окон, чатов, расширений и открытых проектов, тем больше расход.

## Почему растёт
Работа идёт внутри веб-страниц: чаты с картинками и видео, звонки, редакторы с расширениями и языковыми серверами. Если закрыть окно, программа обычно остаётся запущенной в фоне.

## Что делать
Выходите из программ, которыми не пользуетесь: закрытие окна не завершает программу, нужно выбрать «Завершить [название]» в меню или нажать ⌘Q. Во вкладке «Память» в SpotlessMac эти процессы сгруппированы по ролям, и видно, какая программа занимает больше всего. В редакторах сохраните файлы перед выходом. Кэши этих программ обычно пересоздаются при следующем запуске: Microsoft предупреждает, что после очистки первый запуск Teams может быть дольше обычного. Поэтому найденные SpotlessMac кэши можно удалять: всё попадает в Корзину и при необходимости восстанавливается.

## Чего не делать
Не завершайте процессы helper и renderer по одному в «Мониторинге системы»: окно программы перестанет работать, а несохранённый текст может пропасть. Не очищайте кэш Teams при проблемах с чатами и каналами: по словам Microsoft, это не поможет и удалит журналы для диагностики.
