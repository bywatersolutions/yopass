#!/usr/bin/env bash
# BWS - Fail fast if the token used to push synced branches cannot do so.
#
# GH_TOKEN must be the PAT the sync workflow checks out with. Pushes made with
# the default GITHUB_TOKEN would not trigger bws-build.yml, and commits that
# touch .github/workflows are rejected unless a classic PAT has the 'workflow'
# scope. Fine-grained tokens send no scope header; they need Contents and
# Workflows write permission on the repository instead.
set -euo pipefail

repo="${GITHUB_REPOSITORY:-bywatersolutions/yopass}"

if ! gh api "repos/${repo}" --jq '.permissions.push' | grep -qx true; then
  echo "::error::the sync token cannot push to ${repo}"
  exit 1
fi

scopes="$(gh api -i user | tr -d '\r' | awk -F': ' 'tolower($1) == "x-oauth-scopes" {print $2}')"
if [[ -z "${scopes}" ]]; then
  echo "token scopes: none reported (fine-grained token); it needs Contents and Workflows write on ${repo}"
  exit 0
fi
echo "token scopes: ${scopes}"
if [[ "${scopes}" != *workflow* ]]; then
  echo "::error::the sync token lacks the 'workflow' scope; pushes that touch .github/workflows will be rejected"
  exit 1
fi
