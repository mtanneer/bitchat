import Testing
@testable import PlaneChat

struct ChatFavoriteTogglePolicyTests {
    @Test
    func addingWithoutExistingStatusUsesFallbackNickname() {
        let plan = ChatFavoriteTogglePolicy.plan(
            currentStatus: nil,
            fallbackNickname: "alice"
        )

        #expect(plan == ChatFavoriteTogglePlan(
            persistenceAction: .add(nickname: "alice"),
            notification: .none
        ))
    }

    @Test
    func addingMutualFavoriteSendsPositiveNotification() {
        let plan = ChatFavoriteTogglePolicy.plan(
            currentStatus: ChatFavoriteStatusSnapshot(
                peerNickname: "alice",
                isFavorite: false,
                theyFavoritedUs: true
            ),
            fallbackNickname: "fallback"
        )

        #expect(plan == ChatFavoriteTogglePlan(
            persistenceAction: .add(nickname: "alice"),
            notification: .send(isFavorite: true)
        ))
    }

    @Test
    func addingWithoutAnyNicknameUsesUnknown() {
        let plan = ChatFavoriteTogglePolicy.plan(
            currentStatus: nil,
            fallbackNickname: nil
        )

        #expect(plan == ChatFavoriteTogglePlan(
            persistenceAction: .add(nickname: "Unknown"),
            notification: .none
        ))
    }

    @Test
    func removingFavoriteSendsNegativeNotification() {
        let plan = ChatFavoriteTogglePolicy.plan(
            currentStatus: ChatFavoriteStatusSnapshot(
                peerNickname: "alice",
                isFavorite: true,
                theyFavoritedUs: false
            ),
            fallbackNickname: nil
        )

        #expect(plan == ChatFavoriteTogglePlan(
            persistenceAction: .remove,
            notification: .send(isFavorite: false)
        ))
    }
}
