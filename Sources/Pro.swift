import Foundation
import SwiftUI

/// LARP.AI Pro: the same $5 Lemon Squeezy key as on the PC.
let FREE_DAILY = 20, PRO_DAILY = 50
let PRO_SOON = true                                       // not on sale yet: lock screens say "coming soon"
let PRO_PAGE = URL(string: "https://mylarpai.com/support")!
let LS_PRODUCT_ID = 1496414                               // test-mode id, same as the PC app; swap for the live id at launch
let FREE_ACCENTS = 5                                      // the first five colors are free; the rest and "any color" are Pro

enum QuotaKind: String { case img, up }

enum LockReason: Identifiable {
    case quota(QuotaKind), perk
    var id: String { if case .quota(let k) = self { return k.rawValue }; return "perk" }
}

@MainActor
final class Pro: ObservableObject {
    @Published private(set) var active: Bool
    @Published var lock: LockReason?
    private var key: String
    private var instance: String

    init() {
        let d = UserDefaults.standard
        active = d.bool(forKey: "proOK")
        key = d.string(forKey: "proKey") ?? ""
        instance = d.string(forKey: "proInstance") ?? ""
    }

    var cap: Int { active ? PRO_DAILY : FREE_DAILY }
    var maskedKey: String { key.count > 8 ? String(key.prefix(4)) + "…" + String(key.suffix(4)) : "" }

    // MARK: daily pictures / uploads (reset at midnight)
    private var today: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }
    func used(_ kind: QuotaKind) -> Int {
        let u = UserDefaults.standard.dictionary(forKey: "usage") ?? [:]
        return (u["day"] as? String) == today ? (u[kind.rawValue] as? Int ?? 0) : 0
    }
    /// Counts one picture or upload; false (and the unlock card) when today's limit is reached.
    func use(_ kind: QuotaKind) -> Bool {
        if used(kind) >= cap { lock = .quota(kind); return false }
        var u = UserDefaults.standard.dictionary(forKey: "usage") ?? [:]
        if (u["day"] as? String) != today { u = ["day": today] }
        u[kind.rawValue] = used(kind) + 1
        UserDefaults.standard.set(u, forKey: "usage")
        return true
    }

    // MARK: license (Lemon Squeezy License API)
    private func ls(_ what: String, _ params: [String: String]) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: "https://api.lemonsqueezy.com/v1/licenses/" + what)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        req.httpBody = params.map { k, v in k + "=" + (v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, j)
    }

    /// nil when it worked, otherwise what to tell the user
    func activate(_ raw: String) async -> String? {
        let k = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        guard k.range(of: "^[A-Za-z0-9-]{16,80}$", options: .regularExpression) != nil else {
            return "That doesn't look like a license key. Copy the whole key from your Lemon Squeezy email."
        }
        guard let r = try? await ls("activate", ["license_key": k, "instance_name": "LARP.AI on iPhone"]) else {
            return "No internet. Connect once to unlock, after that it works offline."
        }
        let j = r.1
        guard j["activated"] as? Bool == true else {
            let why = j["error"] as? String ?? ""
            if why.localizedCaseInsensitiveContains("limit") { return "This key is already used on the maximum number of devices." }
            if why.localizedCaseInsensitiveContains("not found") || why.localizedCaseInsensitiveContains("invalid") { return "That key wasn't found. Check you copied all of it." }
            return why.isEmpty ? "That key didn't work." : why
        }
        let meta = j["meta"] as? [String: Any]
        guard (meta?["product_id"] as? NSNumber)?.intValue == LS_PRODUCT_ID else { return "That key is for a different product, not LARP.AI Pro." }
        key = k
        instance = (j["instance"] as? [String: Any])?["id"] as? String ?? ""
        save(true)
        return nil
    }

    /// Frees the slot for another device.
    func remove() async {
        if !instance.isEmpty { _ = try? await ls("deactivate", ["license_key": key, "instance_id": instance]) }
        key = ""; instance = ""
        save(false)
    }

    /// Now and then when online, so refunded keys stop working (offline never locks anyone out).
    func recheck() async {
        guard active, !instance.isEmpty, let r = try? await ls("validate", ["license_key": key, "instance_id": instance]) else { return }
        let (status, j) = r
        let lk = (j["license_key"] as? [String: Any])?["status"] as? String ?? ""
        let bad = status == 404 || (j["valid"] as? Bool == false && ["disabled", "expired"].contains(lk))
        if bad { save(false) }
    }

    private func save(_ ok: Bool) {
        active = ok
        let d = UserDefaults.standard
        d.set(ok, forKey: "proOK"); d.set(key, forKey: "proKey"); d.set(instance, forKey: "proInstance")
    }
}

/// The unlock card (same wording as the PC app).
struct LockSheet: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pro: Pro
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL
    let reason: LockReason
    @State private var showKey = false
    @State private var key = ""
    @State private var busy = false
    @State private var err: String?

    private var what: String { if case .quota(let k) = reason { return k == .img ? "pictures" : "uploads" }; return "" }
    private var title: String {
        switch reason {
        case .perk: return "A Pro perk"
        case .quota: return pro.active ? "That's \(pro.cap) \(what) today" : "You've used today's \(pro.cap) free \(what)"
        }
    }
    private var bodyText: String {
        switch reason {
        case .perk: return "Bonus colors, your own custom color and the Pro badge come with LARP.AI Pro.\n\n$5 once also unlocks \(PRO_DAILY) pictures and uploads a day, on your iPhone and your PC."
        case .quota(let k):
            if pro.active { return "You've used today's \(pro.cap) \(what). It resets at midnight. Thanks for getting Pro ❤️" }
            return "Free lets you \(k == .img ? "make" : "add") \(FREE_DAILY) \(what) a day, and it resets at midnight.\n\nPro gets \(PRO_DAILY) a day, plus Code Mode on the PC, for $5 once."
        }
    }
    private var canBuy: Bool { if case .quota = reason, pro.active { return false }; return true }

    var body: some View {
        VStack(spacing: 14) {
            Text(canBuy ? "🔒" : "⏳").font(.system(size: 40)).padding(.top, 24)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(bodyText).font(.subheadline).foregroundStyle(Theme.mute).multilineTextAlignment(.center)
            if canBuy && PRO_SOON {
                Text("⏳ LARP.AI Pro will be buyable soon! Check mylarpai.com for the launch.")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(state.accentColor).multilineTextAlignment(.center)
            }
            if canBuy {
                HStack {
                    Button(PRO_SOON ? "Coming soon" : "Unlock for $5") { openURL(PRO_PAGE) }.buttonStyle(.borderedProminent)
                    Button("I have a key") { showKey = true }.buttonStyle(.bordered)
                }
                if showKey {
                    HStack {
                        TextField("Paste your license key", text: $key).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                        Button(busy ? "Checking…" : "Unlock") {
                            busy = true; err = nil
                            Task {
                                err = await pro.activate(key); busy = false
                                if err == nil { dismiss() }
                            }
                        }.buttonStyle(.borderedProminent).disabled(busy)
                    }
                }
                if let err { Text(err).font(.footnote).foregroundStyle(.orange) }
            } else {
                Button("OK") { dismiss() }.buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
    }
}

/// Settings → LARP.AI Pro
struct ProSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pro: Pro
    @Environment(\.openURL) var openURL
    @State private var key = ""
    @State private var busy = false
    @State private var err: String?

    var body: some View {
        Section {
            if pro.active {
                Label("You have LARP.AI Pro. Thank you!", systemImage: "sparkles").foregroundStyle(state.accentColor)
                Text("\(PRO_DAILY) pictures and \(PRO_DAILY) uploads a day, bonus colors and your own color. Key \(pro.maskedKey)")
                    .font(.footnote).foregroundStyle(Theme.mute)
                Button("Remove key from this iPhone", role: .destructive) { Task { await pro.remove() } }
            } else {
                Text("$5 once, yours forever. Unlocks \(PRO_DAILY) pictures and \(PRO_DAILY) uploads a day (free: \(FREE_DAILY)), bonus colors, your own color and Code Mode on the PC. One payment, works offline.")
                    .font(.footnote).foregroundStyle(Theme.mute)
                Button(PRO_SOON ? "Coming soon" : "Unlock for $5") { openURL(PRO_PAGE) }
                HStack {
                    TextField("Already paid? Paste your key", text: $key).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button(busy ? "Checking…" : "Unlock") {
                        busy = true; err = nil
                        Task { err = await pro.activate(key); busy = false; if err == nil { key = "" } }
                    }.disabled(busy || key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err { Text(err).font(.footnote).foregroundStyle(.orange) }
            }
        } header: {
            HStack(spacing: 6) {
                Text("LARP.AI Pro")
                if pro.active { Text("✦ PRO").font(.caption2.weight(.bold)).foregroundStyle(state.accentColor) }
                else if PRO_SOON { Text("COMING SOON").font(.caption2.weight(.bold)).foregroundStyle(state.accentColor) }
            }
        } footer: {
            Text("Today: \(pro.used(.img))/\(pro.cap) pictures · \(pro.used(.up))/\(pro.cap) uploads")
        }
    }
}
