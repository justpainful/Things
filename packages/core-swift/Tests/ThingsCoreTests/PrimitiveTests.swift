import Foundation
import XCTest
@testable import ThingsCore

final class TimestampTests: XCTestCase {

    func testRoundTrip() {
        let text = "2026-08-09T21:14:03.412Z"
        let millis = Timestamp.milliseconds(fromISO8601: text)
        XCTAssertNotNil(millis)
        XCTAssertEqual(Timestamp.string(millisecondsSinceEpoch: millis!), text)
    }

    func testEpoch() {
        XCTAssertEqual(Timestamp.string(millisecondsSinceEpoch: 0), "1970-01-01T00:00:00.000Z")
    }

    func testLeapDay() {
        let millis = Timestamp.milliseconds(fromISO8601: "2024-02-29T12:00:00.000Z")
        XCTAssertEqual(Timestamp.string(millisecondsSinceEpoch: millis!), "2024-02-29T12:00:00.000Z")
    }

    func testSortsLexicographically() {
        let earlier = Timestamp.string(millisecondsSinceEpoch: 1_000_000)
        let later = Timestamp.string(millisecondsSinceEpoch: 2_000_000)
        XCTAssertTrue(earlier < later)
    }

    func testRejectsGarbage() {
        XCTAssertNil(Timestamp.milliseconds(fromISO8601: "not a date"))
        XCTAssertNil(Timestamp.milliseconds(fromISO8601: ""))
    }
}

final class UUIDv7Tests: XCTestCase {

    func testShapeAndVersion() {
        let id = UUIDv7.make(millisecondsSinceEpoch: 1_754_772_843_412,
                             random: [0x0A, 0x1B, 0x2C, 0x3D, 0x4E, 0x5F, 0x60, 0x71, 0x82, 0x93])
        XCTAssertEqual(id.count, 36)
        XCTAssertTrue(UUIDv7.isValid(id))
        XCTAssertEqual(UUIDv7.millisecondsSinceEpoch(of: id), 1_754_772_843_412)
    }

    func testDeterministicForFixedInputs() {
        let random: [UInt8] = Array(repeating: 0xAB, count: 10)
        let first = UUIDv7.make(millisecondsSinceEpoch: 1, random: random)
        let second = UUIDv7.make(millisecondsSinceEpoch: 1, random: random)
        XCTAssertEqual(first, second)
    }

    func testTimeSortable() {
        let clock = FixedClock(stepMilliseconds: 1)
        var ids: [String] = []
        for _ in 0..<50 { ids.append(UUIDv7.generate(clock: clock)) }
        XCTAssertEqual(ids, ids.sorted())
    }

    func testRejectsNonV7() {
        XCTAssertFalse(UUIDv7.isValid("not-a-uuid"))
        XCTAssertFalse(UUIDv7.isValid(UUID().uuidString))     // v4, uppercase
    }
}

final class HLCTests: XCTestCase {

    func testWireFormatRoundTrip() {
        let stamp = HLC(millis: 1_754_772_843_412, counter: 7, deviceID: "00000000-0000-7000-8000-00000000000a")
        let parsed = HLC.parse(stamp.description)
        XCTAssertEqual(parsed, stamp)
    }

    func testLexicographicOrderMatchesLogicalOrder() {
        let a = HLC(millis: 1000, counter: 0, deviceID: "aaa")
        let b = HLC(millis: 1000, counter: 1, deviceID: "aaa")
        let c = HLC(millis: 1001, counter: 0, deviceID: "aaa")
        XCTAssertTrue(a < b)
        XCTAssertTrue(b < c)
        XCTAssertTrue(a.description < b.description)
        XCTAssertTrue(b.description < c.description)
    }

    func testMonotonicWithinSameMillisecond() {
        let clock = FixedClock(stepMilliseconds: 0)
        let generator = HLCGenerator(deviceID: "device", clock: clock)
        var previous = generator.next()
        for _ in 0..<20 {
            let next = generator.next()
            XCTAssertTrue(previous < next)
            previous = next
        }
    }

    func testReceiveAdvancesPastRemote() {
        let clock = FixedClock(stepMilliseconds: 0)
        let generator = HLCGenerator(deviceID: "local", clock: clock)
        let remote = HLC(millis: clock.peekMilliseconds() + 5000, counter: 3, deviceID: "remote")
        let folded = generator.receive(remote)
        XCTAssertTrue(remote < folded)
    }

    func testRejectsAbsurdFutureClock() {
        let clock = FixedClock(stepMilliseconds: 0)
        let generator = HLCGenerator(deviceID: "local", clock: clock)
        let wayAhead = HLC(millis: clock.peekMilliseconds() + 10 * 365 * 24 * 3_600_000,
                           counter: 0, deviceID: "broken")
        let folded = generator.receive(wayAhead)
        XCTAssertLessThan(folded.millis,
                          clock.peekMilliseconds() + HLCGenerator.maximumDriftMilliseconds + 1000)
    }
}

final class VersionVectorTests: XCTestCase {

    func testDominance() {
        let a = VersionVector(["pc": 3, "phone": 1])
        let b = VersionVector(["pc": 2, "phone": 1])
        XCTAssertEqual(a.compare(to: b), .dominates)
        XCTAssertEqual(b.compare(to: a), .dominated)
    }

    func testEquality() {
        XCTAssertEqual(VersionVector(["pc": 1]).compare(to: VersionVector(["pc": 1])), .equal)
    }

    func testConcurrent() {
        let phone = VersionVector(["phone": 2, "pc": 1])
        let pc = VersionVector(["phone": 1, "pc": 2])
        XCTAssertEqual(phone.compare(to: pc), .concurrent)
        XCTAssertTrue(phone.isConcurrent(with: pc))
    }

    func testMergeTakesMaximum() {
        let merged = VersionVector(["a": 1, "b": 5]).merged(with: VersionVector(["a": 4, "c": 2]))
        XCTAssertEqual(merged.counters, ["a": 4, "b": 5, "c": 2])
    }

    func testCanonicalJSONIsSorted() {
        let vector = VersionVector(["zeta": 1, "alpha": 2])
        XCTAssertEqual(vector.json, "{\"alpha\":2,\"zeta\":1}")
        XCTAssertEqual(VersionVector.parse(vector.json), vector)
    }

    func testMalformedDegradesToEmpty() {
        XCTAssertEqual(VersionVector.parse("]["), .empty)
        XCTAssertEqual(VersionVector.parse(nil), .empty)
    }
}

final class JSONValueTests: XCTestCase {

    func testCanonicalOrderingAndEscaping() {
        let value = JSONValue.object([
            "b": .string("two"),
            "a": .number("1"),
            "c": .string("line\nbreak")
        ])
        XCTAssertEqual(value.canonicalJSON, "{\"a\":1,\"b\":\"two\",\"c\":\"line\\nbreak\"}")
    }

    func testNumbersKeepTheirText() throws {
        let parsed = try JSONValue.parse("{\"amount\":\"12.50\"}")
        XCTAssertEqual(parsed["amount"]?.stringValue, "12.50")
    }

    func testBoolIsNotANumber() throws {
        let parsed = try JSONValue.parse("{\"flag\":true}")
        XCTAssertEqual(parsed["flag"], .bool(true))
    }
}

final class FractionalOrderTests: XCTestCase {

    func testInsertBetween() {
        XCTAssertEqual(FractionalOrder.between(2.0, 3.0), 2.5)
        XCTAssertEqual(FractionalOrder.between(nil, 3.0), 2.0)
        XCTAssertEqual(FractionalOrder.between(2.0, nil), 3.0)
        XCTAssertEqual(FractionalOrder.between(nil, nil), 1.0)
    }

    func testRebalanceDetection() {
        XCTAssertFalse(FractionalOrder.needsRebalance([1, 2, 3]))
        XCTAssertTrue(FractionalOrder.needsRebalance([1, 1 + 1e-12, 2]))
    }
}
