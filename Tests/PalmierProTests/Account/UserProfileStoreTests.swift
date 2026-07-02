import Foundation
import Testing
@testable import PalmierPro

@Suite("UserProfileStore — onboarding state")
@MainActor
struct UserProfileStoreTests {

    @Test func localMirrorRoundTrips() {
        let uid = "test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "onboarded-\(uid)") }

        #expect(!UserProfileStore.localMirror(userId: uid))
        UserProfileStore.setLocalMirror(userId: uid, onboarded: true)
        #expect(UserProfileStore.localMirror(userId: uid))
        UserProfileStore.setLocalMirror(userId: uid, onboarded: false)
        #expect(!UserProfileStore.localMirror(userId: uid))
    }

    @Test func mirrorIsPerUser() {
        let a = "test-\(UUID().uuidString)"
        let b = "test-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "onboarded-\(a)")
            UserDefaults.standard.removeObject(forKey: "onboarded-\(b)")
        }
        UserProfileStore.setLocalMirror(userId: a, onboarded: true)
        #expect(UserProfileStore.localMirror(userId: a))
        #expect(!UserProfileStore.localMirror(userId: b))
    }

    @Test func signedOutIsNeverOnboarded() {
        // No Supabase session in tests → no user id → onboarding gate applies.
        #expect(SupabaseService.shared.currentUserId == nil)
        #expect(!UserProfileStore.shared.isOnboarded)
    }

    @Test func profileDecodesSupabaseRow() throws {
        let json = """
        {"user_id": "0B0AA55B-2E77-4C6D-8F4E-111111111111",
         "editing_domain": "malay_wedding",
         "onboarding_completed_at": "2026-07-02T10:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(UserProfileStore.Profile.self, from: Data(json.utf8))
        #expect(profile.editing_domain == "malay_wedding")
        #expect(profile.onboarding_completed_at != nil)
    }
}
