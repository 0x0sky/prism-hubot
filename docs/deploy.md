# Deployment

`prism-hubot` deploys to a single VPS over SSH with the `Deploy` workflow
(`.github/workflows/deploy.yml`). The workflow is release-directory based: each
deployment lands in its own directory, shared runtime state stays outside the
release, and `current` is repointed atomically.

## Trigger

- manually via `workflow_dispatch`, optionally with an explicit `ref`.

Deploy is deliberately not triggered by merges or CI completion. Merging to
`master` runs the normal verification workflows only; an operator explicitly
starts `Deploy` and selects the ref to release.

Deployments are serialised through the `deploy-vps` concurrency group and run in
the `production` environment, so required reviewers or branch restrictions can be
attached there.

## Repository secrets

| Secret | Required | Meaning |
| --- | --- | --- |
| `SSH_HOST` | yes | VPS hostname or IP |
| `SSH_USER` | yes | SSH user that owns the deployment path |
| `SSH_PRIVATE_KEY` | yes | Private key for that user, full PEM including header and footer |
| `SSH_DEPLOYMENT_PATH` | yes | Absolute deployment root, for example `/srv/prism-hubot` |
| `SSH_PORT` | no | SSH port, defaults to `22` |
| `SSH_KNOWN_HOSTS` | no | Pinned host key. Without it the workflow uses `ssh-keyscan`, which trusts the key presented at deploy time |

## Repository variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `DEPLOY_RESTART_COMMAND` | `sudo -n systemctl restart prism-hubot.service` | Command run over SSH after the release is installed |
| `DEPLOY_HEALTHCHECK_URL` | unset | URL curled from the VPS after restart, for example `http://127.0.0.1:9292/healthz`. Skipped when unset |

## Remote layout

```text
$SSH_DEPLOYMENT_PATH/
  current -> releases/<sha>
  releases/<sha>/
  shared/
    .env
    bundle/
    var/interaction-state/
```

Release directories are named by the commit actually checked out for that run,
resolved with `git rev-parse HEAD` after checkout. A manual deployment of a
non-default `ref` therefore lands under its own commit and cannot overwrite an
unrelated release.

The workflow creates `releases/`, `shared/bundle/`, and
`shared/var/interaction-state/` on first run. Each release symlinks
`.env` and `var/interaction-state` into `shared/`, so conversational state
survives releases as `PRISM_HUBOT_INTERACTION_STATE_DIR` requires. The five most
recent releases are kept.

## Server prerequisites

The workflow does not provision the machine. It fails with an explicit message
when any of these is missing:

- Ruby `4.0.6` (see `.ruby-version`) and Bundler on the deploy user's `PATH`;
- `git`, because `aiaiaiai-prism-bot` is a pinned Git dependency;
- `$SSH_DEPLOYMENT_PATH/shared/.env`, created from `.env.example` with real
  values. It is never written by CI and never committed;
- a restart path that needs no TTY — either passwordless `sudo -n systemctl
  restart prism-hubot.service` for the deploy user, or a user unit restarted
  through `DEPLOY_RESTART_COMMAND`.

`shared/.env` and `shared/var/interaction-state` hold runtime configuration and
short-lived interaction state. Keep them owned by the deploy user and not world
readable; the workflow sets mode `0700` on the state directory.

## Suggested systemd unit

```ini
[Unit]
Description=prism-hubot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=prism
WorkingDirectory=/srv/prism-hubot/current
EnvironmentFile=/srv/prism-hubot/shared/.env
ExecStart=/usr/local/bin/bundle exec rackup config.ru -s Puma -o 127.0.0.1 -p 9292
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`WorkingDirectory` points at the `current` symlink, so a restart after a deploy
picks up the new release. Terminate TLS in front of the process and forward
Telegram webhook requests to `/telegram/webhook`; `/healthz` stays internal.

## Rollback

```bash
ln -sfn "$DEPLOY_PATH/releases/<previous-sha>" "$DEPLOY_PATH/current.tmp"
mv -T "$DEPLOY_PATH/current.tmp" "$DEPLOY_PATH/current"
sudo systemctl restart prism-hubot.service
```

Re-running `Deploy` with an older `ref` is equivalent and keeps the release
history consistent.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
