# Account Watchdog — design

> gitzilla was called account-watchdog when this was written.

> Original design record, kept for reference. Names of the original owner and repos are replaced with generic ones; the README describes the tool as it ships.

**Date:** 2026-10-06 · **Owner:** the original author · **Status:** approved in conversation, awaiting spec review

## 1. Why

On 2026-10-03, 08:38–08:50 UTC, a stolen GitHub credential force-pushed the PolinRider payload to 67
branches across 13 repositories while the owner's laptop was asleep. Nothing noticed for two days.
Every on-disk check on the laptop was clean; the attack happened entirely on GitHub with a valid token.

## 2. Goal and success criteria

A tool, set up once, that protects **one personal GitHub account** (the original owner's, 56 public + 15
private repos) against pushes the owner did not make.

| Criterion | Target |
|---|---|
| Time from attacker push to phone alert | ≤ 30 s, **including while the Mac is asleep** |
| Time from clicking "Restore" to branches restored | ≤ 1 min |
| False alerts on the owner's own pushes from this Mac | 0 |
| New stealable credentials introduced | 0 (see §4) |

### Out of scope
- Repositories the owner does not own (other people's repos and collaborations) and organisations the
  owner is only a member of (not an admin).
- Detecting new token / OAuth-app authorisations (no credential-free API; GitHub's own emails cover it).
- Rotating the commit-signing key and the push-note key.
- Fully automatic revert (requires a stored write credential — rejected, see §4).
- Server-side rejection of pushes on private repos (needs GitHub Pro rulesets; can be added later
  independently — the watchdog stays useful as detection + restore either way).

## 3. Architecture

```
GitHub App "account-watchdog" (Contents: read, Metadata: read; events: push, installation,
installation_repositories; installed on all repos; NO private key kept)
   │ webhook, seconds after any push
   ▼
Receiver — Cloudflare Worker + one Durable Object (events kept 7 days; notes, nonces, burst windows minutes)
   • verify X-Hub-Signature-256 with the webhook secret
   • match push against signed push-notes from the Mac
   • classify: forced · burst · note missing/mismatched
   ├─► ntfy (phone push, random topic)          ─┐ both get every
   ├─► Slack incoming webhook (searchable log)  ─┘ non-silent alert
   └─► alert queue (read by the Mac, request signed with the push-note key)
            ▼
Mac agent (launchd, bash + git)
   • reads queue every 5 min and on wake
   • deep check per push: commit signatures vs ~/.config/git/allowed_signers,
     polin-guard scan of what changed (reuses ~/.config/git/polin-guard/scan.sh)
   • offers Restore → Touch ID → push --force-with-lease back to the previous commit
   • daily rotation check (gh token + SSH login key)
   • backup reconciliation (mirrors vs GitHub)
```

### 3.1 Components

| Unit | Path | Responsibility | Depends on |
|---|---|---|---|
| `worker/` | `account-watchdog/worker/` | Webhook intake, note store, classification, fan-out | Cloudflare Workers + Durable Objects |
| `note` | `account-watchdog/bin/note` | Build + sign a push-note, POST to Worker | `push-note` Secretive key, `ssh-keygen -Y sign` |
| `agent` | `account-watchdog/bin/agent` | Pull queue, deep check, raise local alert | Worker queue, mirrors, scan.sh |
| `restore` | `account-watchdog/bin/restore` | Restore a set of branches to their pre-incident commits | mirrors, owner's `github-auth` key |
| `rotate` | `account-watchdog/bin/rotate` | Guided gh-token and SSH-login-key rotation | `gh`, Secretive, browser |
| `reconcile` | `account-watchdog/bin/reconcile` | Backup check: mirror heads vs `git ls-remote` | mirrors, git |
| `install.sh` | `account-watchdog/install.sh` | One-time, resumable setup + self-test | all of the above |

Mac state lives in `~/.local/state/account-watchdog/` (`mirrors/<owner>__<repo>.git`, `heads.json`,
`known-keys.txt`, `rotation.json`, `queue-cursor`, `log/`). Config in `~/.config/account-watchdog/config`.

## 4. Credentials (complete list)

| Credential | Where | If stolen |
|---|---|---|
| Webhook secret | Worker secret | Attacker can send fake alerts. Cannot read or change code. |
| ntfy topic, Slack webhook URL | Worker secrets | Attacker can read/send alerts (repo names, SHAs — no content). |
| `push-note` key | Secure Enclave (Secretive), **no Touch ID** | Not exportable. Only malware *on this Mac* could sign notes. |
| `github-auth` key (existing) | Secure Enclave, Touch ID per use | Not exportable. Used only for deep checks, mirrors, restore. |
| GitHub App private key | **Not kept** — GitHub requires one to install and won't delete the last one, but stores only its public half; the downloaded `.pem` is destroyed right after install (§10.1) | — |
| Cloudflare login | **Not kept** — `wrangler logout` after each deploy | — |
| `gh` token | Fine-grained PAT, **7-day expiry**, rotated every 5 days | Usable for ≤ 7 days, and the watchdog alerts on any push it makes. |

No stored token can push, change account keys, or alter the Worker.

## 5. Detection

### 5.1 Push-note (proof a push came from this Mac)
GitHub's `pusher` field is whoever owns the token, so it cannot distinguish the owner from a token thief,
and commit author/date are forgeable. The only proof is a Secure-Enclave signature.

- The global `pre-push` hook (`~/.config/git/hooks/pre-push`) calls `note` for every ref being pushed,
  **before** the push transmits.
- Note payload: `{repo, ref, old_sha, new_sha, ts, nonce}`, signed with
  `ssh-keygen -Y sign -n account-watchdog-note` using the `push-note` key via the Secretive agent.
- Worker verifies against the `push-note` public key (stored as a Worker var), rejects notes older than
  10 min, and accepts each nonce once.
- If the Worker is unreachable the push proceeds with a local warning (fail-open); the resulting
  webhook then classifies as 🟠 and the owner recognises it.

### 5.2 Classification (Worker, per push webhook)
The Worker waits 20 s after a push webhook before classifying a note as missing.

| Level | Condition |
|---|---|
| ✅ Silent | Valid note matching `repo, ref, new_sha` |
| 🟠 Warning | No valid note, not forced, not part of a burst |
| 🔴 Critical | No valid note **and** (`forced == true` **or** burst) |
| 🔴 Critical | `installation` / `installation_repositories` event removing repos or the app ("watchdog disarmed") |

**Burst:** within a sliding 10-minute window, un-noted pushes touching ≥ 3 repos or ≥ 5 refs.

The Mac's deep check can **upgrade** a 🟠 to 🔴 when it finds an unsigned commit (not verifiable against
`allowed_signers`) or a polin-guard hit in the changed files. It never downgrades.

### 5.3 Alert content
Repo, ref, time (UTC + local), old → new SHA, flags, and the fixed line:
*"If this wasn't you: revoke tokens at https://github.com/settings/applications"*.
No commit content is ever sent to ntfy or Slack.

## 6. Restore

1. **Mirrors stay warm.** After every push the agent learns about (silent or not), it fetches that repo
   into its bare mirror, so the pre-incident commit is on disk independent of GitHub. Initial mirror of
   all repos happens at install over one SSH ControlMaster connection (one Touch ID).
2. **One prompt per incident.** `osascript` dialog: *"Restore N branches in M repos to their state at
   HH:MM?"* — **Restore / Details / Ignore**. Never automatic.
3. **Safe rewind.** Per branch:
   `git push --force-with-lease=refs/heads/<b>:<bad_sha> origin <old_sha>:refs/heads/<b>`
   from the mirror, one ControlMaster connection (one Touch ID for the batch). A branch that moved past
   `bad_sha` is skipped and listed for manual handling. The restore push sends its own note → silent.
4. **Report** restored / skipped branches to the local dialog, ntfy and Slack, repeating the revoke line.
   A repeated attack raises a new alert.

## 7. Rotation

Daily launchd job compares `rotation.json` timestamps with a 5-day interval → dialog
**Rotate now / Snooze 1 day**. Fires on wake if the Mac was asleep. Each flow records its step in
`rotation.json` and resumes from it.

### 7.1 gh token
At install, gh moves from the non-expiring CLI OAuth token to a **fine-grained PAT, 7-day expiry**,
owner's repos only, permissions: Contents read, Metadata read, Pull requests read/write, Issues read/write.

1. Open `https://github.com/settings/personal-access-tokens/new` and print the exact settings.
2. Owner creates and copies it. Tool reads it with `pbpaste`, clears the clipboard, runs
   `gh auth login --with-token`, verifies with `gh api user`.
3. Revoke the previous token (captured with `gh auth token` before the swap) through GitHub's
   credential-revocation endpoint. **Verify in implementation** that it accepts fine-grained PATs;
   if not, open the token list and confirm deletion manually.

Known limitation: some `gh` features behave differently with fine-grained PATs; the owner's actual
commands (PRs, issues, `gh api`) are tested in the plan.

### 7.2 SSH login key
1. Prompt: create `github-auth-YYYY-MM-DD` in Secretive (Secure Enclave, require authentication);
   watch the Secretive `PublicKeys/` dir until it appears.
2. Export to `~/.ssh/github-auth.pub`; keep the previous as `github-auth.prev.pub`.
3. Copy to clipboard, open `https://github.com/settings/ssh/new`, remind: type **Authentication Key**.
4. Poll `https://github.com/<user>.keys` (lists authentication keys only) until the new key appears —
   this also catches "added as a Signing Key".
5. `ssh -T git@github.com` with the new key.
6. Open `https://github.com/settings/keys` to delete the old key; poll `.keys` until it is gone.
7. Ask the owner to delete the old secret in Secretive; confirm with `ssh-add -l`.
8. Update `known-keys.txt` so the rotation doesn't trigger a new-key alert.

Any failure leaves the previous key in place.

## 8. Failure handling

| Failure | Response |
|---|---|
| Webhook not delivered / Worker down | `reconcile`: public repos anonymously hourly; private repos once a day (one Touch ID). Mismatch → alert. |
| Attacker uninstalls the app or removes repos | `installation*` event → 🔴 "watchdog disarmed". App settings need a browser session, not a token. |
| Note replay | Bound to repo/ref/sha, 10-min expiry, single-use nonce. |
| Note arrives after webhook | 20 s grace before classifying. |
| Mac offline for days | Phone + Slack alerts unaffected; agent drains the queue on wake; restore uses mirrors. |
| Worker unhealthy | Agent checks `GET /health` hourly; local notification if unreachable for > 1 h. |
| Unknown key appears on account | `reconcile` diffs authentication keys (`https://github.com/<user>.keys`) and signing keys (`GET /users/<user>/ssh_signing_keys`, unauthenticated) against `known-keys.txt` → 🔴. |

## 9. Testing

- **Worker:** unit tests (vitest + Miniflare): HMAC verification, note signature/expiry/nonce, matching,
  forced/burst classification, sliding window, installation events.
- **Mac side:** shell tests in the style of the existing polin-guard hook suite (throwaway repos,
  `commit.gpgsign=false` where signing is not under test).
- **Live drill** on throwaway private repo `<owner>/watchdog-drill` (exercises the private-repo path; the anonymous public-repo path is covered by tests only) with the real 2026-10-03
  payload sample:

| # | Action | Expected |
|---|---|---|
| 1 | Normal signed push from this Mac | Silent |
| 2 | `git push --no-verify` (no note) | 🟠 on phone + Slack |
| 3 | Force-push an unsigned commit containing the payload | 🔴 on phone ≤ 30 s; deep check reports polin-guard hit; restore returns branch to previous commit |
| 4 | Restore after the branch moved on | Branch skipped and listed; nothing overwritten |
| 5 | 5 un-noted branch pushes within 1 min | Burst → 🔴 |
| 6 | Remove the drill repo from the app installation | 🔴 "watchdog disarmed" |

- **Rotation:** both flows run once during install.

## 10. Open questions — verified 2026-10-08 (plan Task 1)

1. **App without a usable private key delivers webhooks — YES, with one correction.** GitHub refuses to
   *install* an app until a private key has been generated, and refuses to delete an app's *last* key.
   GitHub stores only the public half; the private half exists solely in the `.pem` the browser
   downloads. So "no private key" is achieved by **destroying the downloaded `.pem` immediately after
   installing** — the key registered on GitHub is then unusable by anyone. Verified on a throwaway app
   installed on private `watchdog-drill`: `ping`, `installation` and `push` deliveries arrived within
   seconds, `X-Hub-Signature-256` verified against the webhook secret, push payload carried
   `repository.full_name`, `repository.private`, `ref`, `before`, `after`, `forced`, `pusher`.
   Install step (§3, plan Task 11) therefore: generate key → install → securely delete the `.pem` and
   confirm none remains in `~/Downloads`.
2. **Credential-revocation endpoint accepts fine-grained PATs — YES.** `POST /credentials/revoke`
   (no authentication) returned `202`; the PAT went from `200` to `401` on `/user` and repo reads within
   5 s. §7.1 step 3 uses it; the manual fallback stays only for API errors.
3. **Durable Objects (SQLite) on the Cloudflare free plan — YES.** A SQLite-backed DO deployed with
   wrangler 4.148.0 persisted a counter across requests (1 → 2 → 3). A brand-new `workers.dev`
   subdomain took ~45 s to resolve after the first deploy. `wrangler logout` left no OAuth/refresh
   token on disk.
