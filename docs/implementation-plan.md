# Account Watchdog Implementation Plan

> Original implementation plan record, kept for reference. Names of the original owner and repos are replaced with generic ones; the README describes the tool as it ships.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alert within 30 s on any push to the owner's GitHub repos that did not come from this Mac, offer a Touch-ID restore, and guide 5-day rotation of the gh token and SSH login key — with no stored stealable credential.

**Architecture:** A read-only GitHub App sends push/installation webhooks to a Cloudflare Worker whose single Durable Object matches them against Secure-Enclave-signed "push notes" sent by the Mac's global `pre-push` hook, classifies them, and fans out to ntfy + Slack + a queue. A bash agent on the Mac drains the queue, deep-checks pushes in local bare mirrors, and offers restore; separate launchd jobs reconcile and prompt rotation.

**Tech Stack:** Cloudflare Workers + Durable Objects (JS, ES modules), vitest + `@cloudflare/vitest-pool-workers`, wrangler (devDependency, via `npx`); bash 3.2, git ≥ 2.39, `jq`, `ssh-keygen -Y`, `osascript`, launchd; Secretive agent.

**Spec:** `docs/superpowers/specs/2026-10-06-account-watchdog-design.md`

## Global Constraints

- No stored credential may be able to push, change account keys, or change the Worker (spec §4). Never write the GitHub App private key or a Cloudflare token to disk.
- Push-note namespace: `account-watchdog-note`. Queue-auth namespace: `account-watchdog-queue`.
- Note validity: 10 min, single-use nonce. Queue-auth timestamp validity: ±5 min.
- Classification grace after a push webhook: 20 s.
- Burst: un-noted pushes within a sliding 10-minute window touching ≥ 3 repos or ≥ 5 refs.
- Worker keeps queued events for 7 days (a Mac offline for days still drains them; final-review ruling I4). Notes, nonces and burst windows keep their short lifetimes.
- Levels: `silent`, `warning`, `critical`. Mac may upgrade, never downgrade.
- Every non-silent alert ends with exactly: `If this wasn't you: revoke tokens at https://github.com/settings/applications`
- No commit content (diffs, file contents) is ever sent to ntfy or Slack.
- Restore is never automatic; one dialog and one ControlMaster SSH session (one Touch ID) per incident; `--force-with-lease` against the bad SHA.
- Rotation interval: 5 days; snooze: 1 day. gh token: fine-grained PAT, 7-day expiry, Contents read, Metadata read, Pull requests read/write, Issues read/write.
- `pre-push` note sending is fail-open: a failure prints a warning and never blocks the push.
- Mac paths: code `account-watchdog/` (repo), config `~/.config/account-watchdog/config`, state `~/.local/state/account-watchdog/`. Shell code must run on macOS bash 3.2.
- Secretive agent socket: `~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh`.

## Review Focus

1. **Remote URL forms** — `git@github.com:Owner/Repo.git`, `https://github.com/owner/repo`, `ssh://git@github.com/Owner/Repo.git`, with/without `.git`, mixed case: all must map to the same lower-case `owner/repo` the webhook reports, or every push of the owner's raises a false 🟠. → test in Task 6.
2. **Branch creation and deletion** — `before`/`old_sha` or `after`/`new_sha` of 40 zeros: notes must match, the Worker must classify, and restore of an attacker-*created* branch must delete it (lease on the bad SHA) rather than push `000…`. → tests in Tasks 4 and 8.
3. **Tags** — `refs/tags/*` pushes go through notes, classification and restore exactly like branches. → tests in Tasks 4 and 8.
4. **Many queued events after sleep** — a 67-push burst drained on wake must page through the queue and produce **one** restore dialog, not 67. → test in Task 7.
5. **Clock skew** — Mac clock 4 min ahead of the Worker must still pass note intake (±10 min) and queue auth (±5 min); 6 min ahead must still pass notes but fail queue auth; 11 min ahead fails both. → tests in Tasks 3 and 4.

---

## File Structure

```
account-watchdog/
  README.md                      setup + operations (Task 11)
  install.sh                     one-time resumable installer (Task 11)
  launchd/*.plist.tmpl           agent / reconcile / rotate jobs (Task 11)
  worker/
    package.json  wrangler.toml  vitest.config.js
    src/index.js                 fetch router: /webhook /note /queue /health (Task 4)
    src/sshsig.js                SSHSIG (ecdsa-p256) verification (Task 2)
    src/hmac.js                  X-Hub-Signature-256 check (Task 3)
    src/hub.js                   Durable Object "Hub": notes, nonces, pending, events, alarm (Tasks 3–4)
    src/classify.js              pure classification + burst (Task 4)
    src/notify.js                pure message builders + senders (Task 5)
    test/fixtures/make.sh        regenerates test key + signatures with ssh-keygen (Task 2)
    test/*.test.js
  bin/
    lib.sh                       config, paths, wd_sign, repo_slug, ssh ControlMaster, json helpers (Task 6)
    note                         pre-push note sender + local mirror object copy (Task 6)
    agent                        queue drain, heads, deep check, local alert (Task 7)
    restore                      Touch-ID restore of an incident (Task 8)
    reconcile                    heads + account-key backup check (Task 9)
    rotate                       check | gh | ssh (Task 10)
  tests/
    run.sh  helpers.sh  stub-worker.mjs
    test_*.sh
```

Global `~/.config/git/hooks/pre-push` (outside the repo) gets one line added by `install.sh` that calls `bin/note`.

---

### Task 1: Spike — verify the spec's three open questions (§10)

**Files:**
- Modify: `docs/superpowers/specs/2026-10-06-account-watchdog-design.md` (§10: record results)

**Interfaces:** Produces go/no-go facts later tasks rely on. Needs the owner present (browser steps). Throwaway artifacts only.

- [ ] **Step 1: App webhooks without a private key.** Create a throwaway GitHub App on the owner's account via the web UI: webhook URL = a fresh `https://webhook.site` URL (or `npx smee-client` channel), webhook secret set, permissions Contents: read + Metadata: read, events: Push. Install it on `<owner>/watchdog-drill` (private repo, empty README). Do **not** download the private key; if one was generated, delete it under the app's *Private keys*. Push one commit to the drill repo.
  Expected: a `push` delivery with `X-Hub-Signature-256` arrives. Record "no-key delivery: yes/no".
- [ ] **Step 2: Credential revocation endpoint.** Create a fine-grained PAT (1-day expiry, drill repo only, Metadata read). Run `curl -s https://api.github.com/user -H "Authorization: Bearer $T" -o /dev/null -w '%{http_code}\n'` (expect `200`), then `curl -s -X POST https://api.github.com/credentials/revoke -H 'Accept: application/vnd.github+json' -d "{\"credentials\":[\"$T\"]}" -w '%{http_code}\n'`, then the `/user` call again.
  Expected: last call `401`. Record the exact revoke response code and body.
- [ ] **Step 3: Durable Objects on the free plan.** In a scratch dir run `npm create cloudflare@latest -- dosmoke --type=hello-world --lang=js --no-deploy`, add a SQLite-backed DO class per current Cloudflare docs, `npx wrangler deploy`, hit it twice, `npx wrangler delete`, `npx wrangler logout`.
  Expected: deploy succeeds on the free plan; counter persists across requests.
- [ ] **Step 4: Record and decide.** Write the three results into spec §10. If Step 1 fails → STOP and ask the owner (spec fallback: keep one encrypted app key off the Mac). If Step 2 fails → Task 10 uses the manual-deletion fallback only. If Step 3 fails → STOP and ask the owner. Delete the throwaway app (keep `watchdog-drill`).
- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-10-06-account-watchdog-design.md
git commit -m "docs(watchdog): record spike results for open questions"
```

---

### Task 2: Worker scaffold + SSHSIG verification

**Files:**
- Create: `account-watchdog/worker/{package.json,wrangler.toml,vitest.config.js}`, `src/sshsig.js`, `test/sshsig.test.js`, `test/fixtures/make.sh`, `test/fixtures/{key.pub,msg.txt,msg.sig,other.pub}`

**Interfaces:**
- Produces: `verifySshSig(armoredSig: string, message: Uint8Array, namespace: string, publicKeyLine: string): Promise<boolean>` — `publicKeyLine` is an OpenSSH line `ecdsa-sha2-nistp256 AAAA… comment`. Supports only `ecdsa-sha2-nistp256` with `sha512` or `sha256`; anything else returns `false` (never throws on bad input).

- [ ] **Step 1: Scaffold.** `package.json` (type module; devDependencies `wrangler`, `vitest`, `@cloudflare/vitest-pool-workers` at current versions; scripts `test: vitest run`, `deploy: wrangler deploy`). `wrangler.toml`: name `account-watchdog`, `main = "src/index.js"`, current `compatibility_date`, DO binding `HUB` → class `Hub` with a SQLite migration `v1`, vars `NOTE_PUBKEY = ""`. `vitest.config.js` uses the workers pool with `wrangler.toml`. Commit `package-lock.json`.
- [ ] **Step 2: Fixtures.** `test/fixtures/make.sh`: `ssh-keygen -t ecdsa -b 256 -N '' -f key`, write `msg.txt`, `ssh-keygen -Y sign -f key -n account-watchdog-note msg.txt` → `msg.txt.sig` renamed `msg.sig`; second key → `other.pub`; delete private keys after signing. Run it; commit only the listed fixture files.
- [ ] **Step 3: Write failing tests** in `test/sshsig.test.js`:

```js
it('accepts a valid signature', async () =>
  expect(await verifySshSig(SIG, MSG, 'account-watchdog-note', PUB)).toBe(true));
it('rejects a tampered message', async () =>
  expect(await verifySshSig(SIG, enc('tampered'), 'account-watchdog-note', PUB)).toBe(false));
it('rejects the wrong namespace', async () =>
  expect(await verifySshSig(SIG, MSG, 'account-watchdog-queue', PUB)).toBe(false));
it('rejects a different key', async () =>
  expect(await verifySshSig(SIG, MSG, 'account-watchdog-note', OTHER)).toBe(false));
it('returns false on garbage', async () =>
  expect(await verifySshSig('nope', MSG, 'account-watchdog-note', PUB)).toBe(false));
```

- [ ] **Step 4: Run** `cd account-watchdog/worker && npm test` — expected FAIL (module not found).
- [ ] **Step 5: Implement `verifySshSig`.** Parse armored `-----BEGIN SSH SIGNATURE-----` → `"SSHSIG"`, uint32 version 1, string publickey, string namespace, string reserved, string hash_algorithm, string signature. Reject if embedded publickey blob ≠ blob from `publicKeyLine`, or namespace differs. Signed data = `"SSHSIG" ‖ string(namespace) ‖ string("") ‖ string(hash_alg) ‖ string(HASH(message))`. Signature blob = string `"ecdsa-sha2-nistp256"` ‖ string(mpint r ‖ mpint s); convert r, s to 32-byte big-endian each (strip leading 0x00, left-pad) → 64-byte raw r‖s. Public key: last string of the pubkey blob is the 65-byte uncompressed point → `importKey('raw', …, {name:'ECDSA', namedCurve:'P-256'})`. Two different hashes are involved: `hash_alg` (usually `sha512`) hashes the *message* inside the signed data; the ECDSA signature itself is always over the signed-data blob with **SHA-256** (the P-256 key's hash). So call `crypto.subtle.verify({name:'ECDSA', hash:'SHA-256'}, key, rawSig, signedData)`.
- [ ] **Step 6: Run** `npm test` — expected PASS (5 tests).
- [ ] **Step 7: Commit** `git commit -m "feat(watchdog): worker scaffold + SSHSIG verification"`

---

### Task 3: Worker — webhook HMAC, `/note` intake, Hub storage of notes

**Files:**
- Create: `worker/src/hmac.js`, `worker/src/hub.js`, `worker/test/hmac.test.js`, `worker/test/note.test.js`

**Interfaces:**
- Consumes: `verifySshSig` (Task 2).
- Produces:
  - `verifyGithubSignature(secret: string, body: Uint8Array, header: string|null): Promise<boolean>` (constant-time compare, `sha256=` prefix).
  - Note wire format (Mac → Worker): `POST /note` JSON `{ "payload": "<base64 of UTF-8 JSON>", "sig": "<armored SSHSIG over the raw payload bytes, ns account-watchdog-note>" }`; payload JSON `{repo, ref, old_sha, new_sha, ts, nonce}` — `repo` lower-case `owner/name`, `ref` full (`refs/heads/x`), `ts` unix seconds, `nonce` 32 hex chars.
  - Responses: `204` accepted; `400` malformed; `401` bad signature; `409` replayed nonce; `422` ts outside ±600 s.
  - `Hub` (single instance `idFromName('main')`) methods used by Task 4: `hasNote(repo, ref, new_sha): Promise<boolean>`; notes and nonces pruned after 600 s.

- [ ] **Step 1: Failing tests.** `hmac.test.js`: valid header → true; wrong secret → false; missing header → false; header without `sha256=` → false. `note.test.js` (via `SELF.fetch` with `NOTE_PUBKEY` = fixture key). Tests run inside the Workers runtime and cannot call `ssh-keygen`, so extend `test/fixtures/make.sh` to produce signed note bodies and commit them: `note-ok.json`, `note-tampered.json`. Skew cases reuse `note-ok.json` and move the clock with `vi.setSystemTime(ts*1000 - offset)`:
  - ok note → `204`, then `hasNote(repo, ref, new_sha)` true
  - same note again → `409`
  - ts = now + 240 → `204`; ts = now + 360 → `204`; ts = now + 660 → `422` (Review Focus 5: ±4 min passes, beyond 10 min fails)
  - tampered payload → `401`; non-JSON body → `400`
  - `hasNote` false after 601 s
- [ ] **Step 2: Run** `npm test` — FAIL.
- [ ] **Step 3: Implement** `verifyGithubSignature` (WebCrypto HMAC-SHA256); `Hub` DO storing `note:<repo>|<ref>|<new_sha>` and `nonce:<nonce>` with expiry timestamps (prune on access and in `alarm()`); `/note` route in `src/index.js` decoding, verifying, and forwarding to the Hub.
- [ ] **Step 4: Run** `npm test` — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(watchdog): webhook HMAC + signed push-note intake"`

---

### Task 4: Worker — webhook intake, classification, queue, health

**Files:**
- Create: `worker/src/classify.js`, `worker/test/classify.test.js`, `worker/test/webhook.test.js`
- Modify: `worker/src/hub.js`, `worker/src/index.js`

**Interfaces:**
- Consumes: `verifyGithubSignature`, `Hub.hasNote` (Task 3).
- Produces:
  - `classify(push: Push, noted: boolean, recentUnnoted: Push[]): {level, flags}` where `Push = {repo, ref, before, after, forced, ts}`; flags ⊆ `["no-note","forced","burst","created","deleted"]`. Pure.
  - Event record (queue item): `{seq: number, delivery: string, ts: number, kind: "push"|"disarmed", repo, ref, before, after, forced, level, flags}`.
  - `GET /queue?after=<seq>` with header `X-Watchdog-Auth: <base64 JSON {ts}>.<base64 armored SSHSIG ns account-watchdog-queue over the JSON bytes>` → `200 {events: Event[≤100], next: number}`; `401` otherwise (±300 s).
  - `GET /health` → `200 {"ok":true}`.
  - Hub calls `notify(event, env)` (Task 5) for every non-silent event; until Task 5 exists, a no-op stub in `src/notify.js`.

- [ ] **Step 1: Failing unit tests** (`classify.test.js`):
  - noted, not forced → `silent`
  - not noted, not forced, no recent → `warning` with `["no-note"]`
  - not noted, forced → `critical` with `no-note,forced`
  - not noted; recent un-noted pushes in last 10 min span 3 repos → `critical` + `burst`; 5 refs in 1 repo → `critical` + `burst`; same 5 refs but 11 min old → `warning`
  - `before` all zeros → flag `created`; `after` all zeros → flag `deleted` (Review Focus 2)
  - `ref = refs/tags/v1`, not noted → `warning` (Review Focus 3)
- [ ] **Step 2: Failing integration tests** (`webhook.test.js`, `SELF.fetch` with `WEBHOOK_SECRET` set):
  - bad HMAC → `401`
  - push webhook with matching note posted first → after advancing the DO alarm 20 s, `/queue` shows one event `level: "silent"`
  - push without note → `warning` event; forced → `critical`
  - note arriving 15 s *after* the webhook (before alarm fires) → `silent`
  - `installation_repositories` with `action: "removed"` and `installation` with `action: "deleted"` → `kind: "disarmed"`, `critical`, immediately (no grace)
  - `/queue` paging: 150 events → first page 100 with `next = 100`, second page 50
  - `/queue` bad auth → `401`; `/health` → `200`
  - `/queue` auth `ts` = now + 240 → `200`; now + 360 → `401` (Review Focus 5). Extend `test/fixtures/make.sh` to sign queue-auth fixtures (`queue-auth-*.txt`) with namespace `account-watchdog-queue`; tests pin `Date.now()` with `vi.setSystemTime`.
- [ ] **Step 3: Run** `npm test` — FAIL.
- [ ] **Step 4: Implement.** `/webhook`: verify HMAC; dispatch on `X-GitHub-Event`; for `push` store pending keyed by `X-GitHub-Delivery` with `ts = now`, set DO alarm at now + 20 s; `alarm()` classifies all pending older than 20 s using `hasNote` and the stored 10-min un-noted window, appends events with increasing `seq`, calls `notify` once per alarm run for the non-silent events, prunes events > 7 days (originally 24 h; changed by final-review ruling I4). Lower-case `repository.full_name`. Ignore other events with `204`.
- [ ] **Step 5: Run** `npm test` — PASS.
- [ ] **Step 6: Commit** `git commit -m "feat(watchdog): push classification, queue and health endpoints"`

---

### Task 5: Worker — notifications (ntfy + Slack)

**Files:**
- Modify: `worker/src/notify.js`
- Create: `worker/test/notify.test.js`

**Interfaces:**
- Consumes: Event record (Task 4).
- Produces: `formatAlert(events: Event[], tz = "Africa/Kigali"): {title, body, priority}` pure; `notify(event, env)` sends to `https://ntfy.sh/${env.NTFY_TOPIC}` (headers `Title`, `Priority` 5 critical / 3 warning, `Tags: rotating_light` / `warning`) and `env.SLACK_WEBHOOK_URL` (`{text}`); each sender failure is caught and logged, never thrown.

- [ ] **Step 1: Failing tests.**
  - critical forced push → title starts `🔴 Watchdog:` and contains `owner/repo`; body contains `refs/heads/main`, the short SHAs `abc1234 → def5678`, UTC and local times, flags, and **ends with** the exact revoke line from Global Constraints
  - warning → `🟠`, priority 3; disarmed → title contains `disarmed`
  - body never contains any field other than repo/ref/SHAs/times/flags (assert against an event object carrying an extra `diff` field)
  - `notify` with ntfy returning 500 still calls Slack and resolves
- [ ] **Step 2: Run** `npm test` — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(watchdog): ntfy + Slack alert fan-out"`

---

### Task 6: Mac — `lib.sh`, `note`, pre-push integration, local mirror copy

**Files:**
- Create: `account-watchdog/bin/lib.sh`, `account-watchdog/bin/note`, `account-watchdog/tests/{run.sh,helpers.sh,stub-worker.mjs,test_note.sh}`

**Interfaces:**
- Produces (sourced by every later Mac script):
  - Config file `~/.config/account-watchdog/config` (shell `KEY=value`): `WATCHDOG_URL`, `OWNER` (e.g. `alice`), `NOTE_PUBKEY_FILE`, `TZ_LOCAL`. Override dir with `WATCHDOG_CONFIG_DIR`, state with `WATCHDOG_STATE_DIR` (tests).
  - `repo_slug <remote-url>` → prints lower-case `owner/repo` or nothing if not github.com.
  - `wd_sign <namespace> <file>` → prints armored signature (uses `ssh-keygen -Y sign -f $NOTE_PUBKEY_FILE` via the Secretive agent socket; tests use a file key via `WATCHDOG_SIGN_KEY`).
  - `wd_ssh_env` → exports `GIT_SSH_COMMAND` with `-o ControlMaster=auto -o ControlPath=$STATE/cm-%C -o ControlPersist=120`.
  - `mirror_path <slug>` → `$STATE/mirrors/<owner>__<repo>.git`.
  - `wd_log <msg>` → appends to `$STATE/log/watchdog.log`.
- `note <remote-name> <remote-url>` reads pre-push stdin lines (`<lref> <lsha> <rref> <rsha>`), and for each line where `repo_slug` owner == `OWNER`: POSTs a note `{repo, ref: rref, old_sha: rsha, new_sha: lsha, ts, nonce}` to `$WATCHDOG_URL/note` (curl `--max-time 5`), then copies objects into the mirror if it exists: `git -C <mirror> fetch --quiet <toplevel> <lsha>` (skip when `lsha` is zeros). Always exits 0; on any failure prints `account-watchdog: note not sent (<reason>) — this push will raise a warning` to stderr.

- [ ] **Step 1: Test harness.** `stub-worker.mjs`: node HTTP server on a random port recording POST bodies to a JSON-lines file and serving `/queue` from a fixture file; prints the port. `helpers.sh`: `start_stub`, `stop_stub`, `assert_eq`, `assert_contains`, temp HOME/state dirs, a test signing key generated with `ssh-keygen`. `run.sh` runs every `tests/test_*.sh`, exits non-zero on any failure.
- [ ] **Step 2: Failing tests** (`test_note.sh`):
  - `repo_slug` maps `git@github.com:Alice/Repo.git`, `https://github.com/alice/repo`, `ssh://git@github.com/Alice/Repo.git`, `https://github.com/Alice/Repo/` all → `alice/repo`; `git@gitlab.com:x/y.git` → empty (Review Focus 1)
  - push line for an owned repo → stub received one note; its payload verifies with `ssh-keygen -Y verify` against the test key and namespace `account-watchdog-note`; fields match the stdin line
  - branch delete line (`lsha` zeros) → note sent with `new_sha` zeros, no mirror fetch attempted
  - repo of another owner → no note
  - stub stopped → exit 0 and stderr contains `note not sent`
  - existing mirror receives the pushed commit object (`git -C mirror cat-file -e <lsha>`)
- [ ] **Step 3: Run** `bash account-watchdog/tests/run.sh` — FAIL.
- [ ] **Step 4: Implement** `lib.sh` and `note`.
- [ ] **Step 5: Run** — PASS.
- [ ] **Step 6: Commit** `git commit -m "feat(watchdog): signed push notes from pre-push"`

---

### Task 7: Mac — `agent` (queue drain, heads, deep check, local alert)

**Files:**
- Create: `account-watchdog/bin/agent`, `account-watchdog/tests/test_agent.sh`

**Interfaces:**
- Consumes: `lib.sh` (Task 6); `/queue`, `/health`, Event record (Task 4).
- Produces:
  - `agent poll` — drains all pages after `$STATE/queue-cursor`, updates `$STATE/heads.json` (`{"owner/repo": {"refs/heads/x": "<sha>"}}`) with every event's `after` (removing the ref when `after` is zeros), writes non-silent events to `$STATE/incidents/<first-seq>.json` (one file per poll run, array of events after deep check), shows one local notification per incident file, and if any event is `critical` calls `restore --prompt <incident-file>` (Task 8).
  - Deep check per non-silent push, in the mirror (fetch it first via `wd_ssh_env`; public repos may use `https://github.com/<slug>.git` anonymously): `git log --format='%H %G?' before..after` with `gpg.ssh.allowedSignersFile=~/.config/git/allowed_signers` → any commit not `G` adds flag `unsigned`; `GIT_DIR=<mirror> GIT_WORK_TREE=$(mktemp -d) bash ~/.config/git/polin-guard/scan.sh range <before> <after>` exit 1 adds flag `payload`. Either flag upgrades `warning` → `critical`.
  - `agent health` — `GET /health`; if failing for > 1 h (timestamp in `$STATE/health-fail-since`) shows a local notification.
  - Queue auth header built with `wd_sign account-watchdog-queue`.

- [ ] **Step 1: Failing tests** (stub serves queue fixtures):
  - silent events only → `heads.json` updated, no incident file, cursor advanced
  - 67 critical events across 13 repos served in pages of 100/… → exactly **one** incident file containing 67 events and **one** `restore --prompt` invocation (stub `restore` via `WATCHDOG_RESTORE_CMD`) (Review Focus 4)
  - warning event whose range contains an unsigned commit in a local test mirror → incident level `critical`, flags include `unsigned`
  - warning event whose range adds the real 2026-10-03 sample (`scratchpad` copy committed as `tests/fixtures/vite.config.js.sample`) → flags include `payload`
  - deleted-branch event → ref removed from `heads.json`
  - `/health` failing with `health-fail-since` 2 h old → notification command (`WATCHDOG_NOTIFY_CMD`) called once
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** Use `osascript -e 'display notification …'` by default for `WATCHDOG_NOTIFY_CMD`.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(watchdog): queue agent with deep check and incident grouping"`

---

### Task 8: Mac — `restore`

**Files:**
- Create: `account-watchdog/bin/restore`, `account-watchdog/tests/test_restore.sh`

**Interfaces:**
- Consumes: incident file format (Task 7), `lib.sh`, `note` (Task 6).
- Produces: `restore --prompt <incident-file>` (dialog: `Restore N refs in M repos to their state at HH:MM?` buttons `Restore`, `Details`, `Ignore`; `WATCHDOG_DIALOG_CMD` override for tests) and `restore --yes <incident-file>` (no dialog). Writes `<incident-file>.result.json` `{restored:[…], skipped:[{repo,ref,reason}]}` and shows a summary notification ending with the revoke line.

Per `(repo, ref)`, using the **earliest** `before` and **latest** `after` across the incident's events; `URL` = `git@github.com:<slug>.git` (push to the URL, never `origin` — a `--mirror` clone rejects refspec pushes to its mirror remote; tests set `WATCHDOG_REMOTE_URL_TEMPLATE` to a local bare repo path):
- `before` zeros (attacker-created ref) → `git push --no-verify --force-with-lease=<ref>:<after> URL :<ref>` (delete)
- `after` zeros (attacker-deleted ref) → `git push --no-verify --force-with-lease=<ref>: URL <before>:<ref>` (expect absent)
- otherwise → `git push --no-verify --force-with-lease=<ref>:<after> URL <before>:<ref>`
- `before` object missing in mirror → skipped, reason `old commit not available locally`
- lease rejected → skipped, reason `ref moved since the incident`
`--no-verify` keeps the global hook from re-scanning and double-noting; instead `restore` sends one note per ref itself (via `note`'s functions in `lib.sh`) immediately before that ref's push, so the restore classifies `silent`. All pushes run from the mirror inside one `wd_ssh_env` session.

- [ ] **Step 1: Failing tests** (local bare repo as `origin`, stub worker):
  - forced push incident → branch back at `before`; result lists it restored; one note sent per ref
  - ref moved past `after` before restore → skipped `ref moved since the incident`, origin unchanged
  - attacker-created branch → deleted on origin (Review Focus 2)
  - attacker-pushed tag `refs/tags/v1` (moved) → tag restored (Review Focus 3)
  - two events on the same ref in one incident → restored to the earliest `before`
  - dialog returns `Ignore` → no pushes
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(watchdog): touch-id restore with force-with-lease"`

---

### Task 9: Mac — `reconcile` (missed webhooks + account keys)

**Files:**
- Create: `account-watchdog/bin/reconcile`, `account-watchdog/tests/test_reconcile.sh`

**Interfaces:**
- Consumes: `heads.json` (Task 7), `lib.sh`.
- Produces: `reconcile public` (hourly) and `reconcile all` (private too; runs only if `$STATE/reconcile-all-at` older than 24 h). Repo list `$STATE/repos.txt` (`<slug> <public|private>`, written by install/rotation). Public repos: `git ls-remote https://github.com/<slug>.git`; private: `git ls-remote git@github.com:<slug>.git` inside one `wd_ssh_env` session. Any ref whose remote SHA ≠ `heads.json` → append a `warning` event (`flags: ["missed-webhook"]`) to a new incident file and notify. Keys: `curl https://github.com/<OWNER>.keys` and `https://api.github.com/users/<OWNER>/ssh_signing_keys` → any key blob not in `$STATE/known-keys.txt` → `critical` notification `New key on your GitHub account`.

- [ ] **Step 1: Failing tests** (`WATCHDOG_GIT_LS_REMOTE` and `WATCHDOG_CURL` overridable to fixtures): matching heads → nothing; one moved ref → incident with `missed-webhook`; unknown auth key → critical notification; unknown signing key → critical notification; `reconcile all` skipped when last run < 24 h.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(watchdog): reconcile heads and account keys"`

---

### Task 10: Mac — `rotate` (gh token + SSH login key)

**Files:**
- Create: `account-watchdog/bin/rotate`, `account-watchdog/tests/test_rotate.sh`

**Interfaces:**
- Consumes: `lib.sh`, `known-keys.txt` (Task 9), spike result for the revoke endpoint (Task 1).
- Produces: `rotate check` (daily; for each of `gh`, `ssh` whose `last` in `$STATE/rotation.json` is ≥ 5 days old and `snooze_until` passed → dialog `Rotate now` / `Snooze 1 day`), `rotate gh`, `rotate ssh`. `rotation.json`: `{"gh":{"last":<ts>,"step":"<name>|null","snooze_until":<ts>}, "ssh":{…}}`; each flow persists `step` after every step and resumes from it. Overridable commands for tests: `WATCHDOG_OPEN_CMD`, `WATCHDOG_PBPASTE_CMD`, `WATCHDOG_PBCOPY_CMD`, `WATCHDOG_GH_CMD`, `WATCHDOG_CURL`, `WATCHDOG_DIALOG_CMD`, `WATCHDOG_SECRETIVE_DIR`.

`rotate gh` steps: `open-page` (open `https://github.com/settings/personal-access-tokens/new`, print the settings from Global Constraints) → `read-token` (pbpaste, must start `github_pat_`, clear clipboard) → `capture-old` (`gh auth token`) → `login` (`gh auth login --with-token`, verify `gh api user --jq .login` == OWNER, else restore old token and stop) → `revoke-old` (POST `/credentials/revoke` if the spike passed; otherwise open `https://github.com/settings/personal-access-tokens` and ask to confirm deletion) → `done` (set `last`, refresh `repos.txt` via `gh repo list`).

`rotate ssh` steps: `create` (prompt to create `github-auth-YYYY-MM-DD` in Secretive; wait for a new `*.pub` in `WATCHDOG_SECRETIVE_DIR` whose comment starts with that name) → `export` (`~/.ssh/github-auth.pub` → `github-auth.prev.pub`; new key → `github-auth.pub`) → `add` (pbcopy, open `https://github.com/settings/ssh/new`, remind **Authentication Key**, poll `https://github.com/<OWNER>.keys` every 5 s up to 10 min for the new blob) → `test` (`ssh -T git@github.com` output contains `successfully authenticated`; on failure restore `.prev` and stop) → `remove-old` (open `https://github.com/settings/keys`, poll until the old blob is absent from `.keys`) → `secretive-cleanup` (ask to delete the old secret; confirm absent from `ssh-add -l` on the Secretive socket) → `done` (rewrite `known-keys.txt`, set `last`).

- [ ] **Step 1: Failing tests:** `check` prompts only when ≥ 5 days and not snoozed; `Snooze 1 day` sets `snooze_until` = now + 86400; `gh` flow with stubs ends `last` set and old token revoked (stubbed curl saw the old token); clipboard content not starting `github_pat_` → stops at `read-token` without logging out; `gh api user` mismatch → old token restored; ssh flow interrupted after `export` then rerun → resumes at `add`; new key never appearing on `.keys` within timeout → `.prev` restored and stop; key added as a signing key only (absent from `.keys`) → same timeout path with message `added as a Signing Key? Add it as an Authentication Key`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(watchdog): guided gh-token and ssh-key rotation"`

---

### Task 11: `install.sh`, launchd jobs, README

**Files:**
- Create: `account-watchdog/install.sh`, `account-watchdog/launchd/{agent,reconcile,rotate}.plist.tmpl`, `account-watchdog/README.md`, `account-watchdog/tests/test_install.sh`
- Modify: `README.md` (repo root: one row in the "Run the one for your role" table pointing to `account-watchdog/README.md`)

**Interfaces:**
- Consumes: everything above.
- Produces: `install.sh [--from-step <name>]`, resumable via `$STATE/install-step`, steps: `prereqs` → `note-key` (guide creating `push-note` in Secretive, **no** authentication required; export pub to `~/.config/account-watchdog/push-note.pub`) → `worker` (`npm ci`; `npx wrangler login`; `wrangler deploy` with `NOTE_PUBKEY`; `wrangler secret put` `WEBHOOK_SECRET` (`openssl rand -hex 32`), `NTFY_TOPIC` (`wd-` + `openssl rand -hex 16`, printed once for the phone), `SLACK_WEBHOOK_URL` (prompted); `npx wrangler logout`; verify no file under `~/.wrangler` contains an oauth token) → `github-app` (print exact app settings; open `https://github.com/settings/apps/new`; owner generates a private key (GitHub requires one to install), installs on all repos; installer then deletes every `~/Downloads/*.private-key.pem` for this app (`rm -P`, after showing the path) and verifies none remains — GitHub refuses to delete the last key and keeps only its public half (spec §10.1); verify by posting a test push to `watchdog-drill` and seeing it in `/queue`) → `hook` (idempotently insert `printf '%s\n' "$input" | "$WATCHDOG_HOME/bin/note" "$@"` in `~/.config/git/hooks/pre-push` **after** the polin-guard scan loop and before the repo-hook chain, so blocked pushes send no note) → `repos` (`gh repo list` → `repos.txt`) → `mirrors` (clone `--mirror` all repos in one ControlMaster session) → `known-keys` → `launchd` (render templates to `~/Library/LaunchAgents/io.github.account-watchdog.{agent,reconcile,rotate}.plist`: agent `StartInterval 300` + `RunAtLoad`; reconcile `StartInterval 3600` running `reconcile public && reconcile all`; rotate `StartCalendarInterval` 10:00 daily running `rotate check`; `launchctl bootstrap gui/$UID`) → `first-rotation` (`rotate gh`) → `self-test` (Task 12 rows 1–2).

- [ ] **Step 1: Failing tests** (`test_install.sh`, temp HOME, all external commands stubbed): rerun after `hook` is a no-op (hook line present exactly once); `--from-step mirrors` skips earlier steps; rendered plists pass `plutil -lint`; `worker` step fails if a stubbed `~/.wrangler/config/default.toml` still contains `oauth_token`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS. Also run `cd worker && npm test` — PASS.
- [ ] **Step 5: README** — what it does, the credential table (spec §4), install, daily operation (what each alert means, how to restore, how to snooze), uninstall (`launchctl bootout`, delete app, `wrangler delete`).
- [ ] **Step 6: Commit** `git commit -m "feat(watchdog): installer, launchd jobs, docs"`

---

### Task 12: Live deployment, drill, and first rotation (owner present)

**Files:**
- Create: `account-watchdog/tests/drill.md` (checklist + recorded results)

**Interfaces:** Consumes the installed system. Uses `<owner>/watchdog-drill` and `tests/fixtures/vite.config.js.sample`.

- [ ] **Step 1: Install** — run `account-watchdog/install.sh` with the owner; complete every step.
- [ ] **Step 2: Drill** — run each row, record time-to-phone-alert from `git push` return to ntfy arrival:

| # | Action | Pass when |
|---|---|---|
| 1 | Signed push from this Mac | no alert; queue event `silent` |
| 2 | `git push --no-verify` | 🟠 on phone + Slack |
| 3 | From a second clone with `core.hooksPath=/dev/null`, force-push an unsigned commit adding the sample | 🔴 on phone ≤ 30 s; Mac incident flags include `forced`, `unsigned`, `payload`; Restore returns the branch to the previous SHA |
| 4 | Repeat 3, push one more commit on top, then Restore | ref skipped `ref moved since the incident`; nothing overwritten |
| 5 | 5 un-noted branch pushes within 1 min | `burst` → 🔴 |
| 6 | Remove `watchdog-drill` from the app installation | 🔴 `disarmed` (then re-add) |

- [ ] **Step 3: Rotation** — run `rotate ssh` end to end; confirm `ssh -T git@github.com` works with the new key and the old one is gone from `https://github.com/<owner>.keys`.
- [ ] **Step 4: Record** results in `drill.md`; any failed row → open a fix task before declaring done.
- [ ] **Step 5: Commit** `git commit -m "test(watchdog): live drill results"`
