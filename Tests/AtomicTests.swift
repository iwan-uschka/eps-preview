import Foundation
import XCTest

/// Covers the lock-box the render service builds its one-shot flags and its
/// admission counter on. `withLock` in particular exists so a check-then-act
/// cannot race, which only a concurrent test actually demonstrates.
final class AtomicTests: XCTestCase {

    func testConcurrentWithLockUpdatesNeverLoseAnIncrement() {
        let box = Atomic(0)
        let iterations = 1_000

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            box.withLock { $0 += 1 }
        }

        XCTAssertEqual(box.load(), iterations, "a lost update means the increment was not atomic")
    }

    func testWithLockReturnsTheClosuresResultAndWritesThrough() {
        let box = Atomic(41)

        let previous: Int = box.withLock { value in
            let old = value
            value += 1
            return old
        }

        XCTAssertEqual(previous, 41)
        XCTAssertEqual(box.load(), 42, "the closure's mutation must reach the box")
    }

    func testStoreDiscardsPreviousValue() {
        let box = Atomic("a")

        box.store("b")

        XCTAssertEqual(box.load(), "b")
    }

    func testLoadLeavesTheValueInPlace() {
        let box = Atomic([1, 2, 3])

        XCTAssertEqual(box.load(), [1, 2, 3])
        XCTAssertEqual(box.load(), [1, 2, 3], "reading must not consume the value")
    }

    func testSwapReturnsThePreviousValue() {
        let box = Atomic<DispatchWorkItem?>(nil)
        let item = DispatchWorkItem {}

        XCTAssertNil(box.swap(item))
        XCTAssertTrue(box.swap(nil) === item)
        XCTAssertNil(box.load())
    }

    func testOnlyOneOfManyConcurrentSwapsSeesTheFirstValue() {
        // The one-shot `finish` guard in RenderClient / RenderService: whoever
        // swaps false→true first is the single caller allowed to proceed.
        let didFinish = Atomic(false)
        let winners = Atomic(0)

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if didFinish.swap(true) == false { winners.withLock { $0 += 1 } }
        }

        XCTAssertEqual(winners.load(), 1, "exactly one caller may pass a one-shot guard")
    }
}
