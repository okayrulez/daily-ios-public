import XCTest
@testable import DailyCore

final class SocialProfileTests: XCTestCase {
    func testFreeformIntroductionPreservesLegacyProfilesAndConsent() throws {
        var previous = SocialProfile()
        previous.name = "Deniz"
        previous.instagram = "@deniz"
        previous.linkedin = "linkedin/deniz-yilmaz"
        previous.other = "Portföyüm example.com"
        previous.researchAllowed = true
        let migrated = try previous.replacingIntroduction(previous.introductionText).validated()
        XCTAssertEqual(migrated.other, previous.introductionText)
        XCTAssertTrue(migrated.researchAllowed)
        XCTAssertTrue(migrated.name.isEmpty)
        for hint in ["Deniz", "@deniz", "linkedin/deniz-yilmaz", "example.com"] {
            XCTAssertTrue(try XCTUnwrap(migrated.researchRequest).contains(hint))
        }
        XCTAssertEqual(migrated.introductionText, previous.introductionText)
    }

    func testFreeformResearchAcceptsMixedPlatformsAndNames() throws {
        let text = "Adım Deniz. insta: @deniz, LinkedIn’im: deniz-yilmaz; GitHub: deniz-dev."
        var profile = SocialProfile().replacingIntroduction(text)
        XCTAssertNil(try profile.validated().researchRequest)
        profile.researchAllowed = true
        XCTAssertTrue(try XCTUnwrap(profile.validated().researchRequest).contains(text))
        XCTAssertThrowsError(try profile.replacingIntroduction("  ").validated())
    }

    func testFreeformHandleIsNotGuessedToBeAWebsiteAndOldProfilesStillDecode() throws {
        let profile = try SocialProfile().replacingIntroduction("deniz.name").validated()
        XCTAssertEqual(profile.other, "deniz.name")
        XCTAssertEqual(try JSONDecoder().decode(SocialProfile.self, from: JSONEncoder().encode(profile)), profile)
        let old = Data(#"{"name":"Deniz","instagram":"@deniz","linkedin":"","other":"","researchAllowed":false}"#.utf8)
        let decoded = try JSONDecoder().decode(SocialProfile.self, from: old)
        XCTAssertNil(decoded.freeformInput)
        XCTAssertTrue(decoded.introductionText.contains("@deniz"))
    }
    func testResearchRequiresExplicitOptIn() throws {
        var profile = SocialProfile()
        profile.instagram = "https://www.instagram.com/example/"
        XCTAssertNil(try profile.validated().researchRequest)
        profile.researchAllowed = true
        XCTAssertTrue(try XCTUnwrap(profile.validated().researchRequest).contains(profile.instagram))
    }
    func testCannotResearchAnUnidentifiedPerson() {
        var profile = SocialProfile(); profile.researchAllowed = true
        XCTAssertThrowsError(try profile.validated())
    }
    func testRejectsExecutableAndCredentialLinks() {
        for link in ["https://user:pass@instagram.com/a", "javascript:alert(1)", "file:///private/example", "data:text/html,example"] {
            var profile = SocialProfile(); profile.instagram = link
            XCTAssertThrowsError(try profile.validated(), link)
        }
    }
    func testInstagramAcceptsHandlesAndShorthand() throws {
        for input in ["example.name", "@example.name", "instagram/example.name", "instagram.com/example.name", "www.instagram.com/example.name", "http://instagram.com/example.name"] {
            var profile = SocialProfile(); profile.instagram = input
            let expected = input.hasPrefix("www.") ? "https://www.instagram.com/example.name" : "https://instagram.com/example.name"
            XCTAssertEqual(try profile.validated().instagram, expected, input)
        }
    }
    func testLinkedInCompletesMissingSchemeDomainAndInSegment() throws {
        for input in ["example-name", "@example-name", "linkedin/example-name", "linkedin/in/example-name", "in/example-name", "linkedin.com/example-name", "linkedin.com/in/example-name", "https://linkedin.com/example-name"] {
            var profile = SocialProfile(); profile.linkedin = input
            XCTAssertEqual(try profile.validated().linkedin, "https://linkedin.com/in/example-name", input)
        }
    }
    func testLinkedInCompanyAndCaseSensitivePathsStayIntact() throws {
        var profile = SocialProfile(); profile.linkedin = "linkedin/company/Example"
        XCTAssertEqual(try profile.validated().linkedin, "https://linkedin.com/company/Example")
        profile.linkedin = "https://www.linkedin.com/in/Example-Person/?trk=profile#fragment"
        XCTAssertEqual(try profile.validated().linkedin, "https://www.linkedin.com/in/Example-Person/?trk=profile")
    }
    func testNaturalLanguageHintsAreAcceptedAndLabeledForResearch() throws {
        var profile = SocialProfile(); profile.researchAllowed = true
        profile.linkedin = "LinkedIn nickim example-name, tasarımcı olan benim"
        profile.other = "X hesabım @example; portföyümü de araştır"
        let clean = try profile.validated()
        XCTAssertEqual(clean.linkedin, profile.linkedin)
        XCTAssertEqual(clean.other, profile.other)
        XCTAssertTrue(try XCTUnwrap(clean.researchRequest).contains("LinkedIn: " + profile.linkedin))
        XCTAssertTrue(try XCTUnwrap(clean.researchRequest).contains("Diğer: " + profile.other))
    }
    func testOtherWebsitesDontRequireSchemeAndHintsAreIdempotent() throws {
        var profile = SocialProfile(); profile.other = "example.com/CaseSensitive"
        profile.instagram = "@example.name"; profile.linkedin = "linkedin/example-name"
        let clean = try profile.validated()
        XCTAssertEqual(clean.other, "https://example.com/CaseSensitive")
        XCTAssertEqual(try clean.validated(), clean)
    }
    func testValidationPreservesCaseSensitivePathsAndDropsFragment() throws {
        var profile = SocialProfile(); profile.other = " https://example.com/CaseSensitive#fragment "
        XCTAssertEqual(try profile.validated().other, "https://example.com/CaseSensitive")
    }
    func testProfileRoundTripPreservesDeclinedConsent() throws {
        var profile = SocialProfile(); profile.linkedin = "https://www.linkedin.com/in/example"
        let copy = try JSONDecoder().decode(SocialProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(copy, profile); XCTAssertNil(copy.researchRequest)
    }
    func testResearchPreparationPreservesWritingAndDoesNotDuplicate() {
        var profile = SocialProfile(); profile.name = "Example"; profile.researchAllowed = true
        let text = profile.updatingJournal("My journal", previous: SocialProfile())
        XCTAssertTrue(text.hasPrefix("My journal\n\n"))
        XCTAssertEqual(profile.updatingJournal(text, previous: profile), text)
        var declined = profile; declined.researchAllowed = false
        XCTAssertFalse(declined.updatingJournal(text, previous: profile).contains("[Sosyal profillerimden araştırma]"))
        XCTAssertTrue(declined.updatingJournal(text, previous: profile).hasPrefix("My journal"))
    }
}
