import AccountKit
import BankKit
import SecureStore
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
    private func access(uiTesting: Bool = false, developer: Bool = false, configured: Bool = true, debug: Bool = false,
                        signedIn: Bool = false, entitlement: AppGate.Entitlement = .unknown) -> ProAccess {
        AppGate.proAccess(isUITesting: uiTesting, isDeveloperAccount: developer, isConfigured: configured, isDebugBuild: debug,
                          isSignedIn: signedIn, entitlement: entitlement)
    }

    func testUITestsHaveNoAccountsButReachTheOptInFlows() {
        XCTAssertEqual(access(uiTesting: true, configured: false), .available)
        XCTAssertEqual(access(uiTesting: true, signedIn: false), .available)
    }

    func testSignedOutUsersAreAskedToSignInOnlyForPro() {
        XCTAssertEqual(access(configured: true), .signInRequired)
        XCTAssertEqual(access(configured: false, debug: true), .signInRequired, "Debug builds offer the login screens without a backend")
        XCTAssertEqual(access(configured: false, debug: false), .unavailable, "Release without a backend: no Pro, the app still works")
    }

    func testSignedInFollowsEntitlement() {
        XCTAssertEqual(access(signedIn: true, entitlement: .unknown), .checking)
        XCTAssertEqual(access(signedIn: true, entitlement: .notEntitled), .subscriptionRequired)
        XCTAssertEqual(access(signedIn: true, entitlement: .entitled), .available)
    }

    func testDeveloperAccountIsAlwaysPro() {
        XCTAssertEqual(access(developer: true, configured: false, debug: true, signedIn: true, entitlement: .notEntitled), .available)
    }

    func testTheRightSheetUnlocksPro() {
        XCTAssertEqual(AppGate.sheet(toUnlock: .signInRequired), .signIn)
        XCTAssertEqual(AppGate.sheet(toUnlock: .subscriptionRequired), .paywall)
        XCTAssertEqual(AppGate.sheet(toUnlock: .checking), .paywall)
        XCTAssertNil(AppGate.sheet(toUnlock: .available))
        XCTAssertNil(AppGate.sheet(toUnlock: .unavailable))
    }

    /// Local-first: a signed-out user gets the app, and asking for Pro opens sign-in.
    @MainActor
    func testSignedOutUserGetsTheAppAndCanAskForPro() {
        let environment = AppEnvironment(
            configuration: AppConfiguration(trueLayerClientID: "", trueLayerClientSecret: "", trueLayerEnvironment: "sandbox",
                                            googleClientID: "", appGroupID: "", supabaseURL: "https://abc.supabase.co", supabaseAnonKey: "anon"),
            modelContainer: PersistenceController.makeContainer(appGroupID: "", inMemory: true),
            defaults: UserDefaults(suiteName: "gate.\(UUID().uuidString)")!,
            secureStore: InMemorySecureStore(),
            bankService: MockBankService(connected: true),
            isUITesting: false,
            auth: MockAuthService(isConfigured: true)
        )
        XCTAssertFalse(environment.account.isSignedIn)
        XCTAssertEqual(environment.proAccess, .signInRequired)
        XCTAssertNil(environment.accountSheet, "Nothing is presented until the user asks")
        environment.requestPro()
        XCTAssertEqual(environment.accountSheet, .signIn)
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

/// TrueLayer's client secret must never be needed outside Debug: the backend exchanges tokens.
@MainActor
final class TokenExchangerSelectionTests: XCTestCase {
    private func configuration(secret: String, supabaseURL: String) -> AppConfiguration {
        AppConfiguration(trueLayerClientID: "sandbox-1", trueLayerClientSecret: secret, trueLayerEnvironment: "sandbox",
                         googleClientID: "", appGroupID: "", supabaseURL: supabaseURL, supabaseAnonKey: "anon")
    }

    func testUsesTheBackendWhenNoSecretIsConfigured() {
        let exchanger = AppEnvironment.makeTokenExchanger(configuration: configuration(secret: "", supabaseURL: "https://abc.supabase.co"),
                                                          trueLayer: TrueLayerConfiguration(clientID: "sandbox-1"))
        XCTAssertTrue(exchanger is BackendTrueLayerTokenExchanger)
    }

    func testWithoutBackendOrSecretBankConnectionsSayNotConfigured() {
        let exchanger = AppEnvironment.makeTokenExchanger(configuration: configuration(secret: "", supabaseURL: ""),
                                                          trueLayer: TrueLayerConfiguration(clientID: "sandbox-1"))
        XCTAssertTrue(exchanger is UnavailableTrueLayerTokenExchanger)
    }

    #if DEBUG
    func testDebugBuildsMayUseALocalSandboxSecret() {
        let exchanger = AppEnvironment.makeTokenExchanger(configuration: configuration(secret: "s", supabaseURL: "https://abc.supabase.co"),
                                                          trueLayer: TrueLayerConfiguration(clientID: "sandbox-1"))
        XCTAssertTrue(exchanger is DirectTrueLayerTokenExchanger)
    }
    #endif
}
