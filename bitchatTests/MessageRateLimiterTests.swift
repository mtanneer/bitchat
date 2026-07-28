//
// MessageRateLimiterTests.swift
// bitchatTests
//
// Tests for the public-intake token buckets.
//

import Foundation
import Testing
@testable import PlaneChat

struct MessageRateLimiterTests {

    private func makeLimiter(
        senderCapacity: Double = 2,
        contentCapacity: Double = 100
    ) -> MessageRateLimiter {
        MessageRateLimiter(
            senderCapacity: senderCapacity,
            senderRefillPerSec: 0.0001,
            contentCapacity: contentCapacity,
            contentRefillPerSec: 0.0001
        )
    }

    @Test func senderBucketBlocksAfterCapacity() {
        var limiter = makeLimiter()
        let now = Date()

        let first = limiter.allow(senderKey: "s", contentKey: "c1", now: now)
        let second = limiter.allow(senderKey: "s", contentKey: "c2", now: now)
        let third = limiter.allow(senderKey: "s", contentKey: "c3", now: now)
        let otherSender = limiter.allow(senderKey: "other", contentKey: "c4", now: now)

        #expect(first)
        #expect(second)
        #expect(!third)
        #expect(otherSender)
    }

    @Test("Content buckets do not grow when sender is rate limited")
    func contentBucketsDoNotGrowAfterSenderLimit() {
        var limiter = MessageRateLimiter(
            senderCapacity: 1,
            senderRefillPerSec: 0,
            contentCapacity: 1,
            contentRefillPerSec: 0,
            maxSenderBuckets: 10,
            maxContentBuckets: 10,
            bucketIdleTTL: 60
        )
        let now = Date()

        let first = limiter.allow(senderKey: "sender", contentKey: "content-0", now: now)
        var rejected = true
        for index in 1...100 {
            if limiter.allow(senderKey: "sender", contentKey: "content-\(index)", now: now) {
                rejected = false
            }
        }

        #expect(first)
        #expect(rejected)
        #expect(limiter.bucketCountsForTesting.sender == 1)
        #expect(limiter.bucketCountsForTesting.content == 1)
    }

    @Test("Bucket maps evict entries at configured caps")
    func bucketMapsEvictAtConfiguredCaps() {
        let maxEntries = 3
        var limiter = MessageRateLimiter(
            senderCapacity: 1,
            senderRefillPerSec: 0,
            contentCapacity: 1,
            contentRefillPerSec: 0,
            maxSenderBuckets: maxEntries,
            maxContentBuckets: maxEntries,
            bucketIdleTTL: 60
        )
        let now = Date()

        for index in 0..<25 {
            _ = limiter.allow(
                senderKey: "sender-\(index)",
                contentKey: "content-\(index)",
                now: now.addingTimeInterval(TimeInterval(index))
            )
        }

        #expect(limiter.bucketCountsForTesting.sender == maxEntries)
        #expect(limiter.bucketCountsForTesting.content == maxEntries)
    }
}
