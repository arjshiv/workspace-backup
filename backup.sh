#!/usr/bin/env bash
set -uo pipefail
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
ENCRYPT=false

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# --- Step counter ---
CURRENT_STEP=0
TOTAL_STEPS=19

# --- Results JSON infrastructure ---
RESULTS_FILE=""
CURRENT_STEP_ID=0
CURRENT_STEP_NAME=""
CURRENT_STEP_ERRORS=""
CURRENT_STEP_WARNINGS=""
RESUME_FROM=""
RESUME_FROM_ID=0

init_results() {
  RESULTS_FILE="$1"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$RESULTS_FILE" << INITJSON
{
  "script": "backup.sh",
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
  local name="$1" status="$2" detail="${3:-}"
  [ -z "$RESULTS_FILE" ] && return
  local entry
  if [ -n "$detail" ]; then
    entry="{\"name\":\"$name\",\"status\":\"$status\",\"detail\":\"$detail\"}"
  else
    entry="{\"name\":\"$name\",\"status\":\"$status\"}"
  fi
  local tmp="${RESULTS_FILE}.tmp"
  jq --argjson check "$entry" '.preflight.checks += [$check]' "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"
}

set_preflight_failed() {
  [ -z "$RESULTS_FILE" ] && return
  local tmp="${RESULTS_FILE}.tmp"
  jq '.preflight.passed = false' "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"
}

begin_step() {
  local id="$1" name="$2" label="$3"
  CURRENT_STEP_ID="$id"
  CURRENT_STEP_NAME="$name"
  CURRENT_STEP_ERRORS="[]"
  CURRENT_STEP_WARNINGS="[]"

  # Handle --resume-from: skip steps before the resume point
  if [ "$RESUME_FROM_ID" -gt 0 ] && [ "$id" -lt "$RESUME_FROM_ID" ]; then
    # Record as skipped in results.json
    if [ -n "$RESULTS_FILE" ]; then
      local tmp="${RESULTS_FILE}.tmp"
      jq --argjson s "{\"id\":$id,\"name\":\"$name\",\"status\":\"skipped\",\"errors\":[],\"warnings\":[]}" \
        '.steps += [$s] | .summary.skipped += 1' "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"
    fi
    return 1  # Signal caller to skip this step
  fi

  step "$label"
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

  local warn_count
  warn_count=$(echo "$CURRENT_STEP_WARNINGS" | jq 'length')

  local tmp="${RESULTS_FILE}.tmp"
  jq --argjson s "{\"id\":$CURRENT_STEP_ID,\"name\":\"$CURRENT_STEP_NAME\",\"status\":\"$status\",\"errors\":$CURRENT_STEP_ERRORS,\"warnings\":$CURRENT_STEP_WARNINGS}" \
    --arg st "$status" \
    '.steps += [$s] | if $st == "completed" then .summary.completed += 1 else .summary.failed += 1 end | .summary.warnings += ($s.warnings | length)' \
    "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"
}

record_error() {
  local code="$1" msg="$2" category="$3" suggestion="${4:-}"
  local entry
  if [ -n "$suggestion" ]; then
    entry=$(jq -n --arg c "$code" --arg m "$msg" --arg cat "$category" --arg s "$suggestion" \
      '{code: $c, message: $m, category: $cat, suggestion: $s}')
  else
    entry=$(jq -n --arg c "$code" --arg m "$msg" --arg cat "$category" \
      '{code: $c, message: $m, category: $cat}')
  fi
  CURRENT_STEP_ERRORS=$(echo "$CURRENT_STEP_ERRORS" | jq --argjson e "$entry" '. += [$e]')
}

record_warning() {
  local code="$1" msg="$2" category="${3:-transient}"
  local entry
  entry=$(jq -n --arg c "$code" --arg m "$msg" --arg cat "$category" \
    '{code: $c, message: $m, category: $cat}')
  CURRENT_STEP_WARNINGS=$(echo "$CURRENT_STEP_WARNINGS" | jq --argjson e "$entry" '. += [$e]')
}

add_validation_check() {
  local name="$1" status="$2" detail="${3:-}"
  [ -z "$RESULTS_FILE" ] && return
  local entry
  if [ -n "$detail" ]; then
    entry="{\"name\":\"$name\",\"status\":\"$status\",\"detail\":\"$detail\"}"
  else
    entry="{\"name\":\"$name\",\"status\":\"$status\"}"
  fi
  local tmp="${RESULTS_FILE}.tmp"
  jq --argjson check "$entry" '.validation.checks += [$check]' "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"
  if [ "$status" != "ok" ]; then
    jq '.validation.passed = false' "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"
  fi
}

finalize_results() {
  local code="${1:-$?}"
  [ -z "$RESULTS_FILE" ] && return
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local tmp="${RESULTS_FILE}.tmp"
  jq --arg t "$now" --argjson c "$code" '.finished_at = $t | .exit_code = $c' "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"
}

warn() {
  echo -e "  ${YELLOW}WARN:${NC} $1"
  WARN_COUNT=$((WARN_COUNT + 1))
  [ -n "$LOG_FILE" ] && echo "WARN: $1" >> "$LOG_FILE"
  record_warning "WARN" "$1" "transient"
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
  --help                Show this help message and exit
  --dry-run             Print what would be done without writing anything
  --encrypt             Encrypt the backup as a password-protected .zip
                        after completion (prompts for password)
  --resume-from=STEP    Resume from a named step, skipping earlier ones.
                        Step names: create_dirs, claude_code, project_configs,
                        codex_cli, shared_agents, conductor_worktrees,
                        conductor_db, shell_env, homebrew, volta, edge,
                        cursor_ide, db_tools, desktop_apps, github_repos,
                        manifest, restore_guide, copy_scripts, permissions

Prerequisites:
  - macOS with Homebrew installed
  - jq (brew install jq)
  - sqlite3 (usually pre-installed on macOS)

Output:
  backups/workspace-backup-YYYY-MM-DD-HHMMSS/
    Containing configs, history, worktree metadata, restore scripts,
    and a RESTORE-GUIDE.md describing the contents.

  results.json is written alongside the backup with machine-readable
  status for each step (for agent self-healing).
HELPTEXT
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --help|-h) show_help ;;
    --dry-run) DRY_RUN=true ;;
    --encrypt) ENCRYPT=true ;;
    --resume-from=*) RESUME_FROM="${arg#*=}" ;;
    *) echo "Unknown option: $arg"; echo "Try 'backup.sh --help'"; exit 1 ;;
  esac
done

# Resolve --resume-from step name to numeric ID
if [ -n "$RESUME_FROM" ]; then
  case "$RESUME_FROM" in
    create_dirs)          RESUME_FROM_ID=1 ;;
    claude_code)          RESUME_FROM_ID=2 ;;
    project_configs)      RESUME_FROM_ID=3 ;;
    codex_cli)            RESUME_FROM_ID=4 ;;
    shared_agents)        RESUME_FROM_ID=5 ;;
    conductor_worktrees)  RESUME_FROM_ID=6 ;;
    conductor_db)         RESUME_FROM_ID=7 ;;
    shell_env)            RESUME_FROM_ID=8 ;;
    homebrew)             RESUME_FROM_ID=9 ;;
    volta)                RESUME_FROM_ID=10 ;;
    edge)                 RESUME_FROM_ID=11 ;;
    cursor_ide)           RESUME_FROM_ID=12 ;;
    db_tools)             RESUME_FROM_ID=13 ;;
    desktop_apps)         RESUME_FROM_ID=14 ;;
    github_repos)         RESUME_FROM_ID=15 ;;
    manifest)             RESUME_FROM_ID=16 ;;
    restore_guide)        RESUME_FROM_ID=17 ;;
    copy_scripts)         RESUME_FROM_ID=18 ;;
    permissions)          RESUME_FROM_ID=19 ;;
    *) echo "Unknown step name: $RESUME_FROM"; echo "Try 'backup.sh --help'"; exit 1 ;;
  esac
fi

if $DRY_RUN; then
  echo -e "${YELLOW}DRY RUN MODE — no files will be written${NC}"
fi

# --- EXIT trap ---
exit_code=0
trap 'finalize_results ${exit_code:-$?}' EXIT

# --- Initialize results.json (dry-run uses SCRIPT_DIR) ---
if $DRY_RUN; then
  init_results "$SCRIPT_DIR/results.json"
fi

# --- Preflight checks ---
echo ""
echo -e "${BOLD}Running preflight checks...${NC}"
preflight_ok=true

# Required tools
for tool in jq git tar; do
  if command -v "$tool" &>/dev/null; then
    add_preflight_check "$tool" "ok"
  else
    add_preflight_check "$tool" "fail" "$tool is required but not found"
    set_preflight_failed
    preflight_ok=false
    echo -e "  ${RED}FAIL:${NC} $tool is required but not found"
  fi
done

# Optional tools
for tool in plutil sqlite3 brew volta; do
  if command -v "$tool" &>/dev/null; then
    add_preflight_check "$tool" "ok"
  else
    add_preflight_check "$tool" "skip" "$tool not found (optional)"
    echo -e "  ${YELLOW}SKIP:${NC} $tool not found (optional)"
  fi
done

# Resolve Cursor CLI: PATH first, then app bundle fallback
CURSOR_CLI=""
if command -v cursor &>/dev/null; then
  CURSOR_CLI="cursor"
elif [ -x "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" ]; then
  CURSOR_CLI="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
fi
if [ -n "$CURSOR_CLI" ]; then
  add_preflight_check "cursor" "ok"
else
  add_preflight_check "cursor" "skip" "cursor not found (optional)"
  echo -e "  ${YELLOW}SKIP:${NC} cursor not found (optional)"
fi

# Disk space
avail_mb=$(df -m "$SCRIPT_DIR" | awk 'NR==2{print $4}')
if [ "$avail_mb" -ge 500 ]; then
  add_preflight_check "disk_space" "ok" "${avail_mb}MB available"
else
  add_preflight_check "disk_space" "fail" "Only ${avail_mb}MB available, need 500MB"
  set_preflight_failed
  preflight_ok=false
  echo -e "  ${RED}FAIL:${NC} Only ${avail_mb}MB available, need 500MB"
fi

if ! $preflight_ok; then
  echo -e "${RED}Preflight checks failed. Aborting.${NC}"
  exit_code=2
  exit 2
fi
echo -e "  ${GREEN}All preflight checks passed.${NC}"

# --- Safety checks ---
if [ -d "$BACKUP_DIR" ]; then
  echo "Backup directory already exists: $BACKUP_DIR"
  read -rp "Overwrite? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  rm -rf "$BACKUP_DIR"
fi

# --- Create directory structure ---
if begin_step 1 "create_dirs" "Creating backup directory structure"; then

run_cmd mkdir -p "$BACKUP_DIR"
if ! $DRY_RUN; then
  # Initialize results.json inside backup dir (non-dry-run)
  init_results "$BACKUP_DIR/results.json"
  LOG_FILE="$BACKUP_DIR/backup.log"
  echo "Backup started at $(date)" > "$LOG_FILE"
fi

run_cmd mkdir -p "$BACKUP_DIR"/{claude-code/skills,claude-code-project-configs}
run_cmd mkdir -p "$BACKUP_DIR"/codex-cli/{rules,skills,sqlite}
run_cmd mkdir -p "$BACKUP_DIR"/shared-agents
run_cmd mkdir -p "$BACKUP_DIR"/conductor/workspaces
run_cmd mkdir -p "$BACKUP_DIR"/shell-env/{ssh,gh,inshellisense,aws}
run_cmd mkdir -p "$BACKUP_DIR"/volta
run_cmd mkdir -p "$BACKUP_DIR"/edge-browser
run_cmd mkdir -p "$BACKUP_DIR"/{cursor-ide,db-tools/datagrip,db-tools/psql,desktop-apps,github-repos}

end_step
fi

# ============================================================
# CLAUDE CODE
# ============================================================
if begin_step 2 "claude_code" "Backing up Claude Code"; then

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

end_step
fi

# ============================================================
# PROJECT-SPECIFIC .claude DIRS
# ============================================================
if begin_step 3 "project_configs" "Backing up project-specific Claude configs"; then

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
      cp -R "$src/"* "$BACKUP_DIR/claude-code-project-configs/$key/" 2>/dev/null || record_warning "COPY_PROJECT" "Failed to copy some files from $key" "transient"
    fi
    echo "  Backed up: $key"
  else
    warn "Project config not found: $src"
  fi
done

end_step
fi

# ============================================================
# CODEX CLI
# ============================================================
if begin_step 4 "codex_cli" "Backing up Codex CLI"; then

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
    cp -RL "$CODEX_HOME/skills/remotion-best-practices" "$BACKUP_DIR/codex-cli/skills/" 2>/dev/null || record_warning "COPY_SKILL" "Failed to copy codex remotion skill" "transient"
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

end_step
fi

# ============================================================
# SHARED AGENTS
# ============================================================
if begin_step 5 "shared_agents" "Backing up shared agents"; then

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

end_step
fi

# ============================================================
# CONDUCTOR — WORKTREE METADATA
# ============================================================
if begin_step 6 "conductor_worktrees" "Backing up Conductor workspaces"; then

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
    git -C "$main_repo" stash list > "$backup_ws_dir/_stash-list.txt" 2>/dev/null || record_warning "STASH_LIST" "Failed to list stashes for $project_name" "transient"
    for i in $(seq 0 $((stash_count - 1))); do
      git -C "$main_repo" stash show -p "stash@{$i}" > "$backup_ws_dir/_stash-${i}.patch" 2>/dev/null || record_warning "STASH_PATCH" "Failed to export stash $i for $project_name" "transient"
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
      tar -czf "$backup_ws_dir/${name}-context.tar.gz" -C "$ws" .context/ 2>/dev/null || record_warning "CONTEXT_TAR" "Failed to archive .context for $name" "transient"
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

end_step
fi

# ============================================================
# CONDUCTOR — DATABASE & APP DATA
# ============================================================
if begin_step 7 "conductor_db" "Backing up Conductor database"; then

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
  cp "$CONDUCTOR_APP_SUPPORT/conductor.db-wal" "$BACKUP_DIR/conductor/" 2>/dev/null || record_warning "WAL_COPY" "WAL file not found (normal if DB was idle)" "transient"

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
    tar -czf "$BACKUP_DIR/conductor/context-trash.tar.gz" -C "$CONDUCTOR_HOME" .context-trash/ 2>/dev/null || record_warning "TRASH_TAR" "Failed to archive context trash" "transient"
  fi

  # dbtools
  if [ -d "$CONDUCTOR_HOME/dbtools" ]; then
    cp -R "$CONDUCTOR_HOME/dbtools" "$BACKUP_DIR/conductor/" 2>/dev/null || record_warning "DBTOOLS_COPY" "Failed to copy dbtools" "transient"
  fi
fi

echo "  Conductor database done."

end_step
fi

# ============================================================
# SHELL & ENVIRONMENT
# ============================================================
if begin_step 8 "shell_env" "Backing up shell and environment config"; then

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
    tar -czf "$BACKUP_DIR/shell-env/github-copilot.tar.gz" -C "$HOME/.config" github-copilot/ 2>/dev/null || record_warning "COPILOT_TAR" "Failed to archive github-copilot" "transient"
  else
    echo "  [dry-run] tar -czf ... github-copilot/"
  fi
fi

# AWS CLI
copy_if_exists "$HOME/.aws/config" "$BACKUP_DIR/shell-env/aws/"
copy_if_exists "$HOME/.aws/credentials" "$BACKUP_DIR/shell-env/aws/"

# npm global config
copy_if_exists "$HOME/.npmrc" "$BACKUP_DIR/shell-env/npmrc"

echo "  Shell config done."

end_step
fi

# ============================================================
# HOMEBREW
# ============================================================
BREW_START=$SECONDS
if begin_step 9 "homebrew" "Backing up Homebrew package list"; then

run_cmd mkdir -p "$BACKUP_DIR/homebrew"
if command -v brew &>/dev/null; then
  if ! $DRY_RUN; then
    brew bundle dump --file="$BACKUP_DIR/homebrew/Brewfile" --force 2>/dev/null || warn "Failed to dump Brewfile"
    brew list --versions > "$BACKUP_DIR/homebrew/brew-list.txt" 2>/dev/null || record_warning "BREW_LIST" "Failed to list brew packages" "transient"
    brew list --cask --versions > "$BACKUP_DIR/homebrew/brew-cask-list.txt" 2>/dev/null || record_warning "BREW_CASK" "Failed to list brew casks" "transient"
  else
    echo "  [dry-run] brew bundle dump / brew list"
  fi
  echo "  Brewfile and package lists saved."
else
  warn "Homebrew not found"
fi
echo "  Homebrew section took $((SECONDS - BREW_START))s"

end_step
fi

# ============================================================
# VOLTA
# ============================================================
if begin_step 10 "volta" "Backing up Volta package manifest"; then

if ! $DRY_RUN; then
  if command -v volta &>/dev/null; then
    volta list all --format=plain 2>/dev/null > "$BACKUP_DIR/volta/volta-list-all.txt" || record_warning "VOLTA_LIST" "Failed to list volta packages" "transient"

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

end_step
fi

# ============================================================
# MICROSOFT EDGE
# ============================================================
if begin_step 11 "edge" "Backing up Microsoft Edge profiles"; then

if [ ! -d "$EDGE_HOME" ]; then
  warn "Microsoft Edge not installed — skipping"
else
  # Capture open tabs via AppleScript if Edge is running
  if pgrep -x "Microsoft Edge" >/dev/null 2>&1; then
    warn "Microsoft Edge is running — backup may miss in-flight data"
    echo "  Capturing open tabs from running Edge..."
    if ! $DRY_RUN; then
      tabs_json=$(osascript -e '
        use AppleScript version "2.4"
        use scripting additions
        use framework "Foundation"
        tell application "Microsoft Edge"
          set winList to {}
          set winIdx to 1
          repeat with w in windows
            set tabList to {}
            repeat with t in tabs of w
              set end of tabList to "{\"url\":" & my jsonStr(URL of t) & ",\"title\":" & my jsonStr(title of t) & "}"
            end repeat
            set AppleScript'"'"'s text item delimiters to ","
            set end of winList to "{\"window\":" & winIdx & ",\"tabs\":[" & (tabList as text) & "]}"
            set winIdx to winIdx + 1
          end repeat
          set AppleScript'"'"'s text item delimiters to ","
          return "[" & (winList as text) & "]"
        end tell
        on jsonStr(val)
          set s to val as text
          set s to my replaceText(s, "\\", "\\\\")
          set s to my replaceText(s, "\"", "\\\"")
          set s to my replaceText(s, return, "\\n")
          return "\"" & s & "\""
        end jsonStr
        on replaceText(theText, old, new)
          set {TID, AppleScript'"'"'s text item delimiters} to {AppleScript'"'"'s text item delimiters, old}
          set parts to text items of theText
          set AppleScript'"'"'s text item delimiters to new
          set theText to parts as text
          set AppleScript'"'"'s text item delimiters to TID
          return theText
        end replaceText
      ' 2>/dev/null) && {
        echo "$tabs_json" | jq '.' > "$BACKUP_DIR/edge-browser/open-tabs.json"
        tab_count=$(echo "$tabs_json" | jq '[.[].tabs[]] | length')
        echo "  Saved $tab_count open tab(s) across $(echo "$tabs_json" | jq 'length') window(s)."
      } || warn "Failed to capture open tabs via AppleScript"
    else
      echo "  [dry-run] Would capture open tabs via AppleScript"
    fi
  else
    echo "  Edge is not running — skipping open tab capture"
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

end_step
fi

# ============================================================
# CURSOR IDE
# ============================================================
if begin_step 12 "cursor_ide" "Backing up Cursor IDE settings"; then

CURSOR_HOME="$HOME/Library/Application Support/Cursor"

if [ ! -d "$CURSOR_HOME/User" ]; then
  warn "Cursor IDE not installed or no User dir — skipping"
else
  copy_if_exists "$CURSOR_HOME/User/settings.json" "$BACKUP_DIR/cursor-ide/"
  copy_if_exists "$CURSOR_HOME/User/keybindings.json" "$BACKUP_DIR/cursor-ide/"

  if [ -d "$CURSOR_HOME/User/snippets" ]; then
    if ! $DRY_RUN; then
      cp -R "$CURSOR_HOME/User/snippets" "$BACKUP_DIR/cursor-ide/" 2>/dev/null || warn "Failed to copy Cursor snippets"
    else
      echo "  [dry-run] cp -R $CURSOR_HOME/User/snippets $BACKUP_DIR/cursor-ide/"
    fi
  fi

  # Extension list via CLI
  if [ -n "$CURSOR_CLI" ]; then
    if ! $DRY_RUN; then
      "$CURSOR_CLI" --list-extensions > "$BACKUP_DIR/cursor-ide/extensions.txt" 2>/dev/null || warn "Failed to list Cursor extensions via CLI"
    else
      echo "  [dry-run] $CURSOR_CLI --list-extensions > extensions.txt"
    fi
  elif [ -d "$HOME/.cursor/extensions" ]; then
    # Fallback: derive extension list from directory names
    if ! $DRY_RUN; then
      ls -1 "$HOME/.cursor/extensions/" > "$BACKUP_DIR/cursor-ide/extensions.txt" 2>/dev/null || warn "Failed to list Cursor extensions from directory"
    else
      echo "  [dry-run] ls ~/.cursor/extensions/ > extensions.txt"
    fi
  else
    warn "Cannot list Cursor extensions — CLI not in PATH and ~/.cursor/extensions not found"
  fi
fi

echo "  Cursor IDE done."

end_step
fi

# ============================================================
# DATABASE TOOLS (DataGrip + psql)
# ============================================================
if begin_step 13 "db_tools" "Backing up database tools config"; then

# --- DataGrip ---
DATAGRIP_BASE="$HOME/Library/Application Support/JetBrains"
DATAGRIP_HOME=""
if [ -d "$DATAGRIP_BASE" ]; then
  DATAGRIP_HOME=$(ls -1d "$DATAGRIP_BASE"/DataGrip* 2>/dev/null | sort -V | tail -1)
fi

if [ -z "$DATAGRIP_HOME" ] || [ ! -d "$DATAGRIP_HOME" ]; then
  warn "DataGrip not installed — skipping DataGrip section"
else
  DATAGRIP_VERSION=$(basename "$DATAGRIP_HOME")
  echo "  Found $DATAGRIP_VERSION"
  if ! $DRY_RUN; then
    echo "$DATAGRIP_VERSION" > "$BACKUP_DIR/db-tools/datagrip-version.txt"
  fi

  # Directories to copy
  for dir in options workspace consoles codestyles tasks jdbc-drivers; do
    if [ -d "$DATAGRIP_HOME/$dir" ]; then
      echo "  Backing up $dir..."
      if ! $DRY_RUN; then
        cp -R "$DATAGRIP_HOME/$dir" "$BACKUP_DIR/db-tools/datagrip/" 2>/dev/null || warn "Failed to copy DataGrip $dir"
      else
        echo "  [dry-run] cp -R $DATAGRIP_HOME/$dir $BACKUP_DIR/db-tools/datagrip/"
      fi
    fi
  done

  # Individual files
  for f in datagrip.vmoptions datagrip.key; do
    copy_if_exists "$DATAGRIP_HOME/$f" "$BACKUP_DIR/db-tools/datagrip/"
  done
fi

# --- psql / PostgreSQL client ---
echo "  Backing up psql settings..."
copy_if_exists "$HOME/.psqlrc" "$BACKUP_DIR/db-tools/psql/psqlrc"
copy_if_exists "$HOME/.psql_history" "$BACKUP_DIR/db-tools/psql/psql_history"
copy_if_exists "$HOME/.pgpass" "$BACKUP_DIR/db-tools/psql/pgpass"
copy_if_exists "$HOME/.pg_service.conf" "$BACKUP_DIR/db-tools/psql/pg_service.conf"

if [ -d "$HOME/.postgresql" ]; then
  if ! $DRY_RUN; then
    cp -R "$HOME/.postgresql" "$BACKUP_DIR/db-tools/psql/postgresql" 2>/dev/null || warn "Failed to copy ~/.postgresql"
  else
    echo "  [dry-run] cp -R $HOME/.postgresql $BACKUP_DIR/db-tools/psql/postgresql"
  fi
fi

echo "  Database tools done."

end_step
fi

# ============================================================
# DESKTOP APPS
# ============================================================
if begin_step 14 "desktop_apps" "Backing up desktop app preferences"; then

# iTerm2
if [ -f "$HOME/Library/Preferences/com.googlecode.iterm2.plist" ]; then
  if ! $DRY_RUN; then
    plutil -convert xml1 -o "$BACKUP_DIR/desktop-apps/iterm2-plist.xml" \
      "$HOME/Library/Preferences/com.googlecode.iterm2.plist" 2>/dev/null || warn "Failed to export iTerm2 plist"
  else
    echo "  [dry-run] plutil -convert xml1 iTerm2 plist"
  fi
  if [ -d "$HOME/Library/Application Support/iTerm2/DynamicProfiles" ]; then
    if ! $DRY_RUN; then
      cp -R "$HOME/Library/Application Support/iTerm2/DynamicProfiles" "$BACKUP_DIR/desktop-apps/" 2>/dev/null || warn "Failed to copy iTerm2 DynamicProfiles"
    else
      echo "  [dry-run] cp -R iTerm2/DynamicProfiles"
    fi
  fi
  echo "  iTerm2 preferences backed up."
else
  echo "  iTerm2 not found — skipping"
fi

# Warp
WARP_PLIST=""
if [ -f "$HOME/Library/Preferences/dev.warp.Warp-Stable.plist" ]; then
  WARP_PLIST="$HOME/Library/Preferences/dev.warp.Warp-Stable.plist"
elif [ -f "$HOME/Library/Preferences/dev.warp.Warp.plist" ]; then
  WARP_PLIST="$HOME/Library/Preferences/dev.warp.Warp.plist"
fi

if [ -n "$WARP_PLIST" ]; then
  if ! $DRY_RUN; then
    plutil -convert xml1 -o "$BACKUP_DIR/desktop-apps/warp-plist.xml" \
      "$WARP_PLIST" 2>/dev/null || warn "Failed to export Warp plist"
  else
    echo "  [dry-run] plutil -convert xml1 Warp plist"
  fi
  echo "  Warp preferences backed up."
else
  echo "  Warp not found — skipping"
fi

# Rectangle
if [ -f "$HOME/Library/Preferences/com.knewton.Rectangle.plist" ]; then
  if ! $DRY_RUN; then
    plutil -convert xml1 -o "$BACKUP_DIR/desktop-apps/rectangle-plist.xml" \
      "$HOME/Library/Preferences/com.knewton.Rectangle.plist" 2>/dev/null || warn "Failed to export Rectangle plist"
  else
    echo "  [dry-run] plutil -convert xml1 Rectangle plist"
  fi
  echo "  Rectangle preferences backed up."
else
  echo "  Rectangle not found — skipping"
fi

# User Fonts
if [ -d "$HOME/Library/Fonts" ] && [ "$(ls -A "$HOME/Library/Fonts" 2>/dev/null)" ]; then
  if ! $DRY_RUN; then
    tar -czf "$BACKUP_DIR/desktop-apps/user-fonts.tar.gz" -C "$HOME/Library" Fonts/ 2>/dev/null || warn "Failed to archive user fonts"
  else
    echo "  [dry-run] tar -czf user-fonts.tar.gz"
  fi
  echo "  User fonts backed up."
else
  echo "  No user fonts found — skipping"
fi

echo "  Desktop apps done."

end_step
fi

# ============================================================
# GITHUB REPOS
# ============================================================
if begin_step 15 "github_repos" "Backing up ~/GitHub repositories"; then

GITHUB_DIR="$HOME/GitHub"
if [ ! -d "$GITHUB_DIR" ]; then
  warn "~/GitHub directory not found — skipping"
else
  echo "  Archiving ~/GitHub (excluding node_modules, build artifacts, backups)..."
  if ! $DRY_RUN; then
    tar -czf "$BACKUP_DIR/github-repos/github.tar.gz" \
      --exclude='node_modules' \
      --exclude='.next' \
      --exclude='.venv' \
      --exclude='venv' \
      --exclude='__pycache__' \
      --exclude='.cache' \
      --exclude='dist' \
      --exclude='build' \
      --exclude='.turbo' \
      --exclude='.nyc_output' \
      --exclude='coverage' \
      --exclude='.DS_Store' \
      --exclude='workspace-backup/backups' \
      -C "$HOME" GitHub/ 2>/dev/null || {
        record_error "GITHUB_TAR" "Failed to archive ~/GitHub" "transient" "Check disk space and retry with --resume-from=github_repos"
        warn "Failed to archive ~/GitHub"
      }
    if [ -f "$BACKUP_DIR/github-repos/github.tar.gz" ]; then
      archive_size=$(du -sh "$BACKUP_DIR/github-repos/github.tar.gz" | cut -f1)
      echo "  ~/GitHub archived ($archive_size)"
    fi
  else
    echo "  [dry-run] tar -czf $BACKUP_DIR/github-repos/github.tar.gz -C $HOME GitHub/"
  fi
fi

end_step
fi

# ============================================================
# MANIFEST
# ============================================================
if begin_step 16 "manifest" "Generating manifest"; then

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
    "edge_browser": "$(du -sh "$BACKUP_DIR/edge-browser" 2>/dev/null | cut -f1)",
    "cursor_ide": "$(du -sh "$BACKUP_DIR/cursor-ide" 2>/dev/null | cut -f1)",
    "db_tools": "$(du -sh "$BACKUP_DIR/db-tools" 2>/dev/null | cut -f1)",
    "desktop_apps": "$(du -sh "$BACKUP_DIR/desktop-apps" 2>/dev/null | cut -f1)",
    "github_repos": "$(du -sh "$BACKUP_DIR/github-repos" 2>/dev/null | cut -f1)"
  }
}
MANIFEST
fi

end_step
fi

# ============================================================
# RESTORE GUIDE FOR THE BACKUP FOLDER
# ============================================================
if begin_step 17 "restore_guide" "Generating RESTORE-GUIDE.md"; then

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
If Edge was running during backup, \`edge-browser/open-tabs.json\` contains all open tab URLs and titles per window.

### Cursor IDE
- **settings.json**: Editor settings and preferences
- **keybindings.json**: Custom keyboard shortcuts
- **snippets/**: User-defined code snippets
- **extensions.txt**: List of installed extensions (via CLI or directory listing)

### Database Tools
- **DataGrip**: Settings (\`options/\`), data source configs (\`workspace/\`), SQL console history (\`consoles/\`), code styles, JDBC driver configs, JVM options, license key
- **psql**: \`.psqlrc\`, \`.psql_history\`, \`.pgpass\` (sensitive), \`.pg_service.conf\`, \`~/.postgresql/\` directory

### Desktop Apps
- **iTerm2**: Preferences plist (XML) + DynamicProfiles
- **Warp**: Preferences plist (XML)
- **Rectangle**: Preferences plist (XML)
- **User Fonts**: \`~/Library/Fonts/\` archive (tar.gz)

### GitHub Repos
- **github.tar.gz**: Full archive of \`~/GitHub/\` excluding node_modules, .venv, venv, .next, __pycache__, .cache, dist, build, .turbo, .nyc_output, coverage, .DS_Store, and workspace-backup/backups.

## SENSITIVE FILES
- \`codex-cli/auth.json\` — OAuth JWT + refresh tokens
- \`shell-env/ssh/id_ed25519\` — SSH private key
- \`shell-env/gh/hosts.yml\` — GitHub CLI auth
- \`shell-env/aws/credentials\` — AWS access keys and secrets
- \`shell-env/npmrc\` — npm registry auth tokens
- \`conductor/workspaces/**/*.env\` — Application secrets
- \`db-tools/datagrip/datagrip.key\` — DataGrip license key
- \`db-tools/psql/pgpass\` — PostgreSQL passwords
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

end_step
fi

# ============================================================
# COPY SCRIPTS INTO BACKUP
# ============================================================
if begin_step 18 "copy_scripts" "Copying scripts into backup"; then

run_cmd cp "$SCRIPT_DIR/backup.sh" "$BACKUP_DIR/"
if ! $DRY_RUN; then
  cp "$SCRIPT_DIR/restore.sh" "$BACKUP_DIR/" 2>/dev/null || warn "restore.sh not found next to backup.sh"
else
  echo "  [dry-run] cp restore.sh"
fi

end_step
fi

# ============================================================
# PERMISSIONS
# ============================================================
if begin_step 19 "permissions" "Setting permissions on sensitive files"; then

if ! $DRY_RUN; then
  chmod 600 "$BACKUP_DIR/codex-cli/auth.json" 2>/dev/null || record_warning "CHMOD" "auth.json not found for chmod" "transient"
  chmod 600 "$BACKUP_DIR/shell-env/ssh/id_ed25519" 2>/dev/null || record_warning "CHMOD" "SSH key not found for chmod" "transient"
  chmod 600 "$BACKUP_DIR/shell-env/gh/hosts.yml" 2>/dev/null || record_warning "CHMOD" "gh hosts.yml not found for chmod" "transient"
  chmod 600 "$BACKUP_DIR/shell-env/aws/credentials" 2>/dev/null || record_warning "CHMOD" "AWS credentials not found for chmod" "transient"
  chmod 600 "$BACKUP_DIR/shell-env/npmrc" 2>/dev/null || record_warning "CHMOD" "npmrc not found for chmod" "transient"
  chmod 600 "$BACKUP_DIR/db-tools/datagrip/datagrip.key" 2>/dev/null || record_warning "CHMOD" "DataGrip key not found for chmod" "transient"
  chmod 600 "$BACKUP_DIR/db-tools/psql/pgpass" 2>/dev/null || record_warning "CHMOD" "pgpass not found for chmod" "transient"
  find "$BACKUP_DIR/conductor/workspaces" -name "*.env" -exec chmod 600 {} \; 2>/dev/null || true
  find "$BACKUP_DIR/edge-browser" -name "History" -exec chmod 600 {} \; 2>/dev/null || true
  find "$BACKUP_DIR/edge-browser" -name "Web Data" -exec chmod 600 {} \; 2>/dev/null || true
else
  echo "  [dry-run] Would chmod 600 sensitive files"
fi

end_step
fi

# ============================================================
# VALIDATION
# ============================================================
echo ""
echo -e "${BOLD}Running post-backup validation...${NC}"

if ! $DRY_RUN; then
  # Check manifest.json exists and is valid JSON
  if [ -f "$BACKUP_DIR/manifest.json" ]; then
    if jq empty "$BACKUP_DIR/manifest.json" 2>/dev/null; then
      add_validation_check "manifest_json" "ok"
    else
      add_validation_check "manifest_json" "fail" "manifest.json is not valid JSON"
    fi
  else
    add_validation_check "manifest_json" "fail" "manifest.json not found"
  fi

  # Check critical directories exist
  for crit_dir in claude-code shell-env conductor; do
    if [ -d "$BACKUP_DIR/$crit_dir" ]; then
      add_validation_check "dir_${crit_dir}" "ok"
    else
      add_validation_check "dir_${crit_dir}" "fail" "$crit_dir directory missing"
    fi
  done

  # Check file count > 10
  val_file_count=$(find "$BACKUP_DIR" -type f | wc -l | tr -d ' ')
  if [ "$val_file_count" -gt 10 ]; then
    add_validation_check "file_count" "ok" "$val_file_count files"
  else
    add_validation_check "file_count" "fail" "Only $val_file_count files (expected >10)"
  fi

  # Check if validation passed
  if [ -n "$RESULTS_FILE" ]; then
    val_passed=$(jq -r '.validation.passed' "$RESULTS_FILE" 2>/dev/null || echo "true")
    if [ "$val_passed" = "false" ]; then
      echo -e "  ${RED}Validation failed — see results.json for details${NC}"
      exit_code=1
    else
      echo -e "  ${GREEN}All validation checks passed.${NC}"
    fi
  fi
else
  echo -e "  ${YELLOW}(skipped in dry-run mode)${NC}"
fi

# ============================================================
# DETERMINE EXIT CODE
# ============================================================
if [ -n "$RESULTS_FILE" ] && [ -f "$RESULTS_FILE" ]; then
  failed_count=$(jq -r '.summary.failed' "$RESULTS_FILE" 2>/dev/null || echo "0")
  if [ "$failed_count" -gt 0 ]; then
    exit_code=1
  fi
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
if $ENCRYPT && ! $DRY_RUN && [ "$exit_code" -eq 0 ]; then
  echo "Encrypting backup..."
  BACKUP_PARENT="$(dirname "$BACKUP_DIR")"
  BACKUP_BASENAME="$(basename "$BACKUP_DIR")"
  ENCRYPTED_FILE="$BACKUP_PARENT/${BACKUP_BASENAME}.zip"
  (cd "$BACKUP_PARENT" && zip -er "$ENCRYPTED_FILE" "$BACKUP_BASENAME/") || {
    echo "Encryption failed — unencrypted backup preserved at $BACKUP_DIR"
    exit "$exit_code"
  }
  rm -rf "$BACKUP_DIR"
  echo ""
  echo "  Encrypted: $ENCRYPTED_FILE"
  echo "  Size:      $(du -sh "$ENCRYPTED_FILE" | cut -f1)"
  echo ""
  echo "  Upload this .zip to Google Drive. The unencrypted folder has been deleted."
fi

if $ENCRYPT && $DRY_RUN; then
  echo "  [dry-run] Would encrypt backup to .zip and delete unencrypted folder"
fi

if ! $DRY_RUN && ! $ENCRYPT; then
  echo -e "  ${RED}WARNING: This backup contains SENSITIVE data:${NC}"
  echo "    - SSH private key (shell-env/ssh/id_ed25519)"
  echo "    - Codex OAuth tokens (codex-cli/auth.json)"
  echo "    - .env files with API keys (conductor/workspaces/**/*.env)"
  echo "    - GitHub CLI auth (shell-env/gh/hosts.yml)"
  echo "    - AWS credentials (shell-env/aws/credentials)"
  echo "    - npm auth tokens (shell-env/npmrc)"
  echo "    - DataGrip license key (db-tools/datagrip/datagrip.key)"
  echo "    - PostgreSQL passwords (db-tools/psql/pgpass)"
  echo "    - Edge browsing history and form data (edge-browser/*/History, Web Data)"
  echo ""
  echo -e "  ${RED}ENCRYPT BEFORE UPLOADING TO GOOGLE DRIVE.${NC}"
  echo "  Example: zip -er workspace-backup.zip $BACKUP_DIR"
  echo ""
fi

if ! $DRY_RUN && [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
  echo "Backup finished at $(date)" >> "$LOG_FILE"
fi

exit "$exit_code"
