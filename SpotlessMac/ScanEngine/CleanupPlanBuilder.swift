import Foundation

enum CleanupPlanBuilder {
    static func make(items: [ScanItem]) throws -> [ScanItem] {
        var result: [ScanItem] = []
        for item in items.filter({ $0.isSelected && $0.cleanupPolicy.canDelete }).sorted(by: { PathPolicy.canonical($0.path).count < PathPolicy.canonical($1.path).count }) {
            let path = PathPolicy.canonical(item.path)
            if let ancestor = result.first(where: { PathPolicy.contains(path, in: PathPolicy.canonical($0.path)) }) {
                guard ancestor.cleanupPolicy.disposition == item.cleanupPolicy.disposition else { throw CocoaError(.fileWriteNoPermission) }
                continue
            }
            result.append(item)
        }
        return result
    }
    static func validationFailure(for item: ScanItem, allowsPath: (URL) -> Bool = SafetyRules.isSafe) -> String? {
        guard item.cleanupPolicy.canDelete, allowsPath(item.path) else { return "Путь не разрешён правилами безопасности." }
        guard let current = StorageFileIdentity.read(item.path), !current.isSymbolicLink,
              current.isDirectory || current.isRegularFile else { return "Объект исчез или изменил тип. Сканируйте снова." }
        if let captured = item.identity, current != captured { return "Объект изменился после предпросмотра. Сканируйте снова." }
        if item.cleanupPolicy.requiresClosedOwner && item.identity == nil { return "Не удалось подтвердить идентичность объекта." }
        return nil
    }
}
