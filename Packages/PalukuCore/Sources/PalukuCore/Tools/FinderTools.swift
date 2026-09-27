import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Finder / file-system tools. Search uses Spotlight (`mdfind`).
public enum FinderTools {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func expand(_ path: String) -> URL {
        let p = (path as NSString).expandingTildeInPath
        let named: [String: String] = ["desktop": "Desktop", "downloads": "Downloads", "documents": "Documents", "home": ""]
        if let sub = named[p.lowercased()] { return home.appending(path: sub) }
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : home.appending(path: p)
    }

    static let kinds: [String: String] = [
        "pdf": "com.adobe.pdf", "image": "public.image", "document": "public.content", "spreadsheet": "public.spreadsheet",
        "presentation": "public.presentation", "folder": "public.folder", "audio": "public.audio", "movie": "public.movie",
        "text": "public.text", "application": "com.apple.application",
    ]

    /// Build a Spotlight query: name matches OR content matches, with optional kind/date filters.
    // MARK: path policy (docs/SECURITY.md)

    /// Canonical, lowercased path for policy checks on a case-insensitive filesystem. Symlinks are resolved on the
    /// deepest *existing* ancestor too, so `link/new-file` can't slip through where `link` points into ~/Library.
    /// Paths with `..` are refused outright: the kernel applies `..` after following symlinks, string cleanup doesn't.
    static func policyPath(_ url: URL) throws -> String {
        if url.path.split(separator: "/").contains("..") { throw ToolArgumentError(message: "Use a full path without '..'.") }
        var existing = url
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for c in tail { resolved.append(path: c) }
        return resolved.path.lowercased()
    }

    /// Path relative to the home folder, or nil when outside it.
    static func homeRelative(_ path: String) throws -> Substring? {
        let homePath = home.resolvingSymlinksInPath().path.lowercased()
        guard path.hasPrefix(homePath + "/") else { return nil }
        return path.dropFirst(homePath.count + 1)
    }

    /// Hidden (dot) components or anything under ~/Library (app data, credentials, browser profiles, mail, messages…),
    /// except iCloud Drive, which is the user's own documents.
    static func isPrivateArea(_ rel: Substring) -> Bool {
        (rel.hasPrefix("library") && !rel.hasPrefix("library/mobile documents/com~apple~clouddocs/"))
            || rel.split(separator: "/").contains(where: { $0.hasPrefix(".") })
    }

    /// Reads (allowlist): only the user's own content — inside home, outside ~/Library and hidden paths.
    static func checkReadable(_ url: URL) throws {
        let path = try policyPath(url)
        if path == home.resolvingSymlinksInPath().path.lowercased() { return }  // the home folder itself (list/reveal ~)
        guard let rel = try homeRelative(path), !isPrivateArea(rel) else {
            throw ToolArgumentError(message: "Paluku only reads your own files in your home folder — not app data, Library, hidden or system files.")
        }
    }

    /// Writes/moves/deletes (allowlist): same area as reads.
    static func checkWritable(_ url: URL) throws {
        guard let rel = try homeRelative(policyPath(url)), !isPrivateArea(rel) else {
            throw ToolArgumentError(message: "Paluku only changes your own files in your home folder — not app data, Library, hidden or system files.")
        }
    }

    /// Document types that open in a viewer/editor without running code, installing or importing (allowlist).
    static let openableTypes: [UTType] = [
        .pdf, .image, .audiovisualContent, .presentation, .spreadsheet, .rtf, .rtfd, .flatRTFD, .plainText, .commaSeparatedText,
        UTType("org.openxmlformats.wordprocessingml.document"), UTType("com.microsoft.word.doc"), UTType("com.apple.iwork.pages.sffpages"),
        UTType("com.apple.iwork.pages.pages"), UTType("com.apple.iwork.numbers.sffnumbers"), UTType("com.apple.iwork.keynote.sffkey"),
        UTType("net.daringfireball.markdown"), UTType("org.oasis-open.opendocument.text"),
    ].compactMap { $0 }

    /// Conforming to these disqualifies a type even if it also conforms to an allowed one (scripts are plain text, HTML is text…).
    static let activeTypes: [UTType] = [.sourceCode, .script, .html, .xml, .executable, .application, .bundle, .archive, .diskImage, .svg]

    /// Folders open in Finder. Files open only if they're a known document type, not an alias, and not executable.
    public static func checkOpenable(_ url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isAliasFileKey, .contentTypeKey])
        if values?.isAliasFile == true && values?.isDirectory != true {
            throw ToolArgumentError(message: "Paluku won't open alias files — open it yourself if you trust it.")
        }
        if values?.isDirectory == true && values?.isPackage != true { return }
        let type = values?.contentType ?? UTType(filenameExtension: target.pathExtension)
        let refuse = ToolArgumentError(message: "Paluku only opens documents, pictures, audio and video — open other files yourself if you trust them.")
        guard let type, openableTypes.contains(where: type.conforms(to:)), !activeTypes.contains(where: type.conforms(to:)) else { throw refuse }
        if values?.isDirectory != true && FileManager.default.isExecutableFile(atPath: target.path) { throw refuse }
    }

    static func spotlightQuery(_ q: String, kind: String?, after: Date?, before: Date?) -> String {
        // Strip query metacharacters so model-supplied text can't close the quoted literal or add wildcards.
        let words = q.split(separator: " ").map { $0.filter { !"\"\\*?".contains($0) } }.filter { !$0.isEmpty }
        let nameClause = words.map { "kMDItemFSName == \"*\($0)*\"cd" }.joined(separator: " && ")
        let textClause = "kMDItemTextContent == \"\(words.joined(separator: " "))\"cd"
        var clauses = ["((\(nameClause)) || \(textClause))"]
        if let kind, let uti = kinds[kind.lowercased()] { clauses.append("kMDItemContentTypeTree == \"\(uti)\"") }
        if let after { clauses.append("kMDItemContentModificationDate >= $time.iso(\(DateParsing.iso(after, timeZone: .gmt)))") }
        if let before { clauses.append("kMDItemContentModificationDate <= $time.iso(\(DateParsing.iso(before, timeZone: .gmt)))") }
        return clauses.joined(separator: " && ")
    }

    /// Filename matches first, then shorter paths; hides Library/caches noise.
    static func rank(_ paths: [String], query: String) -> [String] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let noise = ["/Library/", "/.Trash/", "/node_modules/", "/.git/", "/DerivedData/", "/.build/"]
        return paths.filter { p in !noise.contains { p.contains($0) } }
            .sorted { a, b in
                func score(_ p: String) -> Int {
                    let name = (p as NSString).lastPathComponent.lowercased()
                    return words.filter { name.contains($0) }.count * 100 - p.count / 10
                }
                return score(a) > score(b)
            }
    }

    static func fileCard(_ urls: [URL], title: String) -> Card {
        let f = DateFormatter()
        f.dateStyle = .medium
        return Card(
            icon: "folder", title: title,
            rows: urls.map { u in
                let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return Card.Row(
                    u.lastPathComponent,
                    detail: (u.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~")) + (d.map { " · " + f.string(from: $0) } ?? ""),
                    url: u)
            })
    }

    public static var all: [Tool] {
        [
            Tool(
                name: "files_search", description: "Search files on this Mac by name or content (Spotlight). Returns paths.",
                parameters: Schema.object(
                    [
                        "query": Schema.string("keywords, e.g. 'tax return 2025'"),
                        "kind": Schema.enumeration("file kind filter", Array(kinds.keys).sorted()),
                        "modified_after": Schema.string("ISO date"), "modified_before": Schema.string("ISO date"),
                        "folder": Schema.string("limit to folder, e.g. ~/Documents"),
                    ], required: ["query"]), integration: "finder", untrusted: true
            ) { args in
                let q = try args.string("query")
                let dir = args.optString("folder").map(expand) ?? home
                if dir != home { try checkReadable(dir) }
                let out = try await Shell.run(
                    "/usr/bin/mdfind",
                    [
                        "-onlyin", dir.path,
                        spotlightQuery(q, kind: args.optString("kind"), after: args.date("modified_after"), before: args.date("modified_before")),
                    ], timeout: 15)
                // Spotlight also indexes ~/Library and hidden folders; don't leak those names.
                let visible = out.split(separator: "\n").map(String.init).filter { (try? checkReadable(URL(fileURLWithPath: $0))) != nil }
                let paths = rank(visible, query: q).prefix(12)
                if paths.isEmpty { return ToolResult("No files found for '\(q)'.") }
                let urls = paths.map { URL(fileURLWithPath: $0) }
                return ToolResult(paths.joined(separator: "\n"), card: fileCard(urls, title: "Files"))
            },
            Tool(
                name: "files_list", description: "List a folder's contents (newest first).",
                parameters: Schema.object(["folder": Schema.string("path, e.g. ~/Downloads or 'desktop'")], required: ["folder"]),
                integration: "finder", untrusted: true  // file names are attacker-choosable (downloads)
            ) { args in
                let dir = expand(try args.string("folder"))
                try checkReadable(dir)
                let items = try FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
                )
                .sorted { a, b in
                    let d = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
                    return d(a) > d(b)
                }
                let shown = Array(items.prefix(40))
                return ToolResult(
                    shown.map(\.path).joined(separator: "\n") + (items.count > 40 ? "\n…and \(items.count - 40) more" : ""),
                    card: fileCard(Array(shown.prefix(12)), title: dir.lastPathComponent))
            },
            Tool(
                name: "files_open", description: "Open a document or folder with its default app.",
                parameters: Schema.object(["path": Schema.string("file path")], required: ["path"]),
                integration: "finder"
            ) { args in
                let url = expand(try args.string("path"))
                try checkReadable(url)
                try checkOpenable(url)
                _ = await MainActor.run { NSWorkspace.shared.open(url) }
                return ToolResult("Opened \(url.lastPathComponent).")
            },
            Tool(
                name: "files_reveal", description: "Show a file in Finder.",
                parameters: Schema.object(["path": Schema.string("file path")], required: ["path"]), integration: "finder"
            ) { args in
                let url = expand(try args.string("path"))
                try checkReadable(url)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                return ToolResult("Revealed \(url.lastPathComponent) in Finder.")
            },
            Tool(
                name: "files_read", description: "Read the text of a file (txt, md, code, pdf, rtf, docx). Truncated.",
                parameters: Schema.object(["path": Schema.string("file path")], required: ["path"]), integration: "finder", untrusted: true
            ) { args in
                let url = expand(try args.string("path"))
                try checkReadable(url)
                return ToolResult(try await readText(url))
            },
            Tool(
                name: "files_move", description: "Move a file/folder into a destination folder.",
                parameters: Schema.object(
                    ["path": Schema.string("source"), "destination": Schema.string("destination folder")], required: ["path", "destination"]),
                integration: "finder", isWrite: true,
                preview: { a in "Move \(a.optString("path") ?? "")\n→ \(a.optString("destination") ?? "")" }
            ) { args in
                let src = expand(try args.string("path"))
                let dst = expand(try args.string("destination")).appending(path: src.lastPathComponent)
                try checkWritable(src)
                try checkWritable(dst)
                try FileManager.default.moveItem(at: src, to: dst)
                return ToolResult("Moved to \(dst.path).", card: fileCard([dst], title: "Moved"))
            },
            Tool(
                name: "files_rename", description: "Rename a file/folder.",
                parameters: Schema.object(
                    ["path": Schema.string("file"), "new_name": Schema.string("new file name incl. extension")], required: ["path", "new_name"]),
                integration: "finder", isWrite: true
            ) { args in
                let src = expand(try args.string("path"))
                let dst = src.deletingLastPathComponent().appending(path: try args.string("new_name"))
                try checkWritable(src)
                try checkWritable(dst)
                try FileManager.default.moveItem(at: src, to: dst)
                return ToolResult("Renamed to \(dst.lastPathComponent).", card: fileCard([dst], title: "Renamed"))
            },
            Tool(
                name: "files_create_folder", description: "Create a folder.",
                parameters: Schema.object(["path": Schema.string("new folder path")], required: ["path"]), integration: "finder", isWrite: true
            ) { args in
                let url = expand(try args.string("path"))
                try checkWritable(url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return ToolResult("Created \(url.path).")
            },
            Tool(
                name: "files_write_text", description: "Create or overwrite a text file with content.",
                parameters: Schema.object(["path": Schema.string("file path"), "content": Schema.string("text")], required: ["path", "content"]),
                integration: "finder", isWrite: true, allowBypass: false,
                preview: { a in
                    let c = a.optString("content") ?? ""
                    return "Write \(a.optString("path") ?? "") (\(c.count) characters)\n\(c.prefix(1500))\(c.count > 1500 ? "\n…" : "")"
                }
            ) { args in
                let url = expand(try args.string("path"))
                try checkWritable(url)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try args.string("content").write(to: url, atomically: true, encoding: .utf8)
                return ToolResult("Saved \(url.path).", card: fileCard([url], title: "Saved"))
            },
            Tool(
                name: "files_trash", description: "Move a file/folder to the Trash.",
                parameters: Schema.object(["path": Schema.string("file path")], required: ["path"]), integration: "finder", isWrite: true, allowBypass: false,
                preview: { a in "🗑 Move to Trash:\n\(a.optString("path") ?? "")" }
            ) { args in
                let url = expand(try args.string("path"))
                try checkWritable(url)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return ToolResult("Moved \(url.lastPathComponent) to Trash.")
            },
        ]
    }

    static func readText(_ url: URL, limit: Int = 15_000) async throws -> String {
        let ext = url.pathExtension.lowercased()
        var text: String?
        if ext == "pdf" {
            text = PDFDocument(url: url)?.string
        } else if ["docx", "doc", "rtf", "rtfd", "odt", "html", "webarchive"].contains(ext) {
            text = try? await Shell.run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
        } else {
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let text else { throw Shell.Failure(message: "Can't read \(url.lastPathComponent) as text.") }
        return text.count > limit ? String(text.prefix(limit)) + "\n…[truncated]" : text
    }
}
