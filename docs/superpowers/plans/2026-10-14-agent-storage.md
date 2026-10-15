# Agent Storage Implementation Plan

**Goal:** Мониторинг и безопасная ручная очистка данных ИИ-агентов.
**Architecture:** Scanner + value-type report + MainActor view model; очистка через ScanEngine.
**Tech Stack:** Swift 6, SwiftUI, Foundation, XCTest, macOS 14.
**Spec:** ../specs/2026-10-14-agent-storage-design.md

## Ограничения
Whitelist only; trash only; preview before delete; Git/project/session protection;
Assistant изолирован. Никаких сетевых запросов или команд Git в анализаторе.

## План
- [x] Fixture-тесты классификации и обхода: AgentStorageTests.swift.
- [x] AgentStorageModels.swift, AgentStorageCatalog.swift, AgentStorageScanner.swift:
  источники, bounded discovery, анализ, агрегаты, рекомендации, отмена.
- [x] SafetyRules, ScanCategory, ScanEngine, OwnerActivityChecker: whitelist,
  повторная проверка перед удалением, процессы владельцев, интеграция Scanner.
- [x] AgentStorageViewModel.swift и тесты: снимок выбора, busy/лицензия, ошибки.
- [x] AgentStorageView.swift, ContentView, CareRailView: вкладка, обзор, список,
  фильтры, Finder, выбор корня, предпросмотр очистки.
- [x] Xcode project registration, build, targeted/full tests, review, UI smoke test.

## Review focus
Корень/ссылка подменены после scan; вложенные Git/проекты; свежие вложенные файлы;
неполный обход; пересекающиеся корни и повторный запуск действий.

## Решения
Работа в текущем чистом checkout. Реализация прямо запрошена пользователем;
дополнительные этапы согласования не нужны. Worktree только просмотр: trash и
git worktree remove имеют разные гарантии. Перенос — рекомендация, не действие.

## Проверка выполнения
483 XCTest прошли без ошибок. Финальная Debug-сборка — BUILD SUCCEEDED.
Xcode при одном полном прогоне сообщил об ошибке сохранения .xcresult, сам прогон
завершён TEST SUCCEEDED; текстовый вывод всех тестов сохранён отдельно.
Независимое ревью: исправлены обход через старую категорию кэшей и uninstall,
варианты регистра Git, symlink aliases, неполное чтение соседних папок.
UI: на реальных источниках проверены сводка, поиск, выбор и предпросмотр с отменой;
пользовательские данные не удалялись. По итогам UI проверки раскрытие рекомендаций
сделано явной доступной кнопкой, повторная сборка успешна.
Дополнительно: справочная статья и retrieval eval для новой категории; новые пути
включены в существующую маскировку личных имён для облачного Ассистента.
