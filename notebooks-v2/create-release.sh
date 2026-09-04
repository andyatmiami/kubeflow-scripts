#!/usr/bin/env bash
#
# create-release.sh — automate the kubeflow/notebooks (notebooks-v2) release process.
#
# Mirrors the procedure documented in releasing/README.md, but executes it against
# a scratch clone so that the caller's working repo is never touched.
#
# Highlights:
#   - Dry-run by default; --execute is required for any mutating action.
#   - Every remote-mutating action requires explicit confirmation.
#   - Cherry-picks (patch releases) are applied one-by-one and pushed as a
#     single fast-forward; conflicts pause with a clear recovery menu.
#   - Signed tag creation is guarded by a HEAD-commit-message check.
#   - GitHub release is always created as a --draft; the human publishes.
#
# See releasing/README.md in kubeflow/notebooks for the manual procedure.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

UPSTREAM_URL="git@github.com:kubeflow/notebooks.git"
UPSTREAM_REPO="kubeflow/notebooks"
MAIN_BRANCH="notebooks-v2"
DEPLOY_GUIDE_URL="https://www.kubeflow.org/docs/components/workspaces/operator-guides/deployment-guide/"

# The four files that a "chore: Release X" commit is allowed to touch.
EXPECTED_DIFF_FILES=(
  "releasing/version/VERSION"
  "workspaces/backend/manifests/kustomize/base/kustomization.yaml"
  "workspaces/controller/manifests/kustomize/base/manager/kustomization.yaml"
  "workspaces/frontend/manifests/kustomize/base/kustomization.yaml"
)

# Ordered list of phases; used for --only validation and default execution order.
PHASES=(
  preflight
  clone
  prepare_branch
  cherry_pick
  bump_version_and_manifests
  open_release_pr
  wait_for_merge
  tag_release
  draft_github_release
)

# ---------------------------------------------------------------------------
# Colors + logging
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  BOLD=$'\033[1m'
  NC=$'\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

log_info()  { echo "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo; echo "${BOLD}${BLUE}==> $*${NC}"; }
log_dry()   { echo "${YELLOW}[DRY-RUN]${NC} $*"; }

die() { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Global state (populated by parse_args / parse_version)
# ---------------------------------------------------------------------------

VERSION=""
REMOTE="origin"
EXECUTE=false
CLEAN=false
KEEP=false
ONLY=""
FROM=""

# Derived from VERSION:
RELEASE_TYPE=""       # alpha | beta | rc | ga
IS_PRERELEASE=false
MAJOR="" MINOR="" PATCH=""
SUFFIX_STAGE=""       # alpha | beta | rc | ""
SUFFIX_NUM=""         # integer or ""
RELEASE_BRANCH=""     # e.g. v2.0-alpha-branch
HEAD_BRANCH=""        # e.g. chore/alpha.3-files
PR_TITLE=""           # e.g. chore: Release v2.0.0-alpha.3

# Paths:
BASE_DIR=""           # ~/.cache/kubeflow-release/<version>
SCRATCH_DIR=""        # $BASE_DIR/notebooks
STATE_LOG=""          # $BASE_DIR/state.log
CHERRY_STATE=""       # $BASE_DIR/cherry-pick.json

# Detected at runtime:
BRANCH_EXISTS_ON_REMOTE=false

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

# Runs a command respecting dry-run mode.
# Usage: run <cmd> [args...]
run() {
  if $EXECUTE; then
    "$@"
  else
    log_dry "$*"
  fi
}

# Append a line to the state log (mutations only).
# Usage: log_mutation "<description>" "<undo hint>"
log_mutation() {
  local desc="$1"
  local undo="${2:-}"
  if $EXECUTE; then
    {
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $desc"
      if [[ -n "$undo" ]]; then
        echo "    undo: $undo"
      fi
    } >> "$STATE_LOG"
  fi
}

# Soft confirmation (default no). Auto-accepted in dry-run mode since dry-run
# has no mutations to guard. In execute mode, always interactive.
# Usage: confirm "<prompt>"
confirm() {
  local prompt="$1"
  if ! $EXECUTE; then
    log_info "confirm (dry-run auto-accept): $prompt"
    return 0
  fi
  local reply
  read -r -p "${YELLOW}${prompt} [y/N]: ${NC}" reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Hard confirmation — requires typing 'yes' verbatim. Always interactive in
# execute mode; auto-accepted in dry-run for walkthrough purposes.
# Used for the truly destructive remote pushes (tag push, cherry-pick push).
# Usage: confirm_hard "<prompt>"
confirm_hard() {
  local prompt="$1"
  if ! $EXECUTE; then
    log_info "hard-confirm (dry-run auto-accept): $prompt"
    return 0
  fi
  local reply
  read -r -p "${RED}${BOLD}${prompt}${NC} ${YELLOW}(type 'yes' to confirm): ${NC}" reply
  [[ "$reply" == "yes" ]]
}

# Ensures a command is available on PATH.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
${BOLD}create-release.sh${NC} — automate kubeflow/notebooks (notebooks-v2) releases.

${BOLD}Usage:${NC}
  create-release.sh --version <vX.Y.Z[-alpha.N|-beta.N|-rc.N]> [options]

${BOLD}Required:${NC}
  --version <v...>       Release version (e.g. v2.0.0-alpha.3, v2.0.0, v2.0.1).

${BOLD}Options:${NC}
  --remote <name>        Git remote name inside the scratch clone (default: origin).
  --execute              Actually perform mutations. Without this, dry-run only.
                         In dry-run, all confirmations are auto-accepted for
                         walkthrough purposes.
                         In execute mode, every confirmation is interactive:
                           - Soft prompts:  [y/N]
                           - Hard prompts:  must type 'yes' verbatim
                                            (used for tag push and cherry-pick push)
  --clean                Wipe any existing scratch dir for this version before cloning.
  --keep                 Do not offer to remove the scratch dir on success.
  --only <phase>         Run only one phase (for recovery). One of:
                           ${PHASES[*]}
  --from <phase>         Run from the given phase through the end (for resume
                         after a mid-run failure). Same phase names as --only.
                         Mutually exclusive with --only.
  -h, --help             Show this help.

${BOLD}Naming derived from --version:${NC}
  v2.0.0-alpha.N -> branch v2.0-alpha-branch, head chore/alpha.N-files
  v2.0.0-beta.N  -> branch v2.0-beta-branch,  head chore/beta.N-files
  v2.0.0-rc.N    -> branch v2.0-branch,       head chore/rc.N-files
  v2.0.Z         -> branch v2.0-branch,       head chore/2.0.Z-files

${BOLD}Examples:${NC}
  # dry-run a fresh alpha release
  create-release.sh --version v2.0.0-alpha.4

  # actually execute it
  create-release.sh --version v2.0.0-alpha.4 --execute

  # resume from a failed tag phase
  create-release.sh --version v2.0.0-alpha.4 --execute --only tag_release

EOF
}

# ---------------------------------------------------------------------------
# Argument parsing + version derivation
# ---------------------------------------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)   VERSION="${2:-}"; shift 2 ;;
      --remote)    REMOTE="${2:-}";  shift 2 ;;
      --execute)   EXECUTE=true;      shift ;;
      --clean)     CLEAN=true;        shift ;;
      --keep)      KEEP=true;         shift ;;
      --only)      ONLY="${2:-}";    shift 2 ;;
      --from)      FROM="${2:-}";    shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      *)           usage; die "unknown argument: $1" ;;
    esac
  done

  [[ -n "$VERSION" ]] || { usage; die "--version is required"; }

  [[ -n "$ONLY" && -n "$FROM" ]] && die "--only and --from are mutually exclusive"

  local validate_phase=""
  if [[ -n "$ONLY" ]]; then validate_phase="$ONLY"; fi
  if [[ -n "$FROM" ]]; then validate_phase="$FROM"; fi
  if [[ -n "$validate_phase" ]]; then
    local ok=false
    for p in "${PHASES[@]}"; do [[ "$p" == "$validate_phase" ]] && ok=true; done
    $ok || die "phase '$validate_phase' is not a known phase. Known: ${PHASES[*]}"
  fi
}

parse_version() {
  local re='^v([0-9]+)\.([0-9]+)\.([0-9]+)(-(alpha|beta|rc)\.([0-9]+))?$'
  [[ "$VERSION" =~ $re ]] || die "invalid --version '$VERSION' (expected e.g. v2.0.0-alpha.3, v2.0.0, v2.0.1)"

  MAJOR="${BASH_REMATCH[1]}"
  MINOR="${BASH_REMATCH[2]}"
  PATCH="${BASH_REMATCH[3]}"
  SUFFIX_STAGE="${BASH_REMATCH[5]:-}"
  SUFFIX_NUM="${BASH_REMATCH[6]:-}"

  if [[ -n "$SUFFIX_STAGE" ]]; then
    RELEASE_TYPE="$SUFFIX_STAGE"
    IS_PRERELEASE=true
    case "$SUFFIX_STAGE" in
      alpha|beta) RELEASE_BRANCH="v${MAJOR}.${MINOR}-${SUFFIX_STAGE}-branch" ;;
      rc)         RELEASE_BRANCH="v${MAJOR}.${MINOR}-branch" ;;
    esac
    HEAD_BRANCH="chore/${SUFFIX_STAGE}.${SUFFIX_NUM}-files"
  else
    RELEASE_TYPE="ga"
    IS_PRERELEASE=false
    RELEASE_BRANCH="v${MAJOR}.${MINOR}-branch"
    HEAD_BRANCH="chore/${MAJOR}.${MINOR}.${PATCH}-files"
  fi

  PR_TITLE="chore: Release ${VERSION}"

  BASE_DIR="${HOME}/.cache/kubeflow-release/${VERSION}"
  SCRATCH_DIR="${BASE_DIR}/notebooks"
  STATE_LOG="${BASE_DIR}/state.log"
  CHERRY_STATE="${BASE_DIR}/cherry-pick.json"
}

print_config() {
  cat <<EOF
${BOLD}Release configuration${NC}
  version         : $VERSION
  type            : $RELEASE_TYPE  (prerelease=$IS_PRERELEASE)
  release branch  : $RELEASE_BRANCH
  head branch     : $HEAD_BRANCH
  PR title        : $PR_TITLE
  upstream repo   : $UPSTREAM_REPO
  remote name     : $REMOTE
  scratch dir     : $SCRATCH_DIR
  execute         : $EXECUTE   (dry-run when false)
  only            : ${ONLY:-<none>}
  from            : ${FROM:-<none>}
EOF
}

# ---------------------------------------------------------------------------
# Phase: preflight
# ---------------------------------------------------------------------------

phase_preflight() {
  log_step "preflight — checking tools, auth, and preconditions"

  require_cmd git
  require_cmd gh
  require_cmd python3
  require_cmd jq
  require_cmd curl

  # gh auth
  if ! gh auth status >/dev/null 2>&1; then
    die "'gh auth status' failed; run 'gh auth login' first"
  fi
  log_info "gh CLI authenticated"

  # Signing capability — support both GPG and SSH signing formats.
  local signing_key sig_format
  signing_key="$(git config --global --get user.signingkey || true)"
  [[ -n "$signing_key" ]] || die "git config user.signingkey is not set (required for signed tags/commits)"
  sig_format="$(git config --global --get gpg.format || echo openpgp)"

  case "$sig_format" in
    ssh)
      require_cmd ssh-keygen
      # For SSH signing, user.signingkey is either a path to a public key file
      # or a literal "key ..." string. If it's a path, verify it exists.
      if [[ "$signing_key" == /* || "$signing_key" == ~* ]]; then
        local expanded="${signing_key/#\~/$HOME}"
        [[ -f "$expanded" ]] || die "SSH signing key file not found: $expanded"
      fi
      # Require gpg.ssh.allowedSignersFile so that git verify-tag can attribute
      # the signature to a principal (otherwise verify-tag fails with
      # "No principal matched" even for cryptographically valid signatures).
      local allowed_signers
      allowed_signers="$(git config --global --get gpg.ssh.allowedSignersFile || true)"
      [[ -n "$allowed_signers" ]] \
        || die "SSH signing requires 'git config --global gpg.ssh.allowedSignersFile <path>' to be set (needed for 'git verify-tag' to succeed)"
      local allowed_expanded="${allowed_signers/#\~/$HOME}"
      [[ -f "$allowed_expanded" ]] \
        || die "gpg.ssh.allowedSignersFile points to $allowed_signers but that file does not exist"
      # Sanity: the signing key's public material must appear in the allowed_signers file.
      # Extract the public key text from either a .pub file or a literal "key ..." value.
      local pubkey_line=""
      if [[ "$signing_key" == /* || "$signing_key" == ~* ]]; then
        local key_expanded="${signing_key/#\~/$HOME}"
        pubkey_line="$(awk '{print $1" "$2}' "$key_expanded" 2>/dev/null || true)"
      else
        pubkey_line="$(awk '{print $1" "$2}' <<<"$signing_key")"
      fi
      if [[ -n "$pubkey_line" ]] && ! grep -qF -- "$pubkey_line" "$allowed_expanded"; then
        die "signing key not found in $allowed_signers — add a line like:
    <your-email>  $pubkey_line"
      fi
      log_info "signing configured: format=ssh key=$signing_key allowed_signers=$allowed_signers"
      ;;
    openpgp|"")
      require_cmd gpg
      if ! echo "test" | gpg --local-user "$signing_key" --clearsign >/dev/null 2>&1; then
        die "GPG cannot sign with key '$signing_key' (check gpg-agent / pinentry)"
      fi
      log_info "signing configured: format=openpgp key=$signing_key"
      ;;
    *)
      die "unsupported gpg.format='$sig_format' (expected 'openpgp' or 'ssh')"
      ;;
  esac

  # Verify the release tag does not already exist upstream.
  if git ls-remote --tags "$UPSTREAM_URL" "refs/tags/$VERSION" | grep -q .; then
    die "tag $VERSION already exists on $UPSTREAM_REPO — refusing to proceed"
  fi
  log_info "tag $VERSION does not yet exist upstream"

  # Detect whether the release branch already exists on remote (drives branch/cherry-pick logic).
  if git ls-remote --heads "$UPSTREAM_URL" "refs/heads/$RELEASE_BRANCH" | grep -q .; then
    BRANCH_EXISTS_ON_REMOTE=true
    log_info "release branch $RELEASE_BRANCH exists on upstream (patch/subsequent release path)"
  else
    BRANCH_EXISTS_ON_REMOTE=false
    log_info "release branch $RELEASE_BRANCH does NOT exist on upstream (new-branch path)"
    # Only allow new-branch when this is the first release on that line.
    local first_ok=false
    if [[ -n "$SUFFIX_STAGE" ]]; then
      [[ "$SUFFIX_NUM" == "0" ]] && first_ok=true
    else
      [[ "$PATCH" == "0" ]] && first_ok=true
    fi
    $first_ok || die "release branch $RELEASE_BRANCH is missing but $VERSION is not a '.0' release — refusing to create branch mid-line"
  fi

  log_info "preflight OK"
}

# ---------------------------------------------------------------------------
# Phase: clone
# ---------------------------------------------------------------------------

phase_clone() {
  log_step "clone — preparing scratch clone at $SCRATCH_DIR"

  if [[ -d "$SCRATCH_DIR" ]]; then
    if $CLEAN; then
      log_warn "removing existing scratch dir (--clean): $BASE_DIR"
      run rm -rf "$BASE_DIR"
    else
      die "scratch dir exists: $BASE_DIR
    - pass --clean to wipe it and start over, or
    - pass --only <phase> to resume from a specific step."
    fi
  fi

  run mkdir -p "$BASE_DIR"
  run git clone --origin "$REMOTE" "$UPSTREAM_URL" "$SCRATCH_DIR"
  log_mutation "cloned $UPSTREAM_URL into $SCRATCH_DIR" "rm -rf $BASE_DIR"

  if $EXECUTE; then
    cd "$SCRATCH_DIR"
    git fetch --tags "$REMOTE"

    # Verify main branch exists.
    git rev-parse --verify "$REMOTE/$MAIN_BRANCH" >/dev/null \
      || die "main branch $REMOTE/$MAIN_BRANCH not found in clone"

    # Prepare venv for ruamel.yaml (used by update-manifests-images.py).
    log_info "creating venv and installing ruamel.yaml"
    python3 -m venv .venv
    # shellcheck disable=SC1091
    source .venv/bin/activate
    pip install --quiet --upgrade pip
    pip install --quiet ruamel.yaml
    deactivate
  else
    log_dry "cd $SCRATCH_DIR && git fetch --tags $REMOTE"
    log_dry "python3 -m venv .venv && pip install ruamel.yaml"
  fi

  log_info "clone phase complete"
}

# Helper: cd into the scratch clone. Fails cleanly if it's not there.
# In dry-run mode, if the scratch clone doesn't exist, returns non-zero so the
# caller can print a summary and skip. In execute mode, missing clone is fatal.
enter_scratch() {
  if [[ -d "$SCRATCH_DIR/.git" ]]; then
    cd "$SCRATCH_DIR"
    return 0
  fi
  if $EXECUTE; then
    die "scratch clone not found at $SCRATCH_DIR (run 'clone' phase first)"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Phase: prepare_branch (new-branch path only)
# ---------------------------------------------------------------------------

phase_prepare_branch() {
  if $BRANCH_EXISTS_ON_REMOTE; then
    log_info "prepare_branch: skipped (release branch already exists on remote)"
    return 0
  fi

  log_step "prepare_branch — creating $RELEASE_BRANCH from $REMOTE/$MAIN_BRANCH"

  if ! enter_scratch; then
    log_dry "would create $RELEASE_BRANCH from $REMOTE/$MAIN_BRANCH and push"
    BRANCH_EXISTS_ON_REMOTE=true
    return 0
  fi
  if $EXECUTE; then
    git fetch "$REMOTE"
    local base_sha
    base_sha="$(git rev-parse "$REMOTE/$MAIN_BRANCH")"
    log_info "base commit for new release branch: $base_sha"
    git checkout -b "$RELEASE_BRANCH" "$REMOTE/$MAIN_BRANCH"
  else
    log_dry "git checkout -b $RELEASE_BRANCH $REMOTE/$MAIN_BRANCH"
  fi

  if confirm "push new release branch $RELEASE_BRANCH to $REMOTE?"; then
    run git push "$REMOTE" "$RELEASE_BRANCH"
    log_mutation "pushed new release branch $RELEASE_BRANCH" \
      "git push $REMOTE --delete $RELEASE_BRANCH"
  else
    die "release branch push declined; cannot proceed"
  fi

  BRANCH_EXISTS_ON_REMOTE=true
  log_info "release branch ready"
}

# ---------------------------------------------------------------------------
# Phase: cherry_pick (existing-branch path only)
# ---------------------------------------------------------------------------

# Determine and confirm the "starting point" (previous tag) used to compute
# cherry-pick candidates.
resolve_starting_point() {
  local guessed=""
  guessed="$(git describe --tags --abbrev=0 --match 'v*' "$REMOTE/$RELEASE_BRANCH" 2>/dev/null || true)"

  # Show context
  echo
  log_info "Computed starting point: ${guessed:-<none found>}"
  if [[ -n "$guessed" ]]; then
    local sha date subj
    sha="$(git rev-list -n1 "$guessed")"
    date="$(git log -1 --pretty=%ai "$guessed")"
    subj="$(git log -1 --pretty=%s "$guessed")"
    echo "    tagged commit : $sha  \"$subj\""
    echo "    tagged on     : $date"
  fi
  echo "    recent tags on $RELEASE_BRANCH:"
  git tag --list --sort=-v:refname --merged "$REMOTE/$RELEASE_BRANCH" 'v*' \
    | head -10 | sed 's/^/      /'

  local ahead
  ahead="$(git rev-list --count "${guessed:-$REMOTE/$RELEASE_BRANCH}..$REMOTE/$MAIN_BRANCH" 2>/dev/null || echo 0)"
  echo "    commits on $MAIN_BRANCH ahead of starting point : $ahead"
  echo

  local chosen="$guessed"
  local reply
  while true; do
    read -r -p "${YELLOW}Use '${chosen}' as starting point?  [Y] yes  [n] no, enter different  [q] abort: ${NC}" reply
    reply="${reply:-y}"
    case "$reply" in
      [Yy]|[Yy][Ee][Ss])
        [[ -n "$chosen" ]] || { log_warn "no default; please supply a value"; reply=n; }
        [[ "$reply" != "n" ]] && break ;;
      [Nn]|[Nn][Oo])
        read -r -p "  Enter tag or full 40-char SHA: " chosen
        if [[ "$chosen" =~ ^[0-9a-f]{40}$ ]]; then
          git rev-parse --verify "$chosen^{commit}" >/dev/null 2>&1 \
            || { log_warn "SHA not found in clone"; continue; }
        else
          git rev-parse --verify "refs/tags/$chosen" >/dev/null 2>&1 \
            || { log_warn "tag $chosen not found"; continue; }
        fi
        git merge-base --is-ancestor "$chosen" "$REMOTE/$RELEASE_BRANCH" \
          || { log_warn "$chosen is not an ancestor of $REMOTE/$RELEASE_BRANCH"; continue; }
        ;;
      [Qq]) die "aborted by user at starting-point selection" ;;
      *) : ;;
    esac
  done

  STARTING_POINT="$chosen"
  log_info "starting point confirmed: $STARTING_POINT"
  log_mutation "cherry-pick starting point: $STARTING_POINT" ""
}

# Compute candidates and let the user select which ones to cherry-pick.
select_cherry_picks() {
  # Candidates: commits on notebooks-v2 that are reachable from $REMOTE/$MAIN_BRANCH
  # but not from $REMOTE/$RELEASE_BRANCH, since the starting point.
  local candidates=()
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    candidates+=("$sha")
  done < <(git log --no-merges --reverse --pretty='%H' \
             "$STARTING_POINT..$REMOTE/$MAIN_BRANCH" \
             "^$REMOTE/$RELEASE_BRANCH")

  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_warn "no candidate commits found on $MAIN_BRANCH since $STARTING_POINT that aren't already on $RELEASE_BRANCH"
    SELECTED=()
    return 0
  fi

  echo
  log_info "candidate commits (${#candidates[@]}):"
  local i=1
  for sha in "${candidates[@]}"; do
    local subj author rel
    subj="$(git log -1 --pretty=%s "$sha")"
    author="$(git log -1 --pretty='%an' "$sha")"
    rel="$(git log -1 --pretty='%ar' "$sha")"
    printf "  %3d. %s  %s  (${BLUE}%s${NC}, %s)\n" \
      "$i" "${sha:0:8}" "$subj" "$author" "$rel"
    i=$((i+1))
  done
  echo

  local input
  read -r -p "${YELLOW}Select: comma-separated numbers, ranges (1-3), 'all', or 'none': ${NC}" input
  [[ -n "$input" ]] || die "no selection made"

  SELECTED=()
  case "$input" in
    all)  SELECTED=("${candidates[@]}") ;;
    none) SELECTED=() ;;
    *)
      local IFS=','
      for token in $input; do
        token="${token// /}"
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
          local lo="${BASH_REMATCH[1]}" hi="${BASH_REMATCH[2]}"
          (( lo >= 1 && hi <= ${#candidates[@]} && lo <= hi )) \
            || die "invalid range: $token"
          for ((n=lo; n<=hi; n++)); do SELECTED+=("${candidates[$((n-1))]}"); done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
          (( token >= 1 && token <= ${#candidates[@]} )) \
            || die "invalid index: $token"
          SELECTED+=("${candidates[$((token-1))]}")
        else
          die "invalid selection token: $token"
        fi
      done
      ;;
  esac

  if [[ ${#SELECTED[@]} -eq 0 ]]; then
    log_warn "no commits selected"
    return 0
  fi

  echo
  log_info "you selected ${#SELECTED[@]} commit(s):"
  for sha in "${SELECTED[@]}"; do
    echo "    ${sha:0:8}  $(git log -1 --pretty=%s "$sha")"
  done
  echo
  confirm "proceed with these ${#SELECTED[@]} cherry-pick(s)?" \
    || die "cherry-pick selection declined"
}

# Apply cherry-picks one at a time; halt cleanly on conflict.
apply_cherry_picks() {
  local applied=() remaining=("${SELECTED[@]}")
  local i=0 total=${#SELECTED[@]}
  for sha in "${SELECTED[@]}"; do
    i=$((i+1))
    local subj
    subj="$(git log -1 --pretty=%s "$sha")"
    log_info "[$i/$total] cherry-picking ${sha:0:8}  $subj"

    if $EXECUTE; then
      if ! git cherry-pick "$sha"; then
        # Conflict: pause with recovery menu.
        echo
        log_error "cherry-pick of $sha failed with conflicts"
        echo
        echo "  scratch clone : $SCRATCH_DIR"
        echo "  applied so far: ${applied[*]:-<none>}"
        echo "  failed        : $sha"
        remaining=("${remaining[@]:1}")
        echo "  remaining     : ${remaining[*]:-<none>}"
        echo
        cat <<EOF
Recovery options:

  A) Abort THIS commit and skip it, keep the rest:
       cd "$SCRATCH_DIR"
       git cherry-pick --abort
       # then re-run with an updated selection, e.g.:
       $0 --version $VERSION --execute --only cherry_pick

  B) Resolve manually in the scratch clone, then continue:
       cd "$SCRATCH_DIR"
       # edit conflicting files, then:
       git add <files>
       git cherry-pick --continue
       # apply any remaining commits by hand (git cherry-pick <sha>),
       # then re-run: $0 --version $VERSION --execute --only bump_version_and_manifests

  C) Abort the whole release:
       $0 --version $VERSION --clean
EOF
        die "cherry-pick paused for manual intervention"
      fi
      applied+=("$sha")
      remaining=("${remaining[@]:1}")
    else
      log_dry "git cherry-pick $sha"
      applied+=("$sha")
    fi
  done

  # Persist applied list.
  if $EXECUTE && [[ ${#applied[@]} -gt 0 ]]; then
    printf '%s\n' "${applied[@]}" | jq -R -s -c 'split("\n")|map(select(length>0))' \
      > "$CHERRY_STATE" || true
    log_mutation "applied cherry-picks: ${applied[*]}" ""
  fi
}

phase_cherry_pick() {
  if ! $BRANCH_EXISTS_ON_REMOTE; then
    log_info "cherry_pick: skipped (new release branch has no history to patch)"
    return 0
  fi

  log_step "cherry_pick — computing candidates for patch release"

  if ! enter_scratch; then
    log_dry "would resolve starting point, compute candidates, apply selected cherry-picks, and fast-forward push $RELEASE_BRANCH"
    return 0
  fi
  if $EXECUTE; then
    git fetch "$REMOTE"
    git checkout "$RELEASE_BRANCH" 2>/dev/null || git checkout -b "$RELEASE_BRANCH" "$REMOTE/$RELEASE_BRANCH"
    git reset --hard "$REMOTE/$RELEASE_BRANCH"
  else
    log_dry "git checkout $RELEASE_BRANCH && git reset --hard $REMOTE/$RELEASE_BRANCH"
  fi

  local STARTING_POINT=""
  local SELECTED=()
  resolve_starting_point
  select_cherry_picks

  if [[ ${#SELECTED[@]} -eq 0 ]]; then
    log_info "no cherry-picks to apply; skipping push"
    return 0
  fi

  apply_cherry_picks

  # Pre-push review
  echo
  log_info "commits about to be pushed to $REMOTE/$RELEASE_BRANCH:"
  if $EXECUTE; then
    git log --oneline "$REMOTE/$RELEASE_BRANCH..HEAD" | sed 's/^/    /'
  else
    log_dry "git log --oneline $REMOTE/$RELEASE_BRANCH..HEAD"
  fi
  echo

  confirm_hard "PUSH ${#SELECTED[@]} cherry-picked commit(s) directly to $REMOTE/$RELEASE_BRANCH?" \
    || die "cherry-pick push declined"

  # Plain fast-forward push (no --force) — fails cleanly if remote moved.
  run git push "$REMOTE" "$RELEASE_BRANCH"
  log_mutation "fast-forward pushed ${#SELECTED[@]} cherry-picks to $RELEASE_BRANCH" \
    "manually inspect and revert commits on $RELEASE_BRANCH"

  log_info "cherry-picks pushed"
}

# ---------------------------------------------------------------------------
# Phase: bump_version_and_manifests
# ---------------------------------------------------------------------------

phase_bump_version_and_manifests() {
  log_step "bump_version_and_manifests — write VERSION, update image tags"

  if ! enter_scratch; then
    log_dry "would checkout $RELEASE_BRANCH, create $HEAD_BRANCH, write VERSION=$VERSION, run update-manifests-images.py, diff-guard, then commit '$PR_TITLE'"
    return 0
  fi

  if $EXECUTE; then
    git fetch "$REMOTE"
    git checkout "$RELEASE_BRANCH" 2>/dev/null || git checkout -b "$RELEASE_BRANCH" "$REMOTE/$RELEASE_BRANCH"
    git reset --hard "$REMOTE/$RELEASE_BRANCH"

    # Create the head branch that will host the release PR.
    if git rev-parse --verify "$HEAD_BRANCH" >/dev/null 2>&1; then
      log_warn "local branch $HEAD_BRANCH already exists; deleting"
      git branch -D "$HEAD_BRANCH"
    fi
    git checkout -b "$HEAD_BRANCH"

    echo "$VERSION" > releasing/version/VERSION

    # shellcheck disable=SC1091
    source .venv/bin/activate
    python3 releasing/update-manifests-images.py
    deactivate
  else
    log_dry "checkout $RELEASE_BRANCH && reset --hard $REMOTE/$RELEASE_BRANCH"
    log_dry "checkout -b $HEAD_BRANCH"
    log_dry "echo $VERSION > releasing/version/VERSION"
    log_dry "python3 releasing/update-manifests-images.py"
    log_info "bump phase in dry-run: skipping diff-guard (no changes actually made)"
    return 0
  fi

  # Diff-guard: only the 4 expected files may have changed.
  local changed
  changed="$(git diff --name-only)"
  log_info "changed files:"
  echo "$changed" | sed 's/^/    /'

  local expected_sorted actual_sorted
  expected_sorted="$(printf '%s\n' "${EXPECTED_DIFF_FILES[@]}" | sort)"
  actual_sorted="$(printf '%s\n' "$changed" | sort)"
  if [[ "$expected_sorted" != "$actual_sorted" ]]; then
    log_error "diff-guard FAILED — unexpected file set"
    log_error "expected:"; echo "$expected_sorted" | sed 's/^/    /' >&2
    log_error "actual:";   echo "$actual_sorted"   | sed 's/^/    /' >&2
    die "aborting to avoid a bad release commit"
  fi
  log_info "diff-guard OK (exactly the 4 expected files changed)"

  echo
  git diff --stat
  echo

  confirm "commit these changes as '$PR_TITLE' (signed off)?" \
    || die "release commit declined"

  run git add "${EXPECTED_DIFF_FILES[@]}"
  run git commit -s -m "$PR_TITLE"
  log_mutation "created release commit on $HEAD_BRANCH: $PR_TITLE" \
    "git branch -D $HEAD_BRANCH"
}

# ---------------------------------------------------------------------------
# Phase: open_release_pr
# ---------------------------------------------------------------------------

phase_open_release_pr() {
  log_step "open_release_pr — pushing $HEAD_BRANCH and opening PR"

  if ! enter_scratch; then
    log_dry "would push $HEAD_BRANCH to $REMOTE and open PR '$PR_TITLE' into $RELEASE_BRANCH"
    return 0
  fi

  if $EXECUTE; then
    git rev-parse --verify "$HEAD_BRANCH" >/dev/null \
      || die "expected local branch $HEAD_BRANCH not found (was bump phase skipped?)"
    git checkout "$HEAD_BRANCH"
  fi

  confirm "push $HEAD_BRANCH to $REMOTE and open PR into $RELEASE_BRANCH?" \
    || die "PR push declined"

  run git push --set-upstream "$REMOTE" "$HEAD_BRANCH"
  log_mutation "pushed $HEAD_BRANCH to $REMOTE" \
    "git push $REMOTE --delete $HEAD_BRANCH"

  local body
  body=$(cat <<EOF
This PR bumps the release version to \`$VERSION\` and updates the image tags in
the workspaces component kustomizations.

Merging this PR triggers the release build; a signed tag will be created after
merge by the release operator.

Generated by \`create-release.sh\`.
EOF
  )

  if $EXECUTE; then
    gh pr create \
      --repo "$UPSTREAM_REPO" \
      --base "$RELEASE_BRANCH" \
      --head "$HEAD_BRANCH" \
      --title "$PR_TITLE" \
      --body "$body"
    log_mutation "opened release PR ($PR_TITLE)" "gh pr close --repo $UPSTREAM_REPO <n>"

    PR_NUMBER="$(gh pr list --repo "$UPSTREAM_REPO" \
                   --head "$HEAD_BRANCH" --state open \
                   --json number -q '.[0].number')"
    log_info "release PR opened: https://github.com/$UPSTREAM_REPO/pull/${PR_NUMBER}"
  else
    log_dry "gh pr create --base $RELEASE_BRANCH --head $HEAD_BRANCH --title '$PR_TITLE'"
  fi
}

# ---------------------------------------------------------------------------
# Phase: wait_for_merge
# ---------------------------------------------------------------------------

phase_wait_for_merge() {
  log_step "wait_for_merge — waiting for PR to be merged (poll every 30s)"

  if ! $EXECUTE; then
    log_dry "poll gh pr view until merged"
    return 0
  fi

  enter_scratch
  pr_number="$(gh pr list --repo "$UPSTREAM_REPO" \
                 --head "$HEAD_BRANCH" --state all \
                 --json number -q '.[0].number' 2>/dev/null || true)"
  [[ -n "$pr_number" ]] || die "could not locate PR for head branch $HEAD_BRANCH"

  log_info "watching PR #$pr_number — review CI, then merge in the GitHub UI"
  log_info "URL: https://github.com/$UPSTREAM_REPO/pull/$pr_number"

  while true; do
    local state merged_at
    state="$(gh pr view "$pr_number" --repo "$UPSTREAM_REPO" --json state -q .state)"
    merged_at="$(gh pr view "$pr_number" --repo "$UPSTREAM_REPO" --json mergedAt -q .mergedAt)"
    case "$state" in
      MERGED)
        log_info "PR #$pr_number merged at $merged_at"
        return 0
        ;;
      CLOSED)
        die "PR #$pr_number was closed without merging — aborting"
        ;;
      OPEN)
        printf "  … PR still open, sleeping 30s (Ctrl-C to abort and resume later with --only wait_for_merge)\n"
        sleep 30
        ;;
      *)
        die "unexpected PR state: $state"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Phase: tag_release
# ---------------------------------------------------------------------------

phase_tag_release() {
  log_step "tag_release — creating signed tag $VERSION"

  if ! enter_scratch; then
    log_dry "would checkout $RELEASE_BRANCH, verify HEAD subject == '$PR_TITLE', create signed tag $VERSION, and push to $REMOTE"
    return 0
  fi

  if $EXECUTE; then
    git fetch --tags "$REMOTE"
    git checkout "$RELEASE_BRANCH" 2>/dev/null || git checkout -b "$RELEASE_BRANCH" "$REMOTE/$RELEASE_BRANCH"
    git reset --hard "$REMOTE/$RELEASE_BRANCH"

    local head_subject
    head_subject="$(git log -1 --pretty=%s)"
    # Accept "chore: Release <version>" optionally followed by a squash-merge
    # PR suffix (e.g. " (#1383)").
    if [[ "$head_subject" != "$PR_TITLE" && ! "$head_subject" =~ ^"$PR_TITLE"" (#"[0-9]+")"$ ]]; then
      die "HEAD commit subject is:
    '$head_subject'
  expected:
    '$PR_TITLE' (optionally with ' (#N)' squash-merge suffix)
  Refusing to tag — verify the release PR merged onto $RELEASE_BRANCH."
    fi
    log_info "HEAD commit subject matches PR title — safe to tag"

    if git rev-parse --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
      die "local tag $VERSION already exists — refusing to overwrite"
    fi

    git tag -s "$VERSION" -m "$VERSION"
    git verify-tag "$VERSION" || die "tag $VERSION verify FAILED"
    log_mutation "created signed tag $VERSION locally" "git tag -d $VERSION"
    log_info "signed tag created and verified locally"
  else
    log_dry "checkout $RELEASE_BRANCH && verify HEAD subject == '$PR_TITLE'"
    log_dry "git tag -s $VERSION -m $VERSION && git verify-tag $VERSION"
  fi

  confirm_hard "PUSH signed tag $VERSION to $REMOTE?" \
    || die "tag push declined"

  run git push "$REMOTE" "$VERSION"
  log_mutation "pushed tag $VERSION to $REMOTE" \
    "git push $REMOTE --delete $VERSION"

  log_info "tag $VERSION pushed"
}

# ---------------------------------------------------------------------------
# Phase: draft_github_release
# ---------------------------------------------------------------------------

# Compute previous same-suffix tag, if applicable (e.g. alpha.3 -> alpha.2).
compute_prev_same_suffix_tag() {
  local prev=""
  if [[ -n "$SUFFIX_STAGE" && "$SUFFIX_NUM" -gt 0 ]]; then
    prev="v${MAJOR}.${MINOR}.${PATCH}-${SUFFIX_STAGE}.$((SUFFIX_NUM - 1))"
    if ! git rev-parse --verify "refs/tags/$prev" >/dev/null 2>&1; then
      prev=""
    fi
  fi
  echo "$prev"
}

# For GA: compute latest tag on the release branch with no prerelease suffix.
compute_prev_ga_tag() {
  git tag --list --sort=-v:refname --merged "$REMOTE/$RELEASE_BRANCH" 'v*' \
    | grep -Ev '\-(alpha|beta|rc)\.' \
    | grep -v "^${VERSION}$" \
    | head -1
}

# Resolve <PREV> for the "Full Changelog" link on prereleases, with user confirmation.
resolve_prerelease_prev_ref() {
  local guessed
  guessed="$(compute_prev_same_suffix_tag)"

  echo
  if [[ -n "$guessed" ]]; then
    log_info "Suggested previous ref for changelog link: $guessed"
  else
    log_info "No obvious previous ref (this may be a '.0' prerelease)"
    log_info "  Hint: for beta.0, use latest alpha tag; for alpha.0, use a full 40-char SHA"
    # Print hints
    local recent
    recent="$(git tag --list --sort=-v:refname --merged "$REMOTE/$RELEASE_BRANCH" 'v*' \
               | grep -v "^${VERSION}$" | head -5 || true)"
    if [[ -n "$recent" ]]; then
      echo "  Recent tags reachable from $RELEASE_BRANCH:"
      echo "$recent" | sed 's/^/    /'
    fi
  fi

  local chosen="$guessed"
  local reply
  while true; do
    if [[ -n "$chosen" ]]; then
      read -r -p "${YELLOW}Use '$chosen' as previous ref?  [Y] yes  [n] no, enter different  [q] abort: ${NC}" reply
      reply="${reply:-y}"
    else
      reply="n"
    fi
    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) [[ -n "$chosen" ]] && break ;;
      [Nn]|[Nn][Oo])
        read -r -p "  Enter previous tag or full 40-char SHA: " chosen
        if [[ "$chosen" =~ ^[0-9a-f]{40}$ ]]; then
          git rev-parse --verify "$chosen^{commit}" >/dev/null 2>&1 \
            || { log_warn "SHA not found"; chosen=""; continue; }
        else
          git rev-parse --verify "refs/tags/$chosen" >/dev/null 2>&1 \
            || { log_warn "tag $chosen not found"; chosen=""; continue; }
        fi
        ;;
      [Qq]) die "aborted at previous-ref selection" ;;
      *) : ;;
    esac
  done

  PREV_REF="$chosen"
  log_info "previous ref confirmed: $PREV_REF"
}

phase_draft_github_release() {
  log_step "draft_github_release — creating GitHub draft release for $VERSION"

  if ! enter_scratch; then
    if $IS_PRERELEASE; then
      log_dry "would resolve previous ref, then create DRAFT --prerelease $VERSION with alpha/beta notes template"
    else
      log_dry "would create empty DRAFT release $VERSION and instruct user to complete notes in UI"
    fi
    return 0
  fi

  # Make sure tag is fetched so we can reference it.
  if $EXECUTE; then
    git fetch --tags "$REMOTE"
    git rev-parse --verify "refs/tags/$VERSION" >/dev/null \
      || die "tag $VERSION not present locally; run tag_release first"
  fi

  if $IS_PRERELEASE; then
    local PREV_REF=""
    resolve_prerelease_prev_ref

    local body
    body=$(cat <<EOF
> [!CAUTION]
>
> __THIS IS NOT A GA RELEASE__
> __DO NOT USE ON ANY PRODUCTION CLUSTER__

**Full Changelog**: https://github.com/${UPSTREAM_REPO}/compare/${PREV_REF}...${VERSION}

**Install Instructions**: ${DEPLOY_GUIDE_URL}
EOF
    )

    echo
    log_info "release notes preview:"
    echo "$body" | sed 's/^/    /'
    echo

    confirm "create DRAFT prerelease $VERSION with the above notes?" \
      || die "draft release creation declined"

    if $EXECUTE; then
      gh release create "$VERSION" \
        --repo "$UPSTREAM_REPO" \
        --title "$VERSION" \
        --draft \
        --prerelease \
        --notes "$body"
      log_mutation "created draft prerelease $VERSION" \
        "gh release delete $VERSION --repo $UPSTREAM_REPO"
    else
      log_dry "gh release create $VERSION --draft --prerelease --notes '<template>'"
    fi
  else
    # RC/GA: create a draft with empty body; instruct human to fill in.
    confirm "create empty DRAFT release $VERSION (you will fill notes in the UI)?" \
      || die "draft release creation declined"

    if $EXECUTE; then
      gh release create "$VERSION" \
        --repo "$UPSTREAM_REPO" \
        --title "$VERSION" \
        --draft \
        --notes ""
      log_mutation "created empty draft release $VERSION" \
        "gh release delete $VERSION --repo $UPSTREAM_REPO"
    else
      log_dry "gh release create $VERSION --draft --notes ''"
    fi

    local prev_ga
    prev_ga="$(compute_prev_ga_tag 2>/dev/null || true)"

    echo
    log_warn "RC/GA release notes are NOT auto-generated. Finish manually:"
    echo "  1. Open: https://github.com/$UPSTREAM_REPO/releases"
    echo "  2. Edit the draft for $VERSION."
    if [[ "$RELEASE_TYPE" == "rc" ]]; then
      echo "  3. Ensure 'This is a pre-release' is checked."
      echo "     Add a short description; do NOT include a full changelog."
    else
      echo "  3. In 'Previous tag', select: ${prev_ga:-<no previous GA tag found; choose manually>}"
      echo "  4. Click 'Generate release notes'; format to match prior GA releases."
    fi
    echo "  5. Publish when ready."
  fi

  local draft_url
  if $EXECUTE; then
    draft_url="$(gh release view "$VERSION" --repo "$UPSTREAM_REPO" --json url -q .url 2>/dev/null || true)"
    [[ -n "$draft_url" ]] && log_info "draft release URL: $draft_url"
  fi
}

# ---------------------------------------------------------------------------
# Success / cleanup
# ---------------------------------------------------------------------------

on_success() {
  echo
  log_info "${GREEN}${BOLD}Release automation completed for $VERSION${NC}"
  log_info "State log: ${STATE_LOG:-<none>}"
  if $EXECUTE && [[ -d "$SCRATCH_DIR" ]] && ! $KEEP; then
    if confirm "remove scratch dir $BASE_DIR?"; then
      rm -rf "$BASE_DIR"
      log_info "scratch dir removed"
    else
      log_info "scratch dir kept at $BASE_DIR"
    fi
  fi
}

on_error() {
  local exit_code=$?
  echo
  log_error "release automation FAILED (exit=$exit_code)"
  [[ -n "$STATE_LOG" && -f "$STATE_LOG" ]] && log_error "state log: $STATE_LOG"
  [[ -n "$SCRATCH_DIR" && -d "$SCRATCH_DIR" ]] && log_error "scratch clone preserved at: $SCRATCH_DIR"
  log_error "resume with:   $0 --version $VERSION --execute --only <phase>"
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  parse_version

  print_config
  echo
  if ! $EXECUTE; then
    log_warn "dry-run mode — no mutations will occur. Pass --execute to run for real."
  fi
  confirm "proceed with the above configuration?" || die "aborted at configuration confirmation"

  trap on_error ERR

  local to_run=()
  if [[ -n "$ONLY" ]]; then
    to_run=("$ONLY")
  elif [[ -n "$FROM" ]]; then
    local seen=false
    for p in "${PHASES[@]}"; do
      $seen || [[ "$p" == "$FROM" ]] && { seen=true; to_run+=("$p"); }
    done
  else
    to_run=("${PHASES[@]}")
  fi

  # For --only or --from that starts past 'clone', ensure the scratch clone
  # already exists (we can't skip clone and then reference a missing dir).
  if [[ -n "$ONLY" || -n "$FROM" ]]; then
    local first="${to_run[0]}"
    case "$first" in
      preflight|clone) : ;;
      *)
        phase_preflight
        if [[ ! -d "$SCRATCH_DIR/.git" ]]; then
          die "scratch clone missing at $SCRATCH_DIR; cannot resume — run without --only/--from (or with --from clone) first"
        fi
        ;;
    esac
  fi

  for phase in "${to_run[@]}"; do
    case "$phase" in
      preflight)                 phase_preflight ;;
      clone)                     phase_clone ;;
      prepare_branch)            phase_prepare_branch ;;
      cherry_pick)               phase_cherry_pick ;;
      bump_version_and_manifests) phase_bump_version_and_manifests ;;
      open_release_pr)           phase_open_release_pr ;;
      wait_for_merge)            phase_wait_for_merge ;;
      tag_release)               phase_tag_release ;;
      draft_github_release)      phase_draft_github_release ;;
      *) die "unknown phase: $phase" ;;
    esac
  done

  on_success
}

main "$@"
