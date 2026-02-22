# workspace-backup

Backup and restore scripts for migrating a full AI dev environment between Macs. Captures Claude Code, Codex CLI, Conductor, Microsoft Edge, Cursor IDE, and Desktop Apps state into a single portable folder.

## What gets backed up

| Component | What's captured | Raw → Backed up |
|-----------|----------------|-----------------|
| **Claude Code** | Settings, MCP servers, plugins, skills, project memory, history, plans | ~450MB → ~80MB |
| **Codex CLI** | Config, rules, auth, sessions, skills, history | ~89MB → ~25MB |
| **Conductor** | Worktree metadata + patches (not full clones), SQLite DB, archived contexts | ~13GB → ~100MB |
| **Homebrew** | Full Brewfile (taps, formulae, casks) | ~5KB |
| **Shell** | .zshrc, .gitconfig, SSH keys, GitHub CLI config, AWS config, .npmrc | ~10KB |
| **Volta** | Global package manifest (node, npm, CLIs) | ~5KB |
| **Cursor IDE** | Settings, keybindings, snippets, extension list | ~5KB |
| **Desktop Apps** | iTerm2, Warp, Rectangle preferences, user fonts | ~10KB |

Conductor worktrees are captured as JSON manifests + `git diff` patches + untracked file archives — not as 13GB of git clones. The restore script re-clones from remotes and recreates worktrees.

## Usage

### Backup (on source Mac)

```bash
./backup.sh              # full backup
./backup.sh --dry-run    # preview what would be backed up
./backup.sh --help       # show all options
```

Creates a timestamped folder under `backups/`:

```
backups/workspace-backup-2026-02-19-143022/
├── RESTORE-GUIDE.md
├── manifest.json
├── backup.sh / restore.sh
├── claude-code/
├── codex-cli/
├── conductor/
├── homebrew/
├── shell-env/
├── volta/
├── cursor-ide/
└── desktop-apps/
```

Project paths, Conductor workspaces, and Volta packages are auto-discovered at runtime — no hardcoded lists to maintain.

### Restore (on target Mac)

```bash
bash restore.sh /path/to/workspace-backup-2026-02-19-143022
bash restore.sh --dry-run /path/to/backup    # preview without writing
bash restore.sh -y /path/to/backup           # skip confirmation prompt
bash restore.sh --help                       # show all options
```

The restore script handles:
1. Installing Homebrew packages from Brewfile
2. Setting up Volta, Oh-My-Zsh, Rust/Cargo
3. Restoring all Claude Code and Codex configs
4. Cloning repos and recreating Conductor worktrees
5. Applying uncommitted change patches
6. Restoring the Conductor database
7. Installing Cursor IDE extensions and restoring settings
8. Importing Desktop Apps preferences and user fonts

Before overwriting existing files (`.zshrc`, `.gitconfig`, SSH keys, etc.), the restore script saves them as `*.pre-restore` backups.

### After restore

A few manual steps remain:
- `gh auth login` — authenticate GitHub CLI
- `ssh -T git@github.com` — verify SSH
- `aws sts get-caller-identity` — verify AWS CLI auth
- `npm install -g @anthropic-ai/claude-code` — install Claude Code binary
- `npm install` in any workspace that needs node_modules
- Install Conductor app from official source
- Launch Cursor and check that extensions loaded correctly
- Restart terminal apps (iTerm2/Warp) to pick up restored settings

See [FAQ.md](FAQ.md) for common restore issues and troubleshooting.

## Sensitive files

The backup contains SSH keys, OAuth tokens, and `.env` files. **Encrypt before uploading to cloud storage:**

```bash
zip -er workspace-backup.zip backups/workspace-backup-*/
```

## License

[MIT](LICENSE)
