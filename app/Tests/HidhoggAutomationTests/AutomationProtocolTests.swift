import Foundation
import Testing
@testable import HidhoggAutomation

struct AutomationProtocolTests {
    @Test func requestRoundTripUsesVersionedNestedSnakeCaseEnvelope() throws {
        let request = AutomationRequest(requestID: "request-1", method: .notificationsEmit, params: .init(topic: "build.done", text: "Completed", ttlSeconds: 30))
        let encoded = try AutomationFrame.encode(request)
        #expect(try AutomationFrame.decodeRequest(encoded) == request)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("\"protocol_version\":1"))
        #expect(text.contains("\"request_id\":\"request-1\""))
        #expect(text.contains("\"topic\":\"build.done\""))
        #expect(!text.contains("\"source\""))
        #expect(text.contains("\"ttl_seconds\":30"))
        #expect(encoded.last == 10)
    }

    @Test(arguments: [
        #"{"protocol_version":1,"request_id":"r","method":"status","extra":1}"#,
        #"{"protocol_version":1,"request_id":"r","request_id":"s","method":"status"}"#,
        #"{"protocol_version":1,"request_id":"r","request_\u0069d":"s","method":"status"}"#,
        #"{"protocol_version":1,"request_id":"r","method":"notifications.emit","params":{"source":"a","source":"b","text":"ok"}}"#,
        #"{"protocol_version":1,"request_id":"r","method":"notifications.emit","params":{"source":"a","text":"ok"}}"#,
        #"{"protocol_version":1,"request_id":"r","method":"notifications.emit","params":{"topic":"a","text":"ok","unknown":1}}"#,
        #"{"protocol_version":1,"request_id":"r","method":"status","params":null}"#,
        #"{"protocol_version":1,"request_id":"r","method":"notifications.emit","params":{"topic":"a","text":"ok","ttl_seconds":null}}"#,
        #"{"protocol_version":1,"request_id":"r","method":"notifications.emit","params":{"topic":"a","text":"ok","ttl_seconds":1.5}}"#,
        #"{"protocol_version":1,"request_id":"r","method":"notifications.emit","params":{"topic":"a","text":"ok","ttl_seconds":1.0}}"#,
        #"{"protocol_version":1,"request_id":"r","method":"notifications.emit","params":{"topic":"a","text":"ok","ttl_seconds":1e0}}"#,
        #"{"protocol_version":1,"request_id":"r","method":"notifications.emit","params":{"topic":"build.*","text":"ok"}}"#,
        #"{"protocol_version":1,"request_id":"r","method":"notifications.clear","params":{"notification_id":"00000000-0000-0000-0000-000000000000","topic":"a"}}"#,
        #"{"protocol_version":1,"request_id":"r","method":"notifications.history","params":{"topic":"a"}}"#,
        #"{"protocol_version":1,"request_id":"r","method":"status","params":{"action_id":"a"}}"#,
        #"{"protocol_version":1,"request_id":"r","method":"actions.invoke","params":{"action_id":"a","topic":"a"}}"#,
        #"{"protocol_version":2,"request_id":"r","method":"status"}"#,
        #"{"protocol_version":1,"request_id":"r","method":"actions.invoke","params":{"action_id":"../a"}}"#
    ]) func malformedRequestsAreRejected(_ json: String) {
        #expect(throws: (any Error).self) { try AutomationFrame.decodeRequest(Data((json + "\n").utf8)) }
    }

    @Test func framesAndTextAreBoundedWithoutPayloadEcho() throws {
        #expect(throws: (any Error).self) { try AutomationFrame.decodeRequest(Data(repeating: 32, count: AutomationFrame.maximumBytes + 1)) }
        #expect(throws: (any Error).self) { try AutomationFrame.decodeRequest(Data("{}\n{}\n".utf8)) }
        #expect(throws: (any Error).self) { try AutomationFrame.decodeRequest(Data("{}".utf8)) }
        for text in ["", "  ", "two\nlines", "direction\u{202e}", String(repeating: "x", count: 65)] {
            let request = AutomationRequest(method: .notificationsEmit, params: .init(topic: "valid", text: text))
            #expect(throws: (any Error).self) { try request.validated() }
        }
        let response = AutomationResponse.success(requestID: "r", result: .object(["matched_count": .integer(0)]))
        #expect(try AutomationFrame.decodeResponse(AutomationFrame.encode(response)) == response)
        #expect(!String(decoding: try AutomationFrame.encode(response), as: UTF8.self).contains("text"))
    }
}
