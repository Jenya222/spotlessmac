# Исправления перед слиянием в main — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Устранить пять замечаний ревью и подготовить `feature/app-uninstaller` к локальному слиянию в `main`.

**Architecture:** Решение о принадлежности файлов приложения принимает отдельная чистая функция. Smart Care работает с неизменяемым списком подтверждённых файлов; результат и учёт лицензии принадлежат операции в `ScanViewModel`, а SwiftUI только отображает состояние. Удаление остаётся в движке с обязательной проверкой безопасности.

**Tech Stack:** Swift 6, SwiftUI, Observation, macOS 14+, Xcode, XCTest.

**Spec:** Пять замечаний ревью в этой беседе от 16 сентября 2026 года, воспроизведённые в критериях ниже; ограничения безопасности — `AGENTS.md` в корне проекта.

## Global Constraints

- Whitelist only: не расширять области сканирования и удаления ради этих исправлений.
- Trash only: использовать `FileManager.trashItem`, не добавлять `removeItem`.
- Preview before delete: до подтверждения видны пути и размеры файлов.
- `SafetyRules.isSafe(_:)` gates every delete call in `ScanEngine.delete()`; сохранить также проверки в потоковом удалении и деинсталляторе.
- Never touch: `/System`, `/private/var/vm`, `/dev`, `/cores`, пути вне whitelist.
- Сохранить `#if DEBUG` bypass в `LicenseManager.canClean`; Release проверяет лицензию.
- Не удалять и не перезаписывать исходные незакоммиченные изменения пользователя.
- В этой задаче нет редизайна, изменения сканеров или подготовки публичного релиза.
- Реальное удаление пользовательских файлов и запись в пользовательский Keychain не используются в автотестах.

## Критерии приёмки и принятые решения

1. Удаление Chrome не выбирает автоматически данные Chrome Canary или общий контейнер по одному сходству имени.
2. Подтверждение Smart Care сразу показывает список файлов с путями и размерами; при пустом выборе очистка недоступна.
3. Уход с экрана очистки не влияет на списание пробной попытки и сохранение результата.
4. Суммы в подтверждении пересчитываются при выборе; активная операция использует зафиксированный набор. Успешная очистка подмножества завершается на 100%.
5. Успех, частичный успех, полный отказ и отмена различаются; ошибки содержат путь и причину.

**Правило trial, предлагаемое этим планом:** одна операция расходует ровно одну попытку, если успешно перемещён хотя бы один объект, включая нулевой размер. Пустой запуск, полный отказ и отмена до первого успешного перемещения попытку не расходуют. Частичный успех и отмена после успешного перемещения расходуют одну попытку: иначе обход останется через отмену. Это уточнение поведения, а не уже существующее правило продукта.

## Task 1: Безопасное сопоставление файлов деинсталлятора

**Files:**
- Create: `SpotlessMac/Uninstall/LeftoverMatcher.swift`
- Modify: `SpotlessMac/Uninstall/UninstallEngine.swift`
- Modify: `SpotlessMac.xcodeproj/project.pbxproj`
- Create: `SpotlessMacTests/LeftoverMatcherTests.swift`
- Create: `SpotlessMac.xcodeproj/xcshareddata/xcschemes/SpotlessMac.xcscheme`

**Interfaces:** `LeftoverMatcher.isExact(component: String, bundleID: String, rootName: String) -> Bool`. Корень нужен для различения Preferences, Saved Application State, Containers и Group Containers.

- [ ] Добавить XCTest target `SpotlessMacTests`, dependency на приложение и shared scheme с Test action; включить новые файлы в соответствующие targets.
- [ ] Написать регрессионные тесты точности сопоставления:

```swift
import XCTest
@testable import SpotlessMac

final class LeftoverMatcherTests: XCTestCase {
    func testChromeDoesNotOwnCanaryPreferences() {
        XCTAssertFalse(LeftoverMatcher.isExact(
            component: "com.google.Chrome.canary.plist",
            bundleID: "com.google.Chrome", rootName: "Preferences"))
    }

    func testOwnPreferencesAreExact() {
        XCTAssertTrue(LeftoverMatcher.isExact(
            component: "com.google.Chrome.plist",
            bundleID: "com.google.Chrome", rootName: "Preferences"))
    }

    func testGroupContainerIsNeverExactByNameAlone() {
        XCTAssertFalse(LeftoverMatcher.isExact(
            component: "TEAM.com.google.Chrome",
            bundleID: "com.google.Chrome", rootName: "Group Containers"))
    }
}
```

- [ ] Запустить тесты и убедиться, что до реализации они не проходят.
- [ ] Реализовать только точные допустимые формы: `bundleID.plist` для Preferences, `bundleID.savedState` для Saved Application State, ровно `bundleID` для прочих индивидуальных корней. Group Containers никогда не считать exact по имени.
- [ ] Подключить matcher в `findLeftovers`. Старые prefix/suffix совпадения можно оставить кандидатами `.nameOnly`, `isSelected: false`; не повышать их уверенность обратно через другой путь. Сама выбранная `.app` остаётся exact.
- [ ] Добавить проверки `com.google.Chrome.canary`, совпадения без bundle ID и того, что неоднозначный кандидат не выбран. Для интеграционной проверки передавать движку список кандидатов/корней тестовой fixture, не обходить реальные Library.
- [ ] Запустить тесты и закоммитить только файлы задачи: `fix: avoid preselecting unrelated app leftovers`.

## Task 2: Видимый предпросмотр и единый набор выбранных файлов

**Files:**
- Modify: `SpotlessMac/App/SmartCareConfirmSheet.swift`
- Modify: `SpotlessMac/ViewModels/ScanViewModel.swift`
- Create: `SpotlessMac/Models/SmartCareRun.swift`
- Create: `SpotlessMacTests/SmartCareSelectionTests.swift`
- Modify: `SpotlessMac.xcodeproj/project.pbxproj`

**Interfaces:** `SmartCareRun` содержит `id: UUID`, `items: [ScanItem]`, `totalBytes: Int64`. `ScanViewModel.smartCareSelectedItems: [ScanItem]` и суммы подтверждения — вычисляемые свойства. `activeSmartCareRun: SmartCareRun?` — snapshot, который не меняется при удалении элементов из общего списка.

- [ ] Добавить регрессионный тест: два eligible файла размером 100 и 200, второй снят с выделения; выбранный объём равен 100, snapshot содержит только первый файл. `.largeFiles` не попадает в Smart Care даже при `isSelected == true`.
- [ ] Добавить тест пустого выбора: запуск не создаёт Task, не вызывает движок и не расходует trial.
- [ ] Убедиться, что тесты падают на текущем поведении; реализовать вычисляемые суммы из выбранного набора:

```swift
var smartCareSelectedItems: [ScanItem] {
    items.filter { smartCareCategories.contains($0.category) && $0.isSelected }
}

var smartCareSelectedBytes: Int64 {
    smartCareSelectedItems.reduce(0) { $0 + $1.size }
}
```

- [ ] На старте синхронно зафиксировать snapshot и установить флаг занятости до создания Task. Повторный старт при активной операции отклонять. Запретить повторную подготовку/сканирование, способные заменить данные текущей операции.
- [ ] Убрать скрывающий список DisclosureGroup: всегда показывать scrollable список с выбором, путём и размером. Сохранить полный путь доступным через tooltip, если строка обрезана. Кнопку отключать при пустом выборе или активной операции.
- [ ] Категории активной операции считать по snapshot; необработанные выбранные ID хранить отдельно от `items`. Не учитывать намеренно невыбранные файлы при завершении категории.
- [ ] Проверить тестами неизменность snapshot после изменения общего списка и завершение выбранного подмножества. Вручную проверить длинные пути, прокрутку, снятие всех галочек.
- [ ] Commit: `fix: preview and freeze selected Smart Care items`.

## Task 3: Результат операции и trial независимо от экрана

**Files:**
- Modify: `SpotlessMac/ViewModels/ScanViewModel.swift`
- Modify: `SpotlessMac/Models/SmartCareRun.swift`
- Modify: `SpotlessMac/ScanEngine/ScanEngine.swift`
- Modify: `SpotlessMac/App/CareDashboardView.swift`
- Modify: `SpotlessMac/App/CleaningProgressView.swift`
- Create: `SpotlessMacTests/SmartCareLifecycleTests.swift`

**Interfaces:** добавить `SmartCareOutcome: Equatable` с `.succeeded`, `.partialFailure`, `.failed`, `.cancelled`; результат содержит successful IDs, failures и unprocessed IDs. `startSmartCare(licenseManager: LicenseManager)` проверяет право запуска и удерживает зависимость до завершения Task. Для тестов добавить internal initializer с замыканиями удаления, проверки лицензии и записи результата, сохранив production defaults.

- [ ] Добавить управляемый fake удаления без файлового I/O и spy учёта. Проверить: без создания `CleaningProgressView` успешное завершение вызывает запись один раз; повторное отображение результата не вызывает запись снова.
- [ ] Добавить тесты: запрещённая лицензия не запускает движок; повторный старт не создаёт вторую операцию; пустой/неудачный запуск не списывает trial; успешный объект нулевого размера списывает; частичный успех и отмена после успеха списывают один раз.
- [ ] Перенести `recordClean()` из `.onChange` view в завершение операции. Применить правило по количеству успешных объектов, а не по `bytesFreedSoFar` или отсутствию ошибок.
- [ ] Перенести запись `lastSmartCareTimestamp` в тот же путь завершения, используя инъекцию хранилища для теста. Обновлять timestamp при наличии хотя бы одного успешного перемещения.
- [ ] В потоковом удалении выдавать отказ безопасности как `DeletionFailure`, а не молча пропускать объект. Оставить `SafetyRules.isSafe` непосредственно перед `trashItem`.
- [ ] Согласовать отмену производителя и потребителя: прекращать новые удаления между объектами, но сохранять итог уже завершённого `trashItem`. Не выходить из обработки события только из-за `Task.isCancelled`, потеряв успешное перемещение. Итог публиковать после остановки производителя.
- [ ] Проверить управляемыми событиями отмену до первого объекта, между объектами и во время последнего перемещения; успешные события не теряются, новые операции не стартуют до завершения текущей.
- [ ] Выполнить lifecycle tests и Commit: `fix: finalize Smart Care independently of view lifecycle`.

## Task 4: Честный прогресс и ошибки очистки

**Files:**
- Modify: `SpotlessMac/App/CleaningProgressView.swift`
- Modify: `SpotlessMac/Models/SmartCareRun.swift`
- Modify: `SpotlessMac/ViewModels/ScanViewModel.swift`
- Create: `SpotlessMacTests/SmartCareOutcomeTests.swift`

**Interfaces:** `SmartCareOutcome` из задачи 3 определяет итог; количество обработанных объектов определяет прогресс работы, успешные bytes — отдельный показатель освобождения места.

- [ ] Добавить тесты классификации результата: все успешны → succeeded; успехи + ошибки → partialFailure; только ошибки → failed; запрос отмены с оставшимися объектами → cancelled. Если последний объект уже завершён, поздняя отмена не меняет законченный результат на cancelled.
- [ ] Проверить вычисление прогресса: выбранный файл обработан → 100%, независимо от невыбранных файлов; нулевые размеры не приводят к делению на ноль. Не показывать freed bytes для отказов.
- [ ] Заменить универсальное «Готово» на точный статус:

```swift
switch outcome {
case .succeeded: "Очистка завершена"
case .partialFailure: "Очистка завершена с ошибками"
case .failed: "Не удалось выполнить очистку"
case .cancelled: "Очистка остановлена"
}
```

- [ ] Показать ошибки списком «путь — причина»; для отмены показать количество необработанных объектов. Категорию с ошибкой не помечать зелёным «очищено», после окончания не оставлять «в очереди».
- [ ] Вручную проверить четыре исхода с fake/fixtures, переход между вкладками и возврат. Удаление реальных данных для такой проверки не требуется.
- [ ] Выполнить тесты и Commit: `fix: show accurate Smart Care progress and failures`.

## Task 5: Проверки и условия слияния

- [ ] Выполнить полный новый набор XCTest:

```bash
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -configuration Debug \
  -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] Проверить обе конфигурации:

```bash
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -configuration Debug \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -configuration Release \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
bash -n scripts/install-local.sh scripts/install-local-debug.sh scripts/build-release.sh
```

- [ ] Проверить Release-путь лицензии с изолированным хранилищем и fake удаления: после одной успешной операции повторный запуск отклоняется. Debug bypass остаётся активным.
- [ ] Повторно провести ревью пяти исходных замечаний, отдельно проверить safety gates и гонку отмены. Все P1/P2 из этого плана должны быть закрыты.
- [ ] Перед слиянием разобрать исходные незакоммиченные файлы: `CLAUDE.md`, `LargeFilesView.swift`, `LicenseManager.swift`, `AGENTS.md`, `scripts/install-local-debug.sh` и HTML-макет. Не включать их автоматически через `git add .`; сохранить пользовательские правки, отдельно зафиксировать относящиеся к ветке изменения после проверки. Статус макета не должен решаться его удалением.
- [ ] Обновить refs через `git fetch origin`, проверить `git status`, актуальную `main` и возможность fast-forward. При выполнении прежнего поручения пользователя слить локально в `main`; повторное разрешение на уже запрошенное слияние не требуется. При новых блокерах оставить feature-ветку и описать их.
- [ ] После слияния проверить тесты итогового дерева и чистоту/ожидаемость git status. Push и публикация релиза в этот план не входят.

## Порядок и готовность

Задачи 1 → 2 → 3 → 4 → 5. Каждая заканчивается проверкой собственного поведения. Нет необходимости в параллельной реализации: задачи 2–4 меняют общий `ScanViewModel`.

Готово к слиянию, когда пять замечаний закрыты, регрессионные тесты проходят, Debug/Release собираются, новый diff проверен, а исходные пользовательские изменения сохранены и учтены явно.
