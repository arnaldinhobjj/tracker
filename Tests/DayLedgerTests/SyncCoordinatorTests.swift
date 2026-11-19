import XCTest
@testable import DayLedger

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    typealias Steps = SyncCoordinator.Steps

    func testStepsRunInPipelineOrderWhateverTheRequestOrder() async {
        var log: [Steps] = []
        let coordinator = SyncCoordinator { log.append($0) }

        await coordinator.request([.cloud, .bank, .widget, .calendar])

        XCTAssertEqual(log, [.bank, .widget, .calendar, .cloud])
        XCTAssertEqual(coordinator.passCount, 1)
        XCTAssertFalse(coordinator.isRunning)
    }

    func testRequestsMadeBeforeThePassStartsShareOnePass() async {
        var log: [Steps] = []
        let coordinator = SyncCoordinator { log.append($0) }

        // E.g. foregrounding, a visit and a bank sync all at once.
        coordinator.schedule(.cloud)
        coordinator.schedule([.calendar, .cloud])
        await coordinator.request([.bank, .calendar])

        XCTAssertEqual(log, [.bank, .calendar, .cloud], "Each step once")
        XCTAssertEqual(coordinator.passCount, 1)
    }

    func testAStepStillToComeIsNotRunTwiceButAFinishedOneRunsAgain() async {
        var log: [Steps] = []
        var coordinator: SyncCoordinator!
        coordinator = SyncCoordinator { step in
            log.append(step)
            if step == .bank && log.count == 1 {
                // The bank sync finished and asks for calendar + cloud (still to come in this
                // pass) and, say, another bank run (already started: must run again).
                coordinator.schedule([.calendar, .cloud, .bank])
            }
        }

        await coordinator.request([.bank, .calendar, .cloud])

        XCTAssertEqual(log, [.bank, .calendar, .cloud, .bank])
        XCTAssertEqual(coordinator.passCount, 2)
    }

    func testRequestReturnsOnlyAfterItsStepsRan() async {
        var log: [Steps] = []
        var coordinator: SyncCoordinator!
        var joined = false
        coordinator = SyncCoordinator { step in
            log.append(step)
            if step == .bank && !joined {
                joined = true
                // Another caller asks for cloud while bank runs, and waits for it.
                let other = coordinator!
                Task { await other.request(.cloud) }
                await Task.yield()
            }
        }

        await coordinator.request(.bank)
        await coordinator.request([])  // Waits for any pass still running.

        XCTAssertEqual(log, [.bank, .cloud])
    }

    func testLaterRequestsStartANewPass() async {
        var count = 0
        let coordinator = SyncCoordinator { _ in count += 1 }

        await coordinator.request(.widget)
        await coordinator.request(.widget)

        XCTAssertEqual(count, 2)
        XCTAssertEqual(coordinator.passCount, 2)
    }

    func testDescriptionNamesTheSteps() {
        XCTAssertEqual(Steps([.bank, .cloud]).description, "bank+cloud")
        XCTAssertEqual(Steps.all.description, "bank+places+widget+calendar+entitlement+cloud")
    }
}
