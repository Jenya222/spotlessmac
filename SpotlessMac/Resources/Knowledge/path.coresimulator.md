---
id: path.coresimulator
kind: path
title: CoreSimulator — симуляторы Xcode и их данные
summary: Симуляторы устройств Xcode вместе с данными установленных в них приложений. Не удаляйте папку вручную: лишние симуляторы убирайте средствами Xcode.
verdict: caution
aliases: [CoreSimulator, симулятор, симуляторы, iOS Simulator, симулятор айфона, Devices and Simulators, Device Hub]
keywords: [xcode, simulator, runtime, данные приложений, платформы, components, симулятор занимает место, виртуальное устройство]
paths: [~/Library/Developer/CoreSimulator]
related: [app.xcode, path.xcode-deriveddata, path.xcode-device-support]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components, https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub, https://help.apple.com/xcode/mac/current/en.lproj/dev8fe7ff80c.html]
---
## Что это
Папка Library/Developer/CoreSimulator — хранилище симуляторов iPhone, iPad, Apple Watch и других устройств, которые создаёт Xcode. Каждый симулятор — отдельное виртуальное устройство со своими данными: установленные приложения, их базы, настройки, тестовые учётные записи. Сами системы для симуляторов (платформы) устанавливаются и удаляются отдельно, в настройках Xcode.

## Норма
Симулятор создаётся на каждую пару «устройство и версия системы», поэтому за годы работы с Xcode набираются гигабайты.

## Почему растёт
Каждая новая версия Xcode и новая система добавляют свои симуляторы, а старые остаются. Приложения, которые вы запускали в симуляторе, тоже копят данные.

## Что делать
Удаляйте ненужные симуляторы в самом Xcode: меню Window → Devices and Simulators, вкладка Simulators, выбрать симулятор и удалить. В новейшей версии Xcode это окно называется Device Hub (Xcode → Open Developer Tool → Device Hub): симулятор убирается командой Remove в контекстном меню. Старые системы для симуляторов удаляются в Xcode → Settings → Components, раздел Other Installed Platforms: кнопка информации, затем Delete (в старых версиях Xcode раздел назывался Platforms). Если понадобится другая версия, Xcode скачает её снова. Данные внутри удалённого симулятора пропадут.

## Чего не делать
Не удаляйте папку целиком в Finder и не делайте этого при запущенных Xcode или Simulator: пропадут все симуляторы и данные их приложений. Не путайте её с DerivedData: там лежат промежуточные файлы сборки, и они восстанавливаются сами.
