#!/usr/bin/env bash
# BWS - Keep upstream-only workflows disabled on the fork.
#
# Upstream workflow files are kept verbatim (deleting or editing them would make
# every cherry-pick onto a new upstream tag conflict). The ones that must not run
# here - Docker Hub publish, Cloudflare Pages deploy, microsite notify, stale
# bot, CodeQL - are disabled by workflow id instead. The disabled state is per
# workflow path and survives pushes, but a *renamed* upstream file registers as
# a new, active workflow, so this runs after every sync. Needs GH_TOKEN with
# actions:write (the workflow grants it).
set -euo pipefail

repo="${GITHUB_REPOSITORY:-bywatersolutions/yopass}"
# Basenames allowed to stay active.
keep_re='^(bws-.*|test|yamllint)\.ya?ml$'

gh api --paginate "repos/${repo}/actions/workflows" \
  --jq '.workflows[] | select(.state == "active") | "\(.id)\t\(.path)"' |
while IFS=$'\t' read -r id path; do
  case "${path}" in .github/workflows/*) ;; *) continue ;; esac
  name="${path##*/}"
  if [[ "${name}" =~ ${keep_re} ]]; then
    echo "keeping   ${path}"
    continue
  fi
  echo "disabling ${path} (id ${id})"
  gh api --silent --method PUT "repos/${repo}/actions/workflows/${id}/disable" || echo "  could not disable ${path}"
done
