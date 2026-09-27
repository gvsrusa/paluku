import Contacts
import Foundation

/// Notes, Mail, Messages, Music/Spotify, Contacts — AppleScript + native frameworks.
public enum AppleAppTools {
    public static var all: [Tool] { notes + mail + messages + media + contacts }

    // MARK: Notes

    static var notes: [Tool] {
        [
            Tool(
                name: "notes_search", description: "Search Apple Notes by title/body text. Returns titles and snippets.",
                parameters: Schema.object(["query": Schema.string("text to find")], required: ["query"]), integration: "notes", untrusted: true
            ) { args in
                let out = try await Shell.appleScript(
                    """
                    on run argv
                      set q to item 1 of argv
                      set out to ""
                      tell application "Notes"
                        set found to (every note whose name contains q or plaintext contains q)
                        repeat with n in (items 1 thru (min(15, count of found)) of found)
                          set out to out & (name of n) & " :: " & (text 1 thru (min(200, length of (plaintext of n as text))) of (plaintext of n as text)) & linefeed
                        end repeat
                      end tell
                      return out
                    end run
                    on min(a, b)
                      if a < b then return a
                      return b
                    end min
                    """, [try args.string("query")])
                return ToolResult(
                    out.isEmpty ? "No matching notes." : out,
                    card: out.isEmpty
                        ? nil
                        : Card(
                            icon: "note.text", title: "Notes", rows: out.split(separator: "\n").map { Card.Row(String($0.components(separatedBy: " :: ")[0])) })
                )
            },
            Tool(
                name: "notes_read", description: "Read the full text of an Apple Note by exact title.",
                parameters: Schema.object(["title": Schema.string("note title")], required: ["title"]), integration: "notes", untrusted: true
            ) { args in
                ToolResult(
                    try await Shell.appleScript(
                        """
                        on run argv
                          tell application "Notes" to return plaintext of (first note whose name is (item 1 of argv))
                        end run
                        """, [try args.string("title")]))
            },
            Tool(
                name: "notes_create", description: "Create a new Apple Note.",
                parameters: Schema.object(["title": Schema.string("title"), "body": Schema.string("body text")], required: ["title", "body"]),
                integration: "notes", isWrite: true,
                preview: { a in "📝 \(a.optString("title") ?? "")\n\(a.optString("body")?.prefix(400) ?? "")" }
            ) { args in
                try await Shell.appleScript(
                    """
                    on run argv
                      tell application "Notes" to make new note at default account with properties {name:(item 1 of argv), body:(item 2 of argv)}
                    end run
                    """, [try args.string("title"), htmlBody(try args.string("title"), try args.string("body"))])
                return ToolResult("Created note.", card: Card(icon: "note.text", title: "Note created", rows: [Card.Row(try args.string("title"))]))
            },
            Tool(
                name: "notes_append", description: "Append text to an existing Apple Note (by exact title).",
                parameters: Schema.object(["title": Schema.string("note title"), "text": Schema.string("text to add")], required: ["title", "text"]),
                integration: "notes", isWrite: true
            ) { args in
                try await Shell.appleScript(
                    """
                    on run argv
                      tell application "Notes"
                        set n to first note whose name is (item 1 of argv)
                        set body of n to (body of n) & (item 2 of argv)
                      end tell
                    end run
                    """, [try args.string("title"), "<div>" + escapeHTML(try args.string("text")).replacingOccurrences(of: "\n", with: "<br>") + "</div>"])
                return ToolResult("Appended to note.")
            },
        ]
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func htmlBody(_ title: String, _ body: String) -> String {
        "<h1>\(escapeHTML(title))</h1>" + body.split(separator: "\n", omittingEmptySubsequences: false).map { "<div>\(escapeHTML(String($0)))</div>" }.joined()
    }

    // MARK: Mail

    static var mail: [Tool] {
        [
            Tool(
                name: "mail_search", description: "Search Apple Mail inbox messages by sender/subject text (most recent first).",
                parameters: Schema.object([
                    "query": Schema.string("sender or subject text; empty for latest"), "limit": Schema.integer("max results, default 10"),
                ]),
                integration: "mail", untrusted: true
            ) { args in
                let out = try await Shell.appleScript(
                    """
                    on run argv
                      set q to item 1 of argv
                      set lim to (item 2 of argv) as integer
                      set out to ""
                      tell application "Mail"
                        if q is "" then
                          set msgs to messages of inbox
                        else
                          set msgs to (messages of inbox whose subject contains q or sender contains q)
                        end if
                        set c to 0
                        repeat with m in msgs
                          set c to c + 1
                          if c > lim then exit repeat
                          set out to out & (id of m) & " | " & (date received of m as string) & " | " & (sender of m) & " | " & (subject of m) & linefeed
                        end repeat
                      end tell
                      return out
                    end run
                    """, [args.optString("query") ?? "", String(args.int("limit") ?? 10)], timeout: 45)
                if out.isEmpty { return ToolResult("No matching mail.") }
                let rows = out.split(separator: "\n").map { l -> Card.Row in
                    let p = l.components(separatedBy: " | ")
                    return Card.Row(p.count > 3 ? p[3] : String(l), detail: p.count > 2 ? p[2] : nil)
                }
                return ToolResult("id | date | sender | subject\n" + out, card: Card(icon: "envelope", title: "Mail", rows: rows))
            },
            Tool(
                name: "mail_read", description: "Read an Apple Mail message body by id (from mail_search).",
                parameters: Schema.object(["id": Schema.string("message id")], required: ["id"]), integration: "mail", untrusted: true
            ) { args in
                let out = try await Shell.appleScript(
                    """
                    on run argv
                      tell application "Mail"
                        set m to first message of inbox whose id is ((item 1 of argv) as integer)
                        return "From: " & (sender of m) & linefeed & "Subject: " & (subject of m) & linefeed & "Date: " & (date received of m as string) & linefeed & linefeed & (content of m)
                      end tell
                    end run
                    """, [try args.string("id")])
                return ToolResult(String(out.prefix(12_000)))
            },
            Tool(
                name: "mail_send",
                description: "Send an email with Apple Mail (or save as draft if draft=true). If the user gave no subject, write a short fitting one yourself.",
                parameters: Schema.object(
                    [
                        "to": Schema.string("recipient email(s), comma-separated"), "subject": Schema.string("subject"),
                        "body": Schema.string("plain-text body"), "cc": Schema.string("cc emails"), "draft": Schema.boolean("only save draft"),
                    ], required: ["to", "subject", "body"]), integration: "mail", isWrite: true, egress: true, allowBypass: false,
                preview: { a in
                    let to = a.optString("to").flatMap(validRecipients)?.joined(separator: ", ") ?? "⚠︎ invalid recipients"
                    var lines = ["✉️ \((a.bool("draft") ?? false) ? "Save DRAFT" : "SEND") to: \(to)"]
                    if let cc = a.optString("cc") { lines.append("Cc: \(validRecipients(cc)?.joined(separator: ", ") ?? "⚠︎ invalid recipients")") }
                    lines.append("Subject: \(a.optString("subject") ?? "")")
                    lines.append("")
                    lines.append(a.optString("body") ?? "")
                    return lines.joined(separator: "\n")
                }
            ) { args in
                let draft = args.bool("draft") ?? false
                guard let to = validRecipients(try args.string("to")) else { throw ToolArgumentError(message: "Recipients must be plain email addresses.") }
                let cc =
                    try args.optString("cc").map { raw -> [String] in
                        guard let v = validRecipients(raw) else { throw ToolArgumentError(message: "Cc must be plain email addresses.") }
                        return v
                    } ?? []
                try await Shell.appleScript(
                    """
                    on run argv
                      tell application "Mail"
                        set m to make new outgoing message with properties {subject:(item 2 of argv), content:(item 3 of argv), visible:false}
                        set AppleScript's text item delimiters to ","
                        repeat with addr in text items of (item 1 of argv)
                          tell m to make new to recipient at end of to recipients with properties {address:(addr as text)}
                        end repeat
                        if (item 4 of argv) is not "" then
                          repeat with addr in text items of (item 4 of argv)
                            tell m to make new cc recipient at end of cc recipients with properties {address:(addr as text)}
                          end repeat
                        end if
                        if (item 5 of argv) is "1" then
                          save m
                        else
                          send m
                        end if
                      end tell
                    end run
                    """, [to.joined(separator: ","), try args.string("subject"), try args.string("body"), cc.joined(separator: ","), draft ? "1" : "0"])
                return ToolResult(
                    draft ? "Draft saved in Mail." : "Email sent.",
                    card: Card(
                        icon: "envelope", title: draft ? "Draft saved" : "Email sent",
                        rows: [Card.Row(try args.string("subject"), detail: try args.string("to"))]))
            },
        ]
    }

    // MARK: Messages

    static var messages: [Tool] {
        [
            Tool(
                name: "messages_send", description: "Send an iMessage/SMS via Messages. 'to' is a phone number, email, or contact name.",
                parameters: Schema.object(["to": Schema.string("phone/email/contact name"), "text": Schema.string("message")], required: ["to", "text"]),
                integration: "messages", isWrite: true, egress: true, allowBypass: false,
                preview: { a in
                    // Show the handle the message will actually go to, not just the spoken name.
                    let to = a.optString("to") ?? ""
                    let resolved = resolveHandle(to).map { $0 == to ? to : "\(to) (\($0))" } ?? "\(to) — ⚠︎ no matching contact"
                    return "💬 To: \(resolved)\n\(a.optString("text") ?? "")"
                }
            ) { args in
                let name = try args.string("to")
                // Same resolution as the preview, so the approved recipient is the one used.
                guard let to = resolveHandle(name) else { throw ToolArgumentError(message: "No phone/email found for contact '\(name)'.") }
                try await Shell.appleScript(
                    """
                    on run argv
                      tell application "Messages"
                        set svc to 1st account whose service type = iMessage
                        send (item 2 of argv) to participant (item 1 of argv) of svc
                      end tell
                    end run
                    """, [to, try args.string("text")])
                return ToolResult(
                    "Message sent to \(to).", card: Card(icon: "message", title: "Message sent", rows: [Card.Row(try args.string("text"), detail: to)]))
            },
            Tool(
                name: "messages_recent", description: "Read recent iMessages (optionally from one contact). Needs Full Disk Access.",
                parameters: Schema.object(["from": Schema.string("phone/email/contact name filter"), "limit": Schema.integer("default 15")]),
                integration: "messages", untrusted: true
            ) { args in
                let db = FinderTools.home.appending(path: "Library/Messages/chat.db").path
                var filter = ""
                if let from = args.optString("from") {
                    let handles =
                        (from.contains("@") || from.rangeOfCharacter(from: .decimalDigits) != nil)
                        ? [from]
                        : (try lookupContacts(from).flatMap { $0.phones + $0.emails })
                    // Only digits or a validated email reach the SQL text (sqlite3 CLI has no bound parameters).
                    let likes = handles.compactMap(sqlSafeHandle).map { "h.id LIKE '%\($0)%'" }
                    if !likes.isEmpty { filter = "AND (" + likes.joined(separator: " OR ") + ")" }
                }
                let sql = """
                    SELECT datetime(m.date/1000000000 + 978307200,'unixepoch','localtime'), CASE m.is_from_me WHEN 1 THEN 'me' ELSE h.id END, replace(m.text, char(10), ' ')
                    FROM message m LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE m.text IS NOT NULL \(filter) ORDER BY m.date DESC LIMIT \(max(1, min(args.int("limit") ?? 15, 50)));
                    """
                do {
                    let out = try await Shell.run("/usr/bin/sqlite3", ["-readonly", "-separator", " | ", db, sql])
                    return ToolResult(out.isEmpty ? "No messages found." : out)
                } catch {
                    throw Shell.Failure(message: "Can't read Messages history. Grant Paluku Full Disk Access in System Settings › Privacy & Security.")
                }
            },
        ]
    }

    // MARK: Music / Spotify

    static var media: [Tool] {
        [
            Tool(
                name: "media_control", description: "Control Apple Music or Spotify: play, pause, next, previous, now_playing, or play a search query.",
                parameters: Schema.object(
                    [
                        "app": Schema.enumeration("player", ["Music", "Spotify"]),
                        "action": Schema.enumeration("action", ["play", "pause", "next", "previous", "now_playing", "play_query", "volume"]),
                        "query": Schema.string("song/artist/playlist for play_query"), "volume": Schema.integer("0-100 for volume"),
                    ], required: ["action"]), integration: "media", untrusted: true  // track titles are third-party text
            ) { args in
                // Interpolated into AppleScript source below, so it must be one of these literals.
                let app = args.optString("app") ?? "Music"
                guard ["Music", "Spotify"].contains(app) else { throw ToolArgumentError(message: "Unsupported player '\(app)'. Use Music or Spotify.") }
                let action = try args.string("action")
                let script: String
                switch action {
                case "play": script = "tell application \"\(app)\" to play"
                case "pause": script = "tell application \"\(app)\" to pause"
                case "next": script = "tell application \"\(app)\" to next track"
                case "previous": script = "tell application \"\(app)\" to previous track"
                case "volume": script = "on run argv\ntell application \"\(app)\" to set sound volume to ((item 1 of argv) as integer)\nend run"
                case "now_playing": script = "tell application \"\(app)\" to return (name of current track) & \" — \" & (artist of current track)"
                case "play_query":
                    script =
                        app == "Spotify"
                        ? "on run argv\ntell application \"Spotify\" to play track (\"spotify:search:\" & (item 1 of argv))\nend run"
                        : """
                        on run argv
                          tell application "Music"
                            set q to item 1 of argv
                            set r to (search library playlist 1 for q)
                            if r is {} then
                              set pl to (every user playlist whose name contains q)
                              if pl is {} then return "Nothing in your library matches " & q
                              play item 1 of pl
                              return "Playing playlist " & (name of item 1 of pl)
                            end if
                            play item 1 of r
                            return "Playing " & (name of item 1 of r) & " — " & (artist of item 1 of r)
                          end tell
                        end run
                        """
                default: throw ToolArgumentError(message: "Unknown action \(action)")
                }
                let arg = action == "volume" ? [String(args.int("volume") ?? 50)] : action == "play_query" ? [try args.string("query")] : []
                let out = try await Shell.appleScript(script, arg)
                return ToolResult(out.isEmpty ? "Done." : out, card: out.isEmpty ? nil : Card(icon: "music.note", title: app, rows: [Card.Row(out)]))
            }
        ]
    }

    /// Comma-separated email list → clean addresses, or nil if anything isn't a plain address (no newlines, no names).
    static func validRecipients(_ raw: String) -> [String]? {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, !raw.contains(where: { $0.isNewline }) else { return nil }
        let ok = parts.allSatisfy { $0.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil }
        return ok ? parts : nil
    }

    /// Phone/email as given, or the first phone/email of the single best-matching contact.
    static func resolveHandle(_ to: String) -> String? {
        guard !to.contains(where: { $0.isNewline }) else { return nil }
        if to.contains("@") { return validRecipients(to)?.count == 1 ? to : nil }
        if to.rangeOfCharacter(from: .decimalDigits) != nil { return to.allSatisfy({ $0.isNumber || " +()-.".contains($0) }) ? to : nil }
        // Exactly one matching contact, or nothing: an ambiguous name must not resolve differently on card vs send.
        guard let matches = try? lookupContacts(to), matches.count == 1, let p = matches.first else { return nil }
        return p.phones.first ?? p.emails.first
    }

    /// Phone → last 10 digits; email → validated address; anything else → nil. Safe to embed in a LIKE literal.
    static func sqlSafeHandle(_ h: String) -> String? {
        if h.contains("@") {
            return h.range(of: #"^[A-Za-z0-9.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil ? h : nil
        }
        let digits = String(h.filter(\.isNumber).suffix(10))
        return digits.count >= 7 ? digits : nil
    }

    // MARK: Contacts

    struct Person { var name: String; var emails: [String]; var phones: [String] }

    static func lookupContacts(_ name: String) throws -> [Person] {
        let store = CNContactStore()
        let keys =
            [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactOrganizationNameKey]
            as [CNKeyDescriptor]
        let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
        return found.prefix(10).map {
            Person(
                name: "\($0.givenName) \($0.familyName)".trimmingCharacters(in: .whitespaces).ifEmpty($0.organizationName),
                emails: $0.emailAddresses.map { $0.value as String }, phones: $0.phoneNumbers.map { $0.value.stringValue })
        }
    }

    static var contacts: [Tool] {
        [
            Tool(
                name: "contacts_search", description: "Look up a person's email addresses and phone numbers in Contacts.",
                parameters: Schema.object(["name": Schema.string("person name")], required: ["name"]), integration: "contacts", untrusted: true
            ) { args in
                let store = CNContactStore()
                if CNContactStore.authorizationStatus(for: .contacts) != .authorized {
                    guard try await store.requestAccess(for: .contacts) else { throw Shell.Failure(message: "Contacts access denied.") }
                }
                let people = try lookupContacts(try args.string("name"))
                if people.isEmpty { return ToolResult("No contact named \(try args.string("name")).") }
                return ToolResult(
                    people.map { "\($0.name): emails \($0.emails.joined(separator: ", ")); phones \($0.phones.joined(separator: ", "))" }.joined(
                        separator: "\n"),
                    card: Card(
                        icon: "person.crop.circle", title: "Contacts",
                        rows: people.map { Card.Row($0.name, detail: ($0.emails + $0.phones).joined(separator: " · ")) }))
            }
        ]
    }
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
