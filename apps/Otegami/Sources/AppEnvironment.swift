import Foundation

/// Root dependency-injection container for the app. Empty scaffold for M0;
/// will grow to hold the database, sync coordinator, and account store as
/// those land (M1+).
@MainActor
@Observable
final class AppEnvironment {
    init() {}
}
