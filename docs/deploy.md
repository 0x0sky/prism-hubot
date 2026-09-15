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

`deploy/bootstrap.sh` performs the one-time server preparation. It is
idempotent: rerunning it after installing a dependency or changing a value is
the intended way to use it, and it never rewrites an existing `shared/.env`.

```bash
sudo DEPLOY_USER=deploy DEPLOY_PATH=/srv/prism-hubot \
  PUBLIC_HOST=prism.example.org deploy/bootstrap.sh
```

It creates the deploy account and its `.ssh` directory, the deployment root and
shared directories, a sudoers rule scoped to restarting the service, and the
systemd unit rendered from `deploy/prism-hubot.service` with the account,
paths, and the real `bundle` path resolved through the deploy user's login
shell. With `PUBLIC_HOST` set and Caddy installed, it also renders
`deploy/Caddyfile` and reloads Caddy.

It exits non-zero while anything on the host still needs a decision, and lists
what: an empty `authorized_keys`, a `shared/.env` still holding placeholders,
a missing Bundler, a `current` symlink that does not exist yet. Rerun it after
each of those is resolved until it exits clean.

Two ordering details it handles rather than hides:

- the unit is installed but not enabled until `current` exists, because that
  symlink appears only after the first successful deployment. Run the workflow
  once, then rerun the script;
- an account that already carries a passwordless `systemctl` grant gets no new
  sudoers rule. Read `sudo -l -U deploy` before trusting the narrow rule: an
  unrestricted `NOPASSWD` entry for `systemctl` or `systemd-run`, or membership
  in `sudo` or `docker`, is arbitrary root execution, which makes
  `SSH_PRIVATE_KEY` a root credential for the machine regardless of what the
  rule says.

The unit binds the process to `127.0.0.1` and grants it one writable path,
`shared/var/interaction-state`. `WorkingDirectory` points at `current`, so a
restart after a deployment picks up the new release without editing the unit.
`EnvironmentFile` is parsed by systemd rather than a shell: plain `KEY=VALUE`
lines, no `export`, no interpolation, which is the shape `.env.example`
already has.

## Public endpoint

The service listens on loopback. Telegram delivers updates only to a public
HTTPS URL, so a reverse proxy, a certificate and a DNS record have to exist
before the bot receives anything. Caddy needs no application code; it obtains
and renews the certificate itself.

`deploy/Caddyfile` proxies `/telegram/webhook` to the application and answers
`404` everywhere else, so `/healthz` is not published: it stays a loopback
liveness probe, which is what `DEPLOY_HEALTHCHECK_URL` should point at
(`http://127.0.0.1:9292/healthz`, curled from inside the VPS over SSH).

Register the webhook once the service answers:

```bash
sudo deploy/set-webhook.sh prism.example.org
```

The script reads the token and `PRISM_BOT_TELEGRAM_WEBHOOK_SECRET` from the
deployed `.env`, refuses to run while either still holds a placeholder, keeps
the token out of the argument list, and prints `getWebhookInfo` afterwards.
That output reports the registered URL and the last delivery error, which is
the first thing to read when updates stop arriving. Rerun it only when the
hostname or the webhook secret changes.

## What stays manual

Nothing above reaches outside the machine, so these remain operator actions:

- a DNS `A` record for the public hostname pointing at the server's IPv4
  address. Add `AAAA` only if the host really serves IPv6;
- inbound `443`, and the SSH port for the workflow, allowed in the Hetzner
  Cloud firewall and in any host firewall;
- the public half of `SSH_PRIVATE_KEY` appended to the deploy user's
  `authorized_keys`;
- real values in `$SSH_DEPLOYMENT_PATH/shared/.env`;
- the repository secrets and variables listed above;
- installing Ruby, Bundler, `git` and Caddy. The script reports which of them
  are missing but does not choose a package source for the machine.

A workable order: secrets and SSH reachability first, so the workflow can land
a release; then `deploy/bootstrap.sh` until it exits clean; then DNS and Caddy;
then `deploy/set-webhook.sh` last.

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
