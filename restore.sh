#!/usr/bin/env bash
set -euo pipefail

SECONDS=0

# --- Color constants ---
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN='' YELLOW='' RED='' BOLD='' NC=''
fi

# --- Argument parsing ---
SKIP_CONFIRM=false
DRY_RUN=false
BACKUP_DIR=""

usage() {
  echo "Usage: bash restore.sh [OPTIONS] /path/to/workspace-backup-YYYY-MM-DD"
  echo ""
  echo "Restore a full AI dev environment from a workspace backup."
  echo ""
  echo "Options:"
  echo "  -y, --yes       Skip confirmation prompt"
  echo "  --dry-run       Show what would be restored without writing"
  echo "  -h, --help      Show this help message"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    -y|--yes) SKIP_CONFIRM=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -*) echo "Unknown option: $1"; echo "Run with --help for usage."; exit 1 ;;
    *) BACKUP_DIR="$1"; shift ;;
  esac
done

if [ -z "$BACKUP_DIR" ]; then
  echo "ERROR: No backup directory specified."
  echo "Run with --help for usage."
  exit 1
fi

BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  WORKSPACE RESTORE${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo "  Source: $BACKUP_DIR"
if $DRY_RUN; then
  echo -e "  Mode:   ${YELLOW}DRY RUN (no files will be written)${NC}"
fi
echo ""

# --- Validate backup structure ---
for required in RESTORE-GUIDE.md manifest.json claude-code codex-cli conductor shell-env volta; do
  if [ ! -e "$BACKUP_DIR/$required" ]; then
    echo -e "${RED}ERROR: Missing $BACKUP_DIR/$required — is this a valid backup?${NC}"
    exit 1
  fi
done

echo "Backup validated."

# --- Confirmation prompt ---
if ! $SKIP_CONFIRM && ! $DRY_RUN; then
  echo ""
  echo -e "${YELLOW}This will overwrite existing configs in $HOME. Continue? [y/N]${NC}"
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "Starting restore..."
WARN_COUNT=0

warn() {
  echo -e "  ${YELLOW}WARN:${NC} $1"
  WARN_COUNT=$((WARN_COUNT + 1))
}

CURRENT_STEP=0
TOTAL_STEPS=9

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  echo ""
  echo -e "${GREEN}==> [${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${BOLD}$1${NC}"
}

# --- Dry-run helpers ---
# Wrap file operations so --dry-run shows intent without writing
safe_cp() {
  if $DRY_RUN; then
    echo "  [dry-run] cp $*"
  else
    cp "$@"
  fi
}

safe_mkdir() {
  if $DRY_RUN; then
    echo "  [dry-run] mkdir -p $*"
  else
    mkdir -p "$@"
  fi
}

safe_ln() {
  if $DRY_RUN; then
    echo "  [dry-run] ln -sf $*"
  else
    ln -sf "$@"
  fi
}

safe_tar() {
  if $DRY_RUN; then
    echo "  [dry-run] tar -xzf $1 -C ${3:-...}"
  else
    tar "$@"
  fi
}

safe_chmod() {
  if $DRY_RUN; then
    echo "  [dry-run] chmod $*"
  else
    chmod "$@"
  fi
}

# --- Pre-restore backup helper ---
# Before overwriting an existing file, back it up to $target.pre-restore
pre_restore_backup() {
  local target="$1"
  if [ -e "$target" ] && ! $DRY_RUN; then
    cp "$target" "${target}.pre-restore"
    echo "  Backed up existing $target -> ${target}.pre-restore"
  fi
}

# ============================================================
# STEP 1: PREREQUISITES
# ============================================================
step "Checking and installing prerequisites"

if $DRY_RUN; then
  echo "  [dry-run] Skipping prerequisite installs"
else
  # Homebrew
  if ! command -v brew &>/dev/null; then
    echo "  Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
  fi

  # Minimal essentials first (needed by restore script itself)
  for pkg in git jq; do
    if ! command -v "$pkg" &>/dev/null; then
      echo "  Installing $pkg..."
      brew install "$pkg" 2>/dev/null || warn "Failed to install $pkg"
    fi
  done

  # Full Homebrew restore from Brewfile
  if [ -f "$BACKUP_DIR/homebrew/Brewfile" ]; then
    echo "  Restoring all Homebrew packages from Brewfile..."
    echo "  (This may take a while — installing formulae, casks, and taps)"
    brew bundle install --file="$BACKUP_DIR/homebrew/Brewfile" --no-lock 2>/dev/null || warn "Some Brewfile packages failed to install"
    echo "  Homebrew packages restored."
  else
    warn "No Brewfile found — installing minimal packages only"
    for pkg in gh sqlite3 ast-grep fd; do
      command -v "$pkg" &>/dev/null || brew install "$pkg" 2>/dev/null || true
    done
  fi

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

  # Rust / Cargo
  if ! command -v cargo &>/dev/null; then
    echo "  Installing Rust toolchain..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>/dev/null || warn "Failed to install Rust"
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
  fi
fi

echo "  Prerequisites done."

# ============================================================
# STEP 2: SHELL & ENVIRONMENT
# ============================================================
step "Restoring shell and environment config"

pre_restore_backup "$HOME/.zshrc"
safe_cp "$BACKUP_DIR/shell-env/zshrc" "$HOME/.zshrc" 2>/dev/null || warn "Failed to restore .zshrc"
pre_restore_backup "$HOME/.profile"
safe_cp "$BACKUP_DIR/shell-env/profile" "$HOME/.profile" 2>/dev/null || warn "Failed to restore .profile"
pre_restore_backup "$HOME/.gitconfig"
safe_cp "$BACKUP_DIR/shell-env/gitconfig" "$HOME/.gitconfig" 2>/dev/null || warn "Failed to restore .gitconfig"

# SSH keys
safe_mkdir "$HOME/.ssh"
for ssh_file in id_ed25519 id_ed25519.pub known_hosts; do
  if [ -f "$BACKUP_DIR/shell-env/ssh/$ssh_file" ]; then
    pre_restore_backup "$HOME/.ssh/$ssh_file"
  fi
done
safe_cp "$BACKUP_DIR/shell-env/ssh/id_ed25519" "$HOME/.ssh/" 2>/dev/null || warn "Failed to restore SSH private key"
safe_cp "$BACKUP_DIR/shell-env/ssh/id_ed25519.pub" "$HOME/.ssh/" 2>/dev/null || true
safe_cp "$BACKUP_DIR/shell-env/ssh/known_hosts" "$HOME/.ssh/" 2>/dev/null || true
safe_chmod 700 "$HOME/.ssh"
safe_chmod 600 "$HOME/.ssh/id_ed25519" 2>/dev/null || true

# GitHub CLI
safe_mkdir "$HOME/.config/gh"
for gh_file in config.yml hosts.yml; do
  if [ -f "$BACKUP_DIR/shell-env/gh/$gh_file" ]; then
    pre_restore_backup "$HOME/.config/gh/$gh_file"
  fi
done
safe_cp "$BACKUP_DIR/shell-env/gh/config.yml" "$HOME/.config/gh/" 2>/dev/null || true
safe_cp "$BACKUP_DIR/shell-env/gh/hosts.yml" "$HOME/.config/gh/" 2>/dev/null || true
safe_chmod 600 "$HOME/.config/gh/hosts.yml" 2>/dev/null || true

# Inshellisense
safe_mkdir "$HOME/.inshellisense"
safe_cp "$BACKUP_DIR/shell-env/inshellisense/key-bindings.zsh" "$HOME/.inshellisense/" 2>/dev/null || true

# GitHub Copilot
if [ -f "$BACKUP_DIR/shell-env/github-copilot.tar.gz" ]; then
  safe_mkdir "$HOME/.config"
  safe_tar -xzf "$BACKUP_DIR/shell-env/github-copilot.tar.gz" -C "$HOME/.config/" 2>/dev/null || true
fi

echo "  Shell config restored."

# ============================================================
# STEP 3: VOLTA PACKAGES
# ============================================================
step "Restoring Volta packages"

export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"

if $DRY_RUN; then
  echo "  [dry-run] Skipping Volta package installs"
elif command -v volta &>/dev/null && [ -f "$BACKUP_DIR/volta/global-packages.json" ]; then
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

safe_mkdir "$HOME/.claude"

# Direct files
for f in CLAUDE.md settings.json config.json history.jsonl stats-cache.json; do
  [ -f "$BACKUP_DIR/claude-code/$f" ] && safe_cp "$BACKUP_DIR/claude-code/$f" "$HOME/.claude/"
done

# Compressed archives
for archive in plans plugins projects file-history todos tasks paste-cache; do
  if [ -f "$BACKUP_DIR/claude-code/${archive}.tar.gz" ]; then
    echo "  Extracting $archive..."
    safe_tar -xzf "$BACKUP_DIR/claude-code/${archive}.tar.gz" -C "$HOME/.claude/" 2>/dev/null || warn "Failed to extract $archive"
  fi
done

# Shared agents (restore first — skills symlink to these)
safe_mkdir "$HOME/.agents"
if [ -d "$BACKUP_DIR/shared-agents" ] && [ "$(ls -A "$BACKUP_DIR/shared-agents" 2>/dev/null)" ]; then
  safe_cp -R "$BACKUP_DIR/shared-agents/"* "$HOME/.agents/" 2>/dev/null || true
fi

# Skills
safe_mkdir "$HOME/.claude/skills"
if [ -d "$BACKUP_DIR/claude-code/skills/agent-browser" ]; then
  safe_cp -R "$BACKUP_DIR/claude-code/skills/agent-browser" "$HOME/.claude/skills/"
fi
# Recreate symlink for remotion skill
if [ -d "$HOME/.agents/skills/remotion-best-practices" ]; then
  safe_ln "$HOME/.agents/skills/remotion-best-practices" "$HOME/.claude/skills/remotion-best-practices"
else
  # Fallback: copy the resolved files
  [ -d "$BACKUP_DIR/claude-code/skills/remotion-best-practices" ] && \
    safe_cp -R "$BACKUP_DIR/claude-code/skills/remotion-best-practices" "$HOME/.claude/skills/"
fi

# Create expected empty dirs
safe_mkdir "$HOME/.claude/debug" "$HOME/.claude/shell-snapshots" "$HOME/.claude/session-env" \
  "$HOME/.claude/teams" "$HOME/.claude/telemetry" "$HOME/.claude/cache" \
  "$HOME/.claude/chrome" "$HOME/.claude/ide" "$HOME/.claude/statsig"

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
      safe_mkdir "$expanded_path"
      safe_cp -R "$BACKUP_DIR/claude-code-project-configs/$encoded_name/"* "$expanded_path/" 2>/dev/null || true
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

safe_mkdir "$HOME/.codex/rules" "$HOME/.codex/skills" "$HOME/.codex/sqlite" \
  "$HOME/.codex/log" "$HOME/.codex/tmp" "$HOME/.codex/shell_snapshots"

# Direct files
for f in config.json config.toml instructions.md auth.json history.json history.jsonl \
         .codex-global-state.json version.json update-check.json; do
  [ -f "$BACKUP_DIR/codex-cli/$f" ] && safe_cp "$BACKUP_DIR/codex-cli/$f" "$HOME/.codex/"
done

# Rules
[ -f "$BACKUP_DIR/codex-cli/rules/default.rules" ] && safe_cp "$BACKUP_DIR/codex-cli/rules/default.rules" "$HOME/.codex/rules/"

# Skills
if [ -d "$BACKUP_DIR/codex-cli/skills/.system" ]; then
  safe_cp -R "$BACKUP_DIR/codex-cli/skills/.system" "$HOME/.codex/skills/"
fi
# Recreate symlink
if [ -d "$HOME/.agents/skills/remotion-best-practices" ]; then
  safe_ln "$HOME/.agents/skills/remotion-best-practices" "$HOME/.codex/skills/remotion-best-practices"
else
  [ -d "$BACKUP_DIR/codex-cli/skills/remotion-best-practices" ] && \
    safe_cp -R "$BACKUP_DIR/codex-cli/skills/remotion-best-practices" "$HOME/.codex/skills/"
fi

# SQLite
[ -f "$BACKUP_DIR/codex-cli/sqlite/codex-dev.db" ] && safe_cp "$BACKUP_DIR/codex-cli/sqlite/codex-dev.db" "$HOME/.codex/sqlite/"

# Compressed archives
for archive in sessions vendor_imports; do
  if [ -f "$BACKUP_DIR/codex-cli/${archive}.tar.gz" ]; then
    echo "  Extracting $archive..."
    safe_tar -xzf "$BACKUP_DIR/codex-cli/${archive}.tar.gz" -C "$HOME/.codex/" 2>/dev/null || warn "Failed to extract codex $archive"
  fi
done

safe_chmod 600 "$HOME/.codex/auth.json" 2>/dev/null || true

echo "  Codex CLI restored."

# ============================================================
# STEP 7: CONDUCTOR — REPOS & WORKTREES
# ============================================================
step "Restoring Conductor workspaces"

safe_mkdir "$HOME/conductor/workspaces" "$HOME/conductor/archived-contexts" \
  "$HOME/conductor/dbtools" "$HOME/conductor/.context-trash"

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

  if $DRY_RUN; then
    echo "  [dry-run] Would clone $project_name from $remote_origin into $main_repo_path"
    echo "  [dry-run] Would create worktrees under $worktree_parent"
    return
  fi

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
    echo "  To apply: git apply _stash-N.patch"
  fi
}

# Auto-discover Conductor projects to restore
if [ -d "$BACKUP_DIR/conductor/workspaces" ]; then
  for project_dir in "$BACKUP_DIR/conductor/workspaces"/*/; do
    [ -d "$project_dir" ] || continue
    if [ -f "${project_dir}_main-repo-info.json" ]; then
      project_name="$(basename "$project_dir")"
      restore_worktrees "$project_name"
    fi
  done
else
  warn "No conductor/workspaces directory found in backup"
fi

echo "  Conductor workspaces restored."

# ============================================================
# STEP 8: CONDUCTOR — DATABASE & APP DATA
# ============================================================
step "Restoring Conductor database and app data"

CONDUCTOR_APP_SUPPORT="$HOME/Library/Application Support/com.conductor.app"
safe_mkdir "$CONDUCTOR_APP_SUPPORT"

if [ -f "$BACKUP_DIR/conductor/conductor.db" ]; then
  safe_cp "$BACKUP_DIR/conductor/conductor.db" "$CONDUCTOR_APP_SUPPORT/"
  echo "  conductor.db restored"
fi

[ -f "$BACKUP_DIR/conductor/conductor.db-wal" ] && \
  safe_cp "$BACKUP_DIR/conductor/conductor.db-wal" "$CONDUCTOR_APP_SUPPORT/" 2>/dev/null || true

# Plist
if [ -f "$BACKUP_DIR/conductor/conductor-plist.xml" ]; then
  safe_cp "$BACKUP_DIR/conductor/conductor-plist.xml" "$HOME/Library/Preferences/com.conductor.app.plist"
  if ! $DRY_RUN; then
    plutil -convert binary1 "$HOME/Library/Preferences/com.conductor.app.plist" 2>/dev/null || true
  fi
fi

# Archived contexts
if [ -f "$BACKUP_DIR/conductor/archived-contexts.tar.gz" ]; then
  safe_tar -xzf "$BACKUP_DIR/conductor/archived-contexts.tar.gz" -C "$HOME/conductor/" 2>/dev/null || warn "Failed to extract archived contexts"
fi

# Context trash
if [ -f "$BACKUP_DIR/conductor/context-trash.tar.gz" ]; then
  safe_tar -xzf "$BACKUP_DIR/conductor/context-trash.tar.gz" -C "$HOME/conductor/" 2>/dev/null || true
fi

# dbtools
if [ -d "$BACKUP_DIR/conductor/dbtools" ]; then
  safe_cp -R "$BACKUP_DIR/conductor/dbtools" "$HOME/conductor/" 2>/dev/null || true
fi

echo "  Conductor database restored."

# ============================================================
# STEP 9: MICROSOFT EDGE
# ============================================================
step "Restoring Microsoft Edge profiles"

EDGE_HOME="$HOME/Library/Application Support/Microsoft Edge"

if [ ! -d "$BACKUP_DIR/edge-browser" ]; then
  echo "  No edge-browser directory in backup — skipping."
else
  # Warn if Edge is running
  if pgrep -x "Microsoft Edge" >/dev/null 2>&1; then
    echo ""
    echo -e "  ${RED}WARNING: Microsoft Edge is currently running.${NC}"
    echo -e "  ${RED}Restoring while Edge is open can corrupt profile data.${NC}"
    echo ""
    if ! $SKIP_CONFIRM && ! $DRY_RUN; then
      echo -e "  ${YELLOW}Quit Edge and press Enter to continue, or type 'skip' to skip this step:${NC}"
      read -r edge_confirm
      if [[ "$edge_confirm" == "skip" ]]; then
        echo "  Skipping Edge restore."
        EDGE_SKIP=true
      fi
    fi
  fi

  if [ "${EDGE_SKIP:-}" != "true" ]; then
    safe_mkdir "$EDGE_HOME"

    # Restore Local State
    if [ -f "$BACKUP_DIR/edge-browser/Local State" ]; then
      pre_restore_backup "$EDGE_HOME/Local State"
      safe_cp "$BACKUP_DIR/edge-browser/Local State" "$EDGE_HOME/" 2>/dev/null || warn "Failed to restore Edge Local State"
    fi

    # Restore each profile
    if [ -f "$BACKUP_DIR/edge-browser/profiles.json" ] && ! $DRY_RUN; then
      profile_count=$(jq length "$BACKUP_DIR/edge-browser/profiles.json")
    else
      profile_count=0
    fi

    # Iterate over profile directories in the backup
    for encoded_dir in "$BACKUP_DIR/edge-browser"/*/; do
      [ -d "$encoded_dir" ] || continue
      encoded_name=$(basename "$encoded_dir")

      # Decode: "Profile_1" -> "Profile 1", "Default" stays "Default"
      profile_name="${encoded_name//_/ }"
      echo "  Restoring profile: $profile_name"

      safe_mkdir "$EDGE_HOME/$profile_name"

      # Restore individual files
      for f in Bookmarks Bookmarks.bak Preferences "Secure Preferences" "Top Sites" Favicons History "Web Data"; do
        if [ -f "$encoded_dir/$f" ]; then
          pre_restore_backup "$EDGE_HOME/$profile_name/$f"
          safe_cp "$encoded_dir/$f" "$EDGE_HOME/$profile_name/" 2>/dev/null || true
        fi
      done

      # Extract tar.gz archives
      for archive in Sessions Extensions Collections; do
        if [ -f "$encoded_dir/${archive}.tar.gz" ]; then
          echo "    Extracting $archive..."
          safe_tar -xzf "$encoded_dir/${archive}.tar.gz" -C "$EDGE_HOME/$profile_name/" 2>/dev/null || warn "Failed to extract $profile_name/$archive"
        fi
      done
    done

    echo "  Microsoft Edge profiles restored."
  fi
fi

# ============================================================
# DONE
# ============================================================
ELAPSED=$SECONDS
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${GREEN}  RESTORE COMPLETE${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo -e "  Warnings: ${WARN_COUNT}"
echo -e "  Elapsed:  ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
echo ""
echo -e "  ${BOLD}MANUAL STEPS REMAINING:${NC}"
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
echo "  5. Run 'npm install' in workspaces that need node_modules:"
# Find worktrees with package.json and suggest npm install
if [ -d "$HOME/conductor/workspaces" ]; then
  while IFS= read -r pkg_json; do
    ws_dir="$(dirname "$pkg_json")"
    echo "     cd $ws_dir && npm install"
  done < <(find "$HOME/conductor/workspaces" -name "package.json" -not -path "*/node_modules/*" -maxdepth 4 2>/dev/null || true)
fi
echo ""
echo "  6. Codex auth token may have expired. Re-authenticate if needed:"
echo "     codex auth"
echo ""
echo "  7. Launch Microsoft Edge and verify bookmarks/extensions restored"
echo ""
echo "  8. Source your shell config:"
echo "     source ~/.zshrc"
echo ""
