import Foundation
import UniFiBSON

/// Offline security / hygiene lint over a single mapped backup. Pure value
/// logic — every rule reads only the model (typed fields plus `rawDocument`)
/// and the backup `Identity`, and each finding is independently derivable and
/// testable. No secret *values* are ever emitted (lengths and field names only);
/// the `isSecretField` predicate is accepted for callers that want to gate any
/// value echoing, and is honoured by the fact that findings never print secrets.
public struct ConfigAudit: Sendable {

    public enum Severity: String, Sendable, Hashable, Comparable, CaseIterable {
        case info
        case low
        case medium
        case high
        case critical

        private var rank: Int {
            switch self {
            case .info: return 0
            case .low: return 1
            case .medium: return 2
            case .high: return 3
            case .critical: return 4
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    public struct Finding: Sendable, Hashable, Identifiable {
        public let id: String
        public let severity: Severity
        public let category: String
        public let title: String
        public let detail: String
        public let collection: String?
        public let recordId: String?
        public let recommendation: String?
        public init(
            id: String,
            severity: Severity,
            category: String,
            title: String,
            detail: String,
            collection: String?,
            recordId: String?,
            recommendation: String?
        ) {
            self.id = id
            self.severity = severity
            self.category = category
            self.title = title
            self.detail = detail
            self.collection = collection
            self.recordId = recordId
            self.recommendation = recommendation
        }
    }

    /// Sorted severity-descending, then category, title, id.
    public let findings: [Finding]

    public init(findings: [Finding]) {
        self.findings = findings
    }

    public var summaryBySeverity: [Severity: Int] {
        var out: [Severity: Int] = [:]
        for f in findings { out[f.severity, default: 0] += 1 }
        return out
    }

    // MARK: - Categories

    private enum Category {
        static let wlan = "WLAN Security"
        static let firewall = "Firewall"
        static let portForwarding = "Port Forwarding"
        static let admin = "Admin & Access"
        static let firmware = "Firmware"
        static let restore = "Restore Safety"
    }

    private static let managementPorts: Set<Int> = [22, 443, 8443, 8080, 27117]

    // MARK: - Run

    public static func run(
        model: ModelMapper.MappedModel, identity: Identity,
        isSecretField: @Sendable (String) -> Bool = { _ in false }
    ) -> ConfigAudit {
        var findings: [Finding] = []
        findings += wlanFindings(model)
        findings += portForwardFindings(model)
        findings += firewallFindings(model)
        findings += adminFindings(model)
        findings += firmwareFindings(model, identity: identity)
        findings += restoreSafetyFindings(model, identity: identity)

        findings.sort { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            if a.category != b.category { return a.category < b.category }
            if a.title != b.title { return a.title < b.title }
            return a.id < b.id
        }
        return ConfigAudit(findings: findings)
    }

    // MARK: - WLAN rules

    private static func wlanFindings(_ m: ModelMapper.MappedModel) -> [Finding] {
        var out: [Finding] = []
        for w in m.wlans {
            let d = w.rawDocument
            let sec = (d["security"]?.stringValue ?? w.security ?? "").lowercased()
            let wpa = (d["wpa_mode"]?.stringValue ?? w.wpaMode ?? "").lowercased()
            let pass = w.passphrase ?? d["x_passphrase"]?.stringValue
            let ssid = firstNonEmpty(w.name, d["name"]?.stringValue) ?? w.id
            let noPass = (pass == nil) || (pass?.isEmpty ?? true)

            if sec == "open" || sec == "none" || (sec.isEmpty && noPass) {
                out.append(Finding(
                    id: "wlan-open-\(w.id)",
                    severity: .high,
                    category: Category.wlan,
                    title: "Open WLAN '\(ssid)'",
                    detail: "SSID '\(ssid)' has no wireless encryption configured (security=\(sec.isEmpty ? "none" : sec)). Anyone in range can join and sniff traffic.",
                    collection: "wlanconf",
                    recordId: w.id,
                    recommendation: "Enable WPA2, or WPA3 / WPA2-WPA3 transition where the hardware supports it."
                ))
            } else if sec == "wep" {
                out.append(Finding(
                    id: "wlan-wep-\(w.id)",
                    severity: .high,
                    category: Category.wlan,
                    title: "WEP WLAN '\(ssid)'",
                    detail: "SSID '\(ssid)' uses WEP, which is trivially breakable in minutes.",
                    collection: "wlanconf",
                    recordId: w.id,
                    recommendation: "Replace WEP with WPA2/WPA3."
                ))
            } else if wpa == "wpa1" {
                out.append(Finding(
                    id: "wlan-wpa1-\(w.id)",
                    severity: .medium,
                    category: Category.wlan,
                    title: "WPA1-only WLAN '\(ssid)'",
                    detail: "SSID '\(ssid)' is configured for WPA1 only, which uses TKIP and is deprecated.",
                    collection: "wlanconf",
                    recordId: w.id,
                    recommendation: "Move to WPA2 (AES/CCMP) at minimum, WPA3 where possible."
                ))
            }

            if let p = pass, !p.isEmpty, p.count < 12 {
                out.append(Finding(
                    id: "wlan-shortpsk-\(w.id)",
                    severity: .medium,
                    category: Category.wlan,
                    title: "Short PSK on WLAN '\(ssid)'",
                    detail: "The pre-shared key for '\(ssid)' is \(p.count) characters; short keys fall quickly to offline brute force.",
                    collection: "wlanconf",
                    recordId: w.id,
                    recommendation: "Use a passphrase of at least 12 characters (ideally a long random string)."
                ))
            }

            let isGuest = w.isGuest ?? d["is_guest"]?.boolValue ?? false
            if isGuest {
                let isolated = d["l2_isolation"]?.boolValue ?? false
                if !isolated {
                    out.append(Finding(
                        id: "wlan-guest-noiso-\(w.id)",
                        severity: .low,
                        category: Category.wlan,
                        title: "Guest WLAN without L2 isolation '\(ssid)'",
                        detail: "SSID '\(ssid)' is marked as a guest network but has no layer-2 isolation flag set, so guests may reach one another.",
                        collection: "wlanconf",
                        recordId: w.id,
                        recommendation: "Enable client/L2 isolation or attach a guest policy for this SSID."
                    ))
                }
            }
        }
        return out
    }

    // MARK: - Port-forwarding rules

    private static func portForwardFindings(_ m: ModelMapper.MappedModel) -> [Finding] {
        var out: [Finding] = []
        for pf in m.portForwards where pf.enabled != false {
            let d = pf.rawDocument
            let name = firstNonEmpty(pf.name, d["name"]?.stringValue) ?? pf.id
            let dstHits = portsIn(pf.dstPort ?? d["dst_port"]?.stringValue).intersection(managementPorts)
            let fwdHits = portsIn(pf.fwdPort ?? d["fwd_port"]?.stringValue).intersection(managementPorts)
            let mgmtHits = dstHits.union(fwdHits)
            let proto = (pf.proto ?? d["proto"]?.stringValue ?? "").lowercased()

            var reasons: [String] = []
            if !mgmtHits.isEmpty {
                let portList = mgmtHits.sorted().map { String($0) }.joined(separator: ", ")
                reasons.append("exposes management/service port(s) \(portList)")
            }
            if proto == "any" || proto == "all" {
                reasons.append("permits all protocols")
            }
            guard !reasons.isEmpty else { continue }

            let src = (pf.src ?? d["src"]?.stringValue ?? "").lowercased()
            if src.isEmpty || src == "any" || src == "0.0.0.0/0" {
                reasons.append("open to any source address")
            }

            out.append(Finding(
                id: "pf-exposure-\(pf.id)",
                severity: .high,
                category: Category.portForwarding,
                title: "Risky port forward '\(name)'",
                detail: "Port forward '\(name)' \(reasons.joined(separator: "; ")).",
                collection: "portforward",
                recordId: pf.id,
                recommendation: "Restrict the source range, avoid forwarding management ports, and prefer a VPN for remote administration."
            ))
        }
        return out
    }

    // MARK: - Firewall rules

    private static func firewallFindings(_ m: ModelMapper.MappedModel) -> [Finding] {
        var out: [Finding] = []
        for fr in m.firewallRules where fr.enabled != false {
            guard (fr.action ?? fr.rawDocument["action"]?.stringValue ?? "").lowercased() == "accept" else { continue }
            let d = fr.rawDocument
            let proto = (d["protocol"]?.stringValue ?? fr.proto ?? "").lowercased()
            let protoOpen = proto.isEmpty || proto == "all" || proto == "any"

            let hasSrc = nonEmptyString(d, "src_address")
                || nonEmptyArray(d, "src_firewallgroup_ids")
                || present(d, "src_networkconf_id")
            let hasDst = nonEmptyString(d, "dst_address")
                || nonEmptyArray(d, "dst_firewallgroup_ids")
                || present(d, "dst_networkconf_id")

            if protoOpen && !hasSrc && !hasDst {
                let name = firstNonEmpty(fr.name, d["name"]?.stringValue) ?? fr.id
                out.append(Finding(
                    id: "fw-anyaccept-\(fr.id)",
                    severity: .medium,
                    category: Category.firewall,
                    title: "Any/any accept rule '\(name)'",
                    detail: "Firewall rule '\(name)' accepts traffic with no source, destination, or protocol constraint.",
                    collection: "firewallrule",
                    recordId: fr.id,
                    recommendation: "Scope the rule to specific networks, addresses, groups, or protocols."
                ))
            }
        }
        return out
    }

    // MARK: - Admin & access

    private static func adminFindings(_ m: ModelMapper.MappedModel) -> [Finding] {
        guard !m.admins.isEmpty else { return [] }
        let hasVerification = m.opaqueCollections.contains {
            $0.name == "verification" && !$0.records.isEmpty
        }
        guard !hasVerification else { return [] }
        return [Finding(
            id: "admin-no-2fa",
            severity: .low,
            category: Category.admin,
            title: "No admin 2FA/TOTP configured",
            detail: "\(m.admins.count) admin account(s) present but the `verification` collection (which holds TOTP secrets) is absent, so no administrator appears to have two-factor authentication enabled.",
            collection: nil,
            recordId: nil,
            recommendation: "Enable multi-factor authentication for every controller administrator."
        )]
    }

    // MARK: - Firmware

    private static func firmwareFindings(_ m: ModelMapper.MappedModel, identity: Identity) -> [Finding] {
        var out: [Finding] = []
        let controllerNote = identity.version.map { " (backup produced by controller \($0))" } ?? ""
        for dev in m.devices {
            let label = firstNonEmpty(dev.name, dev.mac) ?? dev.id
            let raw = dev.version ?? dev.rawDocument["version"]?.stringValue
            guard let major = majorVersion(raw) else {
                out.append(Finding(
                    id: "device-firmware-unknown-\(dev.id)",
                    severity: .low,
                    category: Category.firmware,
                    title: "Unknown firmware on '\(label)'",
                    detail: "Device '\(label)' has no parseable firmware version\(controllerNote).",
                    collection: "device",
                    recordId: dev.id,
                    recommendation: "Confirm the device is adopted and running a current, supported firmware."
                ))
                continue
            }
            // Device firmware versioning is independent of controller
            // versioning, so we flag only clearly ancient majors rather than a
            // fragile relative comparison.
            if major < 4 {
                out.append(Finding(
                    id: "device-firmware-old-\(dev.id)",
                    severity: .low,
                    category: Category.firmware,
                    title: "Old firmware on '\(label)'",
                    detail: "Device '\(label)' reports firmware major version \(major)\(controllerNote), which is well behind current releases.",
                    collection: "device",
                    recordId: dev.id,
                    recommendation: "Upgrade the device to a current, supported firmware."
                ))
            }
        }
        return out
    }

    // MARK: - Restore safety (ROADMAP §3.2)

    private static func restoreSafetyFindings(_ m: ModelMapper.MappedModel, identity: Identity) -> [Finding] {
        var out: [Finding] = []
        if identity.kind == .full && m.sites.count > 1 {
            out.append(Finding(
                id: "restore-multisite",
                severity: .medium,
                category: Category.restore,
                title: "Multi-site full backup",
                detail: "A UniFi OS console import of a full backup only restores the Default site; \(m.sites.count) sites present here will not all import.",
                collection: "site",
                recordId: nil,
                recommendation: "Export each non-default site separately, or restore onto a self-hosted controller that preserves all sites."
            ))
        }
        if !m.firewallRules.isEmpty {
            out.append(Finding(
                id: "restore-legacy-fw",
                severity: .info,
                category: Category.restore,
                title: "Legacy firewall rules present",
                detail: "\(m.firewallRules.count) legacy firewall rule(s) are present; a modern UniFi OS console import can silently drop legacy rules in favour of zone-based policies.",
                collection: "firewallrule",
                recordId: nil,
                recommendation: "Review firewall rules after any migration to a modern console."
            ))
        }
        return out
    }

    // MARK: - Helpers

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for c in candidates {
            if let c, !c.isEmpty { return c }
        }
        return nil
    }

    private static func nonEmptyString(_ d: BSONDocument, _ key: String) -> Bool {
        if let s = d[key]?.stringValue, !s.isEmpty { return true }
        return false
    }

    private static func nonEmptyArray(_ d: BSONDocument, _ key: String) -> Bool {
        if let a = d[key]?.arrayValue, !a.isEmpty { return true }
        return false
    }

    private static func present(_ d: BSONDocument, _ key: String) -> Bool {
        switch d[key] {
        case .none, .some(.null): return false
        case .some(.string(let s)): return !s.isEmpty
        default: return true
        }
    }

    /// Ports referenced by a UniFi port string: single values, comma/space
    /// lists, and ranges (`"8000-8500"`). For ranges we retain the endpoints
    /// plus any management port they span, which is all membership tests need.
    static func portsIn(_ s: String?) -> Set<Int> {
        guard let s, !s.isEmpty else { return [] }
        var result: Set<Int> = []
        let tokens = s.split(whereSeparator: { $0 == "," || $0 == " " })
        for token in tokens {
            let t = token.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.contains("-") {
                let parts = t.split(separator: "-", maxSplits: 1).map { String($0) }
                if parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]), lo <= hi {
                    result.insert(lo)
                    result.insert(hi)
                    for p in managementPorts where p >= lo && p <= hi { result.insert(p) }
                }
            } else if let p = Int(t) {
                result.insert(p)
            }
        }
        return result
    }

    static func majorVersion(_ v: String?) -> Int? {
        guard let v else { return nil }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let head = trimmed.prefix { $0.isNumber }
        return Int(head)
    }

    // MARK: - Markdown rendering

    public func markdownReport() -> String {
        var out = "# Config Audit\n\n"
        let summary = summaryBySeverity
        if findings.isEmpty {
            out += "_No findings._\n"
            return out
        }
        out += "| Severity | Count |\n|---|---|\n"
        for sev in Severity.allCases.reversed() {
            if let n = summary[sev], n > 0 {
                out += "| \(sev.rawValue) | \(n) |\n"
            }
        }
        out += "\n"

        var currentCategory: String? = nil
        for f in findings {
            if f.category != currentCategory {
                out += "## \(f.category)\n\n"
                currentCategory = f.category
            }
            out += "### [\(f.severity.rawValue.uppercased())] \(f.title)\n\n"
            out += "\(f.detail)\n\n"
            if let coll = f.collection {
                let rec = f.recordId.map { " `\($0)`" } ?? ""
                out += "- Location: `\(coll)`\(rec)\n"
            }
            if let rec = f.recommendation {
                out += "- Recommendation: \(rec)\n"
            }
            out += "\n"
        }
        return out
    }
}
