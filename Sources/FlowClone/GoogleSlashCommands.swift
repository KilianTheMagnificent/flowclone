import Foundation

enum GoogleSlashCommands {
    // Gemini CLI command reference and public names in BuiltinCommandLoader.ts, checked 2026-11-18.
    static let gemini = [
        "?", "about", "agents", "auth", "background", "bashes", "bg", "bug", "chat", "clear",
        "commands", "compress", "copy", "corgi", "dir", "directory", "docs", "editor", "exit",
        "export-session", "extensions",
        "help", "hooks", "ide", "init", "mcp", "memory", "model", "permissions", "plan",
        "policies", "privacy", "quit", "restore", "resume", "rewind", "settings",
        "setup-github", "shells", "skills", "stats", "tasks", "terminal-setup", "theme", "tools",
        "upgrade", "vim", "voice",
    ]

    // antigravity.google/docs/cli/reference and /docs/slash-commands, checked 2026-11-18.
    static let antigravity = [
        "add-dir", "agents", "agy-customizations", "antigravity-guide", "artifact", "automation",
        "boost", "branch", "browser", "btw", "changelog", "clear", "codesearch", "config",
        "context", "conversation", "copy", "credits", "cs", "diff", "effort", "exit", "fast",
        "feedback", "fork", "generative_ui", "goal", "grill-me", "help", "hooks", "keybindings",
        "learn", "logout", "mcp", "model", "new", "open", "permissions", "plan", "planning",
        "plugin", "plugins", "quit", "quota", "remote-control", "rename", "resume", "rewind",
        "run-workflow", "schedule", "search", "settings", "skills", "statusline", "swarm", "switch",
        "tasks", "teamwork", "title", "undo", "usage", "voice",
    ]

    // These words are part of the CLI syntax, with a space after the slash command.
    // Match exactly so a similar-sounding argument is never consumed as a subcommand.
    static let subcommands: [String: [String: String]] = {
        let checkpoints = ["debug", "delete", "list", "load", "resume", "save", "share"]
        let directories = ["add", "show"]
        let plugins = ["disable", "enable", "install", "list", "uninstall"]
        let lists: [String: [String]] = [
            "agents": ["config", "disable", "enable", "list", "refresh", "reload"],
            "chat": checkpoints,
            "commands": ["list", "reload"],
            "dir": directories,
            "directory": directories,
            "extensions": ["config", "disable", "enable", "explore", "install", "link", "list",
                           "restart", "uninstall", "update"],
            "hooks": ["disable", "disable-all", "enable", "enable-all", "list", "panel", "show"],
            "ide": ["disable", "enable", "install", "status"],
            "mcp": ["auth", "desc", "disable", "enable", "list", "ls", "reload", "schema"],
            "memory": ["list", "refresh", "show"],
            "model": ["manage", "set"],
            "permissions": ["trust"],
            "plan": ["copy"],
            "plugin": plugins,
            "plugins": plugins,
            "policies": ["list"],
            "remote-control": ["off", "on"],
            "resume": checkpoints,
            "skills": ["disable", "enable", "list", "reload"],
            "stats": ["model", "session", "tools"],
            "swarm": ["board"],
            "tools": ["desc", "descriptions", "nodesc", "nodescriptions"],
            "voice": ["model"],
        ]
        return lists.mapValues { words in
            Dictionary(uniqueKeysWithValues: words.map { ($0.replacingOccurrences(of: "-", with: ""), $0) })
        }
    }()

    /// Gemini's nested TOML file names become colon-delimited commands. Antigravity also
    /// registers user-level skills as slash commands. Discover names without reading content.
    static func owned(in home: URL) -> [String] {
        let fm = FileManager.default
        let commands = home.appendingPathComponent("commands", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let files = fm.enumerator(atPath: commands.path)
        var names: [String] = []
        while let relative = files?.nextObject() as? String {
            if (relative as NSString).lastPathComponent.hasPrefix(".") {
                files?.skipDescendants()
                continue
            }
            let path = commands.appendingPathComponent(relative)
            guard path.pathExtension == "toml",
                  let values = try? path.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            names.append((relative as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: ":"))
        }
        for location in ["skills", "config/skills"] {
            let skills = home.appendingPathComponent(location, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: skills.path)) ?? [] {
                if fm.fileExists(atPath: skills.appendingPathComponent(name).appendingPathComponent("SKILL.md").path) {
                    names.append(name)
                }
            }
        }
        return names.sorted()
    }
}
