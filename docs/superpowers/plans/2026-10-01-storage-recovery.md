# Эффективное освобождение места — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Делегирование допускается только после явного выбора пользователя.

**Goal:** Доработать SpotlessMac для поиска реальных источников занятого места и выборочной очистки с понятным риском и измеренным результатом.

**Architecture:** Переиспользовать вкладки «Диск», «Программы», «Docker» и существующий ScanEngine. Добавить actor анализа, каталог источников и отдельную политику кандидатов; вычисления/файловый I/O вне MainActor, Observable view models на MainActor. Docker сохраняет собственную существующую границу команд.

**Tech Stack:** Swift 6, SwiftUI, Observation, Foundation, XCTest, существующий Docker CLI client; без новых зависимостей.

**Spec:** `docs/superpowers/specs/2026-10-01-storage-recovery-design.md`.

## Результат выполнения — 1 октября 2026

- [x] Этап A: отчёт Корзины/свободного места, ограниченный физический анализ, интерфейс источников.
- [x] Этап B: ручные кандидаты кэшей/HF, артефактов проектов и самостоятельных записей; правила активности/identity.
- [x] Этап C: размеры приложений с разбивкой, отдельная очистка кэша, оценка и перепроверка Docker.
- [x] Общая доменная проверка: `python3 scripts/test-domain.py` — 91 тест, 0 ошибок; fixture 50 000 файлов.
- [x] Debug `build-for-testing` и Release `build` — успешны; `git diff --check` и проверка pbxproj — успешны.
- [x] Независимое ревью: четыре важных замечания устранены; итоговые проверки повторены.
- [x] Документация и повторяемый direct XCTest runner.
- [x] Подготовлена отдельная локально подписанная Debug-копия из проверенной сборки, strict-проверка подписи прошла.
- [ ] Ручная приёмка окна: недоступны Orca GUI runtime/LaunchServices. Компиляция UI проверена, взаимодействие и layout не подтверждены.
- [ ] Коммиты/интеграция: `.git` доступен только для чтения; изменения сохранены в рабочей копии.

Ни пользовательские файлы, ни реальные Docker-ресурсы не очищались; Корзина не опустошалась.
Чек-листы ниже сохраняют исходную последовательность плана; состояние результата и ограничения
зафиксированы здесь. Подробности использования: `docs/storage-recovery.md`.

## Global Constraints

- macOS 14 minimum; Xcode 16.2; Swift 6 strict concurrency.
- No third-party dependencies.
- Сканирование и вычисление размеров выполняются вне MainActor; UI использует Observation.
- Сканирование ограничено явными разрешёнными корнями, без полного обхода диска.
- Файловое удаление использует только FileManager.trashItem, после предпросмотра и проверки SafetyRules.
- Не трогать /System, /private/var/vm, /dev, /cores.
- Сохранить Debug bypass лицензии; в Release проверять лицензию.
- Не запускать реальную очистку пользовательского Mac при разработке и проверке.
- Не перезаписывать существующие незакоммиченные изменения пользователя, в частности `project.pbxproj` и `CareRailView.swift`.
- Read whitelist и delete whitelist разделены: Library доступна для анализа, произвольного разрешения удаления в Library нет.
- Новые кандидаты из этого плана не выбираются автоматически и не включаются в Smart Care по одному признаку категории.
- Docker уже существует: сохранить snapshot, context/builder, повторную проверку использования и отдельное подтверждение томов.
- Не добавлять broad prune, удаление Docker.raw, очистку Корзины или новое исключение из Trash-only.

## Review Focus

1. Симлинк/смена типа объекта между preview и удалением: отказ, повторный анализ; тесты задач 2 и 4.
2. Скрытые файлы, hard links, sparse-файлы, облачные placeholders: корректный ограниченный подсчёт без загрузки облачных данных; тесты задачи 2.
3. Недоступные папки, отмена и устаревший результат: статус partial/denied, отменённый запуск не перезаписывает новый; тесты задачи 3.
4. Общие данные нескольких программ, HF snapshots и родитель/потомок: нет двойного подсчёта/удаления; тесты задач 4 и 6.
5. Корзина, общие слои Docker и посторонняя запись на диск: перемещение/оценка/изменение свободного места раздельны; тесты задач 1 и 7.

## Основание и поправки к первоначальному предложению

В текущем коде уже существуют `DiskOverviewView`, `DiskUsageView`, `DockerClient`,
`DockerCleanupViewModel`, `DockerCleanupView` и тесты Docker. Их развивать, не дублировать.
`DiskSpaceService.systemBytes` — остаток, не результат измерения категории macOS.
`FolderSizeCalculator` пропускает скрытые файлы. `InstalledApp` пока не хранит размер.

Диагностика Mac дала приоритеты: Docker ~64,7 ГиБ, HF cache ~22 ГиБ, записи Wooffoow
~19,3 ГиБ, AnythingLLM storage ~16,8 ГиБ, Cursor ~13,7 ГиБ, Claude ~9,9 ГиБ,
MyProjects ~31 ГиБ. Это объём источников, не обещание освобождения.
Docker показал ~10,26 ГБ reclaimable images и ~20,81 ГБ reclaimable volumes;
reclaimable volume может хранить нужную базу. Не сохранять персональные абсолютные
пути в продукт: использовать homeDirectoryForCurrentUser/явно выбранные корни.

## Карта файлов и ответственности

| Файлы | Ответственность |
|---|---|
| `Models/StorageMeasurement.swift`, `ScanEngine/VolumeSpaceReader.swift` | Логический/физический размер, доступность, измерение тома |
| `Models/CleanupReport.swift` | Итог операции и измеренное изменение свободного места |
| `ScanEngine/PathPolicy.swift`, `StorageAnalysisEngine.swift`, `StorageSourceCatalog.swift` | Ограниченный read-only анализ, каталог известных источников |
| `ViewModels/StorageAnalysisViewModel.swift` | Отмена, состояние анализа, выбранный источник |
| `ScanEngine/KnownCacheScanner.swift`, `HuggingFaceCacheScanner.swift`, `ProjectArtifactsScanner.swift`, `RecordingScanner.swift` | Только конкретные поддерживаемые кандидаты |
| `Models/CleanupPolicy.swift`, `ScanEngine/CleanupPlanBuilder.swift` | Риск, допустимое действие, неизменный набор удаления |
| `Uninstall/AppStorageService.swift`, `Models/AppStorageSummary.swift` | Размер программы и подтверждённо принадлежащих ей данных |
| `Docker/DockerStorageSummary.swift` | Результат Docker без суммирования общих слоёв |

Все пути в таблице относительно `SpotlessMac/`. Новые Swift-файлы и тесты добавлять
в соответствующие targets в `SpotlessMac.xcodeproj/project.pbxproj` в той задаче,
которой они нужны. Не создавать новую вкладку навигации.

## Порядок и команды проверки

Последовательность: **1 → 2 → 3 → 4 → 5 → 6 → 7 → 8**.
Этап A — 1–3; B — 4–5; C — 6–7. После каждого этапа есть рабочая сборка.
Задача 7 зависит от измерений задачи 1, а не требует переписывания задач 4–6.

Для каждого указанного ниже тестового класса запускать:

```bash
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/spotlessmac-storage-derived \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:SpotlessMacTests/CleanupReportTests
```

В задаче заменить последний класс на её перечисленные классы и добавить отдельный
`-only-testing:` для каждого класса. Сначала ожидается FAIL по конкретному новому
утверждению/отсутствующему типу, после реализации — PASS. Sandbox/environment failure
не считать красным тестом продукта: записать причину и использовать разрешённое окружение.
Каждый commit включает только файлы своей задачи; автоматически не stage весь репозиторий.

---

### Task 1: Честный результат файловой очистки

**Files:**
- Create: `SpotlessMac/Models/CleanupReport.swift`, `SpotlessMac/ScanEngine/VolumeSpaceReader.swift`.
- Modify: `SpotlessMac/ViewModels/ScanViewModel.swift`, `SpotlessMac/Models/SmartCareRun.swift`, `SpotlessMac/App/CleaningProgressView.swift`.
- Test: `SpotlessMacTests/CleanupReportTests.swift`, существующие `SmartCareOutcomeTests.swift` и `SmartCareLifecycleTests.swift`.

**Interfaces:** Produces `VolumeSample(volumeID: String, availableBytes: Int64, sampledAt: Date)` и `CleanupReport(trashedBytes: Int64, successfulItems: Int, before: VolumeSample?, after: VolumeSample?)`; свойство `observedFreeSpaceDelta: Int64?`. `VolumeSpaceReader.sample(at: URL) async throws -> VolumeSample`. Для операции на нескольких томах хранить отдельную пару измерений каждого тома; не смешивать их.

- [ ] Добавить регрессионные тесты:

```swift
func testTrashBytesAreIndependentOfFreeSpace() {
    let before = VolumeSample(volumeID: "data", availableBytes: 100, sampledAt: .distantPast)
    let after = VolumeSample(volumeID: "data", availableBytes: 100, sampledAt: .distantFuture)
    let report = CleanupReport(trashedBytes: 800, successfulItems: 1, before: before, after: after)
    XCTAssertEqual(report.trashedBytes, 800)
    XCTAssertEqual(report.observedFreeSpaceDelta, 0)
}
func testDifferentVolumesHaveNoComparableDelta() {
    let report = CleanupReport(trashedBytes: 1, successfulItems: 1,
        before: .init(volumeID: "a", availableBytes: 10, sampledAt: .distantPast),
        after: .init(volumeID: "b", availableBytes: 20, sampledAt: .distantFuture))
    XCTAssertNil(report.observedFreeSpaceDelta)
}
```

- [ ] Запустить `CleanupReportTests`, получить ожидаемый FAIL.
- [ ] Реализовать вычисление, не обрезая отрицательные изменения свободного места:

```swift
var observedFreeSpaceDelta: Int64? {
    guard let before, let after, before.volumeID == after.volumeID else { return nil }
    return after.availableBytes - before.availableBytes
}
```

- [ ] Читать `.volumeIdentifierKey`, `.volumeAvailableCapacityKey` и время до/после операции; отсутствие доступа возвращает ошибку измерения, не выдуманный ноль. Инъецировать reader для lifecycle tests; не менять success-only учёт trial.
- [ ] Заменить «Освобождено» на «Перемещено в Корзину», вывести отдельное изменение свободного места, дату измерения и пояснение о Корзине/других процессах. Старое `bytesFreedSoFar` переименовать вместе со всеми буквальными ссылками либо оставить совместимый alias на переходный период.
- [ ] Добавить тесты partial failure/cancel: учитывать только успешные перемещения; missing sample → неизвестное изменение; свободное место может уменьшиться из-за другой записи.
- [ ] Запустить три перечисленных класса; Debug build; commit `fix: distinguish trashed bytes from free disk space`.

### Task 2: Ограниченный анализ и корректное измерение папок

**Files:**
- Create: `SpotlessMac/Models/StorageMeasurement.swift`, `SpotlessMac/ScanEngine/PathPolicy.swift`, `SpotlessMac/ScanEngine/StorageSourceCatalog.swift`, `SpotlessMac/ScanEngine/StorageAnalysisEngine.swift`.
- Modify: `SpotlessMac/ScanEngine/SafetyRules.swift`, `SpotlessMac/ScanEngine/FolderSizeCalculator.swift`.
- Test: `SpotlessMacTests/StorageAnalysisEngineTests.swift`, `SpotlessMacTests/PathPolicyTests.swift`.

**Interfaces:** `StorageMeasurement(logicalBytes: Int64, allocatedBytes: Int64, unreadableEntries: Int, isComplete: Bool)`; `StorageNode(url: URL, measurement: StorageMeasurement, isDirectory: Bool, isPackage: Bool)`; `PathPolicy(readRoots: [URL]).canRead(_ url: URL) -> Bool`; `StorageAnalysisEngine(policy: PathPolicy).children(of: URL) async throws -> [StorageNode]`. `StorageSourceCatalog.roots(home: URL) -> [URL]` возвращает непересекающиеся верхние корни; вложенные shortcuts не прибавлять к сумме родителя.

- [ ] Создать тест разрешённого дочернего пути и запрета сходного префикса:

```swift
func testReadPolicyUsesPathComponents() {
    let policy = PathPolicy(readRoots: [URL(filePath: "/tmp/fixture/allowed")])
    XCTAssertTrue(policy.canRead(URL(filePath: "/tmp/fixture/allowed/cache")))
    XCTAssertFalse(policy.canRead(URL(filePath: "/tmp/fixture/allowed-other/cache")))
    XCTAssertFalse(policy.canRead(URL(filePath: "/System")))
}
```

- [ ] Запустить `PathPolicyTests` и `StorageAnalysisEngineTests`; проверить FAIL до реализации.
- [ ] Создать fixtures внутри временной папки: `.hidden/blob`, обычный файл, hard link, symlink наружу, sparse file. Ресурсы fixtures не удалять при этой работе; очистку fixtures в будущих тестах направить только на принадлежащий тесту temporary root.
- [ ] Реализовать обход с `.isSymbolicLinkKey`, `.isRegularFileKey`, `.isPackageKey`, `.fileSizeKey`, `.totalFileAllocatedSizeKey`, `.fileAllocatedSizeKey`, `.fileResourceIdentifierKey`, `.volumeIdentifierKey`, `.isUbiquitousItemKey` и `.ubiquitousItemDownloadingStatusKey`. Читать метаданные без открытия содержимого placeholders. Не следовать symlinks; shared resource IDs дедуплицировать в пределах одного агрегата; packages измерять внутри, но не выдавать их внутренности как кандидаты удаления.
- [ ] Ввести не более четырёх одновременно активных sizing workers, отмену между entries и structured async off-main работу; не создавать task на каждый файл. Ошибки доступа увеличивают `unreadableEntries`; полный размер не заявлять.
- [ ] Каталог read roots: существующие пользовательские roots, `/Applications`, `~/Applications`, `~/Library/Application Support`, `~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Developer`, `~/.cache`, `~/.npm/_cacache`, `~/.ollama/models`, `~/MyProjects`. Запрещённые prefixes проверять по границе компонента. В каталог не включать `/` и домашнюю папку как неограниченный recursive root. Пользовательский выбор новой папки требует регистрации конкретного root.
- [ ] Тесты: hidden file учтён; hard link не удвоен; sparse physical < logical; symlink наружу не перечислен; denied ≠ empty; placeholder не вызывает downloader; cancellation прекращает новые обходы. Для permission/placeholder случаев инъецировать metadata/enumeration provider, не зависеть от прав текущего процесса.
- [ ] Перевести старые consumers FolderSizeCalculator на новый механизм, сохранив исходные подписи методов как adapters до задачи 3. Run обе test suites; commit `feat: add scoped physical storage analysis`.

### Task 3: Разбор источников во вкладке «Диск»

**Files:**
- Create: `SpotlessMac/ViewModels/StorageAnalysisViewModel.swift`, `SpotlessMacTests/StorageAnalysisViewModelTests.swift`.
- Modify: `SpotlessMac/App/DiskOverviewView.swift`, `SpotlessMac/App/DiskUsageView.swift`, `SpotlessMac/ScanEngine/DiskSpaceService.swift`, `SpotlessMac/App/ContentView.swift`.

**Interfaces:** Consumes Task 2. `@Observable @MainActor StorageAnalysisViewModel` owns `nodes: [StorageNode]`, `isLoading: Bool`, `errorMessage: String?`, `scan(root: URL) async`, `cancel()`. Инъекция `loadChildren: @Sendable (URL) async throws -> [StorageNode]`. Каждый scan получает generation ID; публикация разрешена только текущему generation.

- [ ] Добавить controlled fake loader и тест: первая загрузка завершается позже второй; итог принадлежит второй. Тест отмены сохраняет предыдущий снимок с подписью «Не обновлён», а не выдаёт его за свежий.
- [ ] Запустить `StorageAnalysisViewModelTests`, подтвердить FAIL; реализовать guard перед публикацией:

```swift
let scanID = UUID()
activeScanID = scanID
let result = try await loadChildren(root)
guard activeScanID == scanID, !Task.isCancelled else { return }
nodes = result
```

- [ ] Перенести loading/cache/navigation из DiskUsageView в view model; хранить размер по каноническому пути и generation. Refresh инвалидирует только нужную ветку по компонентам пути; после очистки инвалидировать предков кандидата.
- [ ] В DiskOverviewView показать источники с drill-down, allocated size по умолчанию, logical size в деталях, полный путь через tooltip/Finder, статус доступа и время измерения. Не скрывать важные известные hidden sources. В первой версии использовать сортируемый список, без отдельной treemap/редизайна.
- [ ] В DiskSpaceService заменить `systemBytes` на `unclassifiedBytes`; включить `~/Applications`; документы измерять по явно заданным roots с дедупликацией пересечений. При incomplete показывать «Измерено» и «Остальной занятый объём» без выдуманной точности. Не пытаться воспроизвести категории Apple арифметикой.
- [ ] Добавить тесты denied source, empty source, missing source, refresh after cleanup; гарантировать, что `defer` старого scan не снимает loading нового scan.
- [ ] Debug build; вручную проверить длинные пути, клавиатуру, отсутствие FDA и отмену только анализа. Не подтверждать удаление. Commit `feat: explain major storage sources in disk overview`.

### Task 4: Известные кэши, HF и безопасный набор удаления

**Files:**
- Create: `SpotlessMac/Models/CleanupPolicy.swift`, `SpotlessMac/ScanEngine/KnownCacheScanner.swift`, `SpotlessMac/ScanEngine/HuggingFaceCacheScanner.swift`, `SpotlessMac/ScanEngine/CleanupPlanBuilder.swift`.
- Modify: `SpotlessMac/Models/ScanItem.swift`, `SpotlessMac/Models/ScanCategory.swift`, `SpotlessMac/ScanEngine/ScanEngine.swift`, `SpotlessMac/ScanEngine/SafetyRules.swift`, `SpotlessMac/App/StorageRecoveryView.swift`.
- Test: `SpotlessMacTests/KnownCacheScannerTests.swift`, `SpotlessMacTests/CleanupPlanTests.swift`, `SpotlessMacTests/HuggingFaceCacheScannerTests.swift`, `SpotlessMacTests/SafetyRulesTests.swift`.

**Interfaces:** `CleanupDisposition: Sendable { case rebuildable, redownload, personalData, inspectOnly }`; `CleanupPolicy(disposition: CleanupDisposition, reason: String, requiresClosedOwner: Bool)`; `ScanItem.cleanupPolicy` с default, сохраняющим поведение старых consumers. `CleanupPlanBuilder.make(items: [ScanItem]) throws -> [ScanItem]`. `KnownCacheScanner` и `HuggingFaceCacheScanner` conform `Scanner`. ScanItem содержит подтверждённый resource identity и type для revalidation; существующий initializer совместим через defaults.

- [ ] Написать тесты: новый кэш unselected; HF выбран только целым `models--org--name`/`datasets--org--name`/`spaces--org--name`; HF snapshots отдельно не выдаются; `Cursor/User` и `Claude/vm_bundles` не кандидаты; symlink repo отклонён; повторный root/родитель+потомок не удваивают план.
- [ ] Регрессионный тест неизменного выбора:

```swift
func testPlanRemovesExactDuplicates() throws {
    let item = ScanItem(path: URL(filePath: "/tmp/fixture/cache"),
                        size: 100, category: .userCaches, isSelected: true)
    let plan = try CleanupPlanBuilder.make(items: [item, item])
    XCTAssertEqual(plan.count, 1)
    XCTAssertEqual(plan.first?.size, 100)
}
```

- [ ] Запустить перечисленные suites; затем реализовать exact cache catalog: Cursor `Cache`, `Code Cache`, `CachedData`, `CachedExtensionVSIXs`; Claude `Cache`, `Code Cache`; `~/.cache/uv` и `~/.npm/_cacache`. У каждого правила явные owner и explanation; не использовать substring «cache» для всего Library. Новые category cases `.modelCaches`, `.projectArtifacts`, `.recordings`, `.knownAppCaches` не batch-cleanable.
- [ ] HF: сканировать только direct repo directories в `~/.cache/huggingface/hub`, включая blobs; показывать repo name и стоимость повторной загрузки. Cache xet и отдельные revision/blob операции в этой версии только просмотр, чтобы не ломать ссылки/не обещать экономию от удаления symlink snapshots. Проверка активности downloader обязательна; если активность неизвестна — отказ с объяснением.
- [ ] Сузить новую delete policy до конкретных каталогов; запретить удаление самих новых root directories. Не добавлять Application Support/Containers целиком в allowedRoots. `SafetyRules.isSafe(url:)` делегирует конкретным predicates, а новый preview entry point дополнительно проверяет identity/type/closed owner; повторить эти проверки в потоковом пути непосредственно перед `trashItem`.
- [ ] `CleanupPlanBuilder` отбрасывает unselected/inspectOnly, дублирующие пути, потомков выбранного родителя; при несовместимых policies отклоняет пересечение целиком. Симлинк/type/identity changed → per-item failure. Не выдавать fixture path за production whitelist: в тестах инъецировать policy/validator и fake trash boundary.
- [ ] Добавить fake-trash тесты: changed symlink/identity, owner running, unknown activity, неподдерживаемый тип, чужой path → spy вызван 0 раз; normal confirmed candidate → один точный вызов. В Smart Care явно запретить все новые review cases независимо от category/selected flag.
- [ ] Re-run SmartCareSelectionTests и новые suites; commit `feat: preview known cache and model cleanup candidates`.

### Task 5: Папки проектов и личные записи

**Files:**
- Create: `SpotlessMac/ScanEngine/ProjectArtifactsScanner.swift`, `SpotlessMac/ScanEngine/RecordingScanner.swift`.
- Modify: `SpotlessMac/ScanEngine/ScanEngine.swift`, `SpotlessMac/ScanEngine/SafetyRules.swift`, `SpotlessMac/App/StorageRecoveryView.swift`, `SpotlessMac/ScanEngine/StorageSourceCatalog.swift`.
- Test: `SpotlessMacTests/ProjectArtifactsScannerTests.swift`, `SpotlessMacTests/RecordingScannerTests.swift`.

**Interfaces:** `ProjectArtifactsScanner(roots: [URL])`, `RecordingScanner(root: URL)`, оба conform `Scanner`; результаты Task 4 с `.projectArtifacts`/`.recordings` и `isSelected: false`. Выбранный project root хранится в read registry и candidate validation policy, но сам root не удаляется.

- [ ] Добавить fixture тесты: project `package.json + node_modules`, Swift project `.build`, обычная папка `build` без маркеров, nested `.git`, `vendor`, `data.sqlite`, `.env`; ожидаемые кандидаты — только первые два. При обнаружении собственного git metadata внутри artifact candidate отклонить его; исходные repositories не candidate.
- [ ] Запустить `ProjectArtifactsScannerTests`; реализовать marker rules: `node_modules` только рядом с `package.json`; `.build` только рядом с `Package.swift`; `build` только с CMakeCache/проверенным generated marker без git metadata. Не выбирать `dist`, `vendor`, неизвестный `build` по имени. Прервать поиск внутри найденного artifact, чтобы не выдать тысячи вложенных candidates.
- [ ] Показывать проект, marker, physical size и объяснение «Потребуется переустановка зависимостей/пересборка»; старость проекта не делает его ненужным. При активном build/install либо неизвестной активности блокировать удаление нового candidate.
- [ ] Recording fixtures: две записи и неизвестный index/database sidecar; возвращать завершённые файлы записей поддерживаемого формата, index/db только просмотр. Root recordings не candidate; никаких preselection по возрасту. Если записи состоят из пакета связанных файлов и нет подтверждённого формата, пакет только просмотр.
- [ ] Для записей добавить Finder/Quick Look и immutable confirmation с путями/датами/размерами; проверять приложение закрыто. AnythingLLM storage, Claude vm bundles, Xcode DeviceSupport и JetBrains versions доступны в анализе с пояснением, но не в generic cleanup.
- [ ] Добавить тест отсутствующей папки и cancellation между проектами; прогнать обе suites и CleanupPlanTests. Commit `feat: review project artifacts and personal recordings`.

### Task 6: Общий размер приложений и раздельные действия

**Files:**
- Create: `SpotlessMac/Models/AppStorageSummary.swift`, `SpotlessMac/Uninstall/AppStorageService.swift`.
- Modify: `SpotlessMac/Uninstall/UninstallEngine.swift`, `SpotlessMac/ViewModels/UninstallViewModel.swift`, `SpotlessMac/App/UninstallerView.swift`, `SpotlessMac/Models/InstalledApp.swift`, `SpotlessMac/ScanEngine/SafetyRules.swift`.
- Test: `SpotlessMacTests/AppStorageServiceTests.swift`, `SpotlessMacTests/LeftoverMatcherTests.swift`.

**Interfaces:** `AppStorageSummary(appID: UUID, bundleBytes: Int64, cacheBytes: Int64, dataBytes: Int64, isComplete: Bool)`; `confirmedTotalBytes` — сумма трёх подтверждённых непересекающихся групп. `AppStorageService.summary(for: InstalledApp) async throws -> AppStorageSummary` consumes measurement from Task 2, existing matcher and exact known ownership catalog. Общие/неоднозначные directories показываются отдельными candidates, не включаются в confirmed total.

- [ ] Добавить pure ownership test с двумя приложениями: точно принадлежащий directory учитывается один раз; prefix-сходный и общий group container не входят в confirmed sum. Размер unknown/denied не отображается как 0. Добавить тест вложенного cache внутри data root: split исключает двойной подсчёт.
- [ ] Запустить `AppStorageServiceTests`; реализовать exact bundle-ID + проверенный app-name catalog, без автоматического доверия fuzzy match. Базовый принцип суммы:

```swift
var confirmedTotalBytes: Int64 { bundleBytes + cacheBytes + dataBytes }
```

Разделение групп до суммирования обязано удалять вложенные overlaps; shared data
остаётся в разделе «Общие/неподтверждённые данные».

- [ ] Загружать summary постепенно с максимум четырьмя workers и отменой. Сортировка по имени/общему размеру, unknown в конце; переиспользовать cache анализа, инвалидировать после действия. Не сканировать весь Library повторно для каждого приложения.
- [ ] В UI отдельно показать программу, кэш и личные данные; действия «Очистить поддерживаемый кэш» и «Удалить приложение» используют существующие разные engines. Для удаления приложения bundle может оставаться выбранным; personal data unselected даже при `.exact`; неоднозначные/shared candidates всегда unselected.
- [ ] Укрепить `SafetyRules.isSafeToUninstall`: канонические пути и component boundaries из Task 2, запрет root deletion/symlink escape; повторная проверка type/identity перед trashItem. Новое общее измерение не расширяет uninstall whitelist. Добавить fake-trash тест symlink leftover наружу: ноль destructive вызовов.
- [ ] Regression tests: Chrome не выбирает Canary; group container не выбран; отмена устаревшего summary не обновляет новый выбранный app; выбранный кэш не заставляет удалять bundle. Прогнать обе suites и SafetyRulesTests.
- [ ] Debug build и проверка сортировки без удаления; commit `feat: show applications with their storage breakdown`.

### Task 7: Доработать существующий Docker и связать с анализом

**Files:**
- Create: `SpotlessMac/Docker/DockerStorageSummary.swift`, `SpotlessMacTests/DockerStorageSummaryTests.swift`.
- Modify: `SpotlessMac/Docker/DockerCleanupViewModel.swift`, `SpotlessMac/App/DockerCleanupView.swift`, `SpotlessMac/App/DiskOverviewView.swift`.
- Test: существующие `DockerClientTests.swift`, `DockerScanParserTests.swift`, `DockerCleanupViewModelTests.swift`.

**Interfaces:** `DockerStorageSummary(virtualDiskAllocatedBytes: Int64?, engineReclaimableBytes: Int64?, report: CleanupReport?)`. Здесь `report.trashedBytes == 0`: Docker удаляет ресурсы через CLI, а не перемещает файлы. Engine-reclaimable — оценка Docker, никогда не сумма resource sizes; при отсутствии поддерживаемого ответа `nil`.

- [ ] Тест общих слоёв: два resource sizes по 100 не доказывают освобождение 200; estimated sum не попадает в report. Тест unavailable sample: UI сообщает неизвестное свободное место, не ноль.
- [ ] Запустить `DockerStorageSummaryTests`; реализовать pure model и reader physical VM size через read engine задачи 2. Измерять `Docker.raw`/поддерживаемый disk image только метаданными в зарегистрированном local Docker root. Если location изменён — явный выбор файла для чтения, не произвольный recursive поиск диска.
- [ ] Read-only оценку Docker получать через существующий runner с pinned context; поддерживаемый машинный формат system df parsing покрыть fixture. При неподдерживаемой версии выводить «Оценка недоступна» и существующий список ресурсов; не извлекать байты эвристикой из произвольного localized stdout.
- [ ] Подключить ссылку «Открыть Docker» из источника com.docker.docker; overview allocated file size и Docker engine resource estimates показать отдельно, без суммирования между ними. Если context удалённый — явно показать endpoint; локальную VM не приписывать удалённому daemon.
- [ ] Через инъекцию `VolumeSpaceReader` измерить before/after существующего `deleteConfirmed`; итог: resource success count, failures, оценка Docker, изменение свободного места Mac. Не обещать мгновенное уменьшение sparse VM; не запускать reclaim helper.
- [ ] Сохранить повторную проверку usage, контекста и builder перед каждым удалением; volume unselected и отдельное acknowledgment. Regression tests с fake runner: context changed/volume attached после preview → отсутствие destructive command; build cache unknown → не выбран; license failure → no delete.
- [ ] Запустить четыре Docker suites; live UI только read scan/preview. Commit `feat: report Docker storage and measured cleanup results`.

### Task 8: Общая приёмка и документация

**Files:**
- Create: `docs/storage-recovery.md` — понятная документация источников/риска/Корзины/Docker.
- Modify: только файлы предыдущих задач для найденных регрессий.

**Interfaces:** готовая к ревью последовательность изменений A/B/C; ни одно тестовое
действие не очищает текущие пользовательские файлы, volumes или images.

- [ ] Запустить полный XCTest suite на временных fixtures/fake runners:

```bash
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/spotlessmac-storage-derived \
  test CODE_SIGNING_ALLOWED=NO
```

- [ ] Сборка Release с сохранённой проверкой лицензии:

```bash
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/spotlessmac-storage-release \
  build CODE_SIGNING_ALLOWED=NO
```

- [ ] Проверить read-only сценарии: известные источники отображаются, hidden files видны,
  missing/denied различаются, новые candidates не выбраны, данные app раздельны,
  Docker uninstalled/stopped/remote context объяснены. Все destructive confirmations
  закрывать кнопкой отмены; никакой очистки/empty Trash в ручной проверке.
- [ ] Performance fixture: 50 000 небольших файлов в temporary root; подтвердить ограничение
  workers ≤4 через injected counter, responsiveness UI и остановку новых обходов после cancel.
  Не задавать обещание времени для всего пользовательского диска без baseline.
- [ ] Проверить `git diff --check`, границы whitelist и все `trashItem` call sites,
  API signatures, success-only trial, отсутствие новых shell/delete/prune путей.
- [ ] В документации дать таблицу inspect/rebuild/redownload/personalData, объяснение
  partial sizes/APFS и различие между Корзиной и свободным местом. Не писать «безопасно
  освободить 134 ГБ» по размеру категории macOS.
- [ ] Исправления safety/data-loss багов начинать с регрессионного failing test; повторять
  только затронутые suites и общий build после последнего изменения.
- [ ] Commit `docs: explain storage analysis and cleanup limits`; предоставить итоговые
  проверки/ограничения пользователю. Публикация, установка и запуск очистки в этот план не входят.

## Самопроверка плана

- Анализ реальных источников: задачи 2–3; новые кэши/модели: задача 4.
- Документы/крупные папки/записи: задача 5; размер приложений: задача 6.
- Существующий Docker и честный результат: задачи 7 и 1 соответственно.
- Все пять Review Focus закреплены указанными regression tests.
- Рассчитываемая экономия всегда отделена от текущего объёма/измеренного изменения.
- AnythingLLM, Claude VM и неизвестные Library данные имеют рабочий путь просмотра;
  неподтверждённые destructive adapters сознательно не входят в первую версию.
- Этапы A/B/C дают отдельно проверяемые версии; общий regression gate — задача 8.
