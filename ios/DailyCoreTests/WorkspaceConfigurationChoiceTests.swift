import XCTest
@testable import DailyCore

final class WorkspaceConfigurationChoiceTests: XCTestCase {
    func testPublicBuildNeverUsesBundledProject() {
        XCTAssertEqual(WorkspaceConfigurationChoice.select(hasPersonalFile: false, personalValid: false,
            declaredProject: nil, bundledProject: "owner-project"), .unconfigured)
        XCTAssertEqual(WorkspaceConfigurationChoice.select(hasPersonalFile: false, personalValid: false,
            declaredProject: "another-project", bundledProject: "owner-project"), .unconfigured)
    }

    func testInternalOwnerBuildCanRestoreExistingAuthWithoutFileImport() {
        XCTAssertEqual(WorkspaceConfigurationChoice.select(hasPersonalFile: false, personalValid: false,
            declaredProject: "owner-project", bundledProject: "owner-project"), .ownerBuild)
    }

    func testSavedChoiceWinsAndCorruptionDoesNotSwitchProjects() {
        XCTAssertEqual(WorkspaceConfigurationChoice.select(hasPersonalFile: true, personalValid: true,
            declaredProject: "owner-project", bundledProject: "owner-project"), .personal)
        XCTAssertEqual(WorkspaceConfigurationChoice.select(hasPersonalFile: true, personalValid: false,
            declaredProject: "owner-project", bundledProject: "owner-project"), .unconfigured)
    }
}
