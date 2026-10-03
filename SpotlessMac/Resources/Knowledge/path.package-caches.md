---
id: path.package-caches
kind: path
title: Кэши менеджеров пакетов (Homebrew, npm, pnpm, Yarn, pip, uv)
summary: Пакеты, которые менеджеры скачали и хранят для повторного использования. Удалять безопасно: скачаются снова, но офлайн-установка может не сработать.
verdict: safe
aliases: [кэш homebrew, кэш npm, npm cache, pnpm store, yarn cache, pip cache, uv cache, кэш пакетов, кэши разработчика, dev кэши]
keywords: [homebrew, brew, npm, pnpm, yarn, pip, uv, python, node, скачанные пакеты, офлайн, разработка, зависимости, cache]
paths: [~/Library/Caches/Homebrew, ~/.npm, ~/Library/pnpm/store, ~/.pnpm-store, ~/Library/Caches/Yarn, ~/Library/Caches/pip, ~/.cache/pip, ~/.cache/uv]
categories: [developer_caches]
related: [guide.caches-explained, path.project-artifacts, path.ml-models, path.xcode-deriveddata]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://docs.brew.sh/Manpage, https://docs.npmjs.com/cli/v10/commands/npm-cache, https://pnpm.io/settings/store, https://pnpm.io/cli/setup, https://pip.pypa.io/en/stable/topics/caching/, https://classic.yarnpkg.com/en/docs/cli/cache, https://docs.astral.sh/uv/concepts/cache/]
---
## Что это
Менеджеры пакетов для программирования складывают скачанные пакеты в кэш, чтобы не загружать их повторно. Homebrew использует Library/Caches/Homebrew, npm — папку .npm, pnpm — хранилище store (на macOS — Library/pnpm/store, в некоторых установках — папка .pnpm-store), Yarn — Library/Caches/Yarn, pip — Library/Caches/pip или .cache/pip, uv — .cache/uv. К кэшам разработчика относятся и данные сборки Xcode, о них отдельная статья.

## Норма
Каждый такой кэш может занимать гигабайты. Homebrew сам удаляет старые загрузки (старше 120 дней), остальные менеджеры кэш не чистят: в документации npm прямо сказано, что очищать его нужно только ради места на диске.

## Почему растёт
Каждая установка и обновление добавляет пакеты, а прежние версии остаются в кэше.

## Что делать
Закройте терминалы и редакторы, в которых что-то устанавливается. Если нужный кэш есть в списке SpotlessMac, уберите его там: кэши внутри Library/Caches (Homebrew, pip, Yarn) считаются пользовательскими и убираются во вкладке «Уход» или в «Диск» → «Освободить место»; кэши npm и uv показаны в «Диск» → «Освободить место», в блоке «ПРОВЕРЬТЕ»: у каждой записи есть «Переместить в Корзину». Если кэша в списке нет, воспользуйтесь средствами самого менеджера пакетов или перенесите папку кэша в Корзину в Finder: папки с точкой в имени (.npm, .cache) скрыты, откройте их через «Переход → Переход к папке» (Shift-Command-G) или покажите скрытые файлы сочетанием Shift-Command-точка. Нужные пакеты скачаются снова при следующей установке: она будет медленнее и потребует интернета.

## Чего не делать
Не чистите кэш перед поездкой или работой без сети, если собираетесь ставить пакеты офлайн: без кэша установка не сработает. Не удаляйте остальное содержимое Library/pnpm: кроме хранилища store там может лежать сам pnpm и глобально установленные пакеты. Не удаляйте кэш во время установки или обновления пакетов. Не путайте кэш с папками node_modules внутри проектов: это зависимости конкретного проекта, а не общий кэш.
