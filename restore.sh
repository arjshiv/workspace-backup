#!/usr/bin/env bash
set -uo pipefail

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

# --- Results JSON infrastructure ---
RESULTS_FILE=""
CURRENT_STEP_ID=0
CURRENT_STEP_NAME=""
CURRENT_STEP_ERRORS="[]"
CURRENT_STEP_WARNINGS="[]"
RESUME_FROM=""
RESUME_FROM_ID=0
ONLY_STEP=""
TOTAL_STEPS=13

init_results() {
  RESULTS_FILE="$1"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$RESULTS_FILE" << INITJSON
{
  "script": "restore.sh",
  "started_at": "$now",
  "finished_at": null,
  "exit_code": null,
  "preflight": {"passed": true, "checks": []},
  "steps": [],
  "validation": {"passed": true, "checks": []},
  "summary": {"total_steps": $TOTAL_STEPS, "completed": 0, "failed": 0, "skipped": 0, "warnings": 0}
}
INITJSON
}

add_preflight_check() {
  [ -z "$RESULTS_FILE" ] && return
  local name="$1" status="$2" message="$3"
  local tmp
  tmp=$(jq \
    --arg name "$name" \
    --arg status "$status" \
    --arg msg "$message" \
    '.preflight.checks += [{"name": $name, "status": $status, "message": $msg}]' \
    "$RESULTS_FILE") && echo "$tmp" > "$RESULTS_FILE"
}

set_preflight_failed() {
  [ -z "$RESULTS_FILE" ] && return
  local tmp
  tmp=$(jq '.preflight.passed = false' "$RESULTS_FILE") && echo "$tmp" > "$RESULTS_FILE"
}

begin_step() {
  local id="$1" name="$2" label="$3"
  CURRENT_STEP_ID=$id
  CURRENT_STEP_NAME="$name"
  CURRENT_STEP_ERRORS="[]"
  CURRENT_STEP_WARNINGS="[]"

  # Handle --only: run only the named step
  if [ -n "$ONLY_STEP" ] && [ "$name" != "$ONLY_STEP" ]; then
    echo ""
    echo -e "${GREEN}==> [${id}/${TOTAL_STEPS}]${NC} ${BOLD}$label${NC} (skipped — only running $ONLY_STEP)"
    if [ -n "$RESULTS_FILE" ]; then
      local tmp
      tmp=$(jq \
        --arg name "$name" \
        --arg label "$label" \
        --argjson id "$id" \
        '.steps += [{"id": $id, "name": $name, "label": $label, "status": "skipped", "errors": [], "warnings": []}] | .summary.skipped += 1' \
        "$RESULTS_FILE") && echo "$tmp" > "$RESULTS_FILE"
    fi
    return 1
  fi

  # Resume support: skip steps before the resume point
  if [ "$RESUME_FROM_ID" -gt 0 ] && [ "$id" -lt "$RESUME_FROM_ID" ]; then
    echo ""
    echo -e "${GREEN}==> [${id}/${TOTAL_STEPS}]${NC} ${BOLD}$label${NC} (skipped — resuming from $RESUME_FROM)"
    if [ -n "$RESULTS_FILE" ]; then
      local tmp
      tmp=$(jq \
        --arg name "$name" \
        --arg label "$label" \
        --argjson id "$id" \
        '.steps += [{"id": $id, "name": $name, "label": $label, "status": "skipped", "errors": [], "warnings": []}] | .summary.skipped += 1' \
        "$RESULTS_FILE") && echo "$tmp" > "$RESULTS_FILE"
    fi
    return 1
  fi

  echo ""
  echo -e "${GREEN}==> [${id}/${TOTAL_STEPS}]${NC} ${BOLD}$label${NC}"
  return 0
}

end_step() {
  [ -z "$RESULTS_FILE" ] && return
  local status="completed"
  local err_count
  err_count=$(echo "$CURRENT_STEP_ERRORS" | jq 'length')
  if [ "$err_count" -gt 0 ]; then
    status="failed"
  fi
  local tmp
  tmp=$(jq \
    --arg name "$CURRENT_STEP_NAME" \
    --argjson id "$CURRENT_STEP_ID" \
    --arg status "$status" \
    --argjson errors "$CURRENT_STEP_ERRORS" \
    --argjson warnings "$CURRENT_STEP_WARNINGS" \
    '.steps += [{"id": $id, "name": $name, "status": $status, "errors": $errors, "warnings": $warnings}]
     | if $status == "completed" then .summary.completed += 1
       else .summary.failed += 1 end' \
    "$RESULTS_FILE") && echo "$tmp" > "$RESULTS_FILE"
}

record_error() {
  local code="$1" message="$2" category="${3:-permanent}" suggestion="${4:-}"
  if [ -n "$suggestion" ]; then
    CURRENT_STEP_ERRORS=$(echo "$CURRENT_STEP_ERRORS" | jq \
      --arg code "$code" \
      --arg msg "$message" \
      --arg cat "$category" \
      --arg sug "$suggestion" \
      '. += [{"code": $code, "message": $msg, "category": $cat, "suggestion": $sug}]')
  else
    CURRENT_STEP_ERRORS=$(echo "$CURRENT_STEP_ERRORS" | jq \
      --arg code "$code" \
      --arg msg "$message" \
      --arg cat "$category" \
      '. += [{"code": $code, "message": $msg, "category": $cat}]')
  fi
}

record_warning() {
  local code="$1" message="$2" category="${3:-transient}"
  CURRENT_STEP_WARNINGS=$(echo "$CURRENT_STEP_WARNINGS" | jq \
    --arg code "$code" \
    --arg msg "$message" \
    --arg cat "$category" \
    '. += [{"code": $code, "message": $msg, "category": $cat}]')
  [ -z "$RESULTS_FILE" ] && return
  local tmp
  tmp=$(jq '.summary.warnings += 1' "$RESULTS_FILE") && echo "$tmp" > "$RESULTS_FILE"
}

add_validation_check() {
  [ -z "$RESULTS_FILE" ] && return
  local name="$1" status="$2" message="$3"
  local tmp
  tmp=$(jq \
    --arg name "$name" \
    --arg status "$status" \
    --arg msg "$message" \
    '.validation.checks += [{"name": $name, "status": $status, "message": $msg}]
     | if $status == "fail" then .validation.passed = false else . end' \
    "$RESULTS_FILE") && echo "$tmp" > "$RESULTS_FILE"
}

finalize_results() {
  local code="${1:-0}"
  [ -z "$RESULTS_FILE" ] && return
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local tmp
  tmp=$(jq \
    --arg now "$now" \
    --argjson code "$code" \
    '.finished_at = $now | .exit_code = $code' \
    "$RESULTS_FILE") && echo "$tmp" > "$RESULTS_FILE"
}

# --- Argument parsing ---
SKIP_CONFIRM=false
DRY_RUN=false
BACKUP_DIR=""

usage() {
  echo "Usage: bash restore.sh [OPTIONS] /path/to/backup-dir-or-encrypted.zip"
  echo ""
  echo "Restore a full AI dev environment from a workspace backup."
  echo ""
  echo "Options:"
  echo "  -y, --yes              Skip confirmation prompt"
  echo "  --dry-run              Show what would be restored without writing"
  echo "  --only=STEP            Run only the named step, skipping all others"
  echo "  --resume-from=STEP     Resume from a specific step (e.g. --resume-from=edge)"
  echo "  -h, --help             Show this help message"
  echo ""
  echo "Steps (for --only / --resume-from):"
  echo "  prerequisites, shell_env, volta, claude_code, project_configs,"
  echo "  codex_cli, conductor_worktrees, conductor_db, edge, cursor_ide,"
  echo "  db_tools, github_repos, desktop_apps"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    -y|--yes) SKIP_CONFIRM=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --only=*) ONLY_STEP="${1#*=}"; shift ;;
    --resume-from=*) RESUME_FROM="${1#*=}"; shift ;;
    -*) echo "Unknown option: $1"; echo "Run with --help for usage."; exit 1 ;;
    *) BACKUP_DIR="$1"; shift ;;
  esac
done

if [ -z "$BACKUP_DIR" ]; then
  echo "ERROR: No backup directory specified."
  echo "Run with --help for usage."
  exit 1
fi

# --- Zip detection: decrypt and extract if input is a .zip file ---
CLEANUP_TEMP_DIR=""
if [[ "$BACKUP_DIR" == *.zip ]] && [ -f "$BACKUP_DIR" ]; then
  ZIP_FILE="$(cd "$(dirname "$BACKUP_DIR")" && pwd)/$(basename "$BACKUP_DIR")"
  TEMP_DIR=$(mktemp -d)
  echo "Decrypting and extracting $ZIP_FILE..."
  unzip "$ZIP_FILE" -d "$TEMP_DIR" || { echo "Failed to decrypt/extract zip"; exit 1; }
  BACKUP_DIR="$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
  CLEANUP_TEMP_DIR="$TEMP_DIR"
fi

BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

# --- Resolve --resume-from to step ID ---
if [ -n "$RESUME_FROM" ]; then
  case "$RESUME_FROM" in
    prerequisites)        RESUME_FROM_ID=1 ;;
    shell_env)            RESUME_FROM_ID=2 ;;
    volta)                RESUME_FROM_ID=3 ;;
    claude_code)          RESUME_FROM_ID=4 ;;
    project_configs)      RESUME_FROM_ID=5 ;;
    codex_cli)            RESUME_FROM_ID=6 ;;
    conductor_worktrees)  RESUME_FROM_ID=7 ;;
    conductor_db)         RESUME_FROM_ID=8 ;;
    edge)                 RESUME_FROM_ID=9 ;;
    cursor_ide)           RESUME_FROM_ID=10 ;;
    db_tools)             RESUME_FROM_ID=11 ;;
    github_repos)         RESUME_FROM_ID=12 ;;
    desktop_apps)         RESUME_FROM_ID=13 ;;
    *)
      echo "ERROR: Unknown step name '$RESUME_FROM' for --resume-from"
      echo "Valid steps: prerequisites, shell_env, volta, claude_code, project_configs,"
      echo "  codex_cli, conductor_worktrees, conductor_db, edge, cursor_ide,"
      echo "  db_tools, github_repos, desktop_apps"
      exit 1
      ;;
  esac
fi

# Validate --only step name
if [ -n "$ONLY_STEP" ]; then
  case "$ONLY_STEP" in
    prerequisites|shell_env|volta|claude_code|project_configs|\
    codex_cli|conductor_worktrees|conductor_db|edge|cursor_ide|\
    db_tools|github_repos|desktop_apps) ;;
    *)
      echo "ERROR: Unknown step name '$ONLY_STEP' for --only"
      echo "Valid steps: prerequisites, shell_env, volta, claude_code, project_configs,"
      echo "  codex_cli, conductor_worktrees, conductor_db, edge, cursor_ide,"
      echo "  db_tools, github_repos, desktop_apps"
      exit 1
      ;;
  esac
  if [ -n "$RESUME_FROM" ]; then
    echo "ERROR: --only and --resume-from cannot be used together"; exit 1
  fi
fi

echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  WORKSPACE RESTORE${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo "  Source: $BACKUP_DIR"
if $DRY_RUN; then
  echo -e "  Mode:   ${YELLOW}DRY RUN (no files will be written)${NC}"
fi
if [ -n "$RESUME_FROM" ]; then
  echo -e "  Resume: from ${BOLD}$RESUME_FROM${NC} (step $RESUME_FROM_ID)"
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

# --- Initialize results.json ---
init_results "$BACKUP_DIR/results.json"

# --- EXIT trap ---
exit_code=0
trap 'finalize_results ${exit_code:-$?}' EXIT

# --- Confirmation prompt ---
if ! $SKIP_CONFIRM && ! $DRY_RUN; then
  echo ""
  echo -e "${YELLOW}This will overwrite existing configs in $HOME. Continue? [y/N]${NC}"
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit_code=0
    exit 0
  fi
fi

echo "Starting restore..."
WARN_COUNT=0

warn() {
  echo -e "  ${YELLOW}WARN:${NC} $1"
  WARN_COUNT=$((WARN_COUNT + 1))
  record_warning "WARN" "$1" "transient"
}

CURRENT_STEP=0

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
# PREFLIGHT CHECKS
# ============================================================
echo ""
echo -e "${BOLD}Running preflight checks...${NC}"
preflight_ok=true

# Required: jq
if command -v jq &>/dev/null; then
  add_preflight_check "jq" "pass" "jq is available"
else
  add_preflight_check "jq" "fail" "jq is not installed (required for results tracking)"
  set_preflight_failed
  preflight_ok=false
fi

# Required: git
if command -v git &>/dev/null; then
  add_preflight_check "git" "pass" "git is available"
else
  add_preflight_check "git" "fail" "git is not installed (required for worktree restore)"
  set_preflight_failed
  preflight_ok=false
fi

# Network: can reach github.com
if curl -sf --max-time 5 https://github.com >/dev/null 2>&1; then
  add_preflight_check "network" "pass" "Can reach github.com"
else
  add_preflight_check "network" "warn" "Cannot reach github.com — git clones may fail"
  echo -e "  ${YELLOW}WARN: Cannot reach github.com — network-dependent steps may fail${NC}"
fi

# Disk space
avail_mb=$(df -m "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$avail_mb" ] && [ "$avail_mb" -ge 500 ] 2>/dev/null; then
  add_preflight_check "disk_space" "pass" "${avail_mb}MB available"
else
  add_preflight_check "disk_space" "warn" "Less than 500MB available (${avail_mb:-unknown}MB)"
  echo -e "  ${YELLOW}WARN: Low disk space — ${avail_mb:-unknown}MB available${NC}"
fi

# Backup structure valid (already checked above, but record in preflight)
add_preflight_check "backup_structure" "pass" "Backup structure validated"

# Edge not running (informational)
if pgrep -x "Microsoft Edge" >/dev/null 2>&1; then
  add_preflight_check "edge_not_running" "warn" "Microsoft Edge is running — profile restore may conflict"
  echo -e "  ${YELLOW}WARN: Microsoft Edge is running — profile restore may conflict${NC}"
else
  add_preflight_check "edge_not_running" "pass" "Microsoft Edge is not running"
fi

if ! $preflight_ok; then
  echo -e "${RED}Preflight checks failed. Install missing prerequisites and retry.${NC}"
  exit_code=2
  exit 2
fi

echo "  Preflight checks passed."

# ============================================================
# STEP 1: PREREQUISITES
# ============================================================
if begin_step 1 "prerequisites" "Checking and installing prerequisites"; then

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
end_step
fi

# ============================================================
# STEP 2: SHELL & ENVIRONMENT
# ============================================================
if begin_step 2 "shell_env" "Restoring shell and environment config"; then

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

# AWS CLI config
if [ -d "$BACKUP_DIR/shell-env/aws" ]; then
  safe_mkdir "$HOME/.aws"
  if [ -f "$BACKUP_DIR/shell-env/aws/config" ]; then
    pre_restore_backup "$HOME/.aws/config"
    safe_cp "$BACKUP_DIR/shell-env/aws/config" "$HOME/.aws/" 2>/dev/null || warn "Failed to restore AWS config"
  fi
  if [ -f "$BACKUP_DIR/shell-env/aws/credentials" ]; then
    pre_restore_backup "$HOME/.aws/credentials"
    safe_cp "$BACKUP_DIR/shell-env/aws/credentials" "$HOME/.aws/" 2>/dev/null || warn "Failed to restore AWS credentials"
    safe_chmod 600 "$HOME/.aws/credentials" 2>/dev/null || true
  fi
fi

# npmrc
if [ -f "$BACKUP_DIR/shell-env/npmrc" ]; then
  pre_restore_backup "$HOME/.npmrc"
  safe_cp "$BACKUP_DIR/shell-env/npmrc" "$HOME/.npmrc" 2>/dev/null || warn "Failed to restore .npmrc"
  safe_chmod 600 "$HOME/.npmrc" 2>/dev/null || true
fi

echo "  Shell config restored."
end_step
fi

# ============================================================
# STEP 3: VOLTA PACKAGES
# ============================================================
if begin_step 3 "volta" "Restoring Volta packages"; then

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
end_step
fi

# ============================================================
# STEP 4: CLAUDE CODE
# ============================================================
if begin_step 4 "claude_code" "Restoring Claude Code"; then

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
end_step
fi

# ============================================================
# STEP 5: PROJECT-SPECIFIC CLAUDE CONFIGS
# ============================================================
if begin_step 5 "project_configs" "Restoring project-specific Claude configs"; then

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

end_step
fi

# ============================================================
# STEP 6: CODEX CLI
# ============================================================
if begin_step 6 "codex_cli" "Restoring Codex CLI"; then

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
end_step
fi

# ============================================================
# STEP 7: CONDUCTOR — REPOS & WORKTREES
# ============================================================
if begin_step 7 "conductor_worktrees" "Restoring Conductor workspaces"; then

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
end_step
fi

# ============================================================
# STEP 8: CONDUCTOR — DATABASE & APP DATA
# ============================================================
if begin_step 8 "conductor_db" "Restoring Conductor database and app data"; then

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
end_step
fi

# ============================================================
# STEP 9: MICROSOFT EDGE
# ============================================================
if begin_step 9 "edge" "Restoring Microsoft Edge profiles"; then

EDGE_HOME="$HOME/Library/Application Support/Microsoft Edge"

if [ ! -d "$BACKUP_DIR/edge-browser" ] && [ ! -f "$BACKUP_DIR/open-tabs.json" ]; then
  echo "  No edge-browser directory or open-tabs.json in backup — skipping."
else
  # Warn if Edge is running
  if pgrep -x "Microsoft Edge" >/dev/null 2>&1; then
    if ! $SKIP_CONFIRM && ! $DRY_RUN; then
      echo ""
      echo -e "  ${RED}WARNING: Microsoft Edge is currently running.${NC}"
      echo -e "  ${RED}Restoring while Edge is open can corrupt profile data.${NC}"
      echo ""
      echo -e "  ${YELLOW}Quit Edge and press Enter to continue, or type 'skip' to skip this step:${NC}"
      read -r edge_confirm
      if [[ "$edge_confirm" == "skip" ]]; then
        echo "  Skipping Edge restore."
        EDGE_SKIP=true
      fi
    else
      record_warning "EDGE_RUNNING" "Microsoft Edge is running — profile data may be overwritten on exit" "user_action"
      warn "Edge is running — restoring anyway (--yes mode)"
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

  # Restore open tabs (preserving per-window grouping)
  # Check both edge-browser/ subdir and backup root for the JSON
  OPEN_TABS_FILE=""
  if [ -f "$BACKUP_DIR/edge-browser/open-tabs.json" ]; then
    OPEN_TABS_FILE="$BACKUP_DIR/edge-browser/open-tabs.json"
  elif [ -f "$BACKUP_DIR/open-tabs.json" ]; then
    OPEN_TABS_FILE="$BACKUP_DIR/open-tabs.json"
  fi

  if [ -n "$OPEN_TABS_FILE" ]; then
    tab_count=$(jq '[.[].tabs[]] | length' "$OPEN_TABS_FILE" 2>/dev/null || echo 0)
    window_count=$(jq 'length' "$OPEN_TABS_FILE" 2>/dev/null || echo 0)
    if [ "$tab_count" -gt 0 ]; then
      echo "  Found $tab_count open tab(s) across $window_count window(s) from backup."
      open_tabs=true
      if ! $SKIP_CONFIRM && ! $DRY_RUN; then
        echo -e "  ${YELLOW}Open all $tab_count tabs in $window_count window(s)? [y/N/skip]:${NC}"
        read -r tabs_confirm
        [[ "$tabs_confirm" =~ ^[Yy]$ ]] || open_tabs=false
      fi
      if $open_tabs && ! $DRY_RUN; then
        while IFS= read -r win; do
          win_num=$(echo "$win" | jq '.window')
          win_tabs=$(echo "$win" | jq '.tabs | length')
          echo "    Opening window $win_num ($win_tabs tabs)..."
          first_url=$(echo "$win" | jq -r '.tabs[0].url')
          if [ -n "$first_url" ] && [ "$first_url" != "null" ]; then
            open -na "Microsoft Edge" --args --new-window "$first_url" 2>/dev/null || true
            sleep 1
          fi
          echo "$win" | jq -r '.tabs[1:][].url' | while IFS= read -r url; do
            [ -z "$url" ] && continue
            open -a "Microsoft Edge" "$url" 2>/dev/null || true
            sleep 0.2
          done
        done < <(jq -c '.[]' "$OPEN_TABS_FILE")
        echo "  Opened $tab_count tab(s) across $window_count window(s) in Microsoft Edge."
      elif $DRY_RUN; then
        echo "  [dry-run] Would open $tab_count tab(s) across $window_count window(s) in Microsoft Edge"
      else
        echo "  Skipped opening tabs. URLs are saved in: $OPEN_TABS_FILE"
      fi
    fi
  fi
fi

end_step
fi

# ============================================================
# STEP 10: CURSOR IDE
# ============================================================
if begin_step 10 "cursor_ide" "Restoring Cursor IDE settings"; then

if [ ! -d "$BACKUP_DIR/cursor-ide" ]; then
  echo "  No cursor-ide directory in backup — skipping."
else
  CURSOR_USER_DIR="$HOME/Library/Application Support/Cursor/User"
  safe_mkdir "$CURSOR_USER_DIR"

  # Settings and keybindings
  for f in settings.json keybindings.json; do
    if [ -f "$BACKUP_DIR/cursor-ide/$f" ]; then
      pre_restore_backup "$CURSOR_USER_DIR/$f"
      safe_cp "$BACKUP_DIR/cursor-ide/$f" "$CURSOR_USER_DIR/" 2>/dev/null || warn "Failed to restore Cursor $f"
    fi
  done

  # Snippets directory
  if [ -d "$BACKUP_DIR/cursor-ide/snippets" ]; then
    safe_mkdir "$CURSOR_USER_DIR/snippets"
    safe_cp -R "$BACKUP_DIR/cursor-ide/snippets/"* "$CURSOR_USER_DIR/snippets/" 2>/dev/null || true
  fi

  # Extensions
  if [ -f "$BACKUP_DIR/cursor-ide/extensions.txt" ]; then
    if $DRY_RUN; then
      ext_count=$(wc -l < "$BACKUP_DIR/cursor-ide/extensions.txt" | tr -d ' ')
      echo "  [dry-run] Would install $ext_count Cursor extensions"
    else
      CURSOR_CLI=""
      if command -v cursor &>/dev/null; then
        CURSOR_CLI="cursor"
      elif [ -x "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" ]; then
        CURSOR_CLI="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
      fi
      if [ -n "$CURSOR_CLI" ]; then
        echo "  Installing Cursor extensions..."
        while IFS= read -r ext; do
          [ -z "$ext" ] && continue
          "$CURSOR_CLI" --install-extension "$ext" 2>/dev/null || warn "Failed to install Cursor extension: $ext"
        done < "$BACKUP_DIR/cursor-ide/extensions.txt"
      else
        echo "  Cursor CLI not found. Install extensions manually:"
        echo "    cat $BACKUP_DIR/cursor-ide/extensions.txt | xargs -L1 cursor --install-extension"
      fi
    fi
  fi

  echo "  Cursor IDE restored."
fi

end_step
fi

# ============================================================
# STEP 11: DATABASE TOOLS (DataGrip + psql)
# ============================================================
if begin_step 11 "db_tools" "Restoring database tools config"; then

if [ ! -d "$BACKUP_DIR/db-tools" ]; then
  echo "  No db-tools directory in backup — skipping."
else
  # --- DataGrip ---
  if [ -d "$BACKUP_DIR/db-tools/datagrip" ]; then
    DATAGRIP_BASE="$HOME/Library/Application Support/JetBrains"

    # Determine target version: prefer existing install, then backed-up version
    DATAGRIP_VERSION=""
    if [ -f "$BACKUP_DIR/db-tools/datagrip-version.txt" ]; then
      DATAGRIP_VERSION=$(cat "$BACKUP_DIR/db-tools/datagrip-version.txt")
    fi

    EXISTING_DG=""
    if [ -d "$DATAGRIP_BASE" ]; then
      EXISTING_DG=$(ls -1d "$DATAGRIP_BASE"/DataGrip* 2>/dev/null | sort -V | tail -1)
    fi

    if [ -n "$EXISTING_DG" ]; then
      DATAGRIP_HOME="$EXISTING_DG"
      echo "  Found existing $(basename "$EXISTING_DG")"
    elif [ -n "$DATAGRIP_VERSION" ]; then
      DATAGRIP_HOME="$DATAGRIP_BASE/$DATAGRIP_VERSION"
      echo "  Creating $DATAGRIP_VERSION config directory"
    else
      DATAGRIP_HOME="$DATAGRIP_BASE/DataGrip2025.2"
      echo "  No version info — defaulting to DataGrip2025.2"
    fi

    safe_mkdir "$DATAGRIP_HOME"

    # Restore directories
    for dir in options workspace consoles codestyles tasks jdbc-drivers; do
      if [ -d "$BACKUP_DIR/db-tools/datagrip/$dir" ]; then
        echo "  Restoring DataGrip $dir..."
        safe_mkdir "$DATAGRIP_HOME/$dir"
        safe_cp -R "$BACKUP_DIR/db-tools/datagrip/$dir/"* "$DATAGRIP_HOME/$dir/" 2>/dev/null || warn "Failed to restore DataGrip $dir"
      fi
    done

    # Restore individual files
    for f in datagrip.vmoptions datagrip.key; do
      if [ -f "$BACKUP_DIR/db-tools/datagrip/$f" ]; then
        pre_restore_backup "$DATAGRIP_HOME/$f"
        safe_cp "$BACKUP_DIR/db-tools/datagrip/$f" "$DATAGRIP_HOME/" 2>/dev/null || warn "Failed to restore DataGrip $f"
      fi
    done

    safe_chmod 600 "$DATAGRIP_HOME/datagrip.key" 2>/dev/null || true
    echo "  DataGrip settings restored."
  else
    echo "  No DataGrip config in backup — skipping."
  fi

  # --- psql / PostgreSQL client ---
  if [ -d "$BACKUP_DIR/db-tools/psql" ]; then
    echo "  Restoring psql settings..."
    if [ -f "$BACKUP_DIR/db-tools/psql/psqlrc" ]; then
      pre_restore_backup "$HOME/.psqlrc"
      safe_cp "$BACKUP_DIR/db-tools/psql/psqlrc" "$HOME/.psqlrc" 2>/dev/null || warn "Failed to restore .psqlrc"
    fi
    if [ -f "$BACKUP_DIR/db-tools/psql/psql_history" ]; then
      pre_restore_backup "$HOME/.psql_history"
      safe_cp "$BACKUP_DIR/db-tools/psql/psql_history" "$HOME/.psql_history" 2>/dev/null || warn "Failed to restore .psql_history"
    fi
    if [ -f "$BACKUP_DIR/db-tools/psql/pgpass" ]; then
      pre_restore_backup "$HOME/.pgpass"
      safe_cp "$BACKUP_DIR/db-tools/psql/pgpass" "$HOME/.pgpass" 2>/dev/null || warn "Failed to restore .pgpass"
      safe_chmod 600 "$HOME/.pgpass" 2>/dev/null || true
    fi
    if [ -f "$BACKUP_DIR/db-tools/psql/pg_service.conf" ]; then
      pre_restore_backup "$HOME/.pg_service.conf"
      safe_cp "$BACKUP_DIR/db-tools/psql/pg_service.conf" "$HOME/.pg_service.conf" 2>/dev/null || warn "Failed to restore .pg_service.conf"
    fi
    if [ -d "$BACKUP_DIR/db-tools/psql/postgresql" ]; then
      safe_mkdir "$HOME/.postgresql"
      safe_cp -R "$BACKUP_DIR/db-tools/psql/postgresql/"* "$HOME/.postgresql/" 2>/dev/null || warn "Failed to restore ~/.postgresql"
    fi
    echo "  psql settings restored."
  else
    echo "  No psql config in backup — skipping."
  fi
fi

end_step
fi

# ============================================================
# STEP 12: GITHUB REPOS
# ============================================================
if begin_step 12 "github_repos" "Restoring ~/GitHub repositories"; then

if [ ! -f "$BACKUP_DIR/github-repos/github.tar.gz" ]; then
  echo "  No github-repos/github.tar.gz in backup — skipping."
else
  if [ -d "$HOME/GitHub" ]; then
    echo "  ~/GitHub already exists — archive will merge (existing files preserved, backed-up files overwritten)"
  fi
  safe_mkdir "$HOME/GitHub"
  echo "  Extracting ~/GitHub archive (this may take a while)..."
  safe_tar -xzf "$BACKUP_DIR/github-repos/github.tar.gz" -C "$HOME/" 2>/dev/null || {
    record_error "GITHUB_EXTRACT" "Failed to extract ~/GitHub archive" "transient" "Check disk space and retry with --resume-from=github_repos"
    warn "Failed to extract ~/GitHub archive"
  }
  if ! $DRY_RUN && [ -d "$HOME/GitHub" ]; then
    repo_count=$(find "$HOME/GitHub" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo "  ~/GitHub restored ($repo_count top-level directories)"
  fi
fi

end_step
fi

# ============================================================
# STEP 12: DESKTOP APPS (iTerm2, Warp, Rectangle, Fonts)
# ============================================================
if begin_step 13 "desktop_apps" "Restoring desktop app preferences"; then

if [ ! -d "$BACKUP_DIR/desktop-apps" ]; then
  echo "  No desktop-apps directory in backup — skipping."
else
  # iTerm2
  if [ -f "$BACKUP_DIR/desktop-apps/iterm2-plist.xml" ]; then
    echo "  Restoring iTerm2 preferences..."
    pre_restore_backup "$HOME/Library/Preferences/com.googlecode.iterm2.plist"
    safe_cp "$BACKUP_DIR/desktop-apps/iterm2-plist.xml" "$HOME/Library/Preferences/com.googlecode.iterm2.plist" 2>/dev/null || warn "Failed to restore iTerm2 plist"
    if ! $DRY_RUN; then
      plutil -convert binary1 "$HOME/Library/Preferences/com.googlecode.iterm2.plist" 2>/dev/null || true
    fi
  fi
  if [ -d "$BACKUP_DIR/desktop-apps/DynamicProfiles" ]; then
    safe_mkdir "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
    safe_cp -R "$BACKUP_DIR/desktop-apps/DynamicProfiles/"* "$HOME/Library/Application Support/iTerm2/DynamicProfiles/" 2>/dev/null || true
  fi

  # Warp
  if [ -f "$BACKUP_DIR/desktop-apps/warp-plist.xml" ]; then
    echo "  Restoring Warp preferences..."
    # Detect which Warp plist exists on the target system
    WARP_TARGET=""
    if [ -f "$HOME/Library/Preferences/dev.warp.Warp-Stable.plist" ]; then
      WARP_TARGET="$HOME/Library/Preferences/dev.warp.Warp-Stable.plist"
    elif [ -f "$HOME/Library/Preferences/dev.warp.Warp.plist" ]; then
      WARP_TARGET="$HOME/Library/Preferences/dev.warp.Warp.plist"
    else
      WARP_TARGET="$HOME/Library/Preferences/dev.warp.Warp-Stable.plist"
    fi
    pre_restore_backup "$WARP_TARGET"
    safe_cp "$BACKUP_DIR/desktop-apps/warp-plist.xml" "$WARP_TARGET" 2>/dev/null || warn "Failed to restore Warp plist"
    if ! $DRY_RUN; then
      plutil -convert binary1 "$WARP_TARGET" 2>/dev/null || true
    fi
  fi

  # Rectangle
  if [ -f "$BACKUP_DIR/desktop-apps/rectangle-plist.xml" ]; then
    echo "  Restoring Rectangle preferences..."
    pre_restore_backup "$HOME/Library/Preferences/com.knewton.Rectangle.plist"
    safe_cp "$BACKUP_DIR/desktop-apps/rectangle-plist.xml" "$HOME/Library/Preferences/com.knewton.Rectangle.plist" 2>/dev/null || warn "Failed to restore Rectangle plist"
    if ! $DRY_RUN; then
      plutil -convert binary1 "$HOME/Library/Preferences/com.knewton.Rectangle.plist" 2>/dev/null || true
    fi
  fi

  # Fonts
  if [ -f "$BACKUP_DIR/desktop-apps/user-fonts.tar.gz" ]; then
    echo "  Restoring user fonts..."
    safe_tar -xzf "$BACKUP_DIR/desktop-apps/user-fonts.tar.gz" -C "$HOME/Library/" 2>/dev/null || warn "Failed to extract user fonts"
  fi

  echo "  Desktop app preferences restored."
fi

end_step
fi

# ============================================================
# POST-RESTORE VALIDATION
# ============================================================
if [ -z "$ONLY_STEP" ]; then
echo ""
echo -e "${BOLD}Running post-restore validation...${NC}"

# ~/.claude/settings.json exists (if claude-code was in backup)
if [ -d "$BACKUP_DIR/claude-code" ]; then
  if [ -f "$HOME/.claude/settings.json" ]; then
    add_validation_check "claude_settings" "pass" "~/.claude/settings.json exists"
  else
    add_validation_check "claude_settings" "fail" "~/.claude/settings.json is missing"
  fi
fi

# ~/.zshrc exists
if [ -f "$HOME/.zshrc" ]; then
  add_validation_check "zshrc" "pass" "~/.zshrc exists"
else
  add_validation_check "zshrc" "fail" "~/.zshrc is missing"
fi

# SSH key perms = 600
if [ -f "$HOME/.ssh/id_ed25519" ]; then
  ssh_perms=$(stat -f '%Lp' "$HOME/.ssh/id_ed25519" 2>/dev/null || stat -c '%a' "$HOME/.ssh/id_ed25519" 2>/dev/null || echo "unknown")
  if [ "$ssh_perms" = "600" ]; then
    add_validation_check "ssh_key_perms" "pass" "SSH key permissions are 600"
  else
    add_validation_check "ssh_key_perms" "warn" "SSH key permissions are $ssh_perms (expected 600)"
  fi
else
  add_validation_check "ssh_key_perms" "warn" "SSH key not found at ~/.ssh/id_ed25519"
fi

# volta, node, npm in PATH
for cmd in volta node npm; do
  if command -v "$cmd" &>/dev/null; then
    add_validation_check "${cmd}_in_path" "pass" "$cmd is in PATH"
  else
    add_validation_check "${cmd}_in_path" "warn" "$cmd is not in PATH"
  fi
done

# Conductor worktrees created (check a sample)
if [ -d "$HOME/conductor/workspaces" ]; then
  wt_count=$(find "$HOME/conductor/workspaces" -mindepth 2 -maxdepth 2 -name ".git" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$wt_count" -gt 0 ]; then
    add_validation_check "conductor_worktrees" "pass" "$wt_count worktree(s) found"
  else
    add_validation_check "conductor_worktrees" "warn" "No worktrees found under ~/conductor/workspaces"
  fi
else
  add_validation_check "conductor_worktrees" "warn" "~/conductor/workspaces does not exist"
fi

echo "  Validation complete."
fi  # end --only skip for validation

# ============================================================
# SET EXIT CODE
# ============================================================
if [ -n "$RESULTS_FILE" ] && [ -f "$RESULTS_FILE" ]; then
  failed_count=$(jq '.summary.failed' "$RESULTS_FILE" 2>/dev/null || echo "0")
  if [ "$failed_count" -gt 0 ] 2>/dev/null; then
    exit_code=1
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
if [ -n "$RESULTS_FILE" ]; then
  echo -e "  Results:  $RESULTS_FILE"
fi
echo ""
echo -e "  ${BOLD}MANUAL STEPS REMAINING:${NC}"
echo ""
echo "  1. Authenticate GitHub CLI:"
echo "     gh auth login"
echo ""
echo "  2. Verify SSH key works:"
echo "     ssh -T git@github.com"
echo ""
echo "  3. Verify AWS CLI auth (if AWS was restored):"
echo "     aws sts get-caller-identity"
echo ""
echo "  4. Install Claude Code (if not already installed):"
echo "     npm install -g @anthropic-ai/claude-code"
echo "     # Then run 'claude' and authenticate"
echo ""
echo "  5. Install Conductor app from official source"
echo ""
echo "  6. Run 'npm install' in workspaces that need node_modules:"
# Find worktrees with package.json and suggest npm install
if [ -d "$HOME/conductor/workspaces" ]; then
  while IFS= read -r pkg_json; do
    ws_dir="$(dirname "$pkg_json")"
    echo "     cd $ws_dir && npm install"
  done < <(find "$HOME/conductor/workspaces" -name "package.json" -not -path "*/node_modules/*" -maxdepth 4 2>/dev/null || true)
fi
echo ""
echo "  7. Codex auth token may have expired. Re-authenticate if needed:"
echo "     codex auth"
echo ""
echo "  8. Launch Microsoft Edge and verify bookmarks/extensions restored"
echo ""
echo "  9. Launch Cursor and verify extensions/settings are restored"
echo ""
echo "  10. Launch DataGrip and verify data sources and settings are restored"
echo ""
echo "  11. Restart iTerm2/Warp/Rectangle to pick up restored preferences"
echo ""
echo "  12. Source your shell config:"
echo "      source ~/.zshrc"
echo ""

if [ -n "$CLEANUP_TEMP_DIR" ]; then
  rm -rf "$CLEANUP_TEMP_DIR"
fi

exit $exit_code
