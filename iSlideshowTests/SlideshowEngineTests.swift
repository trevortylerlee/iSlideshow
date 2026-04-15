import XCTest
@testable import iSlideshow

@MainActor
final class SlideshowEngineTests: XCTestCase {
    private func mediaURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    func testNonLoopingNextStopsAtEndAndPlayRestartsFromBeginning() {
        let engine = SlideshowEngine()
        engine.configure(
            mediaURLs: [mediaURL("first.jpg"), mediaURL("second.jpg")],
            duration: 10,
            isLooping: false,
            shuffle: false
        )

        engine.play()
        engine.next()
        XCTAssertEqual(engine.currentIndex, 1)
        XCTAssertTrue(engine.isPlaying)

        engine.next()

        XCTAssertEqual(engine.currentIndex, 1)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.slideStartDate)
        XCTAssertNil(engine.slideEndDate)

        engine.play()

        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertTrue(engine.isPlaying)
    }

    func testManualNavigationWrapsOnlyWhenLoopingIsEnabled() {
        let engine = SlideshowEngine()
        engine.configure(
            mediaURLs: [mediaURL("first.jpg"), mediaURL("second.jpg"), mediaURL("third.jpg")],
            duration: 5,
            isLooping: true,
            shuffle: false
        )

        engine.previous()
        XCTAssertEqual(engine.currentIndex, 2)

        engine.next()
        XCTAssertEqual(engine.currentIndex, 0)

        engine.isLooping = false
        engine.previous()
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testImageTimerAdvancesSlides() async throws {
        let sleeper = ManualSleeper()
        let engine = SlideshowEngine(sleep: sleeper.sleep)
        engine.configure(
            mediaURLs: [mediaURL("first.jpg"), mediaURL("second.jpg"), mediaURL("third.jpg")],
            duration: 0.2,
            isLooping: false,
            shuffle: false
        )

        engine.play()
        await sleeper.waitForSleepRequest()
        XCTAssertEqual(sleeper.requestedDurations, [200_000_000])

        sleeper.resumeNextSleep()
        await waitForCurrentIndex(1, in: engine)

        XCTAssertEqual(engine.currentIndex, 1)
        XCTAssertTrue(engine.isPlaying)
    }

    func testVideoDoesNotStartImageTimer() async throws {
        let engine = SlideshowEngine()
        engine.configure(
            mediaURLs: [mediaURL("clip.mp4"), mediaURL("image.jpg")],
            duration: 0.05,
            isLooping: true,
            shuffle: false
        )

        engine.play()
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertNil(engine.slideStartDate)
        XCTAssertNil(engine.slideEndDate)

        engine.next()

        XCTAssertEqual(engine.currentIndex, 1)
        XCTAssertNotNil(engine.slideStartDate)
        XCTAssertNotNil(engine.slideEndDate)
    }

    func testNonLoopingVideoAtEndStopsWhenAdvanced() {
        let engine = SlideshowEngine()
        engine.configure(
            mediaURLs: [mediaURL("image.jpg"), mediaURL("clip.mp4")],
            duration: 5,
            isLooping: false,
            shuffle: false
        )

        engine.play()
        engine.next()

        XCTAssertEqual(engine.currentIndex, 1)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertNil(engine.slideStartDate)
        XCTAssertNil(engine.slideEndDate)

        engine.next()

        XCTAssertEqual(engine.currentIndex, 1)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.slideStartDate)
        XCTAssertNil(engine.slideEndDate)
    }

    func testConfigureSanitizesInvalidDurations() {
        let invalidDurations: [Double] = [
            .nan,
            .infinity,
            -.infinity
        ]

        for duration in invalidDurations {
            let engine = SlideshowEngine()
            engine.configure(
                mediaURLs: [mediaURL("image.jpg")],
                duration: duration,
                isLooping: false,
                shuffle: false
            )

            XCTAssertEqual(engine.duration, SlideshowEngine.defaultDuration)
        }
    }

    func testConfigureClampsDurationBounds() {
        let engine = SlideshowEngine()
        engine.configure(
            mediaURLs: [mediaURL("image.jpg")],
            duration: 0,
            isLooping: false,
            shuffle: false
        )
        XCTAssertEqual(engine.duration, SlideshowEngine.minimumDuration)

        engine.configure(
            mediaURLs: [mediaURL("image.jpg")],
            duration: SlideshowEngine.maximumDuration + 1,
            isLooping: false,
            shuffle: false
        )
        XCTAssertEqual(engine.duration, SlideshowEngine.maximumDuration)
    }

    private func waitForCurrentIndex(_ index: Int, in engine: SlideshowEngine) async {
        for _ in 0..<10 where engine.currentIndex != index {
            await Task.yield()
        }
    }
}

@MainActor
private final class ManualSleeper {
    private(set) var requestedDurations: [UInt64] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(nanoseconds: UInt64) async {
        requestedDurations.append(nanoseconds)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForSleepRequest() async {
        for _ in 0..<10 where continuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeNextSleep() {
        continuations.removeFirst().resume()
    }
}
