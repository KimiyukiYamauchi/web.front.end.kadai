#!/usr/bin/env bash
# set -x

set -euo pipefail

INPUT_FILE="clone.txt"

log() { printf "%s\n" "$*" ; }

# Create/ensure local tracking branches for every remote branch
create_local_branches() {
  local remote="${1:-origin}"

  # Collect real remote branches (exclude the symbolic HEAD and any weird refs)
  mapfile -t remote_branches < <(
    git for-each-ref --format='%(refname:short)' "refs/remotes/${remote}" 2>/dev/null \
      | grep -v "^${remote}/HEAD$" \
      | grep -v " -> " \
      || true
  )

  for rb in "${remote_branches[@]}"; do
    # rb example: origin/main
    [[ -z "${rb}" ]] && continue
    [[ "${rb}" != ${remote}/* ]] && continue

    local b="${rb#${remote}/}"   # main

    # Sanity: ensure the remote ref exists
    if ! git show-ref --verify --quiet "refs/remotes/${remote}/${b}"; then
      continue
    fi

    if git show-ref --verify --quiet "refs/heads/${b}"; then
      # Existing local branch: ensure it tracks the remote
      local upstream
      upstream="$(git rev-parse --abbrev-ref --symbolic-full-name "${b}@{upstream}" 2>/dev/null || true)"
      if [[ -z "${upstream}" ]]; then
        git branch --set-upstream-to="${remote}/${b}" "${b}" >/dev/null 2>&1 || true
      fi
    else
      # Create a new local branch that tracks the remote branch
      git branch --track "${b}" "${remote}/${b}" >/dev/null 2>&1 || true
    fi
  done
}

# Get default branch name from remote, fallback to origin/HEAD target if available
get_default_branch() {
  local remote="${1:-origin}"
  local def=""

  # Try 'git remote show origin' parsing
  if def="$(git remote show "${remote}" 2>/dev/null | awk -F': ' '/HEAD branch/ {print $2; exit}')"; then
    if [[ -n "${def}" ]]; then
      printf "%s" "${def}"
      return 0
    fi
  fi

  # Fallback to origin/HEAD symref target
  local target
  target="$(git symbolic-ref -q refs/remotes/${remote}/HEAD 2>/dev/null || true)"
  if [[ -n "${target}" ]]; then
    # target like: refs/remotes/origin/main
    printf "%s" "${target##refs/remotes/${remote}/}"
    return 0
  fi

  # Last resort: main or master if present
  if git show-ref --verify --quiet "refs/remotes/${remote}/main"; then
    printf "main"
  elif git show-ref --verify --quiet "refs/remotes/${remote}/master"; then
    printf "master"
  else
    printf ""
  fi
}


# クローン先のベースディレクトリ
DEST_BASE="./repos"
mkdir -p "$DEST_BASE"


while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip empty lines and lines that start with #
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

  repo_url="$(echo "$line" | xargs)"

  # 学籍番号の元になる 25xxx を抽出
  raw_id=$(echo "$repo_url" | grep -oE '[0-9]{5}')

  if [[ -z "$raw_id" ]]; then
    echo "⚠️ 学籍番号(25xxx)を抽出できません: $repo_url"
    continue
  fi

  # 既に n または s が付いている形式もチェック（例: s25001, n25002）
  prefixed_id=$(echo "$repo_url" | grep -oE '[ns]25[0-9]{3}' || true)

  if [[ -n "$prefixed_id" ]]; then
    # そのまま使う
    student_id="$prefixed_id"
  else
    # n が付いていない場合は n を付与
    student_id="n$raw_id"
  fi

  target_dir="$DEST_BASE/$student_id"

  if [[ -d "${target_dir}/.git" ]]; then
    log "📂  既存: ${target_dir} → 更新 & 全ブランチ作成"
    pushd "${target_dir}" >/dev/null

    # Ensure remote URL is correct
    git remote set-url origin "${repo_url}"

    # Fetch all and prune
    git fetch --all --prune

    # Create/ensure local branches
    create_local_branches origin

    # Pull only if current branch has a valid upstream ref that actually exists
    current_branch="$(git rev-parse --abbrev-ref HEAD)"
    upstream_ref="$(git rev-parse --abbrev-ref --symbolic-full-name "${current_branch}@{upstream}" 2>/dev/null || true)"
    if [[ -n "${upstream_ref}" ]] && git show-ref --verify --quiet "refs/remotes/${upstream_ref}"; then
      git pull --ff-only || true
    else
      log "ℹ️  現在のブランチ '${current_branch}' は有効な upstream が未設定のため pull をスキップしました"
    fi

    popd >/dev/null
  else
    log "🆕  新規: ${repo_url} → ${target_dir}"
    git clone "${repo_url}" "${target_dir}"

    pushd "${target_dir}" >/dev/null

    # Fetch all and prune (in case the provider creates branches post-clone)
    git fetch --all --prune

    # Create/ensure local branches
    create_local_branches origin

    # Checkout default branch if resolvable
    def_branch="$(get_default_branch origin)"
    if [[ -n "${def_branch}" ]]; then
      git checkout "${def_branch}" >/dev/null 2>&1 || true
    fi

    popd >/dev/null
  fi

  
done < "${INPUT_FILE}"
