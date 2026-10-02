import Darwin
import Foundation

/// Takes one memory sample off the main thread.
actor MemoryMonitor {
    func sample() -> MemorySample {
        let system = SystemMemoryReader.current()
        let processes = ProcessMemoryReader.readAll()
        let runningApps = RunningAppsReader.current()
        return MemorySample(
            date: Date(),
            system: system,
            groups: ProcessGrouper.group(processes, runningApps: runningApps, currentUID: getuid()),
            runningApps: runningApps
        )
    }
}
