import Foundation

/// Persists recently-opened files as **security-scoped bookmarks** so they
/// survive relaunch under the App Sandbox.
///
/// Freshly picked files (via `NSOpenPanel`) are readable for the session
/// automatically, but that grant does not persist. To reopen a file after a
/// relaunch we must store a security-scoped bookmark (entitlement
/// `com.apple.security.files.bookmarks.app-scope`) and, on resolve, bracket the
/// read with `startAccessingSecurityScopedResource()` /
/// `stopAccessingSecurityScopedResource()`.
struct RecentFilesStore {
    private static let key = "recentFileBookmarks"
    private static let maxEntries = 10

    /// A resolved recent entry. `needsScopeRelease` is true when the URL was
    /// resolved from a security-scoped bookmark and the caller must call
    /// `stopAccessingSecurityScopedResource()` once it has finished reading.
    struct Resolved {
        let url: URL
        let needsScopeRelease: Bool
    }

    /// Returns the display URLs of the stored recents, newest first. Stale
    /// bookmarks are dropped.
    static func urls() -> [URL] {
        bookmarks().compactMap { data in
            var stale = false
            return try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        }
    }

    /// Records `url` as the most-recent entry, de-duplicating by path.
    static func add(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        var existing = bookmarks()
        // Drop any bookmark that resolves to the same file.
        existing.removeAll { candidate in
            var stale = false
            let resolved = try? URL(
                resolvingBookmarkData: candidate,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return resolved?.standardizedFileURL == url.standardizedFileURL
        }
        existing.insert(data, at: 0)
        if existing.count > maxEntries { existing.removeLast(existing.count - maxEntries) }
        UserDefaults.standard.set(existing, forKey: key)
    }

    /// Resolves the bookmark whose file matches `url` and begins security-scoped
    /// access. The caller owns releasing the scope via the returned flag.
    static func resolveForOpening(_ url: URL) -> Resolved {
        for data in bookmarks() {
            var stale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            if resolved.standardizedFileURL == url.standardizedFileURL {
                let began = resolved.startAccessingSecurityScopedResource()
                return Resolved(url: resolved, needsScopeRelease: began)
            }
        }
        // Not a stored bookmark (e.g. a just-picked file); no scope to manage.
        return Resolved(url: url, needsScopeRelease: false)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func bookmarks() -> [Data] {
        (UserDefaults.standard.array(forKey: key) as? [Data]) ?? []
    }
}
