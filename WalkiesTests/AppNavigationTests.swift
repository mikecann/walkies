import Testing
@testable import Walkies

struct AppNavigationTests {
    @Test func opensOnTheMapAtLevel() {
        let navigation = AppNavigation()
        #expect(navigation.tab == .map)
        #expect(navigation.progressSection == .level)
        #expect(navigation.openSecret == nil)
    }

    @Test func showingProgressSwitchesTabAndSection() {
        let navigation = AppNavigation()
        navigation.showProgress(.shop)
        #expect(navigation.tab == .progress)
        #expect(navigation.progressSection == .shop)
        // The celebration's "Level up" goes back to the rewards.
        navigation.showProgress()
        #expect(navigation.progressSection == .level)
    }

    @Test func aReviewNotificationOpensSettingsWithNothingOverIt() {
        let navigation = AppNavigation()
        navigation.showingPlaces = true
        navigation.showSecretsReview()
        #expect(navigation.tab == .settings)
        #expect(!navigation.showingPlaces)
        #expect(navigation.openSecret == nil)
        // Tapping another one while Settings is up still has to fetch and scroll.
        let first = navigation.secretsReviewRequest
        navigation.showSecretsReview()
        #expect(navigation.secretsReviewRequest == first + 1)
    }

    @Test func onlyAKnownTargetOpensAnything() {
        #expect(NotificationTarget(userInfo: ["open": "secretsReview"]) == .secretsReview)
        #expect(NotificationTarget(userInfo: ["open": "somethingFromANewerServer"]) == nil)
        #expect(NotificationTarget(userInfo: ["sticker": "abc"]) == nil)
    }

    @Test func pickingASectionStaysOnProgress() {
        let navigation = AppNavigation()
        navigation.showProgress(.level)
        for section in AppNavigation.ProgressSection.allCases {
            navigation.progressSection = section
            #expect(navigation.progressSection == section)
            #expect(navigation.tab == .progress)
        }
    }

    @Test func watchingAgainGoesBackToTheMap() {
        let navigation = AppNavigation()
        navigation.tab = .walks
        navigation.showMap()
        #expect(navigation.tab == .map)
    }

    @Test func sectionsInOrder() {
        #expect(AppNavigation.ProgressSection.allCases.map(\.rawValue) == ["Level", "Quests", "Shop", "Wardrobe", "Spyglass"])
    }
}
