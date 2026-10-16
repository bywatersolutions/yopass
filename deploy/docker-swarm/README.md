# Sharepass on Docker Swarm (prod-bwsdocker01)

Stacks in this directory:

- `yopass-stack.yml`: the production `yopass` stack (Sharepass + Redis with persistence
  on the `yopass_redis-data` volume), with the Traefik labels for
  sharepass.tools.bywatersolutions.com. Source of truth; redeploy after any change.
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

Secrets are stored in Redis with AOF persistence (fsync every second) plus RDB snapshots,
on the `yopass_redis-data` volume, so restarts and updates of the Redis service keep them.
Back up `/data` in that volume (`appendonlydir/` and `dump.rdb`) to keep them across a
host loss.

## How a new version reaches production

1. `.github/workflows/bws-sync-upstream.yml` (daily) sees a new upstream release,
   replays our commits onto it, pushes branch `<version>` and moves `master`.
2. `.github/workflows/bws-build.yml` builds `quay.io/bywatersolutions/yopass:<version>`
   from the branch and, from `master`, also moves `:latest`.
3. The host's shepherd notices the new `:latest` digest and rolls the `yopass` service
   (start-first, rollback on failure). Our images are pushed with Docker v2 manifests
   because that shepherd's Docker CLI cannot read OCI manifests. Redis
   (`mirror.gcr.io/library/redis:8.10-alpine`) is updated by hand when diun reports a
   patch release; a restart is safe because Redis reloads its data from the volume.

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
