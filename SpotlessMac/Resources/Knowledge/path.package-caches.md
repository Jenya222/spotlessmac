---
id: path.package-caches
kind: path
title: Кэши менеджеров пакетов (Homebrew, npm, pnpm, Yarn, pip, uv)
summary: Пакеты, которые менеджеры скачали и хранят для повторного использования. Удалять безопасно: скачаются снова, но офлайн-установка может не сработать.
verdict: safe
aliases: [кэш homebrew, кэш npm, npm cache, pnpm store, yarn cache, pip cache, uv cache, кэш пакетов, кэши разработчика, dev кэши]
keywords: [homebrew, brew, npm, pnpm, yarn, pip, uv, python, node, скачанные пакеты, офлайн, разработка, зависимости, cache]
paths: [~/Library/Caches/Homebrew, ~/.npm, ~/Library/pnpm, ~/.pnpm-store, ~/Library/Caches/Yarn, ~/Library/Caches/pip, ~/.cache/pip, ~/.cache/uv]
categories: [developer_caches]
related: [guide.caches-explained, path.project-artifacts, path.ml-models, path.xcode-deriveddata]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://docs.brew.sh/Manpage, https://docs.npmjs.com/cli/v10/commands/npm-cache, https://pnpm.io/settings/store, https://pnpm.io/cli/setup, https://pip.pypa.io/en/stable/topics/caching/, https://classic.yarnpkg.com/en/docs/cli/cache, https://docs.astral.sh/uv/concepts/cache/]
---
## Что это
Менеджеры пакетов для программирования складывают скачанные пакеты в кэш, чтобы не загружать их повторно. Homebrew использует Library/Caches/Homebrew, npm — папку .npm, pnpm — общее хранилище store (на macOS внутри Library/pnpm, в некоторых установках — папка .pnpm-store), Yarn — Library/Caches/Yarn, pip — Library/Caches/pip или .cache/pip, uv — .cache/uv. К кэшам разработчика относятся и данные сборки Xcode, о них отдельная статья.

## Норма
Каждый такой кэш может занимать гигабайты. Homebrew сам удаляет старые загрузки (старше 120 дней), остальные менеджеры кэш не чистят: в документации npm прямо сказано, что очищать его нужно только ради места на диске.

## Почему растёт
Каждая установка и обновление добавляет пакеты, а прежние версии остаются в кэше.

## Что делать
Закройте терминалы и редакторы, в которых что-то устанавливается. Если SpotlessMac показывает такой кэш (во вкладке «Чистка» или в «Освободить место» во вкладке «Диск»), уберите его там: файлы уйдут в Корзину. Если нужного кэша в списке нет, воспользуйтесь средствами самого менеджера пакетов или перенесите папку кэша в Корзину в Finder. Нужные пакеты скачаются снова при следующей установке: она будет медленнее и потребует интернета.

## Чего не делать
Не чистите кэш перед поездкой или работой без сети, если собираетесь ставить пакеты офлайн: без кэша установка не сработает. Не удаляйте папку Library/pnpm целиком: кроме хранилища в ней может лежать сам pnpm и глобально установленные пакеты, а кэшем является только подпапка store. Не удаляйте кэш во время установки или обновления пакетов. Не путайте кэш с папками node_modules внутри проектов: это зависимости конкретного проекта, а не общий кэш.
