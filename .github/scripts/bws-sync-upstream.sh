#!/usr/bin/env bash
# BWS - Sync the fork with an upstream (jhaals/yopass) release.
#
# Run by .github/workflows/bws-sync-upstream.yml. The fork's master is expected
# to be "upstream tag + our customization commits" (linear). This script:
#   1. finds the upstream tag master is based on (CUR) and the target tag (NEW),
#   2. stops if NEW is not newer, or the fork already has a branch named NEW,
#   3. replays CUR..master onto NEW in a throw-away git worktree,
#   4. on success pushes branch NEW and moves master to it (force-with-lease),
#      which makes bws-build.yml publish :NEW and :latest,
#   5. on conflict aborts, pushes nothing, and opens (or reuses) a GitHub issue.
#
# Needs: a non-shallow clone whose "origin" is the fork and is allowed to push;
# `gh` with GH_TOKEN (release lookup, issue creation); jq.
#
# Env inputs:
#   TARGET_TAG  upstream tag to sync to (default: latest published release)
#   FORCE       "true": ignore the "NEW is not newer than CUR" check
#   DRY_RUN     "true": replay but never push; Slack/issue titles get "[DRY RUN] "
#   MASTER_REF  ref that plays the role of master (default origin/master); only
#               honoured together with DRY_RUN=true, for local testing
#
# Writes to GITHUB_OUTPUT: outcome=noop|synced|conflict|error, slack_color,
# slack_title, slack_text (consumed by the workflow's Slack step).
# Exit status: 0 for noop/synced, 1 for conflict/error.
set -euo pipefail

UPSTREAM_REPO="jhaals/yopass"
UPSTREAM_URL="https://github.com/${UPSTREAM_REPO}.git"
FORK_REPO="${GITHUB_REPOSITORY:-bywatersolutions/yopass}"
FORK_URL="https://github.com/${FORK_REPO}"
IMAGE="quay.io/bywatersolutions/yopass"
TAG_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

TARGET_TAG="${TARGET_TAG:-}"
FORCE="${FORCE:-false}"
DRY_RUN="${DRY_RUN:-false}"
MASTER_REF="${MASTER_REF:-origin/master}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${FORK_REPO}/actions/runs/${GITHUB_RUN_ID:-local}"
REPO_DIR="$(git rev-parse --show-toplevel)"
WORKTREE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/yopass-sync-worktree"
# Local branch name for the replay; prefixed so it never collides with the tag.
LOCAL_BRANCH=""

prefix=""
if [[ "${DRY_RUN}" == "true" ]]; then prefix="[DRY RUN] "; fi
if [[ "${MASTER_REF}" != "origin/master" && "${DRY_RUN}" != "true" ]]; then
  echo "MASTER_REF override is only allowed with DRY_RUN=true" >&2
  exit 1
fi

# Slack outputs: start with "crashed" defaults, overwrite as we go, emit once on exit.
outcome="error"
slack_color="danger"
slack_title="${prefix}Yopass upstream sync failed unexpectedly"
slack_text="Run: ${RUN_URL}"
NEW=""

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup_and_emit() {
  {
    echo "outcome=${outcome}"
    echo "slack_color=${slack_color}"
    echo "slack_title=${slack_title}"
    echo "slack_text<<BWS_SLACK_EOF"
    echo "${slack_text}"
    echo "BWS_SLACK_EOF"
  } >> "${GITHUB_OUTPUT}"
  printf '## %s\n\n%s\n' "${slack_title}" "${slack_text}" >> "${GITHUB_STEP_SUMMARY}"
  cd "${REPO_DIR}"
  git worktree remove --force "${WORKTREE}" 2>/dev/null || true
  if [[ -n "${LOCAL_BRANCH}" ]]; then git branch -D "${LOCAL_BRANCH}" >/dev/null 2>&1 || true; fi
}
trap cleanup_and_emit EXIT

log() { printf '%s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  slack_text="$*"$'\n'"Run: ${RUN_URL}"
  exit 1
}
describe_commits() { local c; for c in "$@"; do git log -1 --format='%h %s' "${c}"; done; }

# 1. Refs --------------------------------------------------------------------------
log "Fetching upstream tags from ${UPSTREAM_URL}"
git fetch --quiet --no-tags --force "${UPSTREAM_URL}" '+refs/tags/*:refs/tags/*'
git fetch --quiet --no-tags origin '+refs/heads/*:refs/remotes/origin/*'

MASTER_SHA="$(git rev-parse "${MASTER_REF}")"
CUR="$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' "${MASTER_SHA}")"
[[ "${CUR}" =~ ${TAG_RE} ]] || die "Cannot determine the upstream base of ${MASTER_REF} (git describe returned '${CUR}')."

RELEASE_URL=""
if [[ -n "${TARGET_TAG}" ]]; then
  NEW="${TARGET_TAG}"
  RELEASE_URL="https://github.com/${UPSTREAM_REPO}/releases/tag/${NEW}"
else
  IFS=$'\t' read -r NEW RELEASE_URL < <(gh api "repos/${UPSTREAM_REPO}/releases/latest" --jq '[.tag_name, .html_url] | @tsv') || true
fi
[[ "${NEW}" =~ ${TAG_RE} ]] || die "Upstream release tag '${NEW}' is not X.Y.Z; refusing to guess what it means."
git rev-parse -q --verify "refs/tags/${NEW}^{commit}" >/dev/null || die "Tag ${NEW} is not in ${UPSTREAM_REPO} (yet?)."
NEW_TAG_SHA="$(git rev-parse --short=7 "refs/tags/${NEW}^{commit}")"
LOCAL_BRANCH="sync/${NEW}"
log "${MASTER_REF} (${MASTER_SHA:0:7}) is based on upstream ${CUR}; target is ${NEW} (${NEW_TAG_SHA})"

# 2. Anything to do? ---------------------------------------------------------------
newest="$(printf '%s\n%s\n' "${CUR}" "${NEW}" | sort -V | tail -n 1)"
if [[ "${FORCE}" != "true" && ( "${NEW}" == "${CUR}" || "${newest}" != "${NEW}" ) ]]; then
  log "Nothing to do: ${NEW} is not newer than ${CUR}."
  outcome="noop"
  exit 0
fi

if git ls-remote --exit-code --heads origin "refs/heads/${NEW}" >/dev/null 2>&1; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "Branch ${NEW} already exists on the fork; continuing because this is a dry run."
  elif [[ "${NEW}" == "${CUR}" ]]; then
    log "Branch ${NEW} exists and master is based on it; nothing to do."
    outcome="noop"
    exit 0
  else
    slack_title="${prefix}Yopass upstream sync needs a human: branch ${NEW} exists but master is still on ${CUR}"
    die "Branch ${FORK_URL}/tree/${NEW} exists but master is based on ${CUR}. Either move master by hand (git push --force-with-lease=master:${MASTER_SHA} <fork> refs/heads/${NEW}:refs/heads/master) or delete the branch so the sync can retry."
  fi
fi

# 3. Our customization commits -----------------------------------------------------
COMMITS=()
while IFS= read -r c; do COMMITS+=("${c}"); done < <(git rev-list --reverse "refs/tags/${CUR}..${MASTER_SHA}")
[[ ${#COMMITS[@]} -gt 0 ]] || die "No customization commits found between ${CUR} and ${MASTER_REF}."
for c in "${COMMITS[@]}"; do
  if [[ "$(git rev-list --no-walk --parents "${c}" | wc -w)" -ne 2 ]]; then
    die "Commit ${c:0:7} is a merge commit; the replay expects a linear master (upstream tag + our commits)."
  fi
done
log "Replaying ${#COMMITS[@]} commit(s) from ${CUR}..${MASTER_REF} onto ${NEW}:"
describe_commits "${COMMITS[@]}" >&2

# 4. Replay in a throw-away worktree (never in the checkout running this script) --
cd "${REPO_DIR}"
git worktree remove --force "${WORKTREE}" 2>/dev/null || true
git branch -D "${LOCAL_BRANCH}" >/dev/null 2>&1 || true
git worktree add --quiet -b "${LOCAL_BRANCH}" "${WORKTREE}" "refs/tags/${NEW}"
cd "${WORKTREE}"
git config user.name "bws-github-actions"
git config user.email "devops@bywatersolutions.com"

applied=()
skipped=()
failed=""
conflict_files=""
conflict_status=""
for c in "${COMMITS[@]}"; do
  if git cherry-pick --no-edit "${c}" >/dev/null 2>&1; then
    applied+=("${c}")
    continue
  fi
  if [[ -z "$(git ls-files --unmerged)" ]] && git diff --cached --quiet; then
    # Empty result: upstream already contains this change.
    log "  ${c:0:7} is already in ${NEW}; skipping"
    git cherry-pick --skip >/dev/null 2>&1 || true
    skipped+=("${c}")
    continue
  fi
  failed="${c}"
  conflict_files="$(git diff --name-only --diff-filter=U)"
  conflict_status="$(git status --short)"
  git cherry-pick --abort
  break
done

# 5a. Conflict: push nothing, open/reuse an issue, alert ---------------------------
if [[ -n "${failed}" ]]; then
  remaining=()
  seen="false"
  for c in "${COMMITS[@]}"; do
    if [[ "${seen}" == "true" ]]; then remaining+=("${c}"); fi
    if [[ "${c}" == "${failed}" ]]; then seen="true"; fi
  done
  subject="$(git log -1 --format=%s "${failed}")"
  applied_list="$(describe_commits ${applied[@]+"${applied[@]}"})"
  skipped_list="$(describe_commits ${skipped[@]+"${skipped[@]}"})"
  remaining_list="$(describe_commits ${remaining[@]+"${remaining[@]}"})"
  title="${prefix}Upstream sync to ${NEW} failed: cherry-pick conflict"
  body="$(mktemp)"
  cat > "${body}" <<EOF
Upstream release **${NEW}** ([release notes](${RELEASE_URL})) could not be synced automatically.

* Current base: \`${CUR}\` (master @ ${MASTER_SHA:0:7}); target: \`${NEW}\` (${NEW_TAG_SHA})
* Replay of ${#COMMITS[@]} customization commit(s) stopped at \`${failed:0:7}\` "${subject}"
* Nothing was pushed. Run: ${RUN_URL}

Conflicting files:
\`\`\`
${conflict_files}
\`\`\`

\`git status --short\` at the conflict:
\`\`\`
${conflict_status}
\`\`\`

Applied before the conflict:
\`\`\`
${applied_list:-(none)}
\`\`\`

Skipped because upstream already contains them:
\`\`\`
${skipped_list:-(none)}
\`\`\`

Still to replay after the failed commit:
\`\`\`
${remaining_list:-(none)}
\`\`\`

To finish by hand (remotes as in the team clones: \`origin\` = upstream, \`github\` = this fork):
\`\`\`
git fetch origin --tags && git fetch github
git checkout -b custom-${NEW} refs/tags/${NEW}
git cherry-pick refs/tags/${CUR}..github/master   # resolve, git add, git cherry-pick --continue
go test ./cmd/... ./pkg/...
git push github custom-${NEW}:refs/heads/${NEW}
git push --force-with-lease=master:${MASTER_SHA} github custom-${NEW}:refs/heads/master
\`\`\`
Pushing \`${NEW}\` builds \`${IMAGE}:${NEW}\`; pushing master also moves \`${IMAGE}:latest\` (production auto-updates from it).
Close this issue once master is on ${NEW}.
EOF
  issue_url=""
  existing="$(gh issue list --repo "${FORK_REPO}" --state open --search "Upstream sync to ${NEW} in:title" --json number,title 2>/dev/null \
    | jq -r --arg t "${title}" '[.[] | select(.title == $t)][0].number // empty' || true)"
  if [[ -n "${existing}" ]]; then
    issue_url="${FORK_URL}/issues/${existing}"
    log "Reusing open issue ${issue_url}"
  elif issue_url="$(gh issue create --repo "${FORK_REPO}" --title "${title}" --body-file "${body}" 2>&1)"; then
    log "Opened ${issue_url}"
  else
    log "Issue creation failed: ${issue_url}"
    issue_url="(could not create the issue - are Issues enabled on ${FORK_URL}?)"
  fi

  outcome="conflict"
  slack_color="danger"
  slack_title="${prefix}Yopass ${NEW} is available but could NOT be synced automatically"
  slack_text="Cherry-pick conflict at ${failed:0:7} \"${subject}\" while replaying ${#COMMITS[@]} commit(s) from ${CUR} onto ${NEW}.
Conflicting files: $(printf '%s' "${conflict_files}" | tr '\n' ' ')
Nothing was pushed; production stays on ${CUR}.
Issue: ${issue_url}
Release notes: ${RELEASE_URL}
Run: ${RUN_URL}"
  exit 1
fi

# 5b. Success: push branch, move master -------------------------------------------
NEW_SHA="$(git rev-parse HEAD)"
applied_list="$(describe_commits ${applied[@]+"${applied[@]}"})"
skipped_note=""
if [[ ${#skipped[@]} -gt 0 ]]; then skipped_note=" (${#skipped[@]} skipped as already upstream)"; fi

if [[ "${DRY_RUN}" == "true" ]]; then
  log "DRY RUN: would push refs/heads/${NEW} (${NEW_SHA:0:7}) and move master ${MASTER_SHA:0:7} -> ${NEW_SHA:0:7}"
  action="Would push branch ${NEW} and move master from ${CUR} (${MASTER_SHA:0:7}) to ${NEW} (${NEW_SHA:0:7}). Nothing was pushed."
else
  git push --quiet origin "refs/heads/${LOCAL_BRANCH}:refs/heads/${NEW}"
  git push --quiet --force-with-lease="refs/heads/master:${MASTER_SHA}" origin "refs/heads/${LOCAL_BRANCH}:refs/heads/master"
  action="Pushed branch ${FORK_URL}/tree/${NEW} and moved master from ${CUR} (${MASTER_SHA:0:7}) to ${NEW} (${NEW_SHA:0:7})."
fi

outcome="synced"
slack_color="good"
slack_title="${prefix}Yopass ${NEW} is available and was synced automatically"
slack_text="${action}
Replayed ${#applied[@]} customization commit(s) onto upstream ${NEW}${skipped_note}:
${applied_list}
Builds: ${FORK_URL}/actions/workflows/bws-build.yml -> ${IMAGE}:${NEW} and :latest (production auto-updates from :latest)
Release notes: ${RELEASE_URL}
Run: ${RUN_URL}"
exit 0
