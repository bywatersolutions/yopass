#!/usr/bin/env bash
# BWS - Post one message to Slack through an incoming webhook.
#
# Inputs (env): SLACK_WEBHOOK_URL, SLACK_TITLE, SLACK_TEXT (optional, mrkdwn),
# SLACK_COLOR (good | warning | danger | #hex, default good).
# jq builds the JSON so quotes and newlines in the text are safe.
set -euo pipefail

: "${SLACK_WEBHOOK_URL:?SLACK_WEBHOOK_URL is required}"
: "${SLACK_TITLE:?SLACK_TITLE is required}"

jq -n \
  --arg title "${SLACK_TITLE}" \
  --arg text "${SLACK_TEXT:-}" \
  --arg color "${SLACK_COLOR:-good}" \
  '{attachments: [{color: $color, title: $title, text: $text, mrkdwn_in: ["text"]}]}' |
  curl -sS -f -H 'Content-type: application/json' --data @- "${SLACK_WEBHOOK_URL}"
echo
