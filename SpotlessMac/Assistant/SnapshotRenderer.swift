import Foundation

enum SnapshotRenderer {
    static let maxItems = 150
    static let maxCharacters = 32_000 // ≈ 8k tokens at ~4 chars/token
    private static let tailReserve = 2_000
    static let itemColumns = "ID | путь | размер | категория | политика | изменён | владелец | справка"

    // `formatPath` is applied to every path and every piece of user-derived text. The view model
    // passes a closure using PathRedactor.redact for home-prefixed paths and redactText otherwise.
    static func render(_ snapshot: SystemSnapshot, knowledge: KnowledgeContext = .none, formatPath: (String) -> String) -> String {
        var lines = ["Снимок системы на \(dateTime(snapshot.takenAt))."]
        if let volume = snapshot.volume {
            lines.append("Диск: «\(volume.name)», всего \(bytes(volume.totalBytes)), свободно \(bytes(volume.availableBytes)) (\(percent(volume.freeFraction))).")
        } else {
            lines.append("Диск: данные о томе недоступны.")
        }
        let fda = snapshot.fullDiskAccess.map { $0 ? "есть" : "нет" } ?? "неизвестно"
        lines.append("Полный доступ к диску: \(fda).")

        if let scanDate = snapshot.lastScanAt {
            let total = snapshot.items.reduce(Int64(0)) { $0 + $1.bytes }
            lines.append("Сканирование: \(dateTime(scanDate)), найдено \(snapshot.items.count) элементов на \(bytes(total)).")
            if !snapshot.categories.isEmpty {
                lines.append("Категории (id | название | объём | элементов | пакетная очистка):")
                for summary in snapshot.categories {
                    let batch = summary.category.isBatchCleanable ? "да" : "нет, только вручную"
                    lines.append("- \(summary.category.rawValue) | \(summary.category.displayName) | \(bytes(summary.bytes)) | \(summary.count) | \(batch)")
                }
            }
            if !snapshot.items.isEmpty {
                lines.append("Крупные элементы (\(itemColumns)):")
                var used = lines.reduce(0) { $0 + $1.count + 1 }
                var shown = 0
                for item in snapshot.items.prefix(maxItems) {
                    let line = itemLine(item, articleID: knowledge.annotations.items[item.shortID], formatPath: formatPath)
                    guard used + line.count + 1 <= maxCharacters - tailReserve else { break }
                    lines.append(line)
                    used += line.count + 1
                    shown += 1
                }
                if shown < snapshot.items.count {
                    lines.append("(показано \(shown) из \(snapshot.items.count); остальные доступны через list_items или по просьбе пользователя)")
                }
            }
        } else {
            lines.append("Сканирование: ещё не проводилось. Предложи пользователю нажать «Запустить сканирование».")
        }

        if let docker = snapshot.docker {
            let disk = docker.virtualDiskBytes.map(bytes) ?? "неизвестно"
            let reclaimable = docker.reclaimableBytes.map(bytes) ?? "неизвестно"
            lines.append("Docker: \(docker.status); виртуальный диск \(disk), можно освободить \(reclaimable).")
            for kind in docker.kinds {
                let risk = kind.dataLossCount > 0 ? ", с риском потери данных: \(kind.dataLossCount)" : ""
                lines.append("- \(kind.kindName): \(kind.count) шт., \(bytes(kind.bytes))\(risk)")
            }
        } else {
            lines.append("Docker: данные не загружены (вкладка Docker ещё не открывалась).")
        }

        if let leftovers = snapshot.leftovers {
            lines.append("Остатки программы «\(leftovers.appName)»: \(leftovers.count) элементов (точное совпадение: \(leftovers.exactCount), только по имени: \(leftovers.nameOnlyCount)), \(bytes(leftovers.bytes)).")
        }
        if let cleanup = snapshot.lastCleanup {
            let delta = cleanup.observedFreeSpaceDelta.map(bytes) ?? "не измерен"
            lines.append("Последняя очистка: в Корзину перемещено \(bytes(cleanup.trashedBytes)), наблюдаемый прирост свободного места \(delta).")
        }
        if let memory = snapshot.memory {
            var line = "Память: давление \(memory.load.label), занято \(memoryBytes(memory.usedBytes)) из \(memoryBytes(memory.physicalBytes)), своп \(memoryBytes(memory.swapUsedBytes))."
            if !memory.topApps.isEmpty {
                line += " Больше всего памяти занимают: "
                    + memory.topApps.map { app in
                        "\(app.name) — \(memoryBytes(app.bytes))" + tag(knowledge.annotations.apps[app.name])
                    }.joined(separator: ", ") + "."
            }
            lines.append(line)
            if !memory.topProcesses.isEmpty {
                // Names of non-system processes can be user scripts, so they go through formatPath.
                lines.append("Крупные процессы вне программ: " + memory.topProcesses.map { process in
                    "\(formatPath(process.name)) — \(memoryBytes(process.bytes))" + tag(knowledge.annotations.processes[process.name])
                }.joined(separator: ", ") + ".")
            }
        } else {
            lines.append("Память: данные не получены.")
        }
        if let section = KnowledgeRenderer.section(snapshot, context: knowledge) {
            lines.append(section)
        }
        return lines.joined(separator: "\n")
    }

    // `formatPath` is applied to every path and every piece of user-derived text (see `render`).
    static func itemLine(_ item: SnapshotItem, articleID: String? = nil, formatPath: (String) -> String) -> String {
        [item.shortID, formatPath(item.path), bytes(item.bytes), item.category.rawValue, item.disposition.code,
         item.modifiedAt.map(date) ?? "—", item.owner ?? "—", articleID ?? "—"].joined(separator: " | ")
    }

    // `formatPath` is applied to every path and every piece of user-derived text (see `render`).
    static func itemCard(_ item: SnapshotItem, articleID: String? = nil, formatPath: (String) -> String) -> String {
        var lines = [
            "ID: \(item.shortID)",
            "Путь: \(formatPath(item.path))",
            "Размер: \(bytes(item.bytes))",
            "Категория: \(item.category.rawValue) (\(item.category.displayName))",
            "Политика: \(item.disposition.code) — \(item.disposition.label)",
            "Причина: \(formatPath(item.reason))",
            "Изменён: \(item.modifiedAt.map(date) ?? "неизвестно")",
            "Владелец: \(item.owner ?? "—")",
            "Пакетная очистка: \(item.isBatchCleanable ? "да" : "нет, удаляется вручную")",
        ]
        if let articleID { lines.append("Справка: \(articleID)") }
        return lines.joined(separator: "\n")
    }

    private static func tag(_ id: String?) -> String { id.map { " [\($0)]" } ?? "" }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func memoryBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    static func date(_ value: Date) -> String { format(value, "yyyy-MM-dd") }
    static func dateTime(_ value: Date) -> String { format(value, "yyyy-MM-dd HH:mm") }
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    private static func format(_ value: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: value)
    }
}
