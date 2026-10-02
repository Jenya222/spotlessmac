import Foundation

struct DockerStorageSummary: Sendable {
    let virtualDiskAllocatedBytes: Int64?
    let engineReclaimableBytes: Int64?
    var report: CleanupReport?
    static func parseReclaimable(_ output: String) -> Int64? {
        var total: Int64 = 0
        var rowCount = 0
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)(B|kB|KB|MB|GB|TB)(?: \([0-9]+%\))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in output.split(whereSeparator: \.isNewline) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let kind = row["Type"] as? String, ["Images", "Containers", "Local Volumes", "Build Cache"].contains(kind),
                  let text = row["Reclaimable"] as? String,
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let amountRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
                  let number = Double(text[amountRange]) else { return nil }
            let units: [String: Double] = ["B": 1, "kB": 1_000, "KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000, "TB": 1_000_000_000_000]
            guard let multiplier = units[String(text[unitRange])] else { return nil }
            let bytes = number * multiplier
            guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max - total) else { return nil }
            total += Int64(bytes.rounded()); rowCount += 1
        }
        return rowCount > 0 ? total : nil
    }
}
