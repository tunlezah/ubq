import Foundation
import UniFiBSON
import UniFiModel

/// Registry of BSON field names that carry secrets and must be redacted on
/// export unless the user explicitly opts in.
public enum SecretVault {
    /// Field names across all collections that should be treated as secret.
    public static let secretFieldNames: Set<String> = [
        "x_passphrase",
        "x_password",
        "x_shadow",
        "x_key",
        "x_cert",
        "x_ca_crts",
        "x_ssh_keys",
        "secret",
        "api_key",
        "apiKey",
        "totp_secret",
        "totp_backup_codes",
        "backup_codes",
        "openvpn_configuration",
        "client_cert",
        "private_key",
        "pre_shared_key",
        "radius_secret",
        "wpa_personal_psk",
        "wpa2_psk",
        "wpa3_psk",
        "shared_secret",
        "cloud_access_key",
        "cloud_secret_key",
        "sso_password",
        "hotspot_password",
        "password",
        "passwd"
    ]

    /// Returns a Set of fully-qualified field paths ("setting.mgmt.x_ssh_keys"
    /// etc.) where secrets are found within a document. Used by the UI to
    /// display "this record contains N secrets" summaries.
    public static func findSecrets(in doc: BSONDocument, prefix: String = "") -> [String] {
        var paths: [String] = []
        for (key, value) in doc.pairs {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if secretFieldNames.contains(key) {
                paths.append(path)
            }
            switch value {
            case .document(let nested):
                paths.append(contentsOf: findSecrets(in: nested, prefix: path))
            case .array(let values):
                for (i, v) in values.enumerated() {
                    if case .document(let nested) = v {
                        paths.append(contentsOf: findSecrets(in: nested, prefix: "\(path)[\(i)]"))
                    }
                }
            default:
                continue
            }
        }
        return paths
    }

    /// Returns a copy of `doc` with every secret field replaced by
    /// `BSONValue.string("<redacted>")`. Recursive over documents and arrays.
    public static func redact(_ doc: BSONDocument) -> BSONDocument {
        var out = BSONDocument()
        for (key, value) in doc.pairs {
            if secretFieldNames.contains(key) {
                out[key] = .string("<redacted>")
            } else {
                switch value {
                case .document(let d):
                    out[key] = .document(redact(d))
                case .array(let values):
                    out[key] = .array(values.map(redactValue))
                default:
                    out[key] = value
                }
            }
        }
        return out
    }

    private static func redactValue(_ v: BSONValue) -> BSONValue {
        switch v {
        case .document(let d): .document(redact(d))
        case .array(let values): .array(values.map(redactValue))
        default: v
        }
    }

    /// Counts secrets across the whole backup's documents. Useful for the
    /// "secret inventory" affordance in the UI.
    public static func inventory(model: ModelMapper.MappedModel) -> [String: Int] {
        var counts: [String: Int] = [:]
        func tally(_ docs: [BSONDocument], under label: String) {
            for d in docs {
                for p in findSecrets(in: d) {
                    let key = "\(label).\(p)"
                    counts[key, default: 0] += 1
                }
            }
        }
        tally(model.wlans.map(\.rawDocument), under: "wlanconf")
        tally(model.admins.map(\.rawDocument), under: "admin")
        tally(model.accounts.map(\.rawDocument), under: "account")
        tally(model.radiusProfiles.map(\.rawDocument), under: "radiusprofile")
        tally(model.hotspotOperators.map(\.rawDocument), under: "hotspotop")
        tally(model.settings.map(\.rawDocument), under: "setting")
        for c in model.opaqueCollections {
            tally(c.records.map(\.rawDocument), under: c.name)
        }
        return counts
    }
}
