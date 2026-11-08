# account-watchdog

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
  repos, or the app being uninstalled / losing repos ("watchdog disarmed").
- **Alerts** go to ntfy (phone) and, if you set it up, Slack. They carry repo, ref, SHAs and flags, never commit
  content.
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
git clone https://github.com/Valentin-Shyaka/account-watchdog && cd account-watchdog && ./install.sh
```

Keep the clone where it is: the hook, the LaunchAgents and the config point at it. If you move or delete it, the
hook stops scanning and sending notes (pushes still go through, each one an orange alert, and every push prints
"install dir ... not found") until you rerun `./install.sh --from-step hook` from the new place or remove the hook
(Uninstall). The installer is resumable:
`~/.local/state/account-watchdog/install-step` holds the last completed step and a rerun continues after it;
`--from-step <name>` forces a start point (and runs everything after it).

| Step | What it asks / does |
|---|---|
| `prereqs` | checks the tools, Secretive, `gh auth status` and `~/.ssh/github-auth.pub` |
| `note-key` | you create a key named `push-note` in Secretive (Authentication: **Not Required**, so the hook can sign without a prompt) and copy its public key; it is saved to `~/.config/account-watchdog/push-note.pub` |
| `worker` | `npm ci`, `wrangler login` (browser), deploys the Worker with the note public key, then prints the webhook secret and a random ntfy topic **once** and puts them as Worker secrets. Asks for the Slack URL (hidden; press Enter to skip Slack). Runs `wrangler logout` and checks no Cloudflare token is left on disk. Alerts show times in UTC and in your zone: the deploy passes `ALERT_TZ` (the Mac's zone from `/etc/localtime`, or `WATCHDOG_ALERT_TZ=Europe/Paris ./install.sh --from-step worker`; an unknown zone falls back to UTC). Writes `~/.config/account-watchdog/config` (`OWNER`, `WATCHDOG_URL`, `APP_NAME`, `DRILL_REPO`, `ALERT_TZ`, ...). On a rerun it asks whether to keep the secrets (default, redeploy only) or `rotate` them |
| `github-app` | prints the exact settings for your GitHub App (`account-watchdog-<your login>`, cut to 34 characters) and opens the new-app page; you create it, generate a private key (GitHub requires one before install) and install it on **all** repositories. The installer then deletes the downloaded `<app-name>.*.private-key*.pem` from `~/Downloads` after you confirm. If your drill repo does not exist it offers to create it (private). You push one commit to the drill repo; the installer waits until the push shows up in the Worker queue |
| `hook` | installs the push note in your global `pre-push` hook (see below) |
| `repos` | `gh repo list` into `repos.txt` (`<owner/repo> public\|private` per line) |
| `mirrors` | a bare mirror of every repo over one SSH session (one Touch ID), never auto-gc'd (restore needs old commits), then `reconcile seed` baselines them |
| `known-keys` | shows the SSH keys GitHub lists for you; you type `yes` to trust them as the baseline |
| `launchd` | installs three LaunchAgents: `agent` (every 5 min), `reconcile` (hourly), `rotate` (daily 10:00) |
| `first-rotation` | `rotate gh`: replaces your gh login with a fine-grained, 7-day, read-mostly token |
| `self-test` | a signed push (no alert) and a `--no-verify` push (orange alert on the phone) |

In the ntfy app, subscribe to the topic printed in the `worker` step.

**Drill repo.** A throwaway repo the installer and the drill push to, never a real one. The default name is
`watchdog-drill`; to use another, set it before the `worker` step: `WATCHDOG_DRILL_REPO=my-drill ./install.sh`
(or `--from-step worker`). It is saved as `DRILL_REPO` in the config.

**Global pre-push hook.** The hook step reads `git config --global --includes core.hooksPath` (a value in an
included dotfile counts, and is used as it is):

- not set: it lists what is already in `~/.config/git/hooks` and asks before setting `core.hooksPath` there (the
  installer records that in `~/.local/state/account-watchdog/install-set-hookspath`). A global hooks path makes git
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
- any other hook (after a yes): it is backed up (`pre-push.bak-account-watchdog`), moved to
  `pre-push.account-watchdog-prev` and run by the new hook as `account-watchdog-prev/pre-push` (still named
  `pre-push`) with the same input and arguments; its exit status still decides the push. A hook that was not
  executable (git ignored it) stays that way and is not run. Because it now runs from the `account-watchdog-prev/`
  subdirectory, a hook that loads files next to itself via `$(dirname "$0")` must use absolute paths instead.
  Keep `account-watchdog-prev/` (it only holds that link); if it goes missing, rerun `--from-step hook`.

The step also records the absolute `node` (`scanner/node-path`) and `jq` (`~/.config/account-watchdog/jq-path`),
and the hook appends `/opt/homebrew/bin:/usr/local/bin` to `PATH` as fallbacks (your own hooks keep your PATH order), so pushes from GUI clients (GitHub Desktop, Tower,
Xcode) still scan and send notes.

**The scan blocks pushes everywhere.** The hook runs on every push from this Mac, to any remote (work servers,
GitLab, ...), not only your GitHub account. A finding blocks the push, and so does a scan that cannot run (for
example node was removed); the message says why. If you are sure the push is fine, bypass the hook once with
`git push --no-verify`; for a push to your own GitHub account that raises an orange alert.

**Repos with their own hooks path (husky, lefthook, `.githooks`).** A repo-level `core.hooksPath`
(`git config --local core.hooksPath`, set by husky v5+, lefthook and similar) overrides the global one, so in those
repos the watchdog hook never runs: no scan, no note, and every push is an orange alert (red with unsigned commits).
Fix it per repo, either by calling the global hook from the repo's pre-push hook (for husky, add to
`.husky/pre-push`: `"$(git config --global --includes --get core.hooksPath | sed "s|^~|$HOME|")/pre-push" "$@" || exit $?` — note
that stdin must be passed through, so put it first in the file), or by adding the two note lines from
`hooks/pre-push` (`# account-watchdog: push note` and the `bin/note` line, after reading stdin into `input`).
`git config --get-regexp core.hookspath` inside a repo shows whether it has one.

Rerunning `worker` keeps the existing secrets unless you type `rotate`. After a rotate, `github-app` does not create
a second app: it asks you to edit the existing app's webhook secret at
`https://github.com/settings/apps/<app-name>/advanced` and to re-subscribe the phone to the new ntfy topic.

Slack: an empty Slack URL only skips setting the secret. If you rotate the secrets with an empty URL after Slack was
set up once, the old `SLACK_WEBHOOK_URL` secret stays in the Worker and alerts keep going to Slack. To stop them:
`cd worker && npx wrangler login && npx wrangler secret delete SLACK_WEBHOOK_URL && npx wrangler logout`
(then revoke the webhook in Slack).

Files: config in `~/.config/account-watchdog/`, state and logs in `~/.local/state/account-watchdog/`
(`log/agent.out`, `log/reconcile.out`, `log/rotate.out`, `log/watchdog.log`).

## Drill

After the install, run the live drill in `tests/drill.md` in your drill repo: a no-verify push, a force-push of an
unsigned commit carrying the payload sample from a second clone, a burst, removing the repo from the app, and the
rotation and restore dialogs. Each row says what must happen.

## Daily operation

| You see | It means | Do |
|---|---|---|
| Nothing | Pushes you made carry a note; all is quiet | nothing |
| Orange alert | A push with no note from this Mac (or the Worker was unreachable when you pushed, or you used `--no-verify`). GitHub web-UI merges and bot commits (Dependabot, Actions) also have no note | If it was you, ignore it. If not, treat it as red. |
| Red alert | Force-push, burst across repos, unsigned commit, polin-guard hit, or "watchdog disarmed" (app uninstalled, suspended or repos removed) | Open the restore dialog (below), then revoke tokens at https://github.com/settings/applications and rotate keys |
| Red alert + restore dialog for a GitHub web-UI merge or a bot commit | The watchdog only trusts commits signed by keys in your `allowed_signers`; GitHub's web-flow signature is not trusted, so these commits count as unsigned | If it was your own merge or your bot, choose **Ignore** |
| "Restore N branches?" dialog | The agent found rewritten branches | **Restore** pushes the old tips back from the mirrors (`--force-with-lease`; branches that moved on are skipped and listed). **Details** shows them. **Ignore** does nothing. A typical incident costs up to 2 Touch IDs: one for the agent's deep check, and one for the restore push if you answer the dialog more than 2 minutes later |
| Restore skipped "restore target not verified — review manually" | The commit a branch would go back to is not signed by your key (for example the attacker's first push was never deep-checked) | Find the last good commit yourself and use the manual restore below |
| "N event(s) were lost while this Mac was offline" | The Mac was offline longer than the Worker keeps events (7 days) | Check the phone (and Slack) alerts for that period and run `bin/reconcile all` |
| "Worker unreachable" notification | Health check failing for over an hour | Check the Cloudflare dashboard; `curl $WATCHDOG_URL/health` |
| "queue unreadable" notification | The agent could not read the Worker queue for over an hour (Mac clock off by more than 5 min, a Worker deployed without the note key, or a Secretive signing failure) | Check `log/watchdog.log`; fix the clock, or redeploy with `install.sh --from-step worker` |
| "New key on your GitHub account" (Mac, phone and Slack if set) | `reconcile` saw a key not in `known-keys.txt` | If you did not add it, remove it at https://github.com/settings/keys and rotate |
| Rotation reminder dialog | gh token or SSH key is 5 days old | **Rotate now** opens a guided Terminal flow. **Snooze 1 day** delays the next prompt a day. |

Manual commands (run from the clone):

```
bin/rotate gh | ssh      # rotate now
bin/rotate check         # what the daily job runs
bin/restore --prompt <incident-file>   # incident files: ~/.local/state/account-watchdog/incidents/
bin/reconcile public | all | seed
bin/agent poll | health
```

Redeploying the Worker: only with `./install.sh --from-step worker` (press Enter to keep the
secrets). Never run a plain `wrangler deploy`: `wrangler.toml` ships `NOTE_PUBKEY = ""`, so a plain deploy blanks the
note key and every note and queue read then fails with 401.

Manual restore (when the Worker is down, restore sends no note and pushes nothing). From the repo's mirror in
`~/.local/state/account-watchdog/mirrors/<owner>__<repo>.git`, with `<bad>` the attacker's SHA now on GitHub and
`<good>` the last good commit:

```
git -C ~/.local/state/account-watchdog/mirrors/<owner>__<repo>.git push --force-with-lease=<ref>:<bad> git@github.com:<owner>/<repo>.git <good>:<ref>
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
| `push-note` key | Secure Enclave (Secretive), **no Touch ID** | Not exportable. Only malware *on this Mac* could sign notes. |
| `github-auth` key | Secure Enclave (Secretive), Touch ID per use | Not exportable. Used for deep checks, mirrors and restore pushes. |
| GitHub App private key | **Not kept.** GitHub requires one to install the app and stores only the public half; the downloaded `.pem` is deleted right after install | nothing |
| Cloudflare login | **Not kept.** `wrangler logout` after each deploy, checked on disk | nothing |
| `gh` token | `gh`'s own credential store; fine-grained PAT, 7-day expiry, rotated every 5 days; Contents and Metadata read-only (plus pull requests and issues) | Usable for at most 7 days; it cannot push, and any push it could cause would raise an alert anyway |

What is stored where: `~/.config/account-watchdog/config` (mode 600) holds only non-secret settings (login,
Worker URL, app name, drill repo, paths) and `push-note.pub`. `~/.local/state/account-watchdog/` holds the queue
cursor, `repos.txt`, `known-keys.txt`, the bare mirrors, incident files and logs. No secret is written to disk,
logs or command lines: the Worker secrets go to `wrangler secret put` on stdin, the gh token to `gh` on stdin.
No stored credential can push, change account keys or alter the Worker. Every alert that is not silent ends with
"If this wasn't you: revoke tokens at https://github.com/settings/applications".

## Uninstall

```
for j in agent reconcile rotate; do
  launchctl bootout gui/$(id -u)/io.github.account-watchdog.$j
  rm ~/Library/LaunchAgents/io.github.account-watchdog.$j.plist
done
```

1. The global hook, first (before deleting the clone): in `git config --global --includes core.hooksPath`
   (usually `~/.config/git/hooks`), if the installer created `pre-push`, delete it; if it moved your hook aside,
   `mv pre-push.account-watchdog-prev pre-push && rm -r account-watchdog-prev`; if it edited a polin-guard hook,
   remove the two lines starting `# account-watchdog: push note` (or restore `pre-push.bak-account-watchdog`).
   If `~/.local/state/account-watchdog/install-set-hookspath` exists, the installer set `core.hooksPath` (to the
   directory in that file): undo it with `git config --global --unset core.hooksPath`.
2. Delete the GitHub App: https://github.com/settings/apps, your `account-watchdog-<login>` app, Advanced, Delete.
3. Delete the Worker: `cd worker && npx wrangler login && npx wrangler delete && npx wrangler logout`.
4. Delete the `push-note` key in Secretive, the ntfy subscription and the Slack webhook (if any); delete the drill
   repo if you like.
5. `rm -rf ~/.config/account-watchdog ~/.local/state/account-watchdog`, then delete the clone.

## Tests

```
bash tests/run.sh
cd worker && npm ci && npx vitest run
```

The shell tests run with a temporary `HOME` and git config and stub every external command; they never touch your
real setup.

## License

MIT (`LICENSE`). `scanner/polin-guard/` is a vendored copy of polin-guard 0.3.2 (MIT, same author).
