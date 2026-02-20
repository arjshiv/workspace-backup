#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="${1:?Usage: bash restore.sh /path/to/workspace-backup-YYYY-MM-DD}"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

echo "========================================"
echo "  WORKSPACE RESTORE"
echo "========================================"
echo ""
echo "  Source: $BACKUP_DIR"
echo ""

# --- Validate backup structure ---
for required in CLAUDE.md manifest.json claude-code codex-cli conductor shell-env volta; do
  if [ ! -e "$BACKUP_DIR/$required" ]; then
    echo "ERROR: Missing $BACKUP_DIR/$required — is this a valid backup?"
    exit 1
  fi
done

echo "Backup validated. Starting restore..."
WARN_COUNT=0

warn() {
  echo "  WARN: $1"
  WARN_COUNT=$((WARN_COUNT + 1))
}

step() {
  echo ""
  echo "==> $1"
}

# ============================================================
# STEP 1: PREREQUISITES
# ============================================================
step "Checking and installing prerequisites"

# Homebrew
if ! command -v brew &>/dev/null; then
  echo "  Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
fi

# Essential brew packages
for pkg in git gh sqlite3 jq; do
  if ! command -v "$pkg" &>/dev/null; then
    echo "  Installing $pkg..."
    brew install "$pkg" 2>/dev/null || warn "Failed to install $pkg"
  fi
done

# Volta
if ! command -v volta &>/dev/null; then
  echo "  Installing Volta..."
  curl https://get.volta.sh | bash -s -- --skip-setup
  export VOLTA_HOME="$HOME/.volta"
  export PATH="$VOLTA_HOME/bin:$PATH"
fi

# Oh-My-Zsh
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  echo "  Installing Oh-My-Zsh..."
  RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended 2>/dev/null || warn "Oh-My-Zsh install failed"
fi

# Zsh plugins
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
  git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions" 2>/dev/null || warn "Failed to clone zsh-autosuggestions"
fi
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
  git clone https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" 2>/dev/null || warn "Failed to clone zsh-syntax-highlighting"
fi

# pyenv
if ! command -v pyenv &>/dev/null; then
  echo "  Installing pyenv..."
  brew install pyenv 2>/dev/null || warn "Failed to install pyenv"
fi

# Rust / Cargo
if ! command -v cargo &>/dev/null; then
  echo "  Installing Rust toolchain..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>/dev/null || warn "Failed to install Rust"
  [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
fi

echo "  Prerequisites done."

# ============================================================
# STEP 2: SHELL & ENVIRONMENT
# ============================================================
step "Restoring shell and environment config"

cp "$BACKUP_DIR/shell-env/zshrc" "$HOME/.zshrc" 2>/dev/null || warn "Failed to restore .zshrc"
cp "$BACKUP_DIR/shell-env/profile" "$HOME/.profile" 2>/dev/null || warn "Failed to restore .profile"
cp "$BACKUP_DIR/shell-env/gitconfig" "$HOME/.gitconfig" 2>/dev/null || warn "Failed to restore .gitconfig"

# SSH keys
mkdir -p "$HOME/.ssh"
cp "$BACKUP_DIR/shell-env/ssh/id_ed25519" "$HOME/.ssh/" 2>/dev/null || warn "Failed to restore SSH private key"
cp "$BACKUP_DIR/shell-env/ssh/id_ed25519.pub" "$HOME/.ssh/" 2>/dev/null || true
cp "$BACKUP_DIR/shell-env/ssh/known_hosts" "$HOME/.ssh/" 2>/dev/null || true
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/id_ed25519" 2>/dev/null || true

# GitHub CLI
mkdir -p "$HOME/.config/gh"
cp "$BACKUP_DIR/shell-env/gh/config.yml" "$HOME/.config/gh/" 2>/dev/null || true
cp "$BACKUP_DIR/shell-env/gh/hosts.yml" "$HOME/.config/gh/" 2>/dev/null || true

# Inshellisense
mkdir -p "$HOME/.inshellisense"
cp "$BACKUP_DIR/shell-env/inshellisense/key-bindings.zsh" "$HOME/.inshellisense/" 2>/dev/null || true

# GitHub Copilot
if [ -f "$BACKUP_DIR/shell-env/github-copilot.tar.gz" ]; then
  mkdir -p "$HOME/.config"
  tar -xzf "$BACKUP_DIR/shell-env/github-copilot.tar.gz" -C "$HOME/.config/" 2>/dev/null || true
fi

echo "  Shell config restored."

# ============================================================
# STEP 3: VOLTA PACKAGES
# ============================================================
step "Restoring Volta packages"

export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"

if command -v volta &>/dev/null && [ -f "$BACKUP_DIR/volta/global-packages.json" ]; then
  node_ver=$(jq -r '.node_default' "$BACKUP_DIR/volta/global-packages.json")
  npm_ver=$(jq -r '.npm_default' "$BACKUP_DIR/volta/global-packages.json")

  echo "  Installing node@$node_ver..."
  volta install "node@$node_ver" 2>/dev/null || warn "Failed to install node"
  echo "  Installing npm@$npm_ver..."
  volta install "npm@$npm_ver" 2>/dev/null || warn "Failed to install npm"

  # Global packages
  for pkg in $(jq -r '.global_packages[]' "$BACKUP_DIR/volta/global-packages.json"); do
    echo "  Installing $pkg..."
    volta install "$pkg" 2>/dev/null || npm install -g "$pkg" 2>/dev/null || warn "Failed to install $pkg"
  done
else
  warn "Volta or global-packages.json not available"
fi

echo "  Volta packages restored."

# ============================================================
# STEP 4: CLAUDE CODE
# ============================================================
step "Restoring Claude Code"

mkdir -p "$HOME/.claude"

# Direct files
for f in CLAUDE.md settings.json config.json history.jsonl stats-cache.json; do
  [ -f "$BACKUP_DIR/claude-code/$f" ] && cp "$BACKUP_DIR/claude-code/$f" "$HOME/.claude/"
done

# Compressed archives
for archive in plans plugins projects file-history todos tasks paste-cache; do
  if [ -f "$BACKUP_DIR/claude-code/${archive}.tar.gz" ]; then
    echo "  Extracting $archive..."
    tar -xzf "$BACKUP_DIR/claude-code/${archive}.tar.gz" -C "$HOME/.claude/" 2>/dev/null || warn "Failed to extract $archive"
  fi
done

# Shared agents (restore first — skills symlink to these)
mkdir -p "$HOME/.agents"
if [ -d "$BACKUP_DIR/shared-agents" ] && [ "$(ls -A "$BACKUP_DIR/shared-agents" 2>/dev/null)" ]; then
  cp -R "$BACKUP_DIR/shared-agents/"* "$HOME/.agents/" 2>/dev/null || true
fi

# Skills
mkdir -p "$HOME/.claude/skills"
if [ -d "$BACKUP_DIR/claude-code/skills/agent-browser" ]; then
  cp -R "$BACKUP_DIR/claude-code/skills/agent-browser" "$HOME/.claude/skills/"
fi
# Recreate symlink for remotion skill
if [ -d "$HOME/.agents/skills/remotion-best-practices" ]; then
  ln -sf "$HOME/.agents/skills/remotion-best-practices" "$HOME/.claude/skills/remotion-best-practices"
else
  # Fallback: copy the resolved files
  [ -d "$BACKUP_DIR/claude-code/skills/remotion-best-practices" ] && \
    cp -R "$BACKUP_DIR/claude-code/skills/remotion-best-practices" "$HOME/.claude/skills/"
fi

# Create expected empty dirs
mkdir -p "$HOME/.claude/"{debug,shell-snapshots,session-env,teams,telemetry,cache,chrome,ide,statsig}

echo "  Claude Code restored."

# ============================================================
# STEP 5: PROJECT-SPECIFIC CLAUDE CONFIGS
# ============================================================
step "Restoring project-specific Claude configs"

if [ -f "$BACKUP_DIR/claude-code-project-configs/project-paths.json" ]; then
  jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$BACKUP_DIR/claude-code-project-configs/project-paths.json" | \
  while IFS=$'\t' read -r encoded_name original_path; do
    expanded_path="${original_path/#\~/$HOME}"
    parent_dir="$(dirname "$expanded_path")"
    if [ -d "$parent_dir" ]; then
      mkdir -p "$expanded_path"
      cp -R "$BACKUP_DIR/claude-code-project-configs/$encoded_name/"* "$expanded_path/" 2>/dev/null || true
      echo "  Restored: $original_path"
    else
      echo "  SKIP (parent missing): $original_path"
    fi
  done
else
  warn "No project-paths.json found"
fi

# ============================================================
# STEP 6: CODEX CLI
# ============================================================
step "Restoring Codex CLI"

mkdir -p "$HOME/.codex"/{rules,skills,sqlite,log,tmp,shell_snapshots}

# Direct files
for f in config.json config.toml instructions.md auth.json history.json history.jsonl \
         .codex-global-state.json version.json update-check.json; do
  [ -f "$BACKUP_DIR/codex-cli/$f" ] && cp "$BACKUP_DIR/codex-cli/$f" "$HOME/.codex/"
done

# Rules
[ -f "$BACKUP_DIR/codex-cli/rules/default.rules" ] && cp "$BACKUP_DIR/codex-cli/rules/default.rules" "$HOME/.codex/rules/"

# Skills
if [ -d "$BACKUP_DIR/codex-cli/skills/.system" ]; then
  cp -R "$BACKUP_DIR/codex-cli/skills/.system" "$HOME/.codex/skills/"
fi
# Recreate symlink
if [ -d "$HOME/.agents/skills/remotion-best-practices" ]; then
  ln -sf "$HOME/.agents/skills/remotion-best-practices" "$HOME/.codex/skills/remotion-best-practices"
else
  [ -d "$BACKUP_DIR/codex-cli/skills/remotion-best-practices" ] && \
    cp -R "$BACKUP_DIR/codex-cli/skills/remotion-best-practices" "$HOME/.codex/skills/"
fi

# SQLite
[ -f "$BACKUP_DIR/codex-cli/sqlite/codex-dev.db" ] && cp "$BACKUP_DIR/codex-cli/sqlite/codex-dev.db" "$HOME/.codex/sqlite/"

# Compressed archives
for archive in sessions vendor_imports; do
  if [ -f "$BACKUP_DIR/codex-cli/${archive}.tar.gz" ]; then
    echo "  Extracting $archive..."
    tar -xzf "$BACKUP_DIR/codex-cli/${archive}.tar.gz" -C "$HOME/.codex/" 2>/dev/null || warn "Failed to extract codex $archive"
  fi
done

chmod 600 "$HOME/.codex/auth.json" 2>/dev/null || true

echo "  Codex CLI restored."

# ============================================================
# STEP 7: CONDUCTOR — REPOS & WORKTREES
# ============================================================
step "Restoring Conductor workspaces"

mkdir -p "$HOME/conductor"/{workspaces,archived-contexts,dbtools,.context-trash}

restore_worktrees() {
  local project_name="$1"
  local backup_ws_dir="$BACKUP_DIR/conductor/workspaces/$project_name"
  local info_file="$backup_ws_dir/_main-repo-info.json"

  [ -f "$info_file" ] || { warn "No main repo info for $project_name"; return; }

  local remote_origin main_repo_path worktree_parent heroku_remote
  remote_origin=$(jq -r '.remote_origin' "$info_file")
  main_repo_path=$(jq -r '.main_repo_path' "$info_file")
  worktree_parent=$(jq -r '.worktree_parent' "$info_file")
  heroku_remote=$(jq -r '.remote_heroku // empty' "$info_file")

  # Clone main repo if needed
  if [ ! -d "$main_repo_path/.git" ]; then
    echo "  Cloning $project_name from $remote_origin..."
    mkdir -p "$(dirname "$main_repo_path")"
    git clone "$remote_origin" "$main_repo_path" || { warn "Failed to clone $project_name"; return; }
    if [ -n "$heroku_remote" ]; then
      git -C "$main_repo_path" remote add heroku "$heroku_remote" 2>/dev/null || true
    fi
  fi

  # Fetch all remote branches
  echo "  Fetching all branches for $project_name..."
  git -C "$main_repo_path" fetch --all 2>/dev/null || warn "Failed to fetch for $project_name"

  # Create worktree parent dir
  mkdir -p "$worktree_parent"

  # Process each workspace manifest
  for manifest in "$backup_ws_dir"/*.json; do
    local basename_f
    basename_f=$(basename "$manifest")
    [[ "$basename_f" == _* ]] && continue  # Skip _main-repo-info.json, etc.

    local ws_name ws_branch ws_commit ws_dir
    ws_name=$(jq -r '.name' "$manifest")
    ws_branch=$(jq -r '.branch' "$manifest")
    ws_commit=$(jq -r '.commit' "$manifest")
    ws_dir="$worktree_parent/$ws_name"

    if [ -d "$ws_dir" ]; then
      echo "  $ws_name: already exists, skipping"
      continue
    fi

    echo "  Creating worktree: $ws_name -> $ws_branch"
    # Try multiple strategies to create the worktree
    if git -C "$main_repo_path" worktree add "$ws_dir" "$ws_branch" 2>/dev/null; then
      true
    elif git -C "$main_repo_path" worktree add "$ws_dir" -b "$ws_branch" "origin/$ws_branch" 2>/dev/null; then
      true
    elif git -C "$main_repo_path" worktree add --detach "$ws_dir" "$ws_commit" 2>/dev/null; then
      warn "$ws_name: created at detached HEAD $ws_commit (branch $ws_branch not found on remote)"
    else
      warn "Could not create worktree for $ws_name"
      continue
    fi

    # Apply uncommitted changes patch
    local patch_file="$backup_ws_dir/${ws_name}.patch"
    if [ -f "$patch_file" ] && [ -s "$patch_file" ]; then
      echo "  $ws_name: applying uncommitted changes..."
      git -C "$ws_dir" apply --allow-empty "$patch_file" 2>/dev/null || \
        { warn "$ws_name: patch did not apply cleanly — saved as ${ws_name}.patch.failed"; cp "$patch_file" "$ws_dir/${ws_name}.patch.failed"; }
    fi

    # Restore untracked files
    local untracked_archive="$backup_ws_dir/${ws_name}-untracked.tar.gz"
    if [ -f "$untracked_archive" ]; then
      echo "  $ws_name: restoring untracked files..."
      tar -xzf "$untracked_archive" -C "$ws_dir/" 2>/dev/null || warn "$ws_name: failed to extract untracked files"
    fi

    # Restore .env
    local env_file="$backup_ws_dir/${ws_name}.env"
    if [ -f "$env_file" ]; then
      cp "$env_file" "$ws_dir/.env"
      chmod 600 "$ws_dir/.env"
      echo "  $ws_name: .env restored"
    fi

    # Restore .context dir
    local context_archive="$backup_ws_dir/${ws_name}-context.tar.gz"
    if [ -f "$context_archive" ]; then
      tar -xzf "$context_archive" -C "$ws_dir/" 2>/dev/null || true
    fi
  done

  # Stash info
  local stash_list="$backup_ws_dir/_stash-list.txt"
  if [ -f "$stash_list" ] && [ -s "$stash_list" ]; then
    local stash_count
    stash_count=$(wc -l < "$stash_list" | tr -d ' ')
    echo "  NOTE: $stash_count stashes were backed up as patch files in the backup."
    echo "  To apply: git stash apply < _stash-N.patch"
  fi
}

# Restore each project's worktrees
restore_worktrees "Server_Web_Outlook"
restore_worktrees "dash"

echo "  Conductor workspaces restored."

# ============================================================
# STEP 8: CONDUCTOR — DATABASE & APP DATA
# ============================================================
step "Restoring Conductor database and app data"

CONDUCTOR_APP_SUPPORT="$HOME/Library/Application Support/com.conductor.app"
mkdir -p "$CONDUCTOR_APP_SUPPORT"

if [ -f "$BACKUP_DIR/conductor/conductor.db" ]; then
  cp "$BACKUP_DIR/conductor/conductor.db" "$CONDUCTOR_APP_SUPPORT/"
  echo "  conductor.db restored"
fi

[ -f "$BACKUP_DIR/conductor/conductor.db-wal" ] && \
  cp "$BACKUP_DIR/conductor/conductor.db-wal" "$CONDUCTOR_APP_SUPPORT/" 2>/dev/null || true

# Plist
if [ -f "$BACKUP_DIR/conductor/conductor-plist.xml" ]; then
  cp "$BACKUP_DIR/conductor/conductor-plist.xml" "$HOME/Library/Preferences/com.conductor.app.plist"
  plutil -convert binary1 "$HOME/Library/Preferences/com.conductor.app.plist" 2>/dev/null || true
fi

# Archived contexts
if [ -f "$BACKUP_DIR/conductor/archived-contexts.tar.gz" ]; then
  tar -xzf "$BACKUP_DIR/conductor/archived-contexts.tar.gz" -C "$HOME/conductor/" 2>/dev/null || warn "Failed to extract archived contexts"
fi

# Context trash
if [ -f "$BACKUP_DIR/conductor/context-trash.tar.gz" ]; then
  tar -xzf "$BACKUP_DIR/conductor/context-trash.tar.gz" -C "$HOME/conductor/" 2>/dev/null || true
fi

# dbtools
if [ -d "$BACKUP_DIR/conductor/dbtools" ]; then
  cp -R "$BACKUP_DIR/conductor/dbtools" "$HOME/conductor/" 2>/dev/null || true
fi

echo "  Conductor database restored."

# ============================================================
# DONE
# ============================================================
echo ""
echo "========================================"
echo "  RESTORE COMPLETE"
echo "========================================"
echo ""
echo "  Warnings: $WARN_COUNT"
echo ""
echo "  MANUAL STEPS REMAINING:"
echo ""
echo "  1. Authenticate GitHub CLI:"
echo "     gh auth login"
echo ""
echo "  2. Verify SSH key works:"
echo "     ssh -T git@github.com"
echo ""
echo "  3. Install Claude Code (if not already installed):"
echo "     npm install -g @anthropic-ai/claude-code"
echo "     # Then run 'claude' and authenticate"
echo ""
echo "  4. Install Conductor app from official source"
echo ""
echo "  5. Run 'npm install' in any workspace that needs node_modules:"
for ws_dir in "$HOME/conductor/workspaces"/*/*/; do
  [ -d "$ws_dir" ] && echo "     cd $ws_dir && npm install"
done
echo ""
echo "  6. Codex auth token may have expired. Re-authenticate if needed:"
echo "     codex auth"
echo ""
echo "  7. Source your shell config:"
echo "     source ~/.zshrc"
echo ""
