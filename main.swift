// ClaudeMeter — tiny menu bar monitor for Claude usage limits.
// Pure AppKit, no dependencies. Polls rarely, caches parsed log files.
import AppKit
extension String: @retroactive Error {}

// MARK: - Local log scanning (~/.claude/projects/**/*.jsonl)

struct Entry { let time: Date; let tokens: Int; let key: String }

final class LocalScanner {
    private var cache: [String: (mtime: Date, entries: [Entry])] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// Entries from the last 7 days, deduplicated. Only re-parses files whose mtime changed.
    func entries() -> [Entry] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        var seenPaths = Set<String>()
        var all: [Entry] = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mtime > cutoff else { continue }
            let p = url.path; seenPaths.insert(p)
            if let c = cache[p], c.mtime == mtime { all += c.entries; continue }
            let parsed = parse(url, cutoff: cutoff)
            cache[p] = (mtime, parsed); all += parsed
        }
        cache = cache.filter { seenPaths.contains($0.key) }
        var seen = Set<String>()
        return all.filter { seen.insert($0.key).inserted }.sorted { $0.time < $1.time }
    }

    private func parse(_ url: URL, cutoff: Date) -> [Entry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var out: [Entry] = []
        let needle = Data("\"usage\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: needle) != nil,                       // cheap pre-filter
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String, let t = iso.date(from: ts), t > cutoff else { continue }
            let tok = ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
                .reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
            let key = "\(msg["id"] as? String ?? "")|\(obj["requestId"] as? String ?? UUID().uuidString)"
            out.append(Entry(time: t, tokens: tok, key: key))
        }
        return out
    }
}

struct LocalStats { var blockTokens = 0; var blockEnd: Date?; var weekTokens = 0; var todayTokens = 0 }

func computeLocal(_ es: [Entry]) -> LocalStats {
    var s = LocalStats(); let now = Date(); let cal = Calendar.current
    var start: Date?, last: Date?, blockTok = 0
    for e in es {
        if let st = start, e.time < st.addingTimeInterval(5 * 3600), let l = last, e.time.timeIntervalSince(l) < 5 * 3600 {
            blockTok += e.tokens
        } else {   // new 5h block, starting at the hour
            start = cal.dateInterval(of: .hour, for: e.time)?.start ?? e.time; blockTok = e.tokens
        }
        last = e.time
        s.weekTokens += e.tokens
        if cal.isDateInToday(e.time) { s.todayTokens += e.tokens }
    }
    if let st = start, now < st.addingTimeInterval(5 * 3600) { s.blockTokens = blockTok; s.blockEnd = st.addingTimeInterval(5 * 3600) }
    return s
}

// MARK: - Official usage (same data as Claude Code's /usage)

struct Limit { let name: String; let pct: Double; let resets: Date? }

enum UsageAPI {
    static func token() -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let oa = o["claudeAiOauth"] as? [String: Any] else { return nil }
        return oa["accessToken"] as? String
    }

    static func fetch(_ done: @escaping (Result<[Limit], String>) -> Void) {
        if CommandLine.arguments.contains("--local-only") { return done(.failure("API disabled (--local-only)")) }
        guard let tok = token() else { return done(.failure("No Claude Code login found")) }
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        URLSession.shared.dataTask(with: r) { d, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard err == nil, code == 200, let d,
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                return done(.failure(code == 401 ? "Login expired — run `claude` once" : "Usage API unavailable (\(code))"))
            }
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let iso2 = ISO8601DateFormatter()
            let names = ["five_hour": "Session (5h)", "seven_day": "Weekly (all models)",
                         "seven_day_opus": "Weekly (Opus)", "seven_day_sonnet": "Weekly (Sonnet)"]
            let order = Array(names.keys).sorted { ($0 == "five_hour" ? 0 : 1, $0) < ($1 == "five_hour" ? 0 : 1, $1) }
            var out: [Limit] = []
            for k in order + o.keys.filter({ names[$0] == nil }).sorted() {
                guard let v = o[k] as? [String: Any], let u = (v["utilization"] as? NSNumber)?.doubleValue else { continue }
                let rs = (v["resets_at"] as? String).flatMap { iso.date(from: $0) ?? iso2.date(from: $0) }
                out.append(Limit(name: names[k] ?? k.replacingOccurrences(of: "_", with: " ").capitalized, pct: u, resets: rs))
            }
            done(out.isEmpty ? .failure("No limits in response") : .success(out))
        }.resume()
    }
}

// MARK: - Menu bar

func fmtTok(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0fK", Double(n) / 1e3) : "\(n)"
}
func fmtIn(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = max(0, Int(d.timeIntervalSinceNow)); let h = s / 3600, m = (s % 3600) / 60
    return h >= 24 ? "resets in \(h / 24)d \(h % 24)h" : "resets in \(h)h \(m)m"
}
func bar(_ pct: Double) -> String {
    let n = Int((min(max(pct, 0), 100) / 10).rounded()); return String(repeating: "▰", count: n) + String(repeating: "▱", count: 10 - n)
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let scanner = LocalScanner()
    var limits: [Limit] = []; var apiError: String?; var local = LocalStats(); var updated: Date?
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.title = "✳︎ …"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 60   // let macOS coalesce wakeups → less CPU/battery
    }

    @objc func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let st = computeLocal(self.scanner.entries())
            UsageAPI.fetch { res in
                DispatchQueue.main.async {
                    self.local = st; self.updated = Date()
                    switch res { case .success(let l): self.limits = l; self.apiError = nil
                                 case .failure(let e): self.apiError = e }
                    self.updateTitle()
                }
            }
        }
    }

    func updateTitle() {
        let title: String
        if let s = limits.first(where: { $0.name.hasPrefix("Session") }) ?? limits.first {
            title = "✳︎ \(Int(s.pct.rounded()))%"
        } else { title = "✳︎ \(fmtTok(local.blockTokens))" }
        item.button?.title = title
        let hot = limits.map(\.pct).max() ?? 0
        item.button?.contentTintColor = hot >= 90 ? .systemRed : hot >= 75 ? .systemOrange : nil
    }

    // Build the menu lazily, only when opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ t: String, _ sel: Selector? = nil, _ key: String = "") {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key); i.target = self
            if sel == nil { i.isEnabled = false }; menu.addItem(i)
        }
        func header(_ t: String) { menu.addItem(.sectionHeader(title: t)) }

        header("Plan limits")
        if limits.isEmpty { add(apiError ?? "Loading…") }
        for l in limits {
            add("\(l.name)  \(Int(l.pct.rounded()))%")
            add("   \(bar(l.pct))  \(fmtIn(l.resets))")
        }
        if let e = apiError, !limits.isEmpty { add("⚠︎ \(e) (showing last data)") }

        menu.addItem(.separator()); header("Local Claude Code tokens")
        add("Current 5h block: \(fmtTok(local.blockTokens))" + (local.blockEnd.map { "  (\(fmtIn($0)))" } ?? ""))
        add("Today: \(fmtTok(local.todayTokens))   ·   7 days: \(fmtTok(local.weekTokens))")

        menu.addItem(.separator())
        if let u = updated { add("Updated \(DateFormatter.localizedString(from: u, dateStyle: .none, timeStyle: .short))") }
        add("Refresh now", #selector(refresh), "r")
        add("Quit", #selector(NSApplication.terminate(_:)), "q")
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
