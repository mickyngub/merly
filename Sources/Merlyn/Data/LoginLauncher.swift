// LoginLauncher.swift — runs a provider CLI's own sign-in flow in a terminal, so
// an expired login can be fixed from the panel instead of hunting down the agent.
//
// Merlyn deliberately does not authenticate on the provider's behalf: it never
// mints or refreshes a token (see docs/provider-integration.md). This only shells
// out to the CLI's documented login command — `claude auth login`, `codex login`,
// `kimi login` — which then owns the credentials as usual.

import AppKit
import Foundation

enum LoginLauncher {
    /// Opens the provider's sign-in in a terminal window. Returns false only if the
    /// launch script couldn't be written or handed off.
    ///
    /// Sign-in needs a real TTY and a browser hand-off (device codes, pasted
    /// tokens), so it can't run headless inside the app. A one-shot `.command`
    /// script handed to LaunchServices opens in whatever terminal the user has
    /// associated with `.command` — Terminal.app unless they've changed it — which
    /// needs no Automation permission, unlike scripting Terminal directly.
    @discardableResult
    static func openLogin(for config: ProviderConfig) -> Bool {
        guard let url = writeScript(for: config) else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func writeScript(for config: ProviderConfig) -> URL? {
        let slug = config.id.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("merlyn-signin-\(slug).command")
        do {
            try script(for: config).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                 ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// `zsh -l` on purpose: a *login* shell reads ~/.zshenv and ~/.zprofile, which
    /// is where PATH normally comes from, while staying out of ~/.zshrc — that's
    /// the interactive file, and a common setup auto-attaches tmux there, which
    /// would swallow the login command instead of running it. The PATH prepend
    /// covers installs whose shell config lives only in ~/.zshrc.
    private static func script(for config: ProviderConfig) -> String {
        let label = "\(config.name)\(config.account.isEmpty ? "" : " (\(config.account))")"
        return """
        #!/bin/zsh -l
        export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
        printf '\\033]0;Merlyn — sign in\\007'
        echo "Signing in to \(label.shellEscapedForDoubleQuotes)"
        echo "> \(config.loginShellCommand.shellEscapedForDoubleQuotes)"
        echo
        \(config.loginShellCommand)
        # `rc`, not `status`: zsh makes $status a read-only synonym for $?.
        rc=$?
        echo
        if [ $rc -eq 0 ]; then
          echo "Signed in. Merlyn picks it up on its next refresh."
        else
          echo "Sign-in exited with status $rc."
        fi
        echo "You can close this window."

        """
    }
}

extension String {
    /// Single-quoted for safe use as one shell word.
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Escaped for interpolation inside a double-quoted shell string, so a provider
    /// name carrying `"`, `$`, or a backslash can't break out of the echo.
    var shellEscapedForDoubleQuotes: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}
