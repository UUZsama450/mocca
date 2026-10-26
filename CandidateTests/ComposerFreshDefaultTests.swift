import XCTest
@testable import Mocca

@MainActor final class ComposerFreshDefaultTests: XCTestCase {
    private let key = "user_preferences_v1"
    private var prior: Any?
    override func setUp() {
        super.setUp()
        // Runs only in the isolated QA application's preferences domain.
        prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }
    override func tearDown() {
        if let prior { UserDefaults.standard.set(prior, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }
    func testFreshInstallDefaultsOffAndKeepsChoiceOnNextLaunch() {
        XCTAssertFalse(AppPreferences.loadPreferences(isNewInstallation: true).composerHeightAnimationEnabled)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: key))
        XCTAssertFalse(AppPreferences.loadPreferences().composerHeightAnimationEnabled)
    }
    func testExistingInstallWithoutPreferencesRetainsLegacyDefault() {
        XCTAssertTrue(AppPreferences.loadPreferences().composerHeightAnimationEnabled)
        XCTAssertNil(UserDefaults.standard.data(forKey: key))
    }
    func testSavedOnAndOffArePreservedEvenWhenOnboardingIsShown() throws {
        for enabled in [false, true] {
            let saved = UserPreferences(composerHeightAnimationEnabled: enabled)
            let data = try JSONEncoder().encode(saved)
            UserDefaults.standard.set(data, forKey: key)
            for isNew in [false, true] {
                XCTAssertEqual(AppPreferences.loadPreferences(isNewInstallation: isNew).composerHeightAnimationEnabled, enabled)
                XCTAssertEqual(UserDefaults.standard.data(forKey: key), data)
            }
        }
    }
    func testOldBackupWithoutAnimationFieldRetainsLegacyDefault() throws {
        let legacy = Data("{}".utf8)
        XCTAssertTrue(try JSONDecoder().decode(UserPreferences.self, from: legacy).composerHeightAnimationEnabled)
        UserDefaults.standard.set(legacy, forKey: key)
        XCTAssertTrue(AppPreferences.loadPreferences(isNewInstallation: true).composerHeightAnimationEnabled)
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), legacy)
    }
    func testPreferenceBackupRoundTripPreservesEitherChoice() throws {
        for enabled in [false, true] {
            let data = try JSONEncoder().encode(["preferences": UserPreferences(composerHeightAnimationEnabled: enabled)])
            let restored = try JSONDecoder().decode([String: UserPreferences].self, from: data)
            XCTAssertEqual(restored["preferences"]?.composerHeightAnimationEnabled, enabled)
        }
    }
    func testUnreadableExistingPreferenceRecordIsNotReplacedByFreshDefault() {
        let data = Data("not-valid-json".utf8)
        UserDefaults.standard.set(data, forKey: key)
        XCTAssertTrue(AppPreferences.loadPreferences(isNewInstallation: true).composerHeightAnimationEnabled)
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), data)
    }
}
