import XCTest
@testable import DailyCore

final class WorkspaceExperienceTests:XCTestCase {
    func testCheckinsAreIdempotentPerOccurrenceAndPreserveOtherDates() throws {
        let first=try ExperienceEvent(kind:"agenda_checkin",subjectID:"event_2026-11-02",title:"Yüzme",value:"postponed",now:"2026-11-03T10:00:00Z")
        let second=try ExperienceEvent(kind:"agenda_checkin",subjectID:"event_2026-11-03",title:"Yüzme",value:"done",now:"2026-11-03T11:00:00Z")
        let amended=try ExperienceEvent(kind:"agenda_checkin",subjectID:first.subjectID,title:first.title,value:"done",now:"2026-11-03T12:00:00Z")
        let ledger=try WorkspaceExperience().recording(first).recording(second).recording(amended)
        let reopened=try WorkspaceExperience(record:ledger.record())
        XCTAssertEqual(reopened.items.count,2)
        XCTAssertEqual(reopened.items.first(where:{$0.subjectID == first.subjectID})?.value,"done")
    }
    func testInvalidFeedbackCannotCrossTheRecordBoundary() throws {
        XCTAssertThrowsError(try ExperienceEvent(kind:"unknown",subjectID:"x",title:"x",value:"done"))
        XCTAssertThrowsError(try ExperienceEvent(kind:"agenda_checkin",subjectID:"x",title:"x",value:"probably"))
        let item=try ExperienceEvent(kind:"question_known",subjectID:"question",title:"Nasıldı?",text:"İyiydi",value:"known")
        let record=try WorkspaceExperience().recording(item).record()
        var value=try XCTUnwrap(JSONValue.parse(try record.payload().string!).object)
        var rows=try XCTUnwrap(value["items"]?.array)
        rows.append(rows[0]);value["items"] = .array(rows)
        let duplicate=try WorkspaceRecord.make(key:WorkspaceExperience.key,kind:.note,payload:.string(JSONValue.object(value).canonical()))
        XCTAssertThrowsError(try WorkspaceExperience(record:duplicate))
    }
    func testContextIsBoundedValidJSONEvenWithLargeUnicodeAnswers() throws {
        var ledger=WorkspaceExperience()
        for i in 0..<70 {
            ledger=try ledger.recording(ExperienceEvent(kind:"question_known",subjectID:String(i),title:"Soru \(i)",text:String(repeating:"ö",count:1900),value:"known"))
        }
        XCTAssertLessThanOrEqual(ledger.context.utf8.count,12000)
        XCTAssertNoThrow(try JSONValue.parse(ledger.context))
    }
    func testMemoryEditChunksDecodeAndVersionsOnlyIncrease() throws {
        let empty=try PortableMemory(json:AnalysisCore.invoke("emptyMemory",json:"{}"))
        let edit=try WorkspaceMemoryMutation(before:empty,expectedManifest:nil,action:"rollback",prior:empty)
        let decoded=try PhoneAnalysisCommit.decodeMemory(manifest:edit.manifest,chunks:edit.chunks)
        XCTAssertEqual(decoded.contentHash,edit.memory.contentHash)
        XCTAssertEqual(decoded.revision,1)
        XCTAssertTrue(edit.records.contains(where:{$0.key == ManagedAgenda.key}))
    }
    func testFocusIncludesOnlyDirectNeighborsAndTheirEdges() throws {
        let json=#"{"nodes":[{"id":"a","label":"a","status":"observation","summary":"","updatedAt":"","topicPath":[]},{"id":"b","label":"b","status":"observation","summary":"","updatedAt":"","topicPath":[]},{"id":"c","label":"c","status":"observation","summary":"","updatedAt":"","topicPath":[]}],"edges":[{"id":"ab","source":"a","target":"b","relation":"related"},{"id":"bc","source":"b","target":"c","relation":"related"}]}"#
        let graph=try JSONDecoder().decode(MobileAtlas.Graph.self,from:Data(json.utf8))
        let focus=graph.focused(on:"a")
        XCTAssertEqual(Set(focus.nodes.map(\.id)),Set(["a","b"]))
        XCTAssertEqual(focus.edges.map(\.id),["ab"])
        XCTAssertEqual(graph.focused(on:"missing"),graph)
    }
}
