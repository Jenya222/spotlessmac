---
id: proc.virtualization
kind: process
title: Виртуальная машина на фреймворке Apple (com.apple.Virtualization.VirtualMachine)
summary: Это запущенная виртуальная машина, например Docker Desktop или UTM. Она держит выданную ей память, пока работает: уменьшите лимит или остановите её.
verdict: caution
aliases: [виртуальная машина, виртуалка, vm, virtualization, виртуализация, гостевая система]
keywords: [память, оперативка, ram, docker, utm, контейнеры, линукс, эмулятор, процессор, cpu, много памяти, занимает]
processes: [com.apple.Virtualization.VirtualMachine]
related: [app.docker, guide.memory-pressure, guide.high-swap]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://developer.apple.com/documentation/virtualization, https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/memorysize, https://docs.docker.com/desktop/settings-and-maintenance/settings/, https://docs.docker.com/desktop/features/vmm/, https://docs.getutm.app/settings-apple/virtualization/]
---
## Что это
Фреймворк Virtualization от Apple позволяет программам запускать виртуальные машины с macOS или Linux. Процесс com.apple.Virtualization.VirtualMachine — это такая машина в работе. Им пользуются, например, Docker Desktop (если выбрана виртуализация Apple) и UTM. В списках процессов не видно, чья это машина, поэтому смотрите, какие из таких программ запущены.

## Норма
Виртуальной машине выдаётся фиксированный объём памяти. По документации Apple, он резервируется сразу, но занимается постепенно — по мере того как гостевая система использует страницы. Поэтому потребление растёт во время работы и обычно не возвращается Mac, пока машина не остановлена.

## Почему растёт
Гостевая система занимает страницы памяти по мере необходимости, поэтому потребление приближается к выданному лимиту. Docker Desktop по умолчанию выдаёт своей виртуальной машине до половины памяти Mac.

## Что делать
Во вкладке «Память» в SpotlessMac найдите запущенные программы с виртуальными машинами. Уменьшите объём памяти для машины в настройках программы: в Docker Desktop это «Settings → Resources → Advanced → Memory limit». Остановите машины, которые не нужны: корректно закройте гостевую систему или завершите программу, и память вернётся Mac.

## Чего не делать
Не завершайте этот процесс принудительно: гостевая система выключится без штатного завершения, и работа внутри неё может потеряться. Не задавайте машине больше памяти, чем нужно: остальным программам её не хватит.
