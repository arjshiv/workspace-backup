# workspace-backup

Backup and restore scripts for migrating a full AI dev environment (Claude Code, Codex CLI, Conductor) between Macs.

## Structure

- `backup.sh` — Runs on the source Mac. Produces a self-contained backup folder under `backups/` with all configs, history, workspace metadata, and a restore script.
- `restore.sh` — Runs on the target Mac. Installs prerequisites (Homebrew packages, Volta, Oh-My-Zsh, Rust), restores all configs, re-creates Conductor git worktrees, and applies uncommitted change patches.
- `backups/` — Gitignored output directory where backup folders land.

## Key design decisions

- Conductor worktrees are NOT backed up as full git clones (13GB+). Instead, each worktree is captured as a JSON manifest (branch, commit, remote) + a `git diff` patch for uncommitted changes + a tar of untracked files + `.env` files. Restore re-clones the parent repo and recreates worktrees via `git worktree add`.
- Homebrew state is captured via `brew bundle dump` (Brewfile) and restored via `brew bundle install`.
- Volta global packages are listed in `global-packages.json` and reinstalled on restore.
- Skill symlinks (`~/.claude/skills/remotion-best-practices` -> `~/.agents/skills/...`) are resolved to real files during backup and recreated as symlinks during restore.
- Sensitive files (SSH keys, OAuth tokens, .env files) get `chmod 600` in the backup. The script warns to encrypt before uploading to cloud storage.

## Adding a new backup section

1. Add a new step in `backup.sh` between the existing sections (follow the `step "..."` / section comment pattern).
2. Create the corresponding restore section in `restore.sh` at the same position.
3. Add the new section to the manifest generation block near the end of `backup.sh`.
4. Update `RESTORE-GUIDE.md` generation in `backup.sh` to document the new section.

## What NOT to back up

- Debug logs, shell snapshots, session-env, caches, temp files — anything ephemeral that gets regenerated.
- `node_modules/` — restored via `npm install` after worktree creation.
- Full git repos — only metadata + patches. The repos are re-cloned from remotes.
