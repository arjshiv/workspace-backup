#!/usr/bin/env bash
set -euo pipefail
SECONDS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DATE=$(date +%Y-%m-%d-%H%M%S)
BACKUP_DIR="$SCRIPT_DIR/backups/workspace-backup-${BACKUP_DATE}"
CLAUDE_HOME="$HOME/.claude"
CODEX_HOME="$HOME/.codex"
CONDUCTOR_HOME="$HOME/conductor"
CONDUCTOR_APP_SUPPORT="$HOME/Library/Application Support/com.conductor.app"
AGENTS_HOME="$HOME/.agents"
EDGE_HOME="$HOME/Library/Application Support/Microsoft Edge"
WARN_COUNT=0
LOG_FILE=""
DRY_RUN=false

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# --- Step counter ---
CURRENT_STEP=0
TOTAL_STEPS=15

warn() {
  echo -e "  ${YELLOW}WARN:${NC} $1"
  WARN_COUNT=$((WARN_COUNT + 1))
  [ -n "$LOG_FILE" ] && echo "WARN: $1" >> "$LOG_FILE"
}

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  echo ""
  echo -e "${GREEN}==> [${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${BOLD}$1${NC}"
}

copy_if_exists() {
  local src="$1" dst="$2"
  if [ -f "$src" ]; then
    run_cmd cp "$src" "$dst"
  else
    warn "Not found: $src"
  fi
}

# Wrapper that respects DRY_RUN for write operations
run_cmd() {
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

# --- Argument parsing ---
show_help() {
  cat <<HELPTEXT
Usage: backup.sh [OPTIONS]

Back up your full AI dev environment (Claude Code, Codex CLI, Conductor)
to a self-contained folder under backups/.

Options:
  --help      Show this help message and exit
  --dry-run   Print what would be done without writing anything

Prerequisites:
  - macOS with Homebrew installed
  - jq (brew install jq)
  - sqlite3 (usually pre-installed on macOS)

Output:
  backups/workspace-backup-YYYY-MM-DD-HHMMSS/
    Containing configs, history, worktree metadata, restore scripts,
    and a RESTORE-GUIDE.md describing the contents.
HELPTEXT
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --help|-h) show_help ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown option: $arg"; echo "Try 'backup.sh --help'"; exit 1 ;;
  esac
done

if $DRY_RUN; then
  echo -e "${YELLOW}DRY RUN MODE — no files will be written${NC}"
fi

# --- Safety checks ---
if [ -d "$BACKUP_DIR" ]; then
  echo "Backup directory already exists: $BACKUP_DIR"
  read -rp "Overwrite? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  rm -rf "$BACKUP_DIR"
fi

avail_mb=$(df -m "$SCRIPT_DIR" | awk 'NR==2{print $4}')
if [ "$avail_mb" -lt 500 ]; then
  echo -e "${RED}ERROR: Less than 500MB free. Need space for backup.${NC}"
  exit 1
fi

# --- Create directory structure ---
step "Creating backup directory structure"
run_cmd mkdir -p "$BACKUP_DIR"
if ! $DRY_RUN; then
  LOG_FILE="$BACKUP_DIR/backup.log"
  echo "Backup started at $(date)" > "$LOG_FILE"
fi

run_cmd mkdir -p "$BACKUP_DIR"/{claude-code/skills,claude-code-project-configs}
run_cmd mkdir -p "$BACKUP_DIR"/codex-cli/{rules,skills,sqlite}
run_cmd mkdir -p "$BACKUP_DIR"/shared-agents
run_cmd mkdir -p "$BACKUP_DIR"/conductor/workspaces
run_cmd mkdir -p "$BACKUP_DIR"/shell-env/{ssh,gh,inshellisense}
run_cmd mkdir -p "$BACKUP_DIR"/volta
run_cmd mkdir -p "$BACKUP_DIR"/edge-browser

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
    if ! $DRY_RUN; then
      tar -czf "$BACKUP_DIR/claude-code/${dir}.tar.gz" -C "$CLAUDE_HOME" "$dir/" 2>/dev/null || warn "Failed to archive $dir"
    else
      echo "  [dry-run] tar -czf $BACKUP_DIR/claude-code/${dir}.tar.gz ..."
    fi
  fi
done

# Skills — resolve symlinks to copy actual files
if [ -d "$CLAUDE_HOME/skills/agent-browser" ]; then
  run_cmd cp -R "$CLAUDE_HOME/skills/agent-browser" "$BACKUP_DIR/claude-code/skills/"
fi
if [ -e "$CLAUDE_HOME/skills/remotion-best-practices" ]; then
  if ! $DRY_RUN; then
    cp -RL "$CLAUDE_HOME/skills/remotion-best-practices" "$BACKUP_DIR/claude-code/skills/" 2>/dev/null || warn "Failed to copy remotion skill"
  else
    echo "  [dry-run] cp -RL $CLAUDE_HOME/skills/remotion-best-practices ..."
  fi
fi

echo "  Claude Code done."

# ============================================================
# PROJECT-SPECIFIC .claude DIRS
# ============================================================
step "Backing up project-specific Claude configs"

# Auto-discover project paths by finding .claude directories
declare -A PROJECT_PATHS
while IFS= read -r claude_dir; do
  project_dir="${claude_dir%/.claude}"
  # Build encoded name: strip $HOME/, replace / with --
  rel="${project_dir#$HOME/}"
  encoded_name=$(echo "$rel" | sed 's|/|--|g')
  PROJECT_PATHS["$encoded_name"]="$claude_dir"
done < <(find "$HOME/GitHub" "$HOME/Downloads" -maxdepth 2 -name ".claude" -type d 2>/dev/null || true)

if [ ${#PROJECT_PATHS[@]} -eq 0 ]; then
  warn "No project .claude directories found in ~/GitHub or ~/Downloads"
fi

# Generate project-paths.json using jq
if ! $DRY_RUN; then
  jq -n \
    --argjson paths "$(
      for key in "${!PROJECT_PATHS[@]}"; do
        src="${PROJECT_PATHS[$key]}"
        rel_path="${src/#$HOME/~}"
        printf '%s\n%s\n' "$key" "$rel_path"
      done | jq -Rn '
        [inputs] |
        [range(0; length; 2) as $i | {(.[($i)]): .[($i)+1]}] |
        add // {}
      '
    )" \
    '$paths' > "$BACKUP_DIR/claude-code-project-configs/project-paths.json"
fi

# Copy each project config
for key in "${!PROJECT_PATHS[@]}"; do
  src="${PROJECT_PATHS[$key]}"
  if [ -d "$src" ]; then
    run_cmd mkdir -p "$BACKUP_DIR/claude-code-project-configs/$key"
    if ! $DRY_RUN; then
      cp -R "$src/"* "$BACKUP_DIR/claude-code-project-configs/$key/" 2>/dev/null || true
    fi
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
  run_cmd cp -R "$CODEX_HOME/skills/.system" "$BACKUP_DIR/codex-cli/skills/"
fi
if [ -e "$CODEX_HOME/skills/remotion-best-practices" ]; then
  if ! $DRY_RUN; then
    cp -RL "$CODEX_HOME/skills/remotion-best-practices" "$BACKUP_DIR/codex-cli/skills/" 2>/dev/null || true
  else
    echo "  [dry-run] cp -RL $CODEX_HOME/skills/remotion-best-practices ..."
  fi
fi

# SQLite
copy_if_exists "$CODEX_HOME/sqlite/codex-dev.db" "$BACKUP_DIR/codex-cli/sqlite/"

# Compressed archives
for dir in sessions vendor_imports; do
  if [ -d "$CODEX_HOME/$dir" ]; then
    echo "  Compressing $dir..."
    if ! $DRY_RUN; then
      tar -czf "$BACKUP_DIR/codex-cli/${dir}.tar.gz" -C "$CODEX_HOME" "$dir/" 2>/dev/null || warn "Failed to archive codex $dir"
    else
      echo "  [dry-run] tar -czf $BACKUP_DIR/codex-cli/${dir}.tar.gz ..."
    fi
  fi
done

echo "  Codex CLI done."

# ============================================================
# SHARED AGENTS
# ============================================================
step "Backing up shared agents"

if [ -d "$AGENTS_HOME" ]; then
  if ! $DRY_RUN; then
    # Only suppress "no matches" (exit code 1 from glob), not real failures
    if compgen -G "$AGENTS_HOME/*" > /dev/null 2>&1; then
      cp -RL "$AGENTS_HOME/"* "$BACKUP_DIR/shared-agents/" || warn "Failed to copy shared agents"
    else
      warn "No files in ~/.agents/"
    fi
  else
    echo "  [dry-run] cp -RL $AGENTS_HOME/* $BACKUP_DIR/shared-agents/"
  fi
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

  run_cmd mkdir -p "$backup_ws_dir"

  if $DRY_RUN; then
    echo "  [dry-run] Would back up worktrees for $project_name"
    return
  fi

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

# Auto-discover Conductor workspaces
conductor_found=false
if [ -d "$CONDUCTOR_HOME/workspaces" ]; then
  for ws_dir in "$CONDUCTOR_HOME/workspaces"/*/; do
    [ -d "$ws_dir" ] || continue
    project_name=$(basename "$ws_dir")

    # Find main repo by reading the git remote from any worktree
    main_repo=""
    remote_origin=""
    for sub_ws in "$ws_dir"/*/; do
      [ -d "$sub_ws/.git" ] || [ -f "$sub_ws/.git" ] || continue
      remote_origin=$(git -C "$sub_ws" remote get-url origin 2>/dev/null || echo "")
      if [ -n "$remote_origin" ]; then
        # Derive the main repo path from git worktree metadata
        local_main=$(git -C "$sub_ws" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "")
        if [ -n "$local_main" ] && [ -d "$local_main" ]; then
          # git-common-dir returns the .git dir; go up one level for the repo root
          main_repo="${local_main%/.git}"
          # If it still ends with .git (bare-style worktree), try the parent
          [ -d "$main_repo" ] || main_repo=""
        fi
        break
      fi
    done

    if [ -z "$remote_origin" ]; then
      warn "Could not determine remote for Conductor workspace: $project_name"
      continue
    fi

    # Fallback: if we couldn't find the main repo, try common locations
    if [ -z "$main_repo" ] || [ ! -d "$main_repo" ]; then
      repo_basename=$(basename "$remote_origin" .git)
      for candidate in "$HOME/GitHub"/*/"$repo_basename" "$HOME/GitHub/$repo_basename"; do
        if [ -d "$candidate/.git" ]; then
          main_repo="$candidate"
          break
        fi
      done
    fi

    if [ -z "$main_repo" ] || [ ! -d "$main_repo" ]; then
      warn "Main repo not found for $project_name (remote: $remote_origin)"
      continue
    fi

    echo "  Processing $project_name..."
    conductor_found=true
    backup_worktrees "$project_name" "$main_repo" "$remote_origin" "$ws_dir"
  done
fi

if ! $conductor_found; then
  warn "No Conductor workspaces found"
fi

# ============================================================
# CONDUCTOR — DATABASE & APP DATA
# ============================================================
step "Backing up Conductor database"

if $DRY_RUN; then
  echo "  [dry-run] Would back up conductor.db and related files"
else
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
  if ! $DRY_RUN; then
    tar -czf "$BACKUP_DIR/shell-env/github-copilot.tar.gz" -C "$HOME/.config" github-copilot/ 2>/dev/null || true
  else
    echo "  [dry-run] tar -czf ... github-copilot/"
  fi
fi

echo "  Shell config done."

# ============================================================
# HOMEBREW
# ============================================================
BREW_START=$SECONDS
step "Backing up Homebrew package list"

run_cmd mkdir -p "$BACKUP_DIR/homebrew"
if command -v brew &>/dev/null; then
  if ! $DRY_RUN; then
    brew bundle dump --file="$BACKUP_DIR/homebrew/Brewfile" --force 2>/dev/null || warn "Failed to dump Brewfile"
    brew list --versions > "$BACKUP_DIR/homebrew/brew-list.txt" 2>/dev/null || true
    brew list --cask --versions > "$BACKUP_DIR/homebrew/brew-cask-list.txt" 2>/dev/null || true
  else
    echo "  [dry-run] brew bundle dump / brew list"
  fi
  echo "  Brewfile and package lists saved."
else
  warn "Homebrew not found"
fi
echo "  Homebrew section took $((SECONDS - BREW_START))s"

# ============================================================
# VOLTA
# ============================================================
step "Backing up Volta package manifest"

if ! $DRY_RUN; then
  if command -v volta &>/dev/null; then
    volta list all --format=plain 2>/dev/null > "$BACKUP_DIR/volta/volta-list-all.txt" || true

    # Build global-packages.json dynamically from volta output
    node_ver=$(volta list node --format=plain 2>/dev/null | awk '{print $2; exit}' || echo "")
    npm_ver=$(volta list npm --format=plain 2>/dev/null | awk '{print $2; exit}' || echo "")
    # Extract package names from "volta list all" (lines with "package" prefix)
    pkg_list=$(volta list all --format=plain 2>/dev/null | awk '/^package /{print $2}' || echo "")

    if [ -n "$node_ver" ] && [ -n "$pkg_list" ]; then
      jq -n \
        --arg node "$node_ver" \
        --arg npm "${npm_ver:-bundled}" \
        --argjson pkgs "$(echo "$pkg_list" | jq -R . | jq -s .)" \
        '{node_default: $node, npm_default: $npm, global_packages: $pkgs}' \
        > "$BACKUP_DIR/volta/global-packages.json"
    else
      # Fallback to hardcoded list if volta output is unavailable or empty
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
    fi
  else
    # Volta not installed — write fallback
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
  fi
else
  echo "  [dry-run] Would generate volta/global-packages.json"
fi

echo "  Volta manifest done."

# ============================================================
# MICROSOFT EDGE
# ============================================================
step "Backing up Microsoft Edge profiles"

if [ ! -d "$EDGE_HOME" ]; then
  warn "Microsoft Edge not installed — skipping"
else
  # Warn if Edge is running
  if pgrep -x "Microsoft Edge" >/dev/null 2>&1; then
    warn "Microsoft Edge is running — backup may miss in-flight data"
  fi

  # Copy top-level Local State
  copy_if_exists "$EDGE_HOME/Local State" "$BACKUP_DIR/edge-browser/"

  # Auto-discover profiles (Default + Profile *)
  edge_profiles=()
  for profile_dir in "$EDGE_HOME"/Default "$EDGE_HOME"/Profile\ *; do
    [ -d "$profile_dir" ] && edge_profiles+=("$profile_dir")
  done

  if [ ${#edge_profiles[@]} -eq 0 ]; then
    warn "No Edge profiles found"
  else
    # Files to copy per profile (exclude cookies, login data, caches)
    EDGE_PROFILE_FILES=(
      "Bookmarks" "Bookmarks.bak" "Preferences" "Secure Preferences"
      "Top Sites" "Favicons" "History" "Web Data"
    )
    # Directories to tar.gz per profile
    EDGE_PROFILE_DIRS=("Sessions" "Extensions" "Collections")

    profiles_json="["
    first_profile=true

    for profile_path in "${edge_profiles[@]}"; do
      profile_name=$(basename "$profile_path")
      # Encode spaces: "Profile 1" -> "Profile_1" for filesystem safety
      encoded_name="${profile_name// /_}"
      echo "  Processing profile: $profile_name"

      run_cmd mkdir -p "$BACKUP_DIR/edge-browser/$encoded_name"

      # Copy individual files
      for f in "${EDGE_PROFILE_FILES[@]}"; do
        if [ -f "$profile_path/$f" ]; then
          run_cmd cp "$profile_path/$f" "$BACKUP_DIR/edge-browser/$encoded_name/"
        fi
      done

      # Tar directories
      for d in "${EDGE_PROFILE_DIRS[@]}"; do
        if [ -d "$profile_path/$d" ]; then
          if ! $DRY_RUN; then
            tar -czf "$BACKUP_DIR/edge-browser/$encoded_name/${d}.tar.gz" \
              -C "$profile_path" "$d/" 2>/dev/null || warn "Failed to archive $profile_name/$d"
          else
            echo "  [dry-run] tar -czf $BACKUP_DIR/edge-browser/$encoded_name/${d}.tar.gz ..."
          fi
        fi
      done

      # Build profiles.json entry
      if $first_profile; then
        first_profile=false
      else
        profiles_json+=","
      fi
      profiles_json+="{\"name\":\"$profile_name\",\"encoded\":\"$encoded_name\"}"
    done

    profiles_json+="]"

    # Write profiles.json
    if ! $DRY_RUN; then
      echo "$profiles_json" | jq '.' > "$BACKUP_DIR/edge-browser/profiles.json"
    else
      echo "  [dry-run] Would write edge-browser/profiles.json"
    fi

    echo "  Backed up ${#edge_profiles[@]} Edge profile(s)."
  fi
fi

echo "  Microsoft Edge done."

# ============================================================
# MANIFEST
# ============================================================
step "Generating manifest"

if ! $DRY_RUN; then
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
    "homebrew": "$(du -sh "$BACKUP_DIR/homebrew" 2>/dev/null | cut -f1)",
    "volta": "$(du -sh "$BACKUP_DIR/volta" 2>/dev/null | cut -f1)",
    "edge_browser": "$(du -sh "$BACKUP_DIR/edge-browser" 2>/dev/null | cut -f1)"
  }
}
MANIFEST
fi

# ============================================================
# RESTORE GUIDE FOR THE BACKUP FOLDER
# ============================================================
step "Generating RESTORE-GUIDE.md"

CURRENT_USER=$(whoami)
CURRENT_HOST=$(hostname)

if ! $DRY_RUN; then
cat > "$BACKUP_DIR/RESTORE-GUIDE.md" << CLAUDEMD
# Workspace Backup

Machine: ${CURRENT_USER}'s ${CURRENT_HOST}, macOS
User: ${CURRENT_USER}

## What This Backup Contains

Complete backup of AI coding assistant configs, history, and dev environment.

### Claude Code (\`~/.claude/\`)
- **CLAUDE.md**: Global instructions for Claude Code behavior
- **settings.json**: MCP servers, plugins, model pref, sandbox rules, agent teams mode
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
Local \`.claude/\` directories from GitHub and Downloads projects. See \`project-paths.json\` for the mapping of encoded names to original paths.

### Codex CLI (\`~/.codex/\`)
- **config.json / config.toml**: Provider settings, MCP servers, trusted projects
- **instructions.md**: AI agent guidelines
- **auth.json**: [SENSITIVE] OAuth tokens
- **rules/default.rules**: Coding rules
- **sessions/**: Session rollout data
- **skills/**: System skills + remotion-best-practices

### Shared Agents (\`~/.agents/\`)
- remotion-best-practices skill (symlinked from both Claude and Codex)

### Conductor
**Worktrees** (metadata + patches, NOT full clones):
Auto-discovered from \`~/conductor/workspaces/\`.

Each worktree has: branch/commit JSON, uncommitted changes .patch, untracked files .tar.gz, .env files

**Database**: conductor.db (SQLite backup of the main Conductor DB)
**Archived contexts**: Planning notes and todos from completed tasks

### Shell & Environment
- .zshrc (Oh-My-Zsh), .profile, .gitconfig
- SSH keys (ed25519), GitHub CLI config, Copilot config

### Volta Global Packages
Dynamically captured from \`volta list all\`.

### Microsoft Edge
Browser profiles including bookmarks, settings, extensions, history, collections, and sessions.
Each profile is stored as individual files + tar.gz archives for directories.
Excludes cookies, login data, caches, and service workers.

## SENSITIVE FILES
- \`codex-cli/auth.json\` — OAuth JWT + refresh tokens
- \`shell-env/ssh/id_ed25519\` — SSH private key
- \`shell-env/gh/hosts.yml\` — GitHub CLI auth
- \`conductor/workspaces/**/*.env\` — Application secrets
- \`edge-browser/*/History\` — Browsing history
- \`edge-browser/*/Web Data\` — Autofill and form data

**Encrypt this folder before uploading to cloud storage.**

## How to Restore
\`\`\`bash
bash restore.sh /path/to/this/backup/folder
\`\`\`
Prerequisites: Fresh Mac with Homebrew installed. See \`restore.sh\` for full details.
CLAUDEMD
fi

# ============================================================
# COPY SCRIPTS INTO BACKUP
# ============================================================
step "Copying scripts into backup"

run_cmd cp "$SCRIPT_DIR/backup.sh" "$BACKUP_DIR/"
if ! $DRY_RUN; then
  cp "$SCRIPT_DIR/restore.sh" "$BACKUP_DIR/" 2>/dev/null || warn "restore.sh not found next to backup.sh"
else
  echo "  [dry-run] cp restore.sh"
fi

# ============================================================
# PERMISSIONS
# ============================================================
step "Setting permissions on sensitive files"

if ! $DRY_RUN; then
  chmod 600 "$BACKUP_DIR/codex-cli/auth.json" 2>/dev/null || true
  chmod 600 "$BACKUP_DIR/shell-env/ssh/id_ed25519" 2>/dev/null || true
  chmod 600 "$BACKUP_DIR/shell-env/gh/hosts.yml" 2>/dev/null || true
  find "$BACKUP_DIR/conductor/workspaces" -name "*.env" -exec chmod 600 {} \; 2>/dev/null || true
  find "$BACKUP_DIR/edge-browser" -name "History" -exec chmod 600 {} \; 2>/dev/null || true
  find "$BACKUP_DIR/edge-browser" -name "Web Data" -exec chmod 600 {} \; 2>/dev/null || true
else
  echo "  [dry-run] Would chmod 600 sensitive files"
fi

# ============================================================
# SUMMARY
# ============================================================
elapsed=$SECONDS
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  BACKUP COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
if $DRY_RUN; then
  echo -e "  ${YELLOW}(dry run — nothing was written)${NC}"
else
  echo "  Location: $BACKUP_DIR"
  echo "  Size:     $(du -sh "$BACKUP_DIR" | cut -f1)"
  echo "  Files:    $(find "$BACKUP_DIR" -type f | wc -l | tr -d ' ')"
fi
echo "  Warnings: $WARN_COUNT"
echo "  Elapsed:  ${elapsed}s"
echo ""
if [ "$WARN_COUNT" -gt 0 ] && ! $DRY_RUN; then
  echo "  See $BACKUP_DIR/backup.log for details."
  echo ""
fi
if ! $DRY_RUN; then
  echo -e "  ${RED}WARNING: This backup contains SENSITIVE data:${NC}"
  echo "    - SSH private key (shell-env/ssh/id_ed25519)"
  echo "    - Codex OAuth tokens (codex-cli/auth.json)"
  echo "    - .env files with API keys (conductor/workspaces/**/*.env)"
  echo "    - GitHub CLI auth (shell-env/gh/hosts.yml)"
  echo "    - Edge browsing history and form data (edge-browser/*/History, Web Data)"
  echo ""
  echo -e "  ${RED}ENCRYPT BEFORE UPLOADING TO GOOGLE DRIVE.${NC}"
  echo "  Example: zip -er workspace-backup.zip $BACKUP_DIR"
  echo ""
  echo "Backup finished at $(date)" >> "$LOG_FILE"
fi
