# SpotlessMac

Безопасный cleaner ненужных файлов для macOS (кеши, логи, dev-кеши, корзина).

Распространение: Developer ID + нотаризация. Без Mac App Store, без sandbox, с Full Disk Access.

## Архитектура

```
SpotlessMac/
├── App/            @main App + главное окно (тонкие SwiftUI-вью без логики)
├── Models/         ScanItem, ScanCategory — данные, Sendable
├── ScanEngine/     Scanner (протокол), ScanEngine (actor), SafetyRules
└── ViewModels/     ScanViewModel (@Observable @MainActor)
```

**Поток данных:**
```
View → ScanViewModel.scan() → ScanEngine.scan() → [Scanner] → [ScanItem]
View → ScanViewModel.delete() → ScanEngine.delete() → FileManager.trashItem
```

## Железные правила безопасности

1. **Whitelist-подход** — `SafetyRules.allowedRoots` перечисляет единственные директории, которые разрешено сканировать. Никакого обхода всего диска.
2. **Только Корзина** — удаление исключительно через `FileManager.trashItem`. Метод `removeItem` запрещён.
3. **Обязательный предпросмотр** — пользователь видит список путей и размеров перед любым удалением.
4. **Запрещённые пути** — `SafetyRules.forbiddenPrefixes`: `/System`, `/private/var/vm` (swap), `/dev`, `/cores`.
5. `SafetyRules.isSafe(_:)` вызывается перед каждым удалением в `ScanEngine.delete()`.

## Технический стек

- Swift 6.0, SwiftUI, macOS 14+
- `@Observable` (Observation framework) для ViewModels
- `actor ScanEngine` — файловые операции изолированы от main actor
- `async/await` для всего I/O

## Сборка

Открыть `SpotlessMac.xcodeproj` в Xcode 16+, выбрать свою команду разработчика в настройках таргета, `Cmd+R`.

CLI: `xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" build`
