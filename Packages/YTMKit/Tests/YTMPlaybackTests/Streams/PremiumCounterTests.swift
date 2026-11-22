import Foundation
import Testing
@testable import YTMCore
@testable import YTMPlayback

struct PremiumCounterTests {
    private let now = ContinuousClock.now

    @Test func onlyALongRunOfMissesTurnsOffAKnownPremiumAccount() {
        var counters = PremiumCounters(known: true, none: false)
        for _ in 1..<PremiumCounters.lapsedAfter { counters.recordMiss(at: now) }
        #expect(counters.status == .premium, "a run of uploads")
        counters.recordPremium()
        for _ in 1..<PremiumCounters.lapsedAfter { counters.recordMiss(at: now) }
        #expect(counters.status == .premium, "a Premium song starts the count again")

        counters.recordMiss(at: now)
        #expect(counters.status == .notPremium, "a lapsed subscription")
        #expect(counters.skipped(at: now))
        let result3 = counters.takeRecheck(at: now)
        #expect(!result3, "not due until the cool-off ends")
    }

    @Test func checksAgainInTheBackgroundAfterTakingAnAccountAsWithoutPremium() {
        var counters = PremiumCounters(known: false, none: false)
        counters.recordMiss(at: now)
        counters.recordMiss(at: now)
        #expect(!counters.skipped(at: now), "two songs say nothing yet")
        let result4 = counters.takeRecheck(at: now)
        #expect(!result4, "nothing to check while unknown")
        counters.recordMiss(at: now)
        #expect(counters.status == .notPremium)
        #expect(counters.skipped(at: now), "songs go straight to the free stream")
        let result5 = counters.takeRecheck(at: now)
        #expect(!result5, "not due yet")

        let later = now + PremiumCounters.backoff
        let result6 = counters.takeRecheck(at: later)
        #expect(result6, "due once the cool-off ends")
        let result7 = counters.takeRecheck(at: later)
        #expect(!result7, "only one check at a time")
        #expect(counters.skipped(at: later), "songs still play free meanwhile")

        counters.recordPremium()
        #expect(counters.status == .premium)
        #expect(!counters.skipped(at: later))
        counters.recordMiss(at: later)
        #expect(counters.status == .premium)
    }

    @Test func aRememberedNoPlaysFreeAndIsCheckedAtOnce() {
        var counters = PremiumCounters(known: false, none: true)
        #expect(counters.skipped(at: now), "no Premium request before the first song")
        let result8 = counters.takeRecheck(at: now)
        #expect(result8, "checked in the background straight away")
        let result9 = counters.takeRecheck(at: now)
        #expect(!result9)
    }

    @Test func repeatedErrorsPauseThePremiumPathForTheBackoff() {
        var counters = PremiumCounters(known: true, none: false)
        let result10 = counters.recordError(at: now)
        #expect(!result10)
        let result11 = counters.recordError(at: now)
        #expect(!result11)
        let result12 = counters.recordError(at: now)
        #expect(result12, "the third in a row")
        #expect(counters.skipped(at: now))
        #expect(!counters.skipped(at: now + PremiumCounters.backoff), "back after ten minutes")
        #expect(counters.status == .premium, "errors say nothing about the account")
    }
}
