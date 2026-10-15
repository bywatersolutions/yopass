# Sharepass on Docker Swarm (prod-bwsdocker01)

Two stacks:

- `yopass-stack.yml`: Sharepass (our Yopass build) plus memcached.
- `updaters-stack.yml`: shepherd (automatic rolling updates), apprise (its Slack
  notifications) and diun (alerts when an image has a newer version in its registry).

## Deploy

On a manager node, from a checkout of this repo:

```
# once: the #devops incoming webhook, for diun (docker secret, stays out of git)
printf '%s' 'https://hooks.slack.com/services/T.../B.../xxx' | docker secret create slack_devops_webhook -
# the same webhook in Apprise form, for shepherd: https://hooks.slack.com/services/A/B/C -> slack://A/B/C
export APPRISE_SLACK_URL='slack://T.../B.../xxx'

docker stack deploy -c deploy/docker-swarm/yopass-stack.yml yopass
docker stack deploy -c deploy/docker-swarm/updaters-stack.yml updaters
```

Merge the ports, networks and reverse-proxy wiring of the existing production
service into `yopass-stack.yml` before the first deploy; the `ports:` block in it
is a placeholder.

## How a new version reaches production

1. `.github/workflows/bws-sync-upstream.yml` (daily) sees a new upstream release,
   replays our commits onto it, pushes branch `<version>` and moves `master`.
2. `.github/workflows/bws-build.yml` builds `quay.io/bywatersolutions/yopass:<version>`
   from the branch and, from `master`, also moves `:latest`.
3. shepherd (every 15 minutes) notices the new `:latest` digest and does a start-first
   rolling update of every service labelled `shepherd.enable=true`, rolling back on failure.

Slack (#devops) messages along the way: the sync result (synced, or conflict with a
GitHub issue), the master build result, apprise ("service yopass_yopass updated"), and
diun ("image ... was updated in its registry") for every service labelled `diun.enable=true`.

## Operating

- Opt a service out of automatic updates (alerts continue):
  `docker service update --label-add shepherd.enable=false yopass_yopass`
- Freeze a release: pin the image, e.g.
  `docker service update --image quay.io/bywatersolutions/yopass:15.1.0 yopass_yopass`
  (shepherd then only follows that tag).
- Roll back the last update: `docker service rollback yopass_yopass`
- memcached is never auto-updated (`shepherd.enable=false`): every live secret exists only
  in its RAM, so an automatic restart would wipe them all. diun still announces new versions.
- Watch the updaters: `docker service logs -f updaters_shepherd`, `docker service logs updaters_diun`.
- The Quay repository is public. If it is ever made private, run `docker login quay.io` on the
  manager, deploy the yopass stack with `--with-registry-auth`, and set `WITH_REGISTRY_AUTH=true`
  on shepherd.
