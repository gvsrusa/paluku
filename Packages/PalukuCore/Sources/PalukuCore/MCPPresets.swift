import Foundation

/// Preconfigured open-source MCP servers. Disabled until the user adds credentials in Settings.
public enum MCPPresets {
    /// Versions are pinned: these servers receive OAuth secrets, so an upstream release must not run unreviewed.
    /// taylorwilsdon/google_workspace_mcp — one server for Gmail, Calendar, Drive, Docs, Sheets.
    /// Needs a Google Cloud OAuth "Desktop app" client; first tool call opens the browser consent page.
    public static let googleWorkspace = MCPServerConfig(
        id: "google", name: "Google Workspace (Gmail, Calendar, Drive, Docs, Sheets)", enabled: false,
        command: "uvx", args: ["workspace-mcp==1.29.0", "--single-user", "--tools", "gmail", "calendar", "drive", "docs", "sheets"],
        env: ["GOOGLE_OAUTH_CLIENT_ID": "", "GOOGLE_OAUTH_CLIENT_SECRET": "", "OAUTHLIB_INSECURE_TRANSPORT": "1"])

    /// makenotion/notion-mcp-server — needs an internal integration token.
    public static let notion = MCPServerConfig(
        id: "notion", name: "Notion", enabled: false,
        command: "npx", args: ["-y", "@notionhq/notion-mcp-server@2.5.2"],
        env: ["NOTION_TOKEN": ""])

    public static let all = [googleWorkspace, notion]
}
