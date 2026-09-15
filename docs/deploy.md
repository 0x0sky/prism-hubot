# Deployment

`prism-hubot` deploys to a single VPS over SSH with the `Deploy` workflow
(`.github/workflows/deploy.yml`). The workflow is release-directory based: each
deployment lands in its own directory, shared runtime state stays outside the
release, and `current` is repointed atomically.

## Trigger

- automatically after `Full CI` succeeds on `master`;
- manually via `workflow_dispatch`, optionally with an explicit `ref`.

`workflow_run` triggers only fire for a workflow file that exists on the default
branch, so the first deployment after merging this change must be started
manually.

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

## Server bootstrap

One-time preparation as `root`, for `SSH_DEPLOYMENT_PATH=/srv/prism-hubot`. The
deploy account is called `deploy` here; use whatever name `SSH_USER` holds and
keep it consistent across the sudoers rule and the unit.

The account must exist before any `install -o deploy` call, otherwise `install`
reports `invalid user: 'deploy'`. Verify with `id deploy` before continuing.

```bash
adduser --system --group --home /home/deploy --shell /bin/bash deploy

install -d -o deploy -g deploy -m 700 /home/deploy/.ssh
install -o deploy -g deploy -m 600 /dev/null /home/deploy/.ssh/authorized_keys
# append the public half of SSH_PRIVATE_KEY to that file

install -d -o deploy -g deploy -m 755 /srv/prism-hubot
```

Omitting `-g` is not fatal: the directory is then owned by `deploy:root`, and
`0755` still lets the deploy user write inside it, so the workflow works. Pass
it anyway so ownership is deliberate rather than inherited from the creating
shell. Whatever was used, `Group=` in the unit must match `id -gn deploy`.

The deploy user needs exactly one privileged capability — restarting the unit —
and nothing else. Read what it already has before adding anything:

```bash
sudo -l -U deploy
```

If that output already grants `NOPASSWD` on `systemctl`, the default
`DEPLOY_RESTART_COMMAND` works as is and no new rule is needed. Otherwise add
one in `/etc/sudoers.d/deploy` (mode `0440`, validated with `visudo -cf`):

```text
deploy ALL=(root) NOPASSWD: /usr/bin/systemctl restart prism-hubot.service
```

Resolve the real path first with `command -v systemctl` — it is
`/usr/bin/systemctl` on a usr-merged Debian or Ubuntu and `/bin/systemctl`
elsewhere — because a sudoers rule that does not match the real path silently
fails to apply. Confirm with
`sudo -u deploy sudo -n systemctl restart prism-hubot.service` once the unit
exists.

Read that same output for what it grants beyond a restart. An unrestricted
`NOPASSWD` entry for `systemctl` or `systemd-run` is arbitrary root execution,
not a narrow restart permission, and membership in `sudo` or in a group that
grants container control such as `docker` has the same effect. Where any of
those hold, `SSH_PRIVATE_KEY` is a root credential for the machine and the
narrow rule above changes nothing. Either strip the account down to the restart
rule, give the deployment its own account separate from the interactive one, or
accept the blast radius deliberately.

Ruby `4.0.6`, Bundler and `git` must resolve on the deploy user's `PATH`:

```bash
sudo -u deploy bash -lc 'ruby -v; command -v bundle; command -v git'
```

A login shell is required here because `command` is a shell builtin, so
`sudo -u deploy command -v bundle` fails with `command not found`. If Ruby
comes from a per-user version manager rather than a system package, the systemd
unit needs the absolute path this prints, because systemd does not read login
shell configuration.

Finally, create `/srv/prism-hubot/shared/.env` from `.env.example`, owned by
`deploy` with mode `600`. The remaining directories are created by the workflow
on its first run.

## Suggested systemd unit

`/etc/systemd/system/prism-hubot.service`:

```ini
[Unit]
Description=prism-hubot Telegram client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=deploy
Group=deploy
WorkingDirectory=/srv/prism-hubot/current
EnvironmentFile=/srv/prism-hubot/shared/.env
ExecStart=/usr/bin/bundle exec rackup config.ru -s Puma -o 127.0.0.1 -p 9292
Restart=on-failure
RestartSec=5

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/srv/prism-hubot/shared/var/interaction-state

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now prism-hubot.service
```

Notes on the unit:

- `WorkingDirectory` points at the `current` symlink, so a restart after a
  deployment picks up the new release without editing the unit. It does not
  exist until the first successful deployment, so enable the unit after the
  workflow has run once, or expect the first start to fail;
- `User`/`Group` must match the deploy account, so the service reads the same
  interaction state the deployment writes;
- replace the `ExecStart` path with the output of
  `sudo -u deploy bash -lc 'command -v bundle'`. systemd resolves no login
  shell, so a version-manager shim is not on its `PATH`;
- `ProtectSystem=strict` makes the whole filesystem read-only for the service.
  `ReadWritePaths` reopens only the interaction-state directory, which matches
  what the process actually writes. Point it at
  `PRISM_HUBOT_INTERACTION_STATE_DIR` if that variable is set to another path;
- `ProtectHome=yes` hides `/home`, which is fine for a deployment under `/srv`
  but would hide the release itself under a home-directory deployment path;
- `EnvironmentFile` is parsed by systemd, not by a shell: plain `KEY=VALUE`
  lines, no `export`, no shell interpolation. `.env.example` already has that
  shape;
- terminate TLS in front of the process and forward Telegram webhook requests
  to `/telegram/webhook`. `/healthz` stays bound to `127.0.0.1` and is not
  exposed publicly.

## Public endpoint

The deployment leaves the process bound to `127.0.0.1:9292`. Telegram only
delivers updates to a public HTTPS URL, so a reverse proxy and a certificate
are required before the bot receives anything. Neither is created by the
workflow.

What has to exist, once:

1. a DNS `A` record for the public hostname pointing at the server's IPv4
   address (add `AAAA` only if the host really serves IPv6);
2. a reverse proxy terminating TLS and forwarding to `127.0.0.1:9292`;
3. inbound `443` open in the Hetzner Cloud firewall and any host firewall;
4. a Telegram webhook registered against that hostname.

Caddy obtains and renews the certificate on its own. `/etc/caddy/Caddyfile`:

```text
prism.example.org {
  reverse_proxy 127.0.0.1:9292
}
```

With nginx the certificate is a separate concern (`certbot --nginx`), and the
proxied location needs the usual forwarding headers:

```nginx
location / {
  proxy_pass http://127.0.0.1:9292;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
}
```

Register the webhook after the service answers, using the same value as
`PRISM_BOT_TELEGRAM_WEBHOOK_SECRET`. Read both values from the environment
rather than typing them into a shell that records history:

```bash
set -a && . /srv/prism-hubot/shared/.env && set +a
curl -fsS "https://api.telegram.org/bot$PRISM_BOT_TELEGRAM_TOKEN/setWebhook" \
  --data-urlencode "url=https://prism.example.org/telegram/webhook" \
  --data-urlencode "secret_token=$PRISM_BOT_TELEGRAM_WEBHOOK_SECRET"
```

`getWebhookInfo` on the same token reports the registered URL and the last
delivery error, which is the first thing to read when updates stop arriving.

`/healthz` is for process liveness and stays internal: keep it unproxied and
point `DEPLOY_HEALTHCHECK_URL` at `http://127.0.0.1:9292/healthz`, which the
workflow curls from inside the VPS over SSH.

Registering the webhook is a one-time action against Telegram, not part of a
release, so the workflow does not perform it. It only changes when the public
hostname or the webhook secret changes.

## Troubleshooting

`Verify SSH connectivity` runs before anything is built or uploaded, so a
network problem fails the run in seconds rather than part way through a
release.

`Connection timed out` means packets are dropped rather than refused, so the
port is filtered somewhere:

- a Hetzner Cloud firewall attached to the server, or a host firewall, that does
  not allow the SSH port. GitHub-hosted runners come from a large, changing
  address range, so an allowlist of fixed source addresses will not work for
  them; open the port, or run the deployment from a self-hosted runner or a
  tunnel with a stable address;
- `SSH_HOST` holding an IPv6 address. GitHub-hosted runners are IPv4-only, so
  an AAAA-only target is unreachable from them;
- `sshd` listening on a non-default port, which belongs in `SSH_PORT`.

`Connection refused` instead means the host answered and nothing is listening
on that port. `Permission denied (publickey)` means the network is fine and the
public half of `SSH_PRIVATE_KEY` is missing from the deploy user's
`authorized_keys`.

Check reachability independently of CI before re-running:

```bash
nc -vz <host> 22
ssh -v -i <deploy-key> deploy@<host> true
```

## Rollback

```bash
ln -sfn "$DEPLOY_PATH/releases/<previous-sha>" "$DEPLOY_PATH/current.tmp"
mv -T "$DEPLOY_PATH/current.tmp" "$DEPLOY_PATH/current"
sudo systemctl restart prism-hubot.service
```

Re-running `Deploy` with an older `ref` is equivalent and keeps the release
history consistent.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
