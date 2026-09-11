//
//  ProfilePicker.swift
//  Browserino
//

import SwiftUI

/// Chooses which Chromium profile a rule or site mapping opens in. Renders nothing
/// unless the chosen app actually has several, so it stays out of the way for
/// Safari, Firefox and single-profile browsers.
struct ProfilePicker: View {
    let app: URL?
    @Binding var profile: String?

    private var profiles: [ChromiumProfile] {
        guard let app else {
            return []
        }

        return ChromiumProfileService.profiles(forAppAt: app) ?? []
    }

    var body: some View {
        if profiles.count > 1 {
            Picker("Profile:", selection: $profile) {
                Text("Last used")
                    .tag(String?.none)

                ForEach(profiles, id: \.directory) { profile in
                    Text(profile.name)
                        .tag(String?.some(profile.directory))
                }
            }
            .font(
                .system(size: 14)
            )
        }
    }
}
