# FAQ / Troubleshooting

Common issues encountered during backup and restore, with solutions.

---

## node_modules not found after restore

`node_modules/` directories are excluded from backup by design -- they are large and fully reproducible. After restoring a workspace, install dependencies manually:

```bash
cd /path/to/your/project
npm install
```

Repeat for each restored workspace or conductor worktree.

---

## SSH key permissions denied

SSH refuses keys with overly permissive file modes. Fix them:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
```

If you see `WARNING: UNPROTECTED PRIVATE KEY FILE`, the same fix applies. The restore script sets `chmod 600` on backed-up keys, but verify after restore.

---

## Worktree branch not found on remote

The branch referenced by a conductor worktree may have been deleted from the remote (e.g., after a PR merge). In this case, `git worktree add` creates the worktree at a detached HEAD on the recorded commit.

Check the `.patch` file in the backup to recover any uncommitted changes:

```bash
cd /path/to/worktree
git apply /path/to/backup/conductor/worktree-name/worktree-name.patch
```

You can also inspect the worktree manifest for the original branch and commit:

```bash
cat /path/to/backup/conductor/worktree-name/worktree-manifest.json | jq .
```

---

## Volta package install fails

If a global package fails to install via Volta during restore, install it directly with npm as a fallback:

```bash
npm install -g <package-name>
```

Also verify your Volta version is compatible:

```bash
volta --version
volta install node@latest
```

If Volta itself is missing, the restore script installs it automatically. If that step failed, install manually:

```bash
curl https://get.volta.sh | bash
```

---

## Edge profiles not loading after restore

Microsoft Edge must be completely quit before restoring profiles. If Edge was running during restore, the restored files may have been overwritten by Edge on exit.

1. Quit Edge fully (check for background processes):

```bash
pkill -f "Microsoft Edge"
```

2. Re-run the restore, or manually copy the profile files from the backup.

If a profile appears corrupt after restore, delete the profile directory and re-import your bookmarks from the backup:

```bash
# The backup contains a Bookmarks JSON file per profile
cat /path/to/backup/edge/ProfileName/Bookmarks | python3 -m json.tool
```

Then import via Edge Settings > Import browser data.

---

## Cursor extensions not installing

The Cursor CLI (`cursor`) may not be in your PATH after a fresh install. Verify:

```bash
which cursor
```

If not found, launch Cursor manually, open the Command Palette (`Cmd+Shift+P`), and run "Shell Command: Install 'cursor' command in PATH".

Then install extensions from the backup list:

```bash
while read -r ext; do
  cursor --install-extension "$ext"
done < /path/to/backup/cursor/extensions.txt
```

Alternatively, install extensions from the Extensions panel inside Cursor.

---

## Plist settings not taking effect (iTerm2 / Warp / Rectangle)

macOS caches preferences via `cfprefsd`. After restoring plist files, the running daemon may still serve stale values.

Force a refresh:

```bash
killall cfprefsd
```

Or restart the affected app. In some cases, a logout/login is required for system-level plists.

For iTerm2 specifically, if you use a custom preferences folder, make sure the path is set in iTerm2 > Settings > General > Preferences before restarting.

---

## AWS auth / credentials not working

Restored AWS credentials may contain expired session tokens. Verify your identity:

```bash
aws sts get-caller-identity
```

If this fails:

- For IAM credentials: re-run `aws configure` and enter fresh keys.
- For SSO: re-authenticate with `aws sso login --profile <profile-name>`.
- Check that `~/.aws/credentials` and `~/.aws/config` have correct values.

---

## Codex auth token expired

Codex CLI tokens expire. Re-authenticate after restore:

```bash
codex auth
```

Follow the browser-based login flow to obtain a fresh token.

---

## Backup too large

A well-formed backup should be under a few hundred MB. If it is unexpectedly large, check for accidentally included caches or full repos.

Identify large files in the backup:

```bash
du -sh /path/to/backup/*/
du -ah /path/to/backup/ | sort -rh | head -20
```

Conductor worktrees should contain only metadata (manifest JSON, patch files, untracked tarballs, .env), not full git clones. If a worktree directory is large, it may have been copied incorrectly.

---

## "Not a valid backup" error

The restore script validates that the backup directory contains required entries:

```bash
RESTORE-GUIDE.md
manifest.json
claude-code/
codex-cli/
conductor/
shell-env/
volta/
```

If any of these are missing, the backup may be incomplete or corrupted. Re-run `backup.sh` on the source machine to generate a fresh backup. If you moved the backup between machines, verify that the transfer preserved the full directory structure (e.g., `rsync -a` or `tar` rather than drag-and-drop, which can skip hidden files).

---

## Fonts not rendering after restore

If restored fonts are not visible in applications, the macOS font cache may be stale. Clear it and restart:

```bash
sudo atsutil databases -remove
```

Then restart your machine, or at minimum restart the affected applications. Fonts installed to `~/Library/Fonts/` should be picked up automatically after the cache rebuild.

---

## Using results.json for troubleshooting

Both `backup.sh` and `restore.sh` write a `results.json` file in the backup directory with structured status for every step. This is designed for agent automation but is also useful for manual debugging.

### Reading results.json

```bash
# Quick summary
jq '.summary' results.json

# Show only failed steps
jq '.steps[] | select(.status == "failed")' results.json

# Show all errors with their categories
jq '.steps[].errors[]' results.json

# Check preflight results
jq '.preflight' results.json

# Check post-run validation
jq '.validation' results.json
```

### Common error codes

| Code | Step | Meaning |
|------|------|---------|
| `BREW_DUMP_FAILED` | homebrew | `brew bundle dump` failed — try `brew untap` problematic taps |
| `EDGE_RUNNING` | edge | Edge was running during backup/restore — quit Edge and retry |
| `WARN` | (various) | Generic warning — check the `message` field for details |

### Resuming from a failed step

If a step fails, fix the root cause and resume without re-running completed steps:

```bash
# Check which step failed
jq '.steps[] | select(.status == "failed") | .name' results.json

# Resume from that step
./backup.sh --resume-from=homebrew
bash restore.sh --resume-from=edge /path/to/backup
```

Skipped steps are recorded as `"status": "skipped"` in the new results.json.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | All steps completed |
| `1` | One or more steps failed |
| `2` | Preflight check failed (missing jq, git, or insufficient disk space) |

### Error categories

Each error in results.json has a `category` field:

- **`transient`**: Temporary failures (network timeout, brew flake). Safe to retry with `--resume-from`.
- **`permanent`**: Structural issues (missing directory, corrupt file, wrong permissions). Fix the root cause before retrying.
- **`user_action`**: Requires human intervention (quit Edge, re-authenticate, approve access).
