import Foundation

/// One namespace for logging and notifications, taken from the bundle identifier set by
/// `scripts/build-app.sh` (override with `BUNDLE_ID=...`). Unbundled runs use "DozzleDesk".
public enum AppIdentity {
    public static let id = Bundle.main.bundleIdentifier ?? "DozzleDesk"
}
