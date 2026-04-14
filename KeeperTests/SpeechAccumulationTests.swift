import Testing
@testable import Keepur

@MainActor
struct SpeechAccumulationTests {

    @Test func accumulatesAcrossWindowSlide() async {
        let sm = SpeechManager()
        sm.resetAccumulationForTesting()

        // Tick 1: window contains segments at 0-2s, 2-5s.
        let r1 = sm.absorbTranscriptionTick(
            confirmed: [(2.0, "Hello world."), (5.0, "How are you?")],
            unconfirmed: "I am"
        )
        #expect(r1 == "Hello world. How are you? I am")

        // Tick 2: window has slid; the 0-2s segment was dropped by WhisperKit,
        // but the 2-5s segment is still present and a new 5-8s segment appeared.
        let r2 = sm.absorbTranscriptionTick(
            confirmed: [(5.0, "How are you?"), (8.0, "doing fine.")],
            unconfirmed: ""
        )
        #expect(r2 == "Hello world. How are you? doing fine.")

        // Tick 3: window slid again; only the 8s segment remains, plus a new one.
        let r3 = sm.absorbTranscriptionTick(
            confirmed: [(8.0, "doing fine."), (11.0, "Thanks for asking.")],
            unconfirmed: "Bye"
        )
        #expect(r3 == "Hello world. How are you? doing fine. Thanks for asking. Bye")
    }

    @Test func resetClearsState() async {
        let sm = SpeechManager()
        _ = sm.absorbTranscriptionTick(confirmed: [(1.0, "first")], unconfirmed: "")
        sm.resetAccumulationForTesting()
        let r = sm.absorbTranscriptionTick(confirmed: [(1.0, "second")], unconfirmed: "")
        #expect(r == "second")
    }

    @Test func skipsEmptyAndDuplicateSegments() async {
        let sm = SpeechManager()
        sm.resetAccumulationForTesting()
        _ = sm.absorbTranscriptionTick(confirmed: [(1.0, "  "), (2.0, "hi")], unconfirmed: "")
        // Same end-time should not be re-appended.
        let r = sm.absorbTranscriptionTick(confirmed: [(2.0, "hi")], unconfirmed: "there")
        #expect(r == "hi there")
    }

    @Test func dedupsSegmentWithJitteredEndTimestamp() async {
        // WhisperKit may re-emit a previously confirmed segment with its `end`
        // timestamp refined by a few ms as alignment settles. The epsilon guard
        // in absorbTranscriptionTick must treat such a re-emission as a duplicate.
        let sm = SpeechManager()
        sm.resetAccumulationForTesting()
        _ = sm.absorbTranscriptionTick(confirmed: [(5.000, "hello")], unconfirmed: "")
        // Same segment re-emitted with a 3ms timestamp refinement — must NOT re-append.
        let r = sm.absorbTranscriptionTick(confirmed: [(5.003, "hello")], unconfirmed: "")
        #expect(r == "hello")
    }
}
