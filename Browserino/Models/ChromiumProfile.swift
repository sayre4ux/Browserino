//
//  ChromiumProfile.swift
//  Browserino
//

import AppKit
import Foundation

struct ChromiumProfile: Hashable {
    /// Directory name on disk, e.g. "Default" or "Profile 2". This is what
    /// --profile-directory takes, not the display name.
    let directory: String
    let name: String
    let avatar: URL?
}

@MainActor
enum ChromiumProfileService {
    /// Chromium locates its user data directory from CrProductDirName in its own
    /// Info.plist. Stable Chrome omits the key and relies on a compiled-in default,
    /// so a fallback is still needed — but reading the key first means forks and
    /// beta channels work without being listed here, and non-Chromium browsers
    /// fall out on their own.
    private static let fallbackDirectoryNames: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.dev": "Google/Chrome Dev",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "company.thebrowser.Browser": "Arc/User Data",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.operasoftware.Opera": "com.operasoftware.Opera",
        "org.chromium.Chromium": "Chromium",
    ]

    private static var cache: [URL: (modified: Date, profiles: [ChromiumProfile])] = [:]
    private static var avatarImages: [URL: NSImage] = [:]

    /// Avatars are read while laying out rows, so keep them off the disk path.
    static func avatarImage(_ url: URL) -> NSImage? {
        if let cached = avatarImages[url] {
            return cached
        }

        guard let image = NSImage(contentsOf: url) else {
            return nil
        }

        avatarImages[url] = image

        return image
    }

    private struct LocalState: Decodable {
        struct Profile: Decodable {
            struct Info: Decodable {
                let name: String?
                let isEphemeral: Bool?
                let gaiaPictureFileName: String?

                enum CodingKeys: String, CodingKey {
                    case name
                    case isEphemeral = "is_ephemeral"
                    case gaiaPictureFileName = "gaia_picture_file_name"
                }
            }

            let infoCache: [String: Info]?
            let profilesOrder: [String]?

            enum CodingKeys: String, CodingKey {
                case infoCache = "info_cache"
                case profilesOrder = "profiles_order"
            }
        }

        let profile: Profile?
    }

    /// nil when the app is not a Chromium browser.
    static func userDataDirectory(forAppAt app: URL) -> URL? {
        guard let bundle = Bundle(url: app) else {
            return nil
        }

        let relativePath = bundle.infoDictionary?["CrProductDirName"] as? String
            ?? bundle.bundleIdentifier.flatMap { fallbackDirectoryNames[$0] }

        guard let relativePath,
              let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
              ).first
        else {
            return nil
        }

        return support.appending(path: relativePath)
    }

    /// nil means "could not determine" — either not a Chromium browser, or Local
    /// State was unreadable because the browser was mid-write. Callers must not
    /// collapse that into "no profiles", or a transient failure deletes rows the
    /// user has ordered, hidden and assigned shortcuts to.
    static func profiles(forAppAt app: URL) -> [ChromiumProfile]? {
        guard let root = userDataDirectory(forAppAt: app) else {
            return nil
        }

        let localState = root.appending(path: "Local State")

        guard let modified = try? FileManager.default.attributesOfItem(
            atPath: localState.path
        )[.modificationDate] as? Date else {
            return nil
        }

        if let cached = cache[app], cached.modified == modified {
            return cached.profiles
        }

        guard let data = try? Data(contentsOf: localState),
              let state = try? JSONDecoder().decode(LocalState.self, from: data),
              let infoCache = state.profile?.infoCache
        else {
            return nil
        }

        let ordered = order(
            directories: Array(infoCache.keys),
            preferring: state.profile?.profilesOrder
        )

        let profiles: [ChromiumProfile] = ordered.compactMap { directory in
            guard let info = infoCache[directory], info.isEphemeral != true else {
                return nil
            }

            return ChromiumProfile(
                directory: directory,
                name: info.name ?? directory,
                avatar: avatarURL(root: root, directory: directory, info: info)
            )
        }

        cache[app] = (modified, profiles)

        return profiles
    }

    /// The picture is only cached on disk for signed-in profiles, and its filename
    /// is recorded in Local State rather than being fixed.
    private static func avatarURL(
        root: URL,
        directory: String,
        info: LocalState.Profile.Info
    ) -> URL? {
        guard let fileName = info.gaiaPictureFileName else {
            return nil
        }

        let url = root.appending(path: directory).appending(path: fileName)

        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// profiles_order is Chromium's own display order. Anything missing from it is
    /// appended deterministically — JSON object order is not stable.
    private static func order(directories: [String], preferring order: [String]?) -> [String] {
        let known = order ?? []
        let remaining = Set(directories).subtracting(known)

        return known.filter(directories.contains) + remaining.sorted { lhs, rhs in
            if lhs == "Default" || rhs == "Default" {
                return lhs == "Default"
            }

            switch (profileNumber(lhs), profileNumber(rhs)) {
            case let (lhsNumber?, rhsNumber?):
                return lhsNumber < rhsNumber
            case (nil, nil):
                return lhs < rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            }
        }
    }

    private static func profileNumber(_ directory: String) -> Int? {
        guard directory.hasPrefix("Profile ") else {
            return nil
        }

        return Int(directory.dropFirst("Profile ".count))
    }
}
