import CMUXAuthCore
import Testing
@testable import CmuxAuthRuntime

@Suite struct AuthConfigTests {
    @Test func productionDefaultsToDisabledLoopbackService() {
        let config = AuthConfig(environment: .production)

        #expect(config.stack.projectId == "amux-auth-production-disabled")
        #expect(config.stack.publishableClientKey == "pck_amux_production_disabled")
        #expect(config.magicLinkCallbackURL == "http://127.0.0.1:9/auth/callback")
        #expect(config.apiBaseURL == "http://127.0.0.1:9")
    }
}
