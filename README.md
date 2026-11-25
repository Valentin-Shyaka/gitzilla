# gitzilla

Tells your phone within about a minute when someone pushes to your GitHub repos from anywhere but your Mac, and
(after one click) puts the branches back. It was built after a stolen GitHub token force-pushed malware (PolinRider)
to dozens of branches while the owner's laptop was asleep. It runs on macOS, uses Secure-Enclave keys from
[Secretive](https://github.com/maxgoedjen/secretive), a free Cloudflare Worker and the ntfy phone app, and stores
no credential that can push code.

## How it works

- **Push note.** A global `pre-push` hook signs a small note (`repo, ref, old, new, time, nonce`) with a
  Secure-Enclave key (`push-note`, no Touch ID) and sends it to your Cloudflare Worker before the push goes out.
  The hook also scans the pushed commits with the bundled scanner (polin-guard plus extra checks) and blocks a
  push that carries a known payload.
- **Webhook.** A private GitHub App (read-only: Contents, Metadata) sends push events to the same Worker.
  A push with no matching note is an alert: orange for one stray push, red for a force-push, a burst across
  repos, or the app being uninstalled / losing repos ("gitzilla disarmed").
- **Alerts** go to ntfy (phone) and, if you set it up, Slack; red alerts can also ring your phone (ntfy Pro). They
  carry repo, ref, SHAs and flags, never commit content.
- **Mac agent** (`bin/agent`, every 5 min) drains the Worker queue, keeps bare mirrors of all repos up to date,
  deep-checks suspicious pushes (unsigned commits, scanner hits) and can upgrade orange to red.
- **Restore** (`bin/restore`) rewinds the affected branches from the local mirrors, after you confirm.
- **Reconcile** (`bin/reconcile`, hourly) is the backup if a webhook never arrives: it compares remote heads with
  the known ones, and watches your account for any new SSH authentication or signing key.
- **Rotate** (`bin/rotate`, daily check) walks you through replacing the `gh` token and the SSH login key every
  5 days.

Design record: `docs/design.md`.

## Prerequisites

- macOS (the scripts run on the system `/bin/bash` 3.2)
- [Secretive](https://github.com/maxgoedjen/secretive) in `/Applications`, with your GitHub SSH login key in it
  (walkthrough below)
- `gh` (GitHub CLI), logged in: `gh auth login`
- Node.js and npm, `jq` (`brew install gh node jq`); `git`, `curl`, `openssl` ship with macOS
- a Cloudflare account (the free plan is enough); the installer logs in with `wrangler login` and logs out again
- the [ntfy](https://ntfy.sh) app on your phone
- optional: a Slack incoming-webhook URL
- optional: an [ntfy Pro](https://ntfy.sh/#pricing) account with verified phone numbers, for voice calls on red alerts
- strongly recommended: SSH-signed commits (see "Commit signing" below)

### Secretive SSH setup

The installer, mirrors, restore and `rotate ssh` all use `~/.ssh/github-auth.pub` as your GitHub
authentication key, held by Secretive. The `prereqs` step stops if it is missing.

1. Open Secretive, click **+**, name the key `github-auth`, Require authentication: Touch ID.
2. Select the key, **Copy Public Key**, then save it: `pbpaste > ~/.ssh/github-auth.pub`.
3. Add it at https://github.com/settings/keys as an **Authentication key** ("New SSH key", key type
   Authentication).
4. Point SSH for github.com at Secretive in `~/.ssh/config`:

   ```
   Host github.com
     IdentityAgent ~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh
     IdentityFile ~/.ssh/github-auth.pub
     IdentitiesOnly yes
   ```

5. Check: `ssh -T git@github.com` asks for Touch ID and greets you by login.

### Commit signing

The agent and restore check commit signatures against your allowed-signers file: the one named by
`git config --global gpg.ssh.allowedSignersFile` (a leading `~` is expanded), else `~/.config/git/allowed_signers`.
A commit not signed by a key in that file counts as unsigned, which turns an orange alert red, and restore only
returns a branch to a signed commit. Without the file every push that has no note becomes a red alert; the
`prereqs` step warns about this but carries on.

```
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/git-signing.pub      # a Secretive key's public half
git config --global commit.gpgsign true
git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers
echo "you@example.com $(cat ~/.ssh/git-signing.pub)" >> ~/.config/git/allowed_signers
```

Add the same public key at https://github.com/settings/keys as a **Signing key**.

## Install

```
git clone https://github.com/Valentin-Shyaka/gitzilla && cd gitzilla && ./install.sh
```

Keep the clone where it is: the hook, the LaunchAgents and the config point at it. If you move or delete it, the
hook stops scanning and sending notes (pushes still go through, each one an orange alert, and every push prints
"install dir ... not found") until you rerun `./install.sh --from-step hook` from the new place or remove the hook
(Uninstall). The installer is resumable:
`~/.local/state/gitzilla/install-step` holds the last completed step and a rerun continues after it;
`--from-step <name>` forces a start point (and runs everything after it).

| Step | What it asks / does |
|---|---|
| `prereqs` | checks the tools, Secretive, `gh auth status` and `~/.ssh/github-auth.pub` |
| `note-key` | you create a key named `push-note` in Secretive (Authentication: **Not Required**, so the hook can sign without a prompt) and copy its public key; it is saved to `~/.config/gitzilla/push-note.pub` |
| `worker` | `npm ci`, `wrangler login` (browser), deploys the Worker with the note public key, then prints the webhook secret and a random ntfy topic **once** and puts them as Worker secrets. Asks for the Slack URL (hidden; press Enter to skip Slack), then the phone numbers for red-alert calls (hidden; comma-separated `+E164`, 1 to 5; press Enter to skip calls) and, if you gave numbers, the ntfy access token (hidden; `tk_` and 29 letters or digits). A mistyped Slack URL, number or token is asked again (3 tries); if it still fails, the step stops before any secret is put, and the webhook secret and topic it printed are not saved (rerun `--from-step worker` and type `rotate`). Runs `wrangler logout` and checks no Cloudflare token is left on disk. Alerts show times in UTC and in your zone: the deploy passes `ALERT_TZ` (the Mac's zone from `/etc/localtime`, or `GITZILLA_ALERT_TZ=Europe/Paris ./install.sh --from-step worker`; an unknown zone falls back to UTC). Writes `~/.config/gitzilla/config` (`OWNER`, `GITZILLA_URL`, `APP_NAME`, `DRILL_REPO`, `ALERT_TZ`, ...). On a rerun it asks whether to keep the secrets (default, redeploy only) or `rotate` them |
| `github-app` | prints the exact settings for your GitHub App (`gitzilla-<your login>`, cut to 34 characters) and opens the new-app page; you create it, generate a private key (GitHub requires one before install) and install it on **all** repositories. The installer then deletes the downloaded `<app-name>.*.private-key*.pem` from `~/Downloads` after you confirm. If your drill repo does not exist it offers to create it (private). You push one commit to the drill repo; the installer waits until the push shows up in the Worker queue |
| `hook` | installs the push note in your global `pre-push` hook (see below) |
| `repos` | `gh repo list` into `repos.txt` (`<owner/repo> public\|private` per line) |
| `mirrors` | a bare mirror of every repo over one SSH session (one Touch ID), never auto-gc'd (restore needs old commits), then `reconcile seed` baselines them |
| `known-keys` | shows the SSH keys GitHub lists for you; you type `yes` to trust them as the baseline |
| `launchd` | installs three LaunchAgents: `agent` (every 5 min), `reconcile` (hourly), `rotate` (daily 10:00) |
| `first-rotation` | `rotate gh`: replaces your gh login with a fine-grained, 7-day, read-mostly token |
| `self-test` | a signed push (no alert), a `--no-verify` push (orange alert on the phone) and, if you say yes, a test alert to every channel (`bin/notify-test`; rings the phone if calls are set up) |

In the ntfy app, subscribe to the topic printed in the `worker` step.

**Drill repo.** A throwaway repo the installer and the drill push to, never a real one. The default name is
`gitzilla-drill`; to use another, set it before the `worker` step: `GITZILLA_DRILL_REPO=my-drill ./install.sh`
(or `--from-step worker`). It is saved as `DRILL_REPO` in the config.

**Global pre-push hook.** The hook step reads `git config --global --includes core.hooksPath` (a value in an
included dotfile counts, and is used as it is):

- not set: it lists what is already in `~/.config/git/hooks` and asks before setting `core.hooksPath` there (the
  installer records that in `~/.local/state/gitzilla/install-set-hookspath`). A global hooks path makes git
  ignore each repo's own `.git/hooks`; the installed hook runs the repo's `pre-push` itself (from the shared git dir,
  so worktrees work too), but other repo-local hooks (pre-commit, ...) stop running. If you decline, set your own
  global hooks dir (`git config --global core.hooksPath <absolute dir>`) and rerun `./install.sh --from-step hook`.
- a relative `core.hooksPath` (e.g. `.githooks`) is per-repo, not global: the step refuses it.
- a `core.hooksPath` set only in the system config (`/etc/gitconfig`) is not detected; the global value the step
  writes would override it, so set the global value to that directory yourself first.
- no hook there: it installs `hooks/pre-push` from this repo. That hook scans the pushed commits with
  `scanner/scan.sh` and blocks on a finding (before any note is sent), sends the note (fail-open), then runs the
  repo's own `pre-push` with the same input and exits with its status.
- a polin-guard hook (or one already carrying the note): it inserts the two note lines after the scan loop.
- any other hook (after a yes): it is backed up (`pre-push.bak-gitzilla`), moved to
  `pre-push.gitzilla-prev` and run by the new hook as `gitzilla-prev/pre-push` (still named
  `pre-push`) with the same input and arguments; its exit status still decides the push. A hook that was not
  executable (git ignored it) stays that way and is not run. Because it now runs from the `gitzilla-prev/`
  subdirectory, a hook that loads files next to itself via `$(dirname "$0")` must use absolute paths instead.
  Keep `gitzilla-prev/` (it only holds that link); if it goes missing, rerun `--from-step hook`.

The step also records the absolute `node` (`scanner/node-path`) and `jq` (`~/.config/gitzilla/jq-path`),
and the hook appends `/opt/homebrew/bin:/usr/local/bin` to `PATH` as fallbacks (your own hooks keep your PATH order), so pushes from GUI clients (GitHub Desktop, Tower,
Xcode) still scan and send notes.

**The scan blocks pushes everywhere.** The hook runs on every push from this Mac, to any remote (work servers,
GitLab, ...), not only your GitHub account. A finding blocks the push, and so does a scan that cannot run (for
example node was removed); the message says why. If you are sure the push is fine, bypass the hook once with
`git push --no-verify`; for a push to your own GitHub account that raises an orange alert.

**Repos with their own hooks path (husky, lefthook, `.githooks`).** A repo-level `core.hooksPath`
(`git config --local core.hooksPath`, set by husky v5+, lefthook and similar) overrides the global one, so in those
repos the gitzilla hook never runs: no scan, no note, and every push is an orange alert (red with unsigned commits).
Fix it per repo, either by calling the global hook from the repo's pre-push hook (for husky, add to
`.husky/pre-push`: `"$(git config --global --includes --get core.hooksPath | sed "s|^~|$HOME|")/pre-push" "$@" || exit $?` — note
that stdin must be passed through, so put it first in the file), or by adding the two note lines from
`hooks/pre-push` (`# gitzilla: push note` and the `bin/note` line, after reading stdin into `input`).
`git config --get-regexp core.hookspath` inside a repo shows whether it has one.

Rerunning `worker` keeps the existing secrets unless you type `rotate`. After a rotate, `github-app` does not create
a second app: it asks you to edit the existing app's webhook secret at
`https://github.com/settings/apps/<app-name>/advanced` and to re-subscribe the phone to the new ntfy topic.

Slack: an empty Slack URL only skips setting the secret. If you rotate the secrets with an empty URL after Slack was
set up once, the old `SLACK_WEBHOOK_URL` secret stays in the Worker and alerts keep going to Slack. To stop them:
`cd worker && npx wrangler login && npx wrangler secret delete SLACK_WEBHOOK_URL && npx wrangler logout`
(then revoke the webhook in Slack).

Calls work the same way: pressing Enter at the phone-number prompt only skips setting `NTFY_CALL_NUMBERS` and
`NTFY_CALL_TOKEN`. To stop calls that were set up before:
`cd worker && npx wrangler login && npx wrangler secret delete NTFY_CALL_NUMBERS && npx wrangler secret delete NTFY_CALL_TOKEN && npx wrangler logout`
(then delete the token at https://ntfy.sh/account). To change the numbers or the token, rerun
`./install.sh --from-step worker` and type `rotate` (this also regenerates the webhook secret and ntfy topic).

Files: config in `~/.config/gitzilla/`, state and logs in `~/.local/state/gitzilla/`
(`log/agent.out`, `log/reconcile.out`, `log/rotate.out`, `log/gitzilla.log`).

### Upgrading

After `git pull` in the clone, redeploy the Worker before relying on anything new, and in particular before
`bin/notify-test`: a Worker deployed by an older version rejects the test alert, and `notify-test` then prints
`test alert not sent: worker returned 400`.

- Redeploy only (keeps every secret, the GitHub App and the phone subscription as they are):
  `GITZILLA_INSTALL_STOP_AFTER=worker ./install.sh --from-step worker`, and press Enter at the keep/rotate question.
  Without `GITZILLA_INSTALL_STOP_AFTER=worker`, `--from-step worker` also reruns every later step.
- Adding red-alert calls to an existing install: the call questions are asked only on the rotate path. Run
  `./install.sh --from-step worker` and type `rotate`. This regenerates the webhook secret and the ntfy topic as well
  as asking for the Slack URL, the numbers and the token. Then, in the `github-app` step that follows, paste the new
  webhook secret into the existing app (`https://github.com/settings/apps/<app-name>/advanced`; the step asks for it),
  and subscribe the ntfy app on your phone to the new topic (unsubscribe from the old one). The later steps rerun as
  well; each keeps what is already in place.

### Profiles

One Mac can run more than one gitzilla (for example your personal one and an organization's). Each extra instance is
a profile: `GITZILLA_PROFILE=<name>` in front of `./install.sh` and the `bin/` commands (do not `export` it). The
name is 1 to 40 lower-case letters, digits or hyphens, starting with a letter or digit, and not one of the names
gitzilla uses for its own files in `~/.config/gitzilla/` or `~/.local/state/gitzilla/` (`config`, `jq-path`, `log`,
`mirrors`, `incidents`, `install-step`, `install-set-hookspath`, `install-secrets-rotated`, `queue-cursor`,
`queue-fail-since`, `queue-notified`, `health-notified`, `health-fail-since`, `reconcile-all-at`, `allowed_signers`, `gh`, `gh-token-checked-at`, `gh-token-notified`). A profile keeps
its config in `~/.config/gitzilla/<name>/`, its state, logs and mirrors in `~/.local/state/gitzilla/<name>/`, and its
launchd jobs as `io.github.gitzilla.<name>.agent|reconcile` (the jobs carry `GITZILLA_PROFILE`). It never reads or
writes the personal files or jobs. Without `GITZILLA_PROFILE` everything is as described above (the personal
instance).

What a profile does not do:

- **No Worker of a plain profile.** The `worker` step refuses in a profile made with `GITZILLA_PROFILE=<name>` alone,
  before any `wrangler` call or prompt: it would deploy over the personal Worker `gitzilla` and replace its secrets.
  A Worker of its own comes only with an org profile, made by `./install.sh --org <org-login>` (Organizations, below),
  which deploys the separately named Worker `gitzilla-<org>`. A plain `GITZILLA_PROFILE=<name> ./install.sh` stops at
  the `worker` step and changes nothing remote.
- **No rotation.** `~/.ssh/github-auth.pub` and the personal gh login belong to the personal instance, so only it
  rotates them: a profile gets no rotate job, `first-rotation` is skipped, and `bin/rotate` refuses.
- **Its own gh login.** In a profile, gitzilla runs `gh` with `GH_CONFIG_DIR=~/.config/gitzilla/<name>/gh` (and
  without any `GH_TOKEN` / `GITHUB_TOKEN` from the environment), never with the personal login. The `prereqs` step of
  a profile asks for that login's token (see "Set up an org Worker"); renew it the same way when it expires. The
  profile's hourly reconcile checks that token (`gh api user`) once a day, and every hour while it fails: when GitHub
  rejects it (expired, revoked, or no login) you get one Mac notification a day,
  `gitzilla (<name>): org token expired or revoked — restore can't run`, naming the renew command. Watching goes on
  either way; a network failure only logs. The `prereqs` step also checks that your personal `gh auth status` still
  passes after the profile's login and warns loudly (with `bin/rotate gh` / `gh auth login`) if it does not.
- **Notifications name the profile.** Mac notifications and the restore dialog of a profile are titled
  `gitzilla (<name>)` (for example `gitzilla (org-acme): CRITICAL`), so they are told apart from the personal ones.
- **No hook.** The global pre-push hook belongs to the personal instance: the `hook` step is skipped in a profile. Its
  push note always uses the personal config (and its `ORG_WORKERS`, below), even if `GITZILLA_PROFILE`,
  `GITZILLA_CONFIG_DIR` or `GITZILLA_STATE_DIR` is exported in the shell you push from.

## Organizations

An organization can run its own gitzilla Worker (org mode) that watches the org's repositories. An admin installs it
(`./install.sh --org <org-login>`, below). Each developer keeps their personal gitzilla and *joins* the org's: from
then on, a push to one of the org's repos sends its push note to the org's Worker, signed with the same `push-note`
key. In org mode a note only silences pushes made by the member who signed it (GitHub's `sender` of the push), and a
key counts only after an admin approves it. A pending enrollment never silences anything.

In short:

1. The admin runs `./install.sh --org acme` and gives the Worker URL it prints to the members.
2. Each member (the admin too) runs `./install.sh --join-org <url>` from their personal install and tells the admin
   the fingerprint it prints, in person or over a channel the admin trusts.
3. The admin approves each one: `GITZILLA_PROFILE=org-acme bin/org approve <login> <fingerprint>`.
4. GitHub App bots (`dependabot[bot]`, ...) are always silent unless they force-push; machine-user accounts are
   allowed with `bin/org allow-bot`; web-UI commits follow the web-flow setting.

### Join an org (members)

Your admin gives you the org Worker's URL. With your personal gitzilla installed (no `GITZILLA_PROFILE`):

```
./install.sh --join-org https://gitzilla-acme.example.workers.dev
```

It checks that the URL is an org Worker (its `/health` reports mode `org` and the org's login), asks it to enroll
your `push-note` key under your GitHub login, records `<org>=<url>` in `ORG_WORKERS` in
`~/.config/gitzilla/config`, and prints:

```
Tell your gitzilla admin this fingerprint: SHA256:...
```

Give that fingerprint to your admin yourself (in person, or over a channel where they know it is you). Until they
approve it, your pushes to the org's repos raise alerts like any unannounced push. Rerunning the command is safe: it
only asks the Worker again and says whether you are pending or already a member. To point a joined org at a new URL,
run it with the new URL and confirm. It only accepts `https://` URLs and refuses to run in a profile.

Notes for the org's repos fail open exactly like personal ones: if the org Worker cannot be reached the push still
goes through, with a warning, and the org's Worker alerts on it.

### Admin commands (admins)

Admins run `bin/org` in the org's profile; each command is signed with the profile's `push-note` key, which must be
one of the Worker's admin keys:

```
GITZILLA_PROFILE=<org-profile> bin/org list
GITZILLA_PROFILE=<org-profile> bin/org approve <login> <fingerprint>
GITZILLA_PROFILE=<org-profile> bin/org revoke <login> [<fingerprint>]
GITZILLA_PROFILE=<org-profile> bin/org allow-bot <login>       # a machine-user account, e.g. acme-ci
GITZILLA_PROFILE=<org-profile> bin/org disallow-bot <login>
```

- `list` shows the members and their key fingerprints, the pending enrollments (login, fingerprint, age) and the
  allowed bots. Pending requests expire after 7 days.
- `approve` needs the fingerprint as well as the login. **Anyone can ask to enroll under any login**, so a pending
  entry proves nothing about who sent it: approve only a fingerprint the member gave you directly (the one
  `--join-org` printed for them), and only if it matches the pending entry for that login exactly.
- `revoke <login>` removes every key of that login and clears its pending requests; with a fingerprint, only that key
  (or that pending request). Use it for a departing member, a lost Mac, or a request you did not expect. A note the
  member's key sent before the revoke stays valid for its 10 minutes: a push of that exact commit to that ref by that
  login within those 10 minutes is still silent. After a revoke for a suspected compromise, check the alerts and the
  org's repos for pushes by that login in the following 10 minutes.
- `allow-bot <login>` / `disallow-bot <login>` add or remove a machine-user account (a normal GitHub user account
  that a CI system pushes with) whose non-forced pushes are silent. They have no effect on GitHub App bots (see "Bots
  and the web UI").
- Logins are GitHub logins, lower-cased; `_` is accepted for Enterprise Managed Users (`<user>_<shortcode>`), up to
  39 characters.
- On an error the command prints the Worker's message (for example `no such pending enrollment`) and exits non-zero.

### Set up an org Worker (admins)

On the admin's Mac, next to (and after) the admin's personal gitzilla:

```
./install.sh --org <org-login>
```

This installs the profile `org-<org-login>` (the login lower-cased; at most 36 characters, so that the profile name
fits in 40). Its steps are `prereqs note-key worker github-app repos mirrors launchd self-test`: no `hook`,
`known-keys` or `first-rotation`, which belong to the personal install. It is resumable like the personal install:
rerun the same command, or add `--from-step <step>`. Once the `worker` step has written the profile's config (with
`MODE=org`), `GITZILLA_PROFILE=org-<org-login> ./install.sh` works too; before that, use `--org` (without it the
profile is a plain one, and the `worker` step refuses). It never reads or writes the personal config, state or jobs:
`--org` ignores an exported `GITZILLA_CONFIG_DIR` / `GITZILLA_STATE_DIR` (and says so), and `MODE`/`ORG` come only
from the profile's config, never from the environment.

| Step | In the org profile |
|---|---|
| `prereqs` | as in the personal install, plus the profile's own gh login (see "The profile's gh token" below): it shows the token settings, opens GitHub's new-token page and reads the token hidden. A login already in the profile is kept unless you type `replace` |
| `note-key` | paste the **same** `push-note` public key as your personal install. It becomes the org Worker's only admin key (`ADMIN_PUBKEYS`). It must be a single `ecdsa-sha2-nistp256` line (Secretive's keys are): the Worker trusts no admin key at all when that value is malformed, so the `worker` step checks it and refuses before it deploys anything |
| `worker` | deploys a separate Worker named `gitzilla-<org>` with `MODE=org`, `ORG=<org>`, `ADMIN_PUBKEYS=<your push-note key>` and `WEB_FLOW` (below). Every `wrangler deploy` and `wrangler secret` command carries `--name gitzilla-<org>`, so the personal Worker `gitzilla` is never touched. The org Worker gets its own webhook secret, ntfy topic, optional Slack URL and optional call numbers and token, asked and piped exactly as in the personal install. The config (`~/.config/gitzilla/org-<org>/config`) holds `OWNER=<org>`, `MODE=org`, `ORG`, `WORKER_NAME`, `WEB_FLOW` and the Worker URL. To remove an optional secret later: `npx wrangler secret delete <NAME> --name gitzilla-<org>` |
| `github-app` | create the app `gitzilla-<org>` (cut to 34 characters) in the organization's settings (`https://github.com/organizations/<org>/settings/apps/new`, which needs an org owner), "Only on this account", then install it on the organization with access to **all** repositories. The drill repo is `<org>/gitzilla-drill`; when it does not exist, the installer opens the org's new-repository page and you create it there (private, with a README): the profile's gh token is read-only and cannot create it |
| `repos`, `mirrors` | every repository `gh repo list <org>` returns (with the profile's token), mirrored in `~/.local/state/gitzilla/org-<org>/mirrors/`. The `repos` step also asks GitHub whether your account can push to a sample of up to 3 of them and warns about those it cannot (restore would skip them with `no push permission`) and about those the token cannot see (`repo not visible to org token`) |
| `launchd` | the profile's agent and reconcile jobs (no rotate job). The org's reconcile checks for missed webhooks only: an organization has no SSH keys, and your own account keys stay with your personal install |
| `self-test` | the same rows, pushed from a Mac that joined the org (yours, once you have joined and approved yourself) |

Then join your own org from your personal install (`./install.sh --join-org <url>`) and approve your own key with
`GITZILLA_PROFILE=org-<org> bin/org approve <your-login> <fingerprint>`, like any member: the admin key signs admin
commands, a member key signs push notes. **Restore needs this**: its note goes to the org Worker's `/note`, which
accepts member keys only, so until you have joined and approved yourself every ref is skipped with
`could not send note (worker returned 401)`. `./install.sh --org` ends by saying so.

One admin for now: the installer deploys `ADMIN_PUBKEYS` with exactly one key, the `push-note` key of the Mac that runs
`./install.sh --org`, and every rerun of its `worker` step deploys it again with that one key, replacing whatever was
there. The Worker itself accepts up to 3 admin keys, but the installer has no way to set more than one yet: if a
second person runs `--org` (or redeploys) for the same Worker, their key replaces yours and you are locked out of
`bin/org` until you rerun the `worker` step from your Mac.

The profile's gh token: the org profile never uses your personal gh login (its fine-grained token belongs to your
user and cannot see the org's private repos). The `prereqs` step asks for a separate fine-grained personal access
token, stored by gh in `~/.config/gitzilla/org-<org>/gh` only (`gh auth login --with-token` on stdin,
`--insecure-storage`, so it is gh's `hosts.yml` in that directory, mode 700, and never the macOS keychain entry of your
personal login):

- Resource owner: the organization (not your user). If the org requires approval of fine-grained tokens, an owner
  approves it.
- Repository access: All repositories.
- Permissions: Repository > Contents: **Read-only** and Repository > Metadata: **Read-only**, nothing else. Grant no
  write permission of any kind: no stored credential may be able to push. Restore does not use this token to push; it
  pushes over SSH with your `github-auth` key (Touch ID), as in the personal install.
- Expiry: your choice. When it expires, `gh` calls in the profile fail (the `repos` step finds nothing, and restore
  skips refs with `repo not visible to org token`); renew with
  `GITZILLA_PROFILE=org-<org> GITZILLA_INSTALL_STOP_AFTER=prereqs ./install.sh --from-step prereqs` (type `replace`
  if it asks).

What the admin's GitHub account needs:

- Owner of the organization, to create the app and install it on the organization.
- Push access to every repository restore should put back, and the right to bypass the branch protection rules or
  rulesets of those branches (restore force-pushes with `--force-with-lease`). Before it sends a note or pushes, restore
  in the org profile asks GitHub (`gh api repos/<repo>`, `.permissions.push` or `.permissions.admin`) whether your
  account may push, with the profile's gh token. When GitHub answers 404, 403 or 401 (the token does not see the
  repository, or has expired), every ref of that repository is skipped with `repo not visible to org token`; when
  your account may not push (or gh fails or takes over 15 s), with `no push permission`. The reason shows in the
  restore report.
- Your own member key approved in the org (above): restore's note is signed by it.
- The members' commit-signing keys, in the org profile's own signers file `~/.config/gitzilla/org-<org>/allowed_signers`
  (the `worker` step prints the format): one line per key, `<login> namespaces="git" <key type> <base64 key>`, for
  example from `https://api.github.com/users/<login>/ssh_signing_keys` after checking each key with its owner. The org
  profile uses only this file, never your personal or global `allowed_signers`, so your own trust set is not widened.
  - With the file: the org's deep check marks commits not signed by a listed key `unsigned` (an orange push turns
    red, with a restore dialog), and restore puts a branch back only to a commit signed by a listed key, as in the
    personal install.
  - Without it (missing, or only comments): the deep check skips signatures, so the Worker's alert level stands and
    no restore dialog comes from signatures (a payload hit still turns red), and restore skips every ref it would
    rewind with `no org signers file`.
  - Web-UI merges: with `WEB_FLOW=orange` (the default) a push made in GitHub's web UI is deep-checked, and its
    commits are committed and signed by GitHub's `web-flow` key, which is not in this file. So every pull request
    merged in the web UI is `unsigned`, turns red and opens a restore dialog on your Mac (answer **Ignore** when it was
    a legitimate merge). Adding GitHub's web-flow signing key to this file does not help: GitHub signs web commits
    with a GPG key (`https://github.com/web-flow.gpg`), and this file lists SSH keys only. To stop these dialogs, set
    `WEB_FLOW=silent` (below; a forced push is still red), or keep the default and answer **Ignore** for your own
    merges.
- Restoring a member's push: a member's commits reach your Mac only through the org mirrors (no pre-push hook of
  yours copies them in). The org profile's agent therefore also fetches the mirrors of repos that had only silent
  pushes in each poll, so the commit a branch should go back to is normally local. If it is not (an attacker
  overwrote it before the next poll), restore fetches that one commit from GitHub by its id before giving up with
  `old commit not available locally`.

Bots and the web UI:

- GitHub App senders (GitHub reports the pusher with `sender.type` `Bot`: `dependabot[bot]`, `github-actions[bot]`,
  `renovate[bot]`, any installed App) carry no note and are **always silent unless the push is forced**; a forced push
  is never silenced, by any rule, and is red. `bin/org allow-bot` / `disallow-bot` only affect machine-user accounts
  (ordinary user accounts used by CI): `allow-bot <login>` silences their non-forced pushes, `disallow-bot` makes
  them alert again. Neither command changes anything for an App. To stop a compromised App, uninstall it or revoke
  its repository access in the organization's settings (`https://github.com/organizations/<org>/settings/installations`).
- Commits made in GitHub's web UI (merges, edits) carry no note either. `WEB_FLOW` decides what a push whose every
  commit is by GitHub's `web-flow` gets: `orange` (the default) or `silent` (never for a forced push). Set it with
  `GITZILLA_WEB_FLOW=silent ./install.sh --org <org> --from-step worker` (press Enter to keep the secrets); the value is
  saved in the profile's config and kept on later redeploys.

## Alert channels

| Channel | Gets | Setup |
|---|---|---|
| ntfy push | every alert (red, orange, restore reports, account alerts) | free; subscribe to the topic printed in the `worker` step |
| Slack | the same alerts as ntfy | optional incoming-webhook URL in the `worker` step |
| Voice call | red alerts only (critical pushes, "gitzilla disarmed", a new key on your account) and the test alert | optional; needs [ntfy Pro](https://ntfy.sh/#pricing), an access token, and each number verified in the ntfy web app (Account, Phone numbers) first |

- Calls say only what happened (for example "Possible stolen GitHub credential. 2 events in owner/repo"), never
  SHAs or commit content; then check Slack or the ntfy app for details. The voice is English only.
- Each number gets at most one call per 10 minutes, however many events arrive; the test alert calls at most once
  per hour per number. ntfy Pro plans also cap calls per day (see their pricing page); calls beyond the quota fail
  quietly, and push and Slack still arrive. A failing call never blocks the push or Slack alert.
- `bin/notify-test` sends a signed test alert (`🔴 gitzilla: test alert`) to every channel and prints
  `test alert sent` or why it failed. Run it after changing a channel. For an org Worker:
  `GITZILLA_PROFILE=org-<org> bin/notify-test`. After an upgrade, redeploy first (Upgrading, above).
- Push alerts list, per event, `Repo`, `Ref` (with `(forced)`), `Commits` (short SHAs), `Time` and `Flags`. An org
  Worker adds `Pusher: <login>` (the GitHub account that pushed, as GitHub reports it; `Pusher: unknown` when GitHub
  sent none). Org flags include `unenrolled` (the pusher is not a member), `no-note` (a member pushed without a note),
  `bot` and `web-flow`. Every alert ends with the line
  `If this wasn't you: revoke tokens at https://github.com/settings/applications`.

## Drill

After the install, run the live drill in `tests/drill.md` in your drill repo: a no-verify push, a force-push of an
unsigned commit carrying the payload sample from a second clone, a burst, removing the repo from the app, and the
rotation and restore dialogs. Each row says what must happen.

## Daily operation

| You see | It means | Do |
|---|---|---|
| Nothing | Pushes you made carry a note; all is quiet | nothing |
| Orange alert | A push with no note from this Mac (or the Worker was unreachable when you pushed, or you used `--no-verify`). GitHub web-UI merges and bot commits (Dependabot, Actions) also have no note | If it was you, ignore it. If not, treat it as red. |
| Red alert | Force-push, burst across repos, unsigned commit, polin-guard hit, or "gitzilla disarmed" (app uninstalled, suspended or repos removed) | Open the restore dialog (below), then revoke tokens at https://github.com/settings/applications and rotate keys |
| Red alert + restore dialog for a GitHub web-UI merge or a bot commit | gitzilla only trusts commits signed by keys in your `allowed_signers`; GitHub's web-flow signature is not trusted, so these commits count as unsigned | If it was your own merge or your bot, choose **Ignore** |
| "Restore N branches?" dialog | The agent found rewritten branches | **Restore** pushes the old tips back from the mirrors (`--force-with-lease`; branches that moved on are skipped and listed). **Details** shows them. **Ignore** does nothing. A typical incident costs up to 2 Touch IDs: one for the agent's deep check, and one for the restore push if you answer the dialog more than 2 minutes later |
| Restore skipped "no push permission" (org profile) | Your account cannot push to that org repository, so restore sent no note and pushed nothing | Ask an org owner to restore it, or get push (and bypass) access and run `GITZILLA_PROFILE=org-<org> bin/restore --prompt <incident-file>` again |
| Restore skipped "repo not visible to org token" (org profile) | The org profile's gh token got 404/403/401 for that repository: it does not cover the repo, the org has not approved it, or it expired. Restore sent no note and pushed nothing | Renew or widen the token (`GITZILLA_PROFILE=org-<org> GITZILLA_INSTALL_STOP_AFTER=prereqs ./install.sh --from-step prereqs`, type `replace`), then run `GITZILLA_PROFILE=org-<org> bin/restore --prompt <incident-file>` again |
| Restore skipped "restore target not verified — review manually" | The commit a branch would go back to is not signed by your key (for example the attacker's first push was never deep-checked) | Find the last good commit yourself and use the manual restore below |
| "N event(s) were lost while this Mac was offline" | The Mac was offline longer than the Worker keeps events (7 days) | Check the phone (and Slack) alerts for that period and run `bin/reconcile all` |
| "Worker unreachable" notification | Health check failing for over an hour | Check the Cloudflare dashboard; `curl $GITZILLA_URL/health` |
| "queue unreadable" notification | The agent could not read the Worker queue for over an hour (Mac clock off by more than 5 min, a Worker deployed without the note key, or a Secretive signing failure) | Check `log/gitzilla.log`; fix the clock, or redeploy with `install.sh --from-step worker` |
| "New key on your GitHub account" (Mac, phone and Slack if set) | `reconcile` saw a key not in `known-keys.txt` | If you did not add it, remove it at https://github.com/settings/keys and rotate |
| Rotation reminder dialog | gh token or SSH key is 5 days old | **Rotate now** opens a guided Terminal flow. **Snooze 1 day** delays the next prompt a day. |

Manual commands (run from the clone):

```
bin/rotate gh | ssh      # rotate now
bin/rotate check         # what the daily job runs
bin/restore --prompt <incident-file>   # incident files: ~/.local/state/gitzilla/incidents/
bin/reconcile public | all | seed
bin/agent poll | health
```

Redeploying the Worker: only with `./install.sh --from-step worker` (an org's: `./install.sh --org <org> --from-step
worker`) (press Enter to keep the
secrets). Never run a plain `wrangler deploy`: `wrangler.toml` ships `NOTE_PUBKEY = ""`, so a plain deploy blanks the
note key and every note and queue read then fails with 401.

Manual restore (when the Worker is down, restore sends no note and pushes nothing). From the repo's mirror in
`~/.local/state/gitzilla/mirrors/<owner>__<repo>.git`, with `<bad>` the attacker's SHA now on GitHub and
`<good>` the last good commit:

```
git -C ~/.local/state/gitzilla/mirrors/<owner>__<repo>.git push --force-with-lease=<ref>:<bad> git@github.com:<owner>/<repo>.git <good>:<ref>
```

This push itself raises a red alert (it carries no note); that one is expected.

Snoozing: choose **Snooze 1 day** in the rotation dialog (it delays the next prompt by a day; rotation is what keeps a
stolen token short-lived, so there is no longer snooze).

## Known limits

- A SIGKILL (or power loss) in the middle of the SSH key swap in `rotate ssh` needs a rerun of `bin/rotate ssh`
  to finish or undo the swap.
- `reconcile` alerts (missed pushes, new account keys) reach the phone (and Slack) only while the Worker is reachable;
  otherwise they are desktop notifications only.
- The Worker keeps queued events for 7 days. A Mac offline for longer gets a "lost events" alert instead of the events.
- The private-repo check in `reconcile all` costs one Touch ID per hourly run when it is due.
- A push made while the Worker is unreachable still goes through (fail-open) and shows up as an orange alert.

## Security model

| Credential | Where | What it can do if stolen |
|---|---|---|
| Webhook secret | Worker secret (printed once at install) | Send fake webhooks to your Worker (false alerts). Cannot read or change code. |
| ntfy topic, Slack webhook URL | Worker secrets | Read / send alerts (repo names, SHAs, no content). |
| ntfy call token, call phone numbers | Worker secrets (`NTFY_CALL_TOKEN`, `NTFY_CALL_NUMBERS`), typed hidden at install, piped on stdin, never on disk or in logs (Worker logs show masked numbers) | Place calls on your ntfy account to your verified numbers (uses up your call quota) and learn the numbers. Delete the token at https://ntfy.sh/account |
| `push-note` key | Secure Enclave (Secretive), **no Touch ID** | Not exportable. Only malware *on this Mac* could sign notes. |
| `github-auth` key | Secure Enclave (Secretive), Touch ID per use | Not exportable. Used for deep checks, mirrors and restore pushes. |
| GitHub App private key | **Not kept.** GitHub requires one to install the app and stores only the public half; the downloaded `.pem` is deleted right after install | nothing |
| Cloudflare login | **Not kept.** `wrangler logout` after each deploy, checked on disk | nothing |
| `gh` token | `gh`'s own credential store; fine-grained PAT, 7-day expiry, rotated every 5 days; Contents and Metadata read-only (plus pull requests and issues) | Usable for at most 7 days; it cannot push, and any push it could cause would raise an alert anyway |
| Org profile `gh` token | gh's own store in the profile, `~/.config/gitzilla/org-<org>/gh/hosts.yml` (mode 700 directory); fine-grained PAT owned by the org, Contents and Metadata read-only, expiry chosen by the admin, not rotated | Read the org's code until it expires or is revoked (at https://github.com/settings/personal-access-tokens); it cannot push or change anything |

What is stored where: `~/.config/gitzilla/config` (mode 600) holds only non-secret settings (login, joined org Workers,
Worker URL, app name, drill repo, paths) and `push-note.pub`. `~/.local/state/gitzilla/` holds the queue
cursor, `repos.txt`, `known-keys.txt`, the bare mirrors, incident files and logs. No secret is written to disk,
logs or command lines: the Worker secrets go to `wrangler secret put` on stdin, the gh token to `gh` on stdin.
No stored credential can push, change account keys or alter the Worker. Every alert that is not silent ends with
"If this wasn't you: revoke tokens at https://github.com/settings/applications".

## Uninstall

```
for j in agent reconcile rotate; do
  launchctl bootout gui/$(id -u)/io.github.gitzilla.$j
  rm ~/Library/LaunchAgents/io.github.gitzilla.$j.plist
done
```

For a profile, use `io.github.gitzilla.<name>.$j` above (jobs `agent reconcile` only) and remove only
`~/.config/gitzilla/<name>` and `~/.local/state/gitzilla/<name>` in step 5 (the personal directories hold the
profiles' directories too).

1. The global hook, first (before deleting the clone): in `git config --global --includes core.hooksPath`
   (usually `~/.config/git/hooks`), if the installer created `pre-push`, delete it; if it moved your hook aside,
   `mv pre-push.gitzilla-prev pre-push && rm -r gitzilla-prev`; if it edited a polin-guard hook,
   remove the two lines starting `# gitzilla: push note` (or restore `pre-push.bak-gitzilla`).
   If `~/.local/state/gitzilla/install-set-hookspath` exists, the installer set `core.hooksPath` (to the
   directory in that file): undo it with `git config --global --unset core.hooksPath`.
2. Delete the GitHub App: https://github.com/settings/apps, your `gitzilla-<login>` app, Advanced, Delete.
3. Delete the Worker: `cd worker && npx wrangler login && npx wrangler delete && npx wrangler logout`.
4. Delete the `push-note` key in Secretive, the ntfy subscription, the ntfy call token (if any) and the Slack webhook (if any); delete the drill
   repo if you like.
5. `rm -rf ~/.config/gitzilla ~/.local/state/gitzilla`, then delete the clone.

## Tests

```
bash tests/run.sh
cd worker && npm ci && npx vitest run
```

The shell tests run with a temporary `HOME` and git config and stub every external command; they never touch your
real setup.

## License

MIT (`LICENSE`). `scanner/polin-guard/` is a vendored copy of polin-guard 0.3.2 (MIT, same author).
