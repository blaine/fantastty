import Foundation
import os

/// Manages shell integration scripts for DCS passthrough of OSC 7 through tmux.
/// Writes scripts to ~/.fantastty/ at app launch so that tmux inner shells
/// can report pwd changes directly to Ghostty via DCS passthrough.
class ShellIntegration {
    static let shared = ShellIntegration()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "shell-integration"
    )

    /// Whether the shell integration files were successfully written
    private(set) var isAvailable: Bool = false

    /// Path to the ZDOTDIR proxy directory for zsh
    var zdotdirPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".fantastty/shell/zsh").path
    }

    /// Base directory for all Fantastty shell integration files
    private var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fantastty")
    }

    /// Write all shell integration files if they don't exist or content has changed.
    func ensureInstalled() {
        let fm = FileManager.default

        do {
            // Create directories
            let zshDir = baseDir.appendingPathComponent("shell/zsh")
            let integrationDir = baseDir.appendingPathComponent("shell-integration")
            try fm.createDirectory(at: zshDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: integrationDir, withIntermediateDirectories: true)

            // Write ZDOTDIR proxy files
            try writeIfChanged(zshDir.appendingPathComponent(".zshenv"), content: zshenvContent)
            try writeIfChanged(zshDir.appendingPathComponent(".zshrc"), content: zshrcProxy)
            try writeIfChanged(zshDir.appendingPathComponent(".zprofile"), content: zprofileProxy)
            try writeIfChanged(zshDir.appendingPathComponent(".zlogin"), content: zloginProxy)

            // Write the actual OSC 7 passthrough hook
            try writeIfChanged(
                integrationDir.appendingPathComponent("osc7-passthrough.zsh"),
                content: osc7PassthroughContent
            )

            isAvailable = true
            Self.logger.info("Shell integration installed at \(self.baseDir.path)")
        } catch {
            isAvailable = false
            Self.logger.error("Failed to install shell integration: \(error)")
        }
    }

    // MARK: - Private

    /// Write content to a file only if it differs from existing content.
    private func writeIfChanged(_ url: URL, content: String) throws {
        let data = Data(content.utf8)
        if let existing = try? Data(contentsOf: url), existing == data {
            return
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - File Contents

    /// .zshenv — ZDOTDIR proxy that restores the user's original ZDOTDIR,
    /// sources the user's .zshenv, then loads our integration.
    private var zshenvContent: String {
        """
        # Fantastty shell integration — ZDOTDIR proxy
        # Restore user's ZDOTDIR
        if [[ -n "${FANTASTTY_ORIGINAL_ZDOTDIR+X}" ]]; then
            builtin export ZDOTDIR="$FANTASTTY_ORIGINAL_ZDOTDIR"
            builtin unset 'FANTASTTY_ORIGINAL_ZDOTDIR'
        else
            builtin unset 'ZDOTDIR'
        fi
        # Source user's .zshenv
        builtin typeset _f=${ZDOTDIR-$HOME}/.zshenv
        [[ ! -r "$_f" ]] || builtin source -- "$_f"
        builtin unset '_f'
        # Source Fantastty integration (interactive tmux shells only)
        if [[ -o interactive && -n "$TMUX" ]]; then
            builtin source -- ~/.fantastty/shell-integration/osc7-passthrough.zsh 2>/dev/null
        fi
        """
    }

    /// .zshrc proxy — sources the user's original .zshrc
    private var zshrcProxy: String {
        """
        builtin typeset _f=${ZDOTDIR-$HOME}/.zshrc
        [[ ! -r "$_f" ]] || builtin source -- "$_f"
        builtin unset '_f'
        """
    }

    /// .zprofile proxy — sources the user's original .zprofile
    private var zprofileProxy: String {
        """
        builtin typeset _f=${ZDOTDIR-$HOME}/.zprofile
        [[ ! -r "$_f" ]] || builtin source -- "$_f"
        builtin unset '_f'
        """
    }

    /// .zlogin proxy — sources the user's original .zlogin
    private var zloginProxy: String {
        """
        builtin typeset _f=${ZDOTDIR-$HOME}/.zlogin
        [[ ! -r "$_f" ]] || builtin source -- "$_f"
        builtin unset '_f'
        """
    }

    /// osc7-passthrough.zsh — the actual chpwd/precmd hook that sends
    /// DCS-wrapped OSC 7 through tmux to the outer terminal.
    private var osc7PassthroughContent: String {
        """
        # Fantastty OSC 7 DCS passthrough for tmux
        # Only run inside tmux
        [[ -n "$TMUX" ]] || return 0
        _fantastty_report_pwd() {
            builtin printf '\\ePtmux;\\e\\e]7;kitty-shell-cwd://%s%s\\a\\e\\\\' "${HOST}" "${PWD}"
        }
        chpwd_functions=(${chpwd_functions[@]} "_fantastty_report_pwd")
        precmd_functions=(${precmd_functions[@]} "_fantastty_report_pwd")
        _fantastty_report_pwd
        """
    }
}
