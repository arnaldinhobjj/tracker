import AccountKit
import XCTest
@testable import DayLedger

final class DeveloperLoginTests: XCTestCase {
    #if DEBUG
    func testAcceptsAdminAnd123InDebug() {
        XCTAssertTrue(DeveloperLogin.matches(email: "admin", password: "123"))
        XCTAssertTrue(DeveloperLogin.matches(email: " Admin ", password: "123"))
    }

    func testRejectsOtherPasswordsAndUsers() {
        XCTAssertFalse(DeveloperLogin.matches(email: "admin", password: "1234"))
        XCTAssertFalse(DeveloperLogin.matches(email: "admin", password: ""))
        XCTAssertFalse(DeveloperLogin.matches(email: "admin", password: " 123"))
        XCTAssertFalse(DeveloperLogin.matches(email: "admin@dayledger.local", password: "123"))
        XCTAssertFalse(DeveloperLogin.matches(email: "root", password: "123"))
    }

    @MainActor
    func testDeveloperSignInNeverCallsTheBackendAndPersistsOnlyAFlag() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DeveloperLogin.sessionKey)
        defer { defaults.set(previous, forKey: DeveloperLogin.sessionKey) }

        let auth = MockAuthService(isConfigured: false)
        let account = AccountController(auth: auth)
        var rebuilt = false
        account.onDeveloperSessionChanged = { rebuilt = true }

        try await account.signIn(email: "admin", password: "123")

        XCTAssertTrue(rebuilt)
        XCTAssertTrue(auth.calls.isEmpty, "No Supabase call for the developer login")
        XCTAssertTrue(DeveloperLogin.isSignedIn())
        XCTAssertEqual(defaults.object(forKey: DeveloperLogin.sessionKey) as? Bool, true, "Only a Bool flag is stored, never the password")

        do {
            try await account.signIn(email: "admin", password: "wrong")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .notConfigured, "Other passwords go to the (unconfigured) backend")
        }
    }

    func testEmailFieldAcceptsAdminOnlyForLogIn() {
        var form = EmailAuthForm(mode: .logIn, email: "admin", password: "123")
        XCTAssertNil(form.emailError)
        XCTAssertTrue(form.canSubmit)
        form.mode = .register
        XCTAssertNotNil(form.emailError)
    }
    #endif
}

final class EmailAuthFormTests: XCTestCase {
    func testLogInNeedsValidEmailAndAnyPassword() {
        var form = EmailAuthForm(mode: .logIn)
        XCTAssertFalse(form.canSubmit)
        form.email = "ana@example"
        XCTAssertNotNil(form.emailError)
        form.email = " ana@example.com "
        XCTAssertNil(form.emailError)
        XCTAssertNotNil(form.passwordError)
        form.password = "short"
        XCTAssertTrue(form.canSubmit, "Existing passwords aren't checked against the new rules")
    }

    func testRegisterEnforcesRulesAndConfirmation() {
        var form = EmailAuthForm(mode: .register, email: "ana@example.com", password: "1234567")
        XCTAssertEqual(form.passwordError, "Use at least 8 characters.")
        form.password = "12345678"
        XCTAssertNil(form.passwordError)
        XCTAssertNotNil(form.confirmError)
        form.confirmPassword = "12345679"
        XCTAssertEqual(form.confirmError, "The passwords don't match.")
        form.confirmPassword = "12345678"
        XCTAssertTrue(form.canSubmit)
    }

    func testEmailShapes() {
        XCTAssertTrue(EmailAuthForm.isValidEmail("a.b+c@sub.example.co.uk"))
        XCTAssertFalse(EmailAuthForm.isValidEmail("a@b"))
        XCTAssertFalse(EmailAuthForm.isValidEmail("@example.com"))
        XCTAssertFalse(EmailAuthForm.isValidEmail("a b@example.com"))
        XCTAssertFalse(EmailAuthForm.isValidEmail("a@@example.com"))
    }
}

final class AppGateTests: XCTestCase {
    private func state(uiTesting: Bool = false, developer: Bool = false, configured: Bool = true, debug: Bool = false,
                       signedIn: Bool = false, entitlement: AppGate.Entitlement = .unknown) -> AppGateState {
        AppGate.state(isUITesting: uiTesting, isDeveloperAccount: developer, isConfigured: configured, isDebugBuild: debug,
                      isSignedIn: signedIn, entitlement: entitlement)
    }

    func testUITestsSkipAccounts() {
        XCTAssertEqual(state(uiTesting: true, configured: false), .main)
        XCTAssertEqual(state(uiTesting: true, signedIn: false), .main)
    }

    func testSignedOut() {
        XCTAssertEqual(state(configured: true), .signedOut)
        XCTAssertEqual(state(configured: false, debug: true), .signedOut, "Debug builds show the login screens without a backend")
        XCTAssertEqual(state(configured: false, debug: false), .accountsNotConfigured)
    }

    func testSignedInFollowsEntitlement() {
        XCTAssertEqual(state(signedIn: true, entitlement: .unknown), .checkingSubscription)
        XCTAssertEqual(state(signedIn: true, entitlement: .notEntitled), .paywall)
        XCTAssertEqual(state(signedIn: true, entitlement: .entitled), .main)
    }

    func testDeveloperAccountSkipsPaywall() {
        XCTAssertEqual(state(developer: true, configured: false, debug: true, signedIn: true, entitlement: .notEntitled), .main)
    }

    @MainActor
    func testSubscriptionManagerGateStates() {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        XCTAssertEqual(SubscriptionManager(mode: .alwaysEntitled, rest: nil, defaults: defaults).gateEntitlement, .entitled)
        XCTAssertEqual(SubscriptionManager(mode: .disabled, rest: nil, defaults: defaults).gateEntitlement, .unknown)
    }

    @MainActor
    func testAuthCallbackURLsAreRecognisedWithoutStealingBankCallbacks() {
        XCTAssertTrue(AccountController.isAuthCallback(URL(string: "dayledger://auth-callback?code=abc")!))
        XCTAssertFalse(AccountController.isAuthCallback(URL(string: "dayledger://truelayer-callback?code=abc")!))
        let account = AccountController(auth: MockAuthService())
        XCTAssertFalse(account.handleOpenURL(URL(string: "dayledger://truelayer-callback?code=abc")!))
    }
}
