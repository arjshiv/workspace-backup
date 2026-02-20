#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DATE=$(date +%Y-%m-%d)
BACKUP_DIR="$SCRIPT_DIR/backups/workspace-backup-${BACKUP_DATE}"
CLAUDE_HOME="$HOME/.claude"
CODEX_HOME="$HOME/.codex"
CONDUCTOR_HOME="$HOME/conductor"
CONDUCTOR_APP_SUPPORT="$HOME/Library/Application Support/com.conductor.app"
AGENTS_HOME="$HOME/.agents"
WARN_COUNT=0
LOG_FILE=""

warn() {
  echo "  WARN: $1"
  WARN_COUNT=$((WARN_COUNT + 1))
  [ -n "$LOG_FILE" ] && echo "WARN: $1" >> "$LOG_FILE"
}

step() {
  echo ""
  echo "==> $1"
}

copy_if_exists() {
  local src="$1" dst="$2"
  if [ -f "$src" ]; then
    cp "$src" "$dst"
  else
    warn "Not found: $src"
  fi
}

# --- Safety checks ---
if [ -d "$BACKUP_DIR" ]; then
  echo "Backup directory already exists: $BACKUP_DIR"
  read -rp "Overwrite? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  rm -rf "$BACKUP_DIR"
fi

avail_mb=$(df -m "$SCRIPT_DIR" | awk 'NR==2{print $4}')
if [ "$avail_mb" -lt 250 ]; then
  echo "ERROR: Less than 250MB free. Need space for backup."
  exit 1
fi

# --- Create directory structure ---
step "Creating backup directory structure"
mkdir -p "$BACKUP_DIR"
LOG_FILE="$BACKUP_DIR/backup.log"
echo "Backup started at $(date)" > "$LOG_FILE"

mkdir -p "$BACKUP_DIR"/{claude-code/skills,claude-code-project-configs}
mkdir -p "$BACKUP_DIR"/codex-cli/{rules,skills,sqlite}
mkdir -p "$BACKUP_DIR"/shared-agents
mkdir -p "$BACKUP_DIR"/conductor/workspaces/{Server_Web_Outlook,dash}
mkdir -p "$BACKUP_DIR"/shell-env/{ssh,gh,inshellisense}
mkdir -p "$BACKUP_DIR"/volta

# ============================================================
# CLAUDE CODE
# ============================================================
step "Backing up Claude Code"

# Small files
for f in CLAUDE.md settings.json config.json history.jsonl stats-cache.json; do
  copy_if_exists "$CLAUDE_HOME/$f" "$BACKUP_DIR/claude-code/"
done

# Compressed archives
for dir in plans plugins projects file-history todos tasks paste-cache; do
  if [ -d "$CLAUDE_HOME/$dir" ]; then
    echo "  Compressing $dir..."
    tar -czf "$BACKUP_DIR/claude-code/${dir}.tar.gz" -C "$CLAUDE_HOME" "$dir/" 2>/dev/null || warn "Failed to archive $dir"
  fi
done

# Skills — resolve symlinks to copy actual files
if [ -d "$CLAUDE_HOME/skills/agent-browser" ]; then
  cp -R "$CLAUDE_HOME/skills/agent-browser" "$BACKUP_DIR/claude-code/skills/"
fi
if [ -e "$CLAUDE_HOME/skills/remotion-best-practices" ]; then
  cp -RL "$CLAUDE_HOME/skills/remotion-best-practices" "$BACKUP_DIR/claude-code/skills/" 2>/dev/null || warn "Failed to copy remotion skill"
fi

echo "  Claude Code done."

# ============================================================
# PROJECT-SPECIFIC .claude DIRS
# ============================================================
step "Backing up project-specific Claude configs"

declare -A PROJECT_PATHS
PROJECT_PATHS=(
  ["GitHub--agentic-coding-workshop"]="$HOME/GitHub/agentic-coding-workshop/.claude"
  ["GitHub"]="$HOME/GitHub/.claude"
  ["GitHub--bcs-app"]="$HOME/GitHub/bcs-app/.claude"
  ["GitHub--msearch"]="$HOME/GitHub/msearch/.claude"
  ["Downloads--Application_FinalReview_ResiDesk"]="$HOME/Downloads/Application_FinalReview_ResiDesk/.claude"
  ["Downloads--airtel-docs"]="$HOME/Downloads/airtel-docs/.claude"
  ["Downloads--hoa-results"]="$HOME/Downloads/hoa-results/.claude"
)

# Generate project-paths.json
echo "{" > "$BACKUP_DIR/claude-code-project-configs/project-paths.json"
first=true
for key in "${!PROJECT_PATHS[@]}"; do
  src="${PROJECT_PATHS[$key]}"
  rel_path="${src/#$HOME/~}"
  if $first; then first=false; else echo "," >> "$BACKUP_DIR/claude-code-project-configs/project-paths.json"; fi
  printf '  "%s": "%s"' "$key" "$rel_path" >> "$BACKUP_DIR/claude-code-project-configs/project-paths.json"
done
echo "" >> "$BACKUP_DIR/claude-code-project-configs/project-paths.json"
echo "}" >> "$BACKUP_DIR/claude-code-project-configs/project-paths.json"

# Copy each project config
for key in "${!PROJECT_PATHS[@]}"; do
  src="${PROJECT_PATHS[$key]}"
  if [ -d "$src" ]; then
    mkdir -p "$BACKUP_DIR/claude-code-project-configs/$key"
    cp -R "$src/"* "$BACKUP_DIR/claude-code-project-configs/$key/" 2>/dev/null || true
    echo "  Backed up: $key"
  else
    warn "Project config not found: $src"
  fi
done

# ============================================================
# CODEX CLI
# ============================================================
step "Backing up Codex CLI"

for f in config.json config.toml instructions.md auth.json history.json history.jsonl \
         .codex-global-state.json version.json update-check.json; do
  copy_if_exists "$CODEX_HOME/$f" "$BACKUP_DIR/codex-cli/"
done

# Rules
copy_if_exists "$CODEX_HOME/rules/default.rules" "$BACKUP_DIR/codex-cli/rules/"

# Skills
if [ -d "$CODEX_HOME/skills/.system" ]; then
  cp -R "$CODEX_HOME/skills/.system" "$BACKUP_DIR/codex-cli/skills/"
fi
if [ -e "$CODEX_HOME/skills/remotion-best-practices" ]; then
  cp -RL "$CODEX_HOME/skills/remotion-best-practices" "$BACKUP_DIR/codex-cli/skills/" 2>/dev/null || true
fi

# SQLite
copy_if_exists "$CODEX_HOME/sqlite/codex-dev.db" "$BACKUP_DIR/codex-cli/sqlite/"

# Compressed archives
for dir in sessions vendor_imports; do
  if [ -d "$CODEX_HOME/$dir" ]; then
    echo "  Compressing $dir..."
    tar -czf "$BACKUP_DIR/codex-cli/${dir}.tar.gz" -C "$CODEX_HOME" "$dir/" 2>/dev/null || warn "Failed to archive codex $dir"
  fi
done

echo "  Codex CLI done."

# ============================================================
# SHARED AGENTS
# ============================================================
step "Backing up shared agents"

if [ -d "$AGENTS_HOME" ]; then
  cp -RL "$AGENTS_HOME/"* "$BACKUP_DIR/shared-agents/" 2>/dev/null || warn "Failed to copy shared agents"
  echo "  Shared agents done."
else
  warn "No ~/.agents/ directory found"
fi

# ============================================================
# CONDUCTOR — WORKTREE METADATA
# ============================================================
step "Backing up Conductor workspaces"

backup_worktrees() {
  local project_name="$1"
  local main_repo="$2"
  local remote_origin="$3"
  local worktree_parent="$4"
  local backup_ws_dir="$BACKUP_DIR/conductor/workspaces/$project_name"

  # Main repo info
  local heroku_remote=""
  heroku_remote=$(git -C "$main_repo" remote get-url heroku 2>/dev/null || echo "")
  local main_branch
  main_branch=$(git -C "$main_repo" branch --show-current 2>/dev/null || echo "master")
  local stash_count=0
  stash_count=$(git -C "$main_repo" stash list 2>/dev/null | wc -l | tr -d ' ')

  cat > "$backup_ws_dir/_main-repo-info.json" << INFOJSON
{
  "remote_origin": "$remote_origin",
  "remote_heroku": "$heroku_remote",
  "main_branch": "$main_branch",
  "main_repo_path": "$main_repo",
  "worktree_parent": "$worktree_parent",
  "stash_count": $stash_count
}
INFOJSON

  # Backup stash patches
  if [ "$stash_count" -gt 0 ]; then
    git -C "$main_repo" stash list > "$backup_ws_dir/_stash-list.txt" 2>/dev/null || true
    for i in $(seq 0 $((stash_count - 1))); do
      git -C "$main_repo" stash show -p "stash@{$i}" > "$backup_ws_dir/_stash-${i}.patch" 2>/dev/null || true
    done
    echo "  Saved $stash_count stash patches"
  fi

  # Per-worktree backup
  if [ ! -d "$worktree_parent" ]; then
    warn "Worktree parent not found: $worktree_parent"
    return
  fi

  for ws in "$worktree_parent"/*/; do
    [ -d "$ws" ] || continue
    local name
    name=$(basename "$ws")

    local branch commit remote_url has_env has_nm
    branch=$(git -C "$ws" branch --show-current 2>/dev/null || echo "DETACHED")
    commit=$(git -C "$ws" rev-parse HEAD 2>/dev/null || echo "unknown")
    remote_url=$(git -C "$ws" remote get-url origin 2>/dev/null || echo "$remote_origin")
    has_env=$( [ -f "$ws/.env" ] && echo "true" || echo "false" )
    has_nm=$( [ -d "$ws/node_modules" ] && echo "true" || echo "false" )

    cat > "$backup_ws_dir/${name}.json" << WSJSON
{
  "name": "$name",
  "branch": "$branch",
  "commit": "$commit",
  "remote": "$remote_url",
  "has_env": $has_env,
  "has_node_modules": $has_nm
}
WSJSON

    # Uncommitted tracked changes
    local diff_output
    diff_output=$(git -C "$ws" diff HEAD 2>/dev/null || true)
    if [ -n "$diff_output" ]; then
      echo "$diff_output" > "$backup_ws_dir/${name}.patch"
      echo "  $name: saved uncommitted changes patch"
    fi

    # Untracked files
    local untracked
    untracked=$(git -C "$ws" ls-files --others --exclude-standard 2>/dev/null | grep -v '^node_modules/' || true)
    if [ -n "$untracked" ]; then
      echo "$untracked" > "$backup_ws_dir/${name}.untracked"
      (cd "$ws" && echo "$untracked" | tar -czf "$backup_ws_dir/${name}-untracked.tar.gz" \
        -T - 2>/dev/null) || warn "Failed to archive untracked files for $name"
      echo "  $name: saved untracked files archive"
    fi

    # .env backup
    if [ -f "$ws/.env" ]; then
      cp "$ws/.env" "$backup_ws_dir/${name}.env"
    fi

    # .context dir backup
    if [ -d "$ws/.context" ]; then
      tar -czf "$backup_ws_dir/${name}-context.tar.gz" -C "$ws" .context/ 2>/dev/null || true
    fi

    echo "  $name: $branch @ ${commit:0:7}"
  done
}

# Server_Web_Outlook
if [ -d "$HOME/GitHub/residesk/Server_Web_Outlook/.git" ]; then
  echo "  Processing Server_Web_Outlook..."
  backup_worktrees "Server_Web_Outlook" \
    "$HOME/GitHub/residesk/Server_Web_Outlook" \
    "https://github.com/BrgnTech/Server_Web_Outlook.git" \
    "$CONDUCTOR_HOME/workspaces/Server_Web_Outlook"
else
  warn "Main repo not found: ~/GitHub/residesk/Server_Web_Outlook"
fi

# dash
if [ -d "$HOME/GitHub/dash/.git" ]; then
  echo "  Processing dash..."
  backup_worktrees "dash" \
    "$HOME/GitHub/dash" \
    "https://github.com/agno-agi/dash.git" \
    "$CONDUCTOR_HOME/workspaces/dash"
else
  warn "Main repo not found: ~/GitHub/dash"
fi

# ============================================================
# CONDUCTOR — DATABASE & APP DATA
# ============================================================
step "Backing up Conductor database"

if [ -f "$CONDUCTOR_APP_SUPPORT/conductor.db" ]; then
  if command -v sqlite3 &>/dev/null; then
    sqlite3 "$CONDUCTOR_APP_SUPPORT/conductor.db" ".backup '$BACKUP_DIR/conductor/conductor.db'" 2>/dev/null \
      || { warn "sqlite3 backup failed, falling back to cp"; cp "$CONDUCTOR_APP_SUPPORT/conductor.db" "$BACKUP_DIR/conductor/"; }
  else
    cp "$CONDUCTOR_APP_SUPPORT/conductor.db" "$BACKUP_DIR/conductor/"
  fi
  echo "  conductor.db backed up"
else
  warn "Conductor database not found"
fi

# WAL file
cp "$CONDUCTOR_APP_SUPPORT/conductor.db-wal" "$BACKUP_DIR/conductor/" 2>/dev/null || true

# Plist
if [ -f "$HOME/Library/Preferences/com.conductor.app.plist" ]; then
  plutil -convert xml1 -o "$BACKUP_DIR/conductor/conductor-plist.xml" \
    "$HOME/Library/Preferences/com.conductor.app.plist" 2>/dev/null || warn "Failed to export plist"
fi

# Archived contexts
if [ -d "$CONDUCTOR_HOME/archived-contexts" ]; then
  echo "  Compressing archived contexts..."
  tar -czf "$BACKUP_DIR/conductor/archived-contexts.tar.gz" -C "$CONDUCTOR_HOME" archived-contexts/ 2>/dev/null || warn "Failed to archive contexts"
fi

# Context trash
if [ -d "$CONDUCTOR_HOME/.context-trash" ]; then
  tar -czf "$BACKUP_DIR/conductor/context-trash.tar.gz" -C "$CONDUCTOR_HOME" .context-trash/ 2>/dev/null || true
fi

# dbtools
if [ -d "$CONDUCTOR_HOME/dbtools" ]; then
  cp -R "$CONDUCTOR_HOME/dbtools" "$BACKUP_DIR/conductor/" 2>/dev/null || true
fi

echo "  Conductor database done."

# ============================================================
# SHELL & ENVIRONMENT
# ============================================================
step "Backing up shell and environment config"

copy_if_exists "$HOME/.zshrc" "$BACKUP_DIR/shell-env/zshrc"
copy_if_exists "$HOME/.profile" "$BACKUP_DIR/shell-env/profile"
copy_if_exists "$HOME/.gitconfig" "$BACKUP_DIR/shell-env/gitconfig"

# SSH keys
copy_if_exists "$HOME/.ssh/id_ed25519" "$BACKUP_DIR/shell-env/ssh/"
copy_if_exists "$HOME/.ssh/id_ed25519.pub" "$BACKUP_DIR/shell-env/ssh/"
copy_if_exists "$HOME/.ssh/known_hosts" "$BACKUP_DIR/shell-env/ssh/"

# GitHub CLI
copy_if_exists "$HOME/.config/gh/config.yml" "$BACKUP_DIR/shell-env/gh/"
copy_if_exists "$HOME/.config/gh/hosts.yml" "$BACKUP_DIR/shell-env/gh/"

# Inshellisense
copy_if_exists "$HOME/.inshellisense/key-bindings.zsh" "$BACKUP_DIR/shell-env/inshellisense/"

# GitHub Copilot
if [ -d "$HOME/.config/github-copilot" ]; then
  tar -czf "$BACKUP_DIR/shell-env/github-copilot.tar.gz" -C "$HOME/.config" github-copilot/ 2>/dev/null || true
fi

echo "  Shell config done."

# ============================================================
# VOLTA
# ============================================================
step "Backing up Volta package manifest"

if command -v volta &>/dev/null; then
  volta list all --format=plain 2>/dev/null > "$BACKUP_DIR/volta/volta-list-all.txt" || true
fi

cat > "$BACKUP_DIR/volta/global-packages.json" << 'VOLTAJSON'
{
  "node_default": "24.12.0",
  "npm_default": "11.7.0",
  "global_packages": [
    "@microsoft/inshellisense",
    "@openai/codex",
    "@remotion/cli",
    "agent-browser",
    "firebase-tools",
    "forest-cli",
    "localutils-mcp-server",
    "playwright",
    "pnpm",
    "remotion"
  ]
}
VOLTAJSON

echo "  Volta manifest done."

# ============================================================
# MANIFEST
# ============================================================
step "Generating manifest"

backup_size=$(du -sh "$BACKUP_DIR" | cut -f1)
file_count=$(find "$BACKUP_DIR" -type f | wc -l | tr -d ' ')

cat > "$BACKUP_DIR/manifest.json" << MANIFEST
{
  "backup_date": "$BACKUP_DATE",
  "backup_time": "$(date +%H:%M:%S)",
  "hostname": "$(hostname)",
  "macos_version": "$(sw_vers -productVersion 2>/dev/null || echo 'unknown')",
  "user": "$(whoami)",
  "total_size": "$backup_size",
  "file_count": $file_count,
  "warnings": $WARN_COUNT,
  "sections": {
    "claude_code": "$(du -sh "$BACKUP_DIR/claude-code" 2>/dev/null | cut -f1)",
    "claude_project_configs": "$(du -sh "$BACKUP_DIR/claude-code-project-configs" 2>/dev/null | cut -f1)",
    "codex_cli": "$(du -sh "$BACKUP_DIR/codex-cli" 2>/dev/null | cut -f1)",
    "shared_agents": "$(du -sh "$BACKUP_DIR/shared-agents" 2>/dev/null | cut -f1)",
    "conductor": "$(du -sh "$BACKUP_DIR/conductor" 2>/dev/null | cut -f1)",
    "shell_env": "$(du -sh "$BACKUP_DIR/shell-env" 2>/dev/null | cut -f1)",
    "volta": "$(du -sh "$BACKUP_DIR/volta" 2>/dev/null | cut -f1)"
  }
}
MANIFEST

# ============================================================
# CLAUDE.MD FOR THE BACKUP FOLDER
# ============================================================
step "Generating CLAUDE.md"

cat > "$BACKUP_DIR/CLAUDE.md" << 'CLAUDEMD'
# Workspace Backup

Machine: arjunkannan's MacBook, macOS
User: arjunkannan (GitHub: arjshiv)

## What This Backup Contains

Complete backup of AI coding assistant configs, history, and dev environment.

### Claude Code (`~/.claude/`)
- **CLAUDE.md**: Global instructions for Claude Code behavior
- **settings.json**: MCP servers (context7, pg-aiguide, localutils), plugins (canvas, swift-lsp), model pref (claude-opus-4-6), sandbox rules, agent teams mode (tmux)
- **config.json**: API key approval state
- **history.jsonl**: Conversation history
- **plans/**: Implementation plan markdown files
- **plugins/**: Installed plugins
- **skills/**: agent-browser, remotion-best-practices
- **projects/**: Project workspace state and memory
- **file-history/**: File modification tracking
- **todos/**: Agent todo files
- **tasks/**: Task lists

### Project-Specific Claude Configs
Local `.claude/` directories from GitHub and Downloads projects. See `project-paths.json` for the mapping of encoded names to original paths.

### Codex CLI (`~/.codex/`)
- **config.json / config.toml**: Provider settings, MCP servers, trusted projects
- **instructions.md**: ResiDesk AI agent guidelines
- **auth.json**: [SENSITIVE] OAuth tokens
- **rules/default.rules**: Coding rules
- **sessions/**: Session rollout data
- **skills/**: System skills + remotion-best-practices

### Shared Agents (`~/.agents/`)
- remotion-best-practices skill (symlinked from both Claude and Codex)

### Conductor
**Worktrees** (metadata + patches, NOT full clones):
- Server_Web_Outlook: 7 worktrees from BrgnTech/Server_Web_Outlook
- dash: 2 worktrees from agno-agi/dash

Each worktree has: branch/commit JSON, uncommitted changes .patch, untracked files .tar.gz, .env files

**Database**: conductor.db (SQLite backup of the main Conductor DB)
**Archived contexts**: Planning notes and todos from completed tasks

### Shell & Environment
- .zshrc (Oh-My-Zsh), .profile, .gitconfig (arjshiv)
- SSH keys (ed25519), GitHub CLI config, Copilot config

### Volta Global Packages
Node v24.12.0 + global CLIs: codex, agent-browser, firebase, remotion, etc.

## SENSITIVE FILES
- `codex-cli/auth.json` — OAuth JWT + refresh tokens
- `shell-env/ssh/id_ed25519` — SSH private key
- `shell-env/gh/hosts.yml` — GitHub CLI auth
- `conductor/workspaces/**/*.env` — Application secrets

**Encrypt this folder before uploading to cloud storage.**

## How to Restore
```bash
bash restore.sh /path/to/this/backup/folder
```
Prerequisites: Fresh Mac with Homebrew installed. See `restore.sh` for full details.
CLAUDEMD

# ============================================================
# COPY SCRIPTS INTO BACKUP
# ============================================================
step "Copying scripts into backup"

cp "$SCRIPT_DIR/backup.sh" "$BACKUP_DIR/"
cp "$SCRIPT_DIR/restore.sh" "$BACKUP_DIR/" 2>/dev/null || warn "restore.sh not found next to backup.sh"

# ============================================================
# PERMISSIONS
# ============================================================
step "Setting permissions on sensitive files"

chmod 600 "$BACKUP_DIR/codex-cli/auth.json" 2>/dev/null || true
chmod 600 "$BACKUP_DIR/shell-env/ssh/id_ed25519" 2>/dev/null || true
chmod 600 "$BACKUP_DIR/shell-env/gh/hosts.yml" 2>/dev/null || true
find "$BACKUP_DIR/conductor/workspaces" -name "*.env" -exec chmod 600 {} \; 2>/dev/null || true

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "========================================"
echo "  BACKUP COMPLETE"
echo "========================================"
echo ""
echo "  Location: $BACKUP_DIR"
echo "  Size:     $(du -sh "$BACKUP_DIR" | cut -f1)"
echo "  Files:    $(find "$BACKUP_DIR" -type f | wc -l | tr -d ' ')"
echo "  Warnings: $WARN_COUNT"
echo ""
if [ "$WARN_COUNT" -gt 0 ]; then
  echo "  See $BACKUP_DIR/backup.log for details."
  echo ""
fi
echo "  WARNING: This backup contains SENSITIVE data:"
echo "    - SSH private key (shell-env/ssh/id_ed25519)"
echo "    - Codex OAuth tokens (codex-cli/auth.json)"
echo "    - .env files with API keys (conductor/workspaces/**/*.env)"
echo "    - GitHub CLI auth (shell-env/gh/hosts.yml)"
echo ""
echo "  ENCRYPT BEFORE UPLOADING TO GOOGLE DRIVE."
echo "  Example: zip -er workspace-backup.zip $BACKUP_DIR"
echo ""
echo "Backup finished at $(date)" >> "$LOG_FILE"
