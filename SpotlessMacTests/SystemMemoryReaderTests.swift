import Darwin
import XCTest
@testable import SpotlessMac

final class SystemMemoryReaderTests: XCTestCase {
    func testSnapshotMatchesActivityMonitorBreakdown() {
        let pages = VMPageCounts(free: 50, wired: 200, internalPages: 1000, externalPages: 300, purgeable: 100, compressor: 400)
        let snapshot = SystemMemoryReader.snapshot(pages: pages, pageSize: 16384, physical: 1 << 34,
                                                   swapUsed: 7, swapTotal: 9, pressureLevel: 2)
        XCTAssertEqual(snapshot.appMemory, 900 * 16384)
        XCTAssertEqual(snapshot.cachedFiles, 400 * 16384)
        XCTAssertEqual(snapshot.wired, 200 * 16384)
        XCTAssertEqual(snapshot.compressed, 400 * 16384)
        XCTAssertEqual(snapshot.used, (900 + 200 + 400) * 16384)
        XCTAssertEqual(snapshot.swapUsed, 7)
        XCTAssertEqual(snapshot.swapTotal, 9)
        XCTAssertEqual(snapshot.pressure, .warning)
    }

    func testPurgeableAboveInternalClampsToZero() {
        let pages = VMPageCounts(internalPages: 10, purgeable: 20)
        let snapshot = SystemMemoryReader.snapshot(pages: pages, pageSize: 4096, physical: 1, swapUsed: 0, swapTotal: 0, pressureLevel: nil)
        XCTAssertEqual(snapshot.appMemory, 0)
    }

    func testPressureLevelMapping() {
        XCTAssertEqual(MemoryPressure(sysctlLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(sysctlLevel: 2), .warning)
        XCTAssertEqual(MemoryPressure(sysctlLevel: 4), .critical)
        XCTAssertEqual(MemoryPressure(sysctlLevel: 3), .unknown)
        XCTAssertEqual(MemoryPressure(sysctlLevel: nil), .unknown)
    }

    /// Smoke test: notices if a future macOS drops the private responsibility symbol.
    func testResponsibilitySymbolResolves() {
        XCTAssertNotNil(ResponsibilityResolver.live.responsiblePID(for: getpid()))
    }

    func testLiveReadersReturnPlausibleData() {
        let system = SystemMemoryReader.current()
        XCTAssertEqual(system.physical, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(system.used, 0)
        XCTAssertNotEqual(system.pressure, .unknown)

        let processes = ProcessMemoryReader.readAll()
        let me = processes.first { $0.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertFalse(me?.isPartial ?? true)
        XCTAssertGreaterThan(me?.footprint ?? 0, 0)
        XCTAssertEqual(me?.uid, getuid())
    }
}
