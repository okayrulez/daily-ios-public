import Foundation
import XCTest
@testable import DailyCore

final class ChatGPTOAuthTests: XCTestCase {
    func testPKCEAndCallbackBindOneAttemptAndIssuedClient() throws {
        let a=try ChatGPTOAuthAttempt(port:1455),b=try ChatGPTOAuthAttempt(port:1455)
        XCTAssertNotEqual(a.state,b.state);XCTAssertNotEqual(a.verifier,b.verifier)
        XCTAssertEqual(a.verifier.count,43)
        let url=try a.authorize(hostID:"urn:uuid:fixture")
        let items=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertEqual(items.first{$0.name=="client_id"}?.value,"dynamic_agent_client")
        XCTAssertEqual(items.first{$0.name=="agent_name_hint"}?.value,"DailyX")
        let callback=URL(string:a.redirect+"?code=code&state="+a.state+"&client_id=issued")!
        XCTAssertEqual(try a.callback(callback).clientID,"issued")
        XCTAssertThrowsError(try b.callback(callback))
        XCTAssertThrowsError(try a.callback(URL(string:callback.absoluteString+"&state="+a.state)!))
        XCTAssertThrowsError(try a.callback(URL(string:callback.absoluteString.replacingOccurrences(of:"127.0.0.1",with:"localhost"))!))
    }
    func testReturningRegistrationCannotChangeClient() throws {
        let attempt=try ChatGPTOAuthAttempt(port:5555,clientID:"registered")
        XCTAssertEqual(try attempt.callback(URL(string:attempt.redirect+"?code=code&state="+attempt.state)!).clientID,"registered")
        XCTAssertThrowsError(try attempt.callback(URL(string:attempt.redirect+"?code=code&state="+attempt.state+"&client_id=other")!))
        XCTAssertThrowsError(try attempt.callback(URL(string:attempt.redirect+"?error=access_denied&state="+attempt.state)!))
    }
    func testVerifiesRealSignatureAudienceNonceAndExpiry() throws {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"oidc-fixture",withExtension:"json"))
        let fixture=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        let token=try XCTUnwrap(fixture["token"] as? String)
        let keys=try JSONSerialization.data(withJSONObject:fixture["jwks"]!)
        let now=Date(timeIntervalSince1970:1_790_000_000)
        XCTAssertEqual(try ChatGPTIDToken.verify(token,jwks:keys,clientID:"test-client",nonce:"test-nonce",now:now),"test-account")
        let profile = try ChatGPTIDToken.profile(token,jwks:keys,clientID:"test-client",nonce:"test-nonce",now:now)
        XCTAssertEqual(profile.subject, "test-account")
        XCTAssertEqual(profile.identityKey, "openai-sub:test-account")
        XCTAssertThrowsError(try ChatGPTIDToken.verify(token,jwks:keys,clientID:"other",nonce:"test-nonce",now:now))
        XCTAssertThrowsError(try ChatGPTIDToken.verify(token,jwks:keys,clientID:"test-client",nonce:"other",now:now))
        XCTAssertThrowsError(try ChatGPTIDToken.verify(token,jwks:keys,clientID:"test-client",nonce:"test-nonce",now:Date(timeIntervalSince1970:2_000_000_010)))
        let parts=token.split(separator:".").map(String.init)
        let forged=parts[0]+"."+ChatGPTOAuthAttempt.base64url(Data("{\"sub\":\"forged\"}".utf8))+"."+parts[2]
        XCTAssertThrowsError(try ChatGPTIDToken.verify(forged,jwks:keys,clientID:"test-client",nonce:"test-nonce",now:now))
        XCTAssertThrowsError(try ChatGPTIDToken.profile(forged,jwks:keys,clientID:"test-client",nonce:"test-nonce",now:now))
    }
}
