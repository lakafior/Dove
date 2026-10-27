import DoveKit
import Testing
@testable import DoveAppCore

struct SetupPlanTests {
    @Test func buildsOnlySelectedStepsInOrder() {
        let choices: Set<SetupChoice> = [.service(.realDebrid), .service(.nzbdav), .indexers, .addons, .movies, .games, .books, .iCloudDrive, .calibre, .player, .reading]
        #expect(SetupPlan.steps(for: choices).map(\.page) == [
            .service(.realDebrid), .service(.nzbdav), .routing, .indexers, .addons, .movies, .games,
            .books, .iCloudDrive, .calibre, .saveTo, .player, .reading, .adult, .done
        ])
    }

    @Test func routingAppearsOnlyForSeveralServices() {
        let one: Set<SetupChoice> = [.service(.realDebrid)]
        let two: Set<SetupChoice> = [.service(.realDebrid), .service(.torBox)]
        let debridAndUsenet: Set<SetupChoice> = [.service(.torBox), .service(.nzbdav)]
        #expect(!SetupPlan.steps(for: one).contains { $0.page == .routing })
        #expect(SetupPlan.steps(for: two).contains { $0.page == .routing })
        #expect(SetupPlan.steps(for: debridAndUsenet).contains { $0.page == .routing })
    }

    @Test func marksConfiguredChoicesAlreadySet() {
        let choices: Set<SetupChoice> = [.service(.realDebrid), .addons]
        let steps = SetupPlan.steps(for: choices, configured: [.service(.realDebrid)])
        #expect(steps.first { $0.page == .service(.realDebrid) }?.alreadySet == true)
        #expect(steps.first { $0.page == .addons }?.alreadySet == false)
    }

    @Test func automaticPresentationRequiresAnEmptyUnfinishedInstall() {
        #expect(SetupState.shouldPresentAutomatically(finished: false, hasAnythingConfigured: false))
        #expect(!SetupState.shouldPresentAutomatically(finished: true, hasAnythingConfigured: false))
        #expect(!SetupState.shouldPresentAutomatically(finished: false, hasAnythingConfigured: true))
    }

    @Test func syncedCredentialsPreventAutomaticPresentation() {
        // Keys arriving through iCloud Keychain make the model configured on a fresh device.
        #expect(!SetupState.shouldPresentAutomatically(finished: false, hasAnythingConfigured: true))
    }
}
