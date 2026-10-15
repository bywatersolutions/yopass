# Sharepass on Docker Swarm (prod-bwsdocker01)

Stacks in this directory:

- `yopass-stack.yml`: the production `yopass` stack (Sharepass + memcached), with the
  Traefik labels for sharepass.tools.bywatersolutions.com. Source of truth; redeploy
  after any change.
- `diun-stack.yml`: diun, which posts to Slack when a watched image has a newer version
  in its registry.
- `shepherd-stack.yml`: shepherd + apprise for a host that has no shepherd. prod-bwsdocker01
  already runs one (stack `shepherd`), so it is not deployed there.

## Deploy

On a manager node, from a checkout of this repo:

```
# once: the #devops incoming webhook, for diun (docker secret, stays out of git)
printf '%s' 'https://hooks.slack.com/services/T.../B.../xxx' | docker secret create slack_devops_webhook -

docker stack deploy -c deploy/docker-swarm/yopass-stack.yml yopass
docker stack deploy -c deploy/docker-swarm/diun-stack.yml diun
```

The memcached service is pinned to the digest it is running and keeps the same task
spec, so redeploying the stack does not restart it. Every live secret exists only in its
RAM; bump the digest only in a planned maintenance window.

## How a new version reaches production

1. `.github/workflows/bws-sync-upstream.yml` (daily) sees a new upstream release,
   replays our commits onto it, pushes branch `<version>` and moves `master`.
2. `.github/workflows/bws-build.yml` builds `quay.io/bywatersolutions/yopass:<version>`
   from the branch and, from `master`, also moves `:latest`.
3. The host's shepherd notices the new `:latest` digest and rolls the `yopass` service
   (start-first, rollback on failure). memcached carries `shepherd.autodeploy=false` and
   `shepherd.enable=false` so no updater touches it.

Slack (#devops) messages along the way: the sync result (synced, or conflict with a
GitHub issue), the master build result, and diun's "updated in registry" for every
service labelled `diun.enable=true`.

## Operating

- Freeze a release: `docker service update --image quay.io/bywatersolutions/yopass:15.1.0 yopass_yopass`
  (shepherd then only follows that tag), or edit the image in the stack file and redeploy.
- Roll back the last update: `docker service rollback yopass_yopass`
- Opt a service in or out of diun alerts: `docker service update --label-add diun.enable=false <svc>`
- Watch diun: `docker service logs diun_diun`
- The Quay repository is public. If it is ever made private, run `docker login quay.io` on the
  manager and deploy the yopass stack with `--with-registry-auth`.
