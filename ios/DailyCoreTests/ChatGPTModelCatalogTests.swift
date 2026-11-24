import XCTest
@testable import DailyCore

final class ChatGPTModelCatalogTests: XCTestCase {
    func testAccountCatalogKeepsServerOrderAndOnlyAvailableChoices() throws {
        let models = try ChatGPTModel.catalog(JSONValue.parse(#"{"models":[{"slug":"free-model","display_name":"Free model","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]},{"slug":"hidden","visibility":"hide"},{"slug":"free-model","visibility":"list"}]}"#))
        XCTAssertEqual(models.map(\.id), ["free-model"])
        XCTAssertEqual(models[0].reasoningLevels, ["low", "high"])
        XCTAssertNil(ChatGPTModel.selected(in: models, preferred: "astra")?.reasoning("ultra"))
        XCTAssertEqual(ChatGPTModel.selected(in: models, preferred: "astra")?.id, "free-model")
    }
    func testPreferencesAreIsolatedByAccountRegistrationAndWorkspace() {
        let key = ChatGPTModel.preferenceKey(scope:"workspace",accountID:"alice",clientID:"client")
        XCTAssertNotEqual(key,ChatGPTModel.preferenceKey(scope:"workspace",accountID:"bob",clientID:"client"))
        XCTAssertNotEqual(key,ChatGPTModel.preferenceKey(scope:"workspace",accountID:"alice",clientID:"other"))
        XCTAssertNotEqual(key,ChatGPTModel.preferenceKey(scope:"other",accountID:"alice",clientID:"client"))
    }
    func testMissingReasoningDoesNotInventOptions() throws {
        let models = try ChatGPTModel.catalog(JSONValue.parse(#"{"models":[{"slug":"basic","visibility":"list"}]}"#))
        XCTAssertEqual(models[0].name, "basic")
        XCTAssertTrue(models[0].reasoningLevels.isEmpty)
        XCTAssertNil(models[0].reasoning("high"))
        XCTAssertThrowsError(try ChatGPTModel.catalog(JSONValue.parse("{}")))
    }
    func testReasoningOverridesPromptAndDefaultOmitsField() throws {
        let prompt = #"{"instructions":"x","input":[],"reasoning":{"effort":"ultra"}}"#
        let selected = try ChatGPTModel.applyingReasoning("low", to: prompt)
        XCTAssertEqual(try JSONValue.parse(selected).object?["reasoning"]?.object?["effort"]?.string, "low")
        XCTAssertNil(try JSONValue.parse(ChatGPTModel.applyingReasoning(nil, to: prompt)).object?["reasoning"])
    }
}
