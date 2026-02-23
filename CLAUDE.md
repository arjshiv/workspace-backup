# workspace-backup

Backup and restore scripts for migrating a full AI dev environment (Claude Code, Codex CLI, Conductor, Microsoft Edge, Cursor IDE, Desktop Apps) between Macs.

## Structure

- `backup.sh` — Runs on the source Mac. Auto-discovers project configs, Conductor workspaces, and Volta packages. Produces a self-contained backup folder under `backups/` with all configs, history, workspace metadata, and a restore script. Supports `--dry-run`, `--encrypt`, `--resume-from=STEP`, and `--help`. Writes `results.json` for agent consumption.
- `restore.sh` — Runs on the target Mac. Accepts either a backup directory or an encrypted `.zip` file. Installs prerequisites (Homebrew packages, Volta, Oh-My-Zsh, Rust), restores all configs, re-creates Conductor git worktrees, applies uncommitted change patches, and restores database tools (DataGrip, psql). Saves existing files as `*.pre-restore` before overwriting. Supports `--dry-run`, `--yes`/`-y`, `--resume-from=STEP`, and `--help`. Writes `results.json` for agent consumption.
- `backups/` — Gitignored output directory where backup folders land.

## Key design decisions

- Conductor worktrees are NOT backed up as full git clones (13GB+). Instead, each worktree is captured as a JSON manifest (branch, commit, remote) + a `git diff` patch for uncommitted changes + a tar of untracked files + `.env` files. Restore re-clones the parent repo and recreates worktrees via `git worktree add`.
- Homebrew state is captured via `brew bundle dump` (Brewfile) and restored via `brew bundle install`.
- Volta global packages are dynamically captured from `volta list all` and reinstalled on restore. Falls back to a hardcoded list if Volta is unavailable.
- Skill symlinks (`~/.claude/skills/remotion-best-practices` -> `~/.agents/skills/...`) are resolved to real files during backup and recreated as symlinks during restore.
- Microsoft Edge profiles are backed up per-profile: individual files (Bookmarks, Preferences, History, etc.) plus tar.gz archives for directories (Sessions, Extensions, Collections). Cookies, Login Data, caches, and Service Workers are excluded. Restore warns strongly if Edge is running.
- Cursor IDE settings, keybindings, and snippets are copied from `~/Library/Application Support/Cursor/User/`. The extension list is captured via `cursor --list-extensions` when the CLI is available, falling back to reading directory names from `~/.cursor/extensions/`. Restore reinstalls extensions via `cursor --install-extension`.
- Desktop Apps (iTerm2, Warp, Rectangle) preferences are exported as XML plists via `plutil -convert xml1`. User fonts are archived as a tar.gz from `~/Library/Fonts/`. Each app is independently optional — missing apps are skipped without error.
- AWS credentials (`~/.aws/`) and npm config (`~/.npmrc`) are included in the shell-env backup with `chmod 600` applied to sensitive files.
- DataGrip settings are backed up from the latest `~/Library/Application Support/JetBrains/DataGrip*/` version. Includes `options/` (settings XMLs, database driver configs), `workspace/` (data source connections), `consoles/` (SQL console history), `codestyles/`, `tasks/`, `jdbc-drivers/`, JVM options, and the license key. Plugins and caches are excluded (regenerated on launch). The license key (`datagrip.key`) and `.pgpass` get `chmod 600`.
- PostgreSQL client config (`~/.psqlrc`, `~/.psql_history`, `~/.pgpass`, `~/.pg_service.conf`, `~/.postgresql/`) is backed up alongside DataGrip in the `db-tools` step.
- Sensitive files (SSH keys, OAuth tokens, .env files, browser history, AWS credentials, .npmrc) get `chmod 600` in the backup. The script warns to encrypt before uploading to cloud storage.

## Agent invocation pattern

Both scripts produce a `results.json` alongside the backup with structured per-step status. A Claude Code agent should:

1. Run the script: `bash backup.sh --yes` or `bash restore.sh --yes /path/to/backup`
2. Read `results.json` from the backup directory after the script exits
3. Check `exit_code`: 0 = success, 1 = step failure, 2 = preflight failure
4. On failure, inspect `.steps[]` for entries with `"status": "failed"` and read their `.errors[]`
5. Use the error `category` to decide the action:
   - `transient` — retry with `--resume-from=STEP_NAME`
   - `permanent` — fix the root cause (e.g. missing file, bad perms), then retry
   - `user_action` — ask the user (e.g. quit Edge, re-authenticate)
6. Retry: `bash backup.sh --resume-from=homebrew --yes`

Step names for `--resume-from` (backup.sh): `create_dirs`, `claude_code`, `project_configs`, `codex_cli`, `shared_agents`, `conductor_worktrees`, `conductor_db`, `shell_env`, `homebrew`, `volta`, `edge`, `cursor_ide`, `db_tools`, `desktop_apps`, `github_repos`, `manifest`, `restore_guide`, `copy_scripts`, `permissions`

Step names for `--resume-from` (restore.sh): `prerequisites`, `shell_env`, `volta`, `claude_code`, `project_configs`, `codex_cli`, `conductor_worktrees`, `conductor_db`, `edge`, `cursor_ide`, `db_tools`, `github_repos`, `desktop_apps`

## Adding a new backup section

1. Add a new step in `backup.sh` between the existing sections, wrapped in `begin_step`/`end_step`.
2. Create the corresponding restore section in `restore.sh` at the same position, also wrapped in `begin_step`/`end_step`.
3. Add the new section to the manifest generation block near the end of `backup.sh`.
4. Update `RESTORE-GUIDE.md` generation in `backup.sh` to document the new section.
5. Add the step name to the `--resume-from` lookup in both scripts and update `TOTAL_STEPS`.

## What NOT to back up

- Debug logs, shell snapshots, session-env, caches, temp files — anything ephemeral that gets regenerated.
- `node_modules/` — restored via `npm install` after worktree creation.
- Full git repos — only metadata + patches. The repos are re-cloned from remotes.
