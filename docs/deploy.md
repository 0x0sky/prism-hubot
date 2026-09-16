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
| `SSH_DEPLOYMENT_PATH` | yes | Absolute deployment root, `/opt/prism-hubot` on the current VPS |
| `SSH_PORT` | no | SSH port, defaults to `22` |
| `SSH_KNOWN_HOSTS` | no | Pinned host key. Without it the workflow uses `ssh-keyscan`, which trusts the key presented at deploy time |

## Repository variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `DEPLOY_RESTART_COMMAND` | `sudo -n systemctl restart prism-hubot.service` | Command run over SSH after the release is installed |
| `DEPLOY_HEALTHCHECK_URL` | unset | URL curled from the VPS after restart, for example `http://127.0.0.1:9292/healthz`. Skipped when unset |

## Remote layout

The current VPS deploys to `/opt/prism-hubot` as the `deploy` user, so the
defaults below and in `deploy/install-service.sh` use those values.

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
  values, in the syntax systemd reads (see [Environment file](#environment-file)).
  It is never written by CI and never committed;
- a restart path that needs no TTY — either passwordless `sudo -n systemctl
  restart prism-hubot.service` for the deploy user, or a user unit restarted
  through `DEPLOY_RESTART_COMMAND`.

`shared/.env` and `shared/var/interaction-state` hold runtime configuration and
short-lived interaction state. Keep them owned by the deploy user and not world
readable; the workflow sets mode `0700` on the state directory.

## Environment file

`shared/.env` is read by systemd as an `EnvironmentFile=`, not by a shell. The
two are different languages, and the difference is not cosmetic: `bash` executes
what it reads, so `PRISM_BOT_TELEGRAM_TOKEN=<from-botfather>` is a redirection,
`SECRET=a|b` is a pipeline, and `URL=$(cat /etc/shadow)` is a command
substitution. A file the service starts from perfectly well used to abort the
deployment with `syntax error near unexpected token`.

Nothing in this repository sources that file any more. Deployment tasks read it
with `PrismHubot::EnvFile`, a transcription of systemd's own parser, so what the
tasks see is what the running service sees:

- `NAME=value`, one assignment per line; no `export`, and no whitespace around
  the `=`;
- `#` or `;` in the first non-blank column starts a comment;
- single and double quotes protect whitespace, `#` and shell metacharacters, and
  may span lines; `\` escapes the next character and continues the line at the
  end of one;
- trailing whitespace of an unquoted value is dropped;
- no variable expansion and no command substitution. `$` is a literal `$`.

systemd ignores lines it cannot parse and starts the service without them, which
looks exactly like a credential that was never set. `Deploy` therefore checks the
file after installing the release and before repointing `current`, so a bad line
fails while the previous release is still serving. Run the same check by hand:

```bash
cd /opt/prism-hubot/current
bundle exec rake env:check
```

It prints variable names, never values, and exits non-zero when systemd would
drop a line, quoting the line number.

## systemd unit

The unit is shipped with the repository as a template
(`deploy/prism-hubot.service`) and installed by `deploy/install-service.sh`. Run
it once on the VPS, as root, from a checkout of this repository, before the
first deployment:

```bash
sudo DEPLOY_PATH=/opt/prism-hubot DEPLOY_USER=deploy ./deploy/install-service.sh
```

The script substitutes the deployment path, service user, `bundle` path, bind
address and port into the unit, writes it to
`/etc/systemd/system/prism-hubot.service`, writes a `sudoers` drop-in that lets
the deploy user restart that unit without a password or TTY, reloads systemd and
enables the unit. It deliberately does not start it: the unit needs
`$DEPLOY_PATH/current`, which the first `Deploy` run creates. Re-running the
script is safe.

Overridable environment variables: `DEPLOY_PATH` (`/opt/prism-hubot`),
`DEPLOY_USER` (`deploy`), `BIND_ADDRESS` (`127.0.0.1`), `PORT` (`9292`),
`BUNDLE_BIN` (resolved from the deploy user's `PATH`), `UNIT_NAME`
(`prism-hubot.service`) and `INSTALL_SUDOERS` (`yes`).

`WorkingDirectory` points at the `current` symlink, so a restart after a deploy
picks up the new release. Terminate TLS in front of the process and forward
Telegram webhook requests to `/telegram/webhook`; `/healthz` stays internal.

If the service is managed some other way — a user unit, a container, a different
unit name — leave this script alone and set the `DEPLOY_RESTART_COMMAND`
repository variable instead. The workflow checks before uploading anything: with
no `DEPLOY_RESTART_COMMAND` set, it requires `prism-hubot.service` to exist on
the host and fails with installation instructions when it does not.

## Telegram command menu

The in-app command list (the `/` menu in Telegram clients) is server-side state
owned by the bot token, not by the running process: a bot that never calls
`setMyCommands` shows an empty menu no matter how many commands it routes.
`lib/prism_hubot/command_menu.rb` is the single source of truth for that list,
and `/help` is rendered from the same entries, so the menu and the help text
cannot drift. A test asserts the menu covers exactly the routed commands.

`Deploy` publishes it on every run (`Sync Telegram command menu`). The task reads
the token from `.env` in the working directory, which in a release is the symlink
to `shared/.env`; `PRISM_HUBOT_ENV_FILE` overrides the path, and variables
already exported into the process win over the file. To do it by hand:

```bash
cd /opt/prism-hubot/current
bundle exec rake telegram:commands         # publish the menu
bundle exec rake telegram:commands_status  # show what Telegram currently serves
```

The menu is per bot token and global, so it applies to every chat at once.
Telegram clients cache it; an open chat may need a restart to redraw the list.

## Telegram webhook

`prism-bot` serves `/telegram/webhook` but never registers it, so a fresh bot
token receives nothing until an operator points Telegram at the deployment. An
unregistered webhook looks exactly like a broken bot: every command is routed
correctly and no update ever arrives.

Set `PRISM_HUBOT_WEBHOOK_URL` in `shared/.env` to the public HTTPS URL of
`/telegram/webhook`, then:

```bash
cd /opt/prism-hubot/current
bundle exec rake telegram:webhook         # register it
bundle exec rake telegram:webhook_status  # url, pending updates, last error
```

Registration is idempotent and is deliberately not part of `Deploy`: the
public URL belongs to the fronting TLS terminator, not to a release. Re-run it
when the public URL or the webhook secret changes.

`telegram:webhook` sends `secret_token`, and the process rejects updates whose
`X-Telegram-Bot-Api-Secret-Token` header does not match
`PRISM_BOT_TELEGRAM_WEBHOOK_SECRET`. A `last_error_message` of `403` in
`webhook_status` therefore means the two have drifted apart.

## Rollback

```bash
ln -sfn "/opt/prism-hubot/releases/<previous-sha>" "$DEPLOY_PATH/current.tmp"
mv -T "/opt/prism-hubot/current.tmp" "/opt/prism-hubot/current"
sudo systemctl restart prism-hubot.service
```

Re-running `Deploy` with an older `ref` is equivalent and keeps the release
history consistent.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
