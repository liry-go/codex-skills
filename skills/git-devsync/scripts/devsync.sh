#!/usr/bin/env bash
set -eo pipefail

usage() {
  cat <<'EOF'
Usage:
  devsync.sh status [--source BRANCH] [--source-base REF] [--remote origin] [--dev dev]
  devsync.sh sync   [--source BRANCH] [--source-base REF] [--remote origin] [--dev dev] [--reuse] [--recreate] [--dry-run]
  devsync.sh start  [same options as sync; alias kept for compatibility]
  devsync.sh merge-back [--source BRANCH] [--devsync BRANCH] [--remote origin] [--dev dev] [--dry-run]

Incrementally replays source branch commits that are not yet deployed to dev.
New cherry-picks use -x so future runs can identify already deployed source commits.
EOF
}

cmd="${1:-}"
if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  usage
  exit 0
fi
shift

remote="origin"
dev_branch="dev"
main_branch="main"
source_branch=""
source_base=""
devsync_branch=""
reuse=0
recreate=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      remote="${2:?missing value for --remote}"
      shift 2
      ;;
    --dev)
      dev_branch="${2:?missing value for --dev}"
      shift 2
      ;;
    --main)
      main_branch="${2:?missing value for --main}"
      shift 2
      ;;
    --source)
      source_branch="${2:?missing value for --source}"
      shift 2
      ;;
    --source-base)
      source_base="${2:?missing value for --source-base}"
      shift 2
      ;;
    --devsync)
      devsync_branch="${2:?missing value for --devsync}"
      shift 2
      ;;
    --reuse)
      reuse=1
      shift
      ;;
    --recreate)
      recreate=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

run() {
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

require_git_repo() {
  git rev-parse --show-toplevel >/dev/null
}

current_branch() {
  git rev-parse --abbrev-ref HEAD
}

require_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Worktree is not clean. Commit or stash changes before running git-devsync." >&2
    git status --short --branch >&2
    exit 1
  fi
}

fetch_dev() {
  run git fetch "$remote" "$dev_branch"
}

resolve_source_branch() {
  if [[ -n "$source_branch" ]]; then
    printf '%s\n' "$source_branch"
  else
    current_branch
  fi
}

effective_dev_ref() {
  local remote_dev="$remote/$dev_branch"
  if git show-ref --verify --quiet "refs/heads/${dev_branch}"; then
    if git merge-base --is-ancestor "$remote_dev" "$dev_branch"; then
      printf '%s\n' "$dev_branch"
      return
    fi
    if ! git merge-base --is-ancestor "$dev_branch" "$remote_dev"; then
      echo "Local ${dev_branch} diverged from ${remote_dev}; reconcile dev before running git-devsync." >&2
      exit 1
    fi
  fi
  printf '%s\n' "$remote_dev"
}

default_source_base() {
  local branch="$1"
  local dev_ref="$2"
  local upstream
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name "${branch}@{upstream}" 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    git merge-base --fork-point "$upstream" "$branch" 2>/dev/null || git merge-base "$upstream" "$branch"
    return
  fi
  if git show-ref --verify --quiet "refs/remotes/${remote}/${main_branch}" &&
    git merge-base --is-ancestor "$remote/$main_branch" "$branch"; then
    printf '%s\n' "$remote/$main_branch"
    return
  fi
  if git show-ref --verify --quiet "refs/heads/${main_branch}" &&
    git merge-base --is-ancestor "$main_branch" "$branch"; then
    printf '%s\n' "$main_branch"
    return
  fi
  git merge-base "$dev_ref" "$branch"
}

ensure_no_merge_commits() {
  local base="$1"
  local source="$2"
  local merges
  merges="$(git rev-list --merges "${base}..${source}")"
  if [[ -n "$merges" ]]; then
    echo "Source range contains merge commits; inspect and cherry-pick manually with an explicit mainline parent." >&2
    git log --oneline --merges "${base}..${source}" >&2
    exit 1
  fi
}

collect_source_commits() {
  local base="$1"
  local source="$2"
  commits=()
  while IFS= read -r commit; do
    commits+=("$commit")
  done < <(git rev-list --reverse "${base}..${source}")
}

collect_cherry_map() {
  local dev_ref="$1"
  local source="$2"
  local base="$3"
  cherry_signs=()
  cherry_commits=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    cherry_signs+=("${line%% *}")
    cherry_commits+=("${line#* }")
  done < <(git cherry "$dev_ref" "$source" "$base")
}

cherry_sign_for() {
  local commit="$1"
  local i
  for ((i = 0; i < ${#cherry_commits[@]}; i++)); do
    if [[ "${cherry_commits[$i]}" == "$commit" ]]; then
      printf '%s\n' "${cherry_signs[$i]}"
      return
    fi
  done
  printf '?\n'
}

has_source_trailer_in_dev() {
  local dev_ref="$1"
  local commit="$2"
  [[ -n "$(git log --fixed-strings --grep="(cherry picked from commit ${commit})" --format=%H -n 1 "$dev_ref")" ]]
}

classify_commits() {
  local dev_ref="$1"
  pending_commits=()
  trailer_commits=()
  patch_commits=()
  unknown_commits=()

  local commit sign
  for commit in "${commits[@]}"; do
    if has_source_trailer_in_dev "$dev_ref" "$commit"; then
      trailer_commits+=("$commit")
      continue
    fi
    sign="$(cherry_sign_for "$commit")"
    case "$sign" in
      -)
        patch_commits+=("$commit")
        ;;
      +)
        pending_commits+=("$commit")
        ;;
      *)
        unknown_commits+=("$commit")
        pending_commits+=("$commit")
        ;;
    esac
  done
}

print_commit_list() {
  local title="$1"
  shift
  echo "${title}: $#"
  if [[ "$#" -gt 0 ]]; then
    git log --oneline --no-walk "$@"
  fi
}

prepare_context() {
  fetch_dev

  source="$(resolve_source_branch)"
  if [[ "$source" == *_devsync ]]; then
    echo "Current/source branch already ends with _devsync. Run from the source branch or pass --source." >&2
    exit 1
  fi

  target="${devsync_branch:-${source}_devsync}"
  dev_ref="$(effective_dev_ref)"
  base="${source_base}"
  if [[ -z "$base" ]]; then
    base="$(default_source_base "$source" "$dev_ref")"
  fi

  ensure_no_merge_commits "$base" "$source"
  collect_source_commits "$base" "$source"
  collect_cherry_map "$dev_ref" "$source" "$base"
  classify_commits "$dev_ref"
}

print_status() {
  require_git_repo
  prepare_context

  echo "Source branch: ${source}"
  echo "Source base:   ${base}"
  echo "Dev ref:       ${dev_ref}"
  echo "Devsync:       ${target}"
  print_commit_list "Source commits" "${commits[@]}"
  print_commit_list "Already deployed by -x trailer" "${trailer_commits[@]}"
  print_commit_list "Already deployed by patch-id" "${patch_commits[@]}"
  print_commit_list "Pending commits" "${pending_commits[@]}"
  if [[ "${#unknown_commits[@]}" -gt 0 ]]; then
    print_commit_list "Pending commits with unknown git-cherry status" "${unknown_commits[@]}"
  fi
}

checkout_devsync_branch() {
  local target="$1"
  local dev_ref="$2"

  if git show-ref --verify --quiet "refs/heads/${target}"; then
    if [[ "$reuse" -eq 1 ]]; then
      run git switch "$target"
      return
    fi
    if [[ "$recreate" -eq 1 ]] || git merge-base --is-ancestor "$target" "$dev_ref"; then
      local current
      current="$(current_branch)"
      if [[ "$current" == "$target" ]]; then
        run git reset --hard "$dev_ref"
      else
        run git branch -f "$target" "$dev_ref"
        run git switch "$target"
      fi
      return
    fi
    echo "Branch ${target} exists and is not contained in ${dev_ref}." >&2
    echo "Resolve/merge it, or pass --reuse to continue there, or --recreate to reset it to ${dev_ref}." >&2
    exit 1
  fi

  run git switch -c "$target" "$dev_ref"
}

sync_devsync() {
  require_git_repo
  require_clean_worktree
  prepare_context

  echo "Source branch: ${source}"
  echo "Source base:   ${base}"
  echo "Dev ref:       ${dev_ref}"
  echo "Devsync:       ${target}"
  print_commit_list "Source commits" "${commits[@]}"
  print_commit_list "Already deployed by -x trailer" "${trailer_commits[@]}"
  print_commit_list "Already deployed by patch-id" "${patch_commits[@]}"
  print_commit_list "Pending commits" "${pending_commits[@]}"

  if [[ "${#pending_commits[@]}" -eq 0 ]]; then
    echo "Nothing to sync."
    return
  fi

  checkout_devsync_branch "$target" "$dev_ref"
  run git cherry-pick -x "${pending_commits[@]}"
}

merge_back() {
  require_git_repo
  require_clean_worktree

  local current
  current="$(current_branch)"

  local source="$source_branch"
  local target="$devsync_branch"
  if [[ -z "$target" ]]; then
    if [[ "$current" == *_devsync ]]; then
      target="$current"
    else
      if [[ -z "$source" ]]; then
        source="$current"
      fi
      target="${source}_devsync"
    fi
  fi

  if [[ -z "$source" ]]; then
    if [[ "$target" == *_devsync ]]; then
      source="${target%_devsync}"
    elif [[ "$current" != "$target" ]]; then
      source="$current"
    else
      echo "Cannot infer source branch from devsync branch: ${target}. Pass --source explicitly." >&2
      exit 1
    fi
  fi

  if ! git show-ref --verify --quiet "refs/heads/${source}"; then
    echo "Source branch not found: ${source}" >&2
    exit 1
  fi

  if ! git show-ref --verify --quiet "refs/heads/${target}"; then
    echo "Devsync branch not found: ${target}" >&2
    exit 1
  fi

  fetch_dev

  if git show-ref --verify --quiet "refs/heads/${dev_branch}"; then
    run git switch "$dev_branch"
  else
    run git switch -c "$dev_branch" "$remote/$dev_branch"
  fi

  run git merge --ff-only "$remote/$dev_branch"

  if [[ "$dry_run" -eq 0 ]] && ! git merge-base --is-ancestor HEAD "$target"; then
    echo "Local ${dev_branch} cannot fast-forward to ${target}. Recreate or rebase ${target} from latest ${remote}/${dev_branch}." >&2
    exit 1
  fi

  run git merge --ff-only "$target"
  run git switch "$source"

  if [[ "$dry_run" -eq 0 ]]; then
    echo "Returned to source branch: ${source}"
  fi
}

case "$cmd" in
  status)
    print_status
    ;;
  start|sync)
    sync_devsync
    ;;
  merge-back)
    merge_back
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
