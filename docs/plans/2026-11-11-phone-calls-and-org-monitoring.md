# Phone calls and org monitoring — implementation plan

> For agentic workers: execute task by task (subagent-driven). Steps use checkbox syntax.

**Goal:** red alerts also ring phones through ntfy calls (A); an org security team can watch a whole GitHub
organization with one org Worker, enrolled members and an admin Mac (B).

**Spec:** `docs/specs/2026-11-11-phone-calls-and-org-monitoring.md` (approved 2026-11-11). Base design:
`docs/design.md`. The spec is the authority; this plan argues from it.

**Tech:** macOS `/bin/bash` 3.2 scripts (`bin/`, `install.sh`), Cloudflare Worker + Durable Object (`worker/src`),
bash tests (`tests/*.sh`, run by `bash tests/run.sh`), vitest (`cd worker && npx vitest run`).

## Global constraints

- Every git command in tests and probes runs with `HOME=<temp>`, `GIT_CONFIG_GLOBAL=<temp file>`,
  `GIT_CONFIG_NOSYSTEM=1` (the real config triggers Touch ID signing and hangs). tests/helpers.sh already does this.
- Never run install.sh, launchctl, `wrangler login/deploy/secret`, `gh auth`, or ssh to GitHub against the real HOME;
  never touch the real `~/.config`, `~/.ssh`, `~/Library/LaunchAgents`, or the real global git hooks.
- Commits are signed with the owner's key (Touch ID). Commit normally (`git commit`); if signing is refused or
  times out, report BLOCKED. Never use `--no-gpg-sign` or `commit.gpgsign=false`. No `Co-Authored-By` trailer.
- No secret (webhook secret, ntfy topic, Slack URL, ntfy call token, phone numbers) on disk, in logs or in argv.
  Secrets reach wrangler on stdin.
- Every non-silent alert body ends with exactly:
  `If this wasn't you: revoke tokens at https://github.com/settings/applications`. Alerts never carry commit content.
- Shell runs on macOS `/bin/bash` 3.2: no associative arrays, `${x,,}`, `mapfile`, `readarray`.
- No subagents inside subagents. Work only in `/Users/bigwi/Documents/code/security/gitzilla`, branch `org-and-calls`.
- Personal mode stays byte-for-byte compatible: with `MODE` unset and no profile, every existing test still passes
  unchanged (except where a task explicitly updates it).

## Review focus

1. A note signed by member A must never silence a push whose `sender.login` is member B (org mode).
2. Pending enrollments must never make any push silent; only admin-signed approval activates a key.
3. Call limits: a burst of 50 events places at most one call per number per 10 minutes; a failing ntfy call never
   blocks Slack/ntfy push delivery.
4. Profiles: running the org profile must not read or write the personal profile's config, state or launchd jobs.
5. Phone numbers and the call token never appear in logs, test output files, config files or argv.

---

### Task 1: Worker — calls on red alerts

**Files:** modify `worker/src/notify.js`, `worker/src/hub.js`, `worker/src/index.js`; test
`worker/test/calls.test.js` (new).

**Interfaces (produces):**
- `notify.js`: `parseCallNumbers(str) -> string[]` (split on `,`, trim, keep `^\+[1-9][0-9]{6,14}$`, dedupe, first 5).
- `notify.js`: `formatCall(events) -> string` and `formatAccountCall(alert) -> string`: spoken text per spec §A
  (`gitzilla critical alert. Possible stolen GitHub credential. <N> event(s) in <r1>, <r2>, <r3> and <k> more. Check
  Slack or the ntfy app, and revoke tokens if this was not you.`; repo names reduced to `[a-z0-9._/-]`, max 60 chars,
  max 3 names; for account alerts: `gitzilla critical alert. A new key was added to your GitHub account. Check Slack
  or the ntfy app, and revoke tokens if this was not you.`; disarmed: `... gitzilla was disarmed for <names>. ...`).
- `send({title, body, priority, spoken}, env, timeoutMs, callGate)`: unchanged ntfy/Slack behaviour; additionally,
  when `priority === 5`, `spoken` is set, `env.NTFY_TOPIC`, `env.NTFY_CALL_TOKEN` (must match `^tk_[A-Za-z0-9]{29}$`)
  and at least one number exist: for each number with `await callGate(number) === true`, POST to `https://ntfy.sh`
  JSON `{topic: NTFY_TOPIC + "-call", title, message: spoken, priority: 5, call: number}` with header
  `Authorization: Bearer <token>`. Calls run in the same `Promise.allSettled` as the other jobs. A log line on
  failure contains the HTTP status and the number masked to its last 2 digits (`+******42`), never the token.
- `hub.js`: `Hub.callAllowed(number, now = Date.now(), test = false) -> boolean`. Normal: key `call:<number>` holds
  the last call ms; allowed when absent or `now - last >= 600_000`, then stores `now`. Test: key `testcall:<number>`,
  allowed when `now - last >= 3_600_000`, stores `now`, and does not touch `call:`. Prune `call:`/`testcall:` keys
  older than 1 h in `#prune`.
- Hub's `#notify` passes `(n) => this.callAllowed(n)`; index.js handlers pass `(n) => getHub(env).callAllowed(n)`.

- [ ] Tests first (`calls.test.js`): parseCallNumbers (valid, invalid dropped, >5 cut, dedupe); formatCall caps and
  charset; a critical push run with 2 numbers posts 2 call requests with Bearer header and topic `<topic>-call`;
  a warning run posts no call; missing token / bad token / no numbers / no NTFY_TOPIC → no call; second critical run
  within 10 min → no call, after 10 min → call; a call fetch rejecting still delivers ntfy push and Slack; no log
  line contains the token or a full number (spy on console.error).
- [ ] Implement; `npx vitest run` green; commit `feat(worker): voice calls on red alerts via ntfy`.

### Task 2: test alert, installer prompts, docs

**Files:** modify `worker/src/index.js`, `worker/src/notify.js`, `install.sh`, `README.md`, `tests/drill.md`;
create `bin/notify-test`; tests `worker/test/alert.test.js`, `tests/test_install.sh`, `tests/test_notify_test.sh`
(new, wire into `tests/run.sh` if it does not glob).

**Interfaces:**
- `/alert` accepts `kind: "test"` with exactly `{kind, ts, nonce}`; renders title `🔴 gitzilla: test alert`, body
  `This is a test of every alert channel.\nTime: ...\n\n<REVOKE>`, priority 5, spoken
  `gitzilla test call. Your alert channels work.`; its callGate uses `callAllowed(n, now, true)`.
- `bin/notify-test`: builds and signs the test alert like `bin/reconcile`'s account alerts (reuse the lib.sh helper
  that `wd_send_alert` uses; extend it to accept `test`), prints `test alert sent` or the failure reason; exit 0/1.
- install.sh worker step (fresh or rotate mode), after the Slack prompt:
  `Phone numbers for red-alert calls, comma-separated +E164 (ntfy Pro; Enter to skip) (input hidden): `, then if
  non-empty `ntfy access token (tk_...) (input hidden): `. Validation: every number `^\+[1-9][0-9]{6,14}$`, 1–5
  numbers, token `^tk_[A-Za-z0-9]{29}$`; on failure `worker_die` with a clear message. Values go to
  `wrangler secret put NTFY_CALL_NUMBERS` / `NTFY_CALL_TOKEN` on stdin; cleared from variables afterwards. Empty:
  no secret put (and README says how to delete old ones, as for Slack).
- self-test: optional row 3 `Send a test alert to every channel (rings the phone if calls are set up)?` → runs
  `bin/notify-test`, then asks whether every channel received it; logged like rows 1–2.
- README: channels section (ntfy push, Slack, calls with ntfy Pro and verified numbers, quotas, English-only voice),
  security table row for the call token and numbers; drill.md row: red alert rings the phone.

- [ ] Tests first: Worker `/alert` test kind accepted/rejected shapes, hourly test-call gate; install worker step
  with numbers+token (secrets piped on stdin, never in argv log of the npx stub, never in config), invalid number,
  invalid token, skip; notify-test signs with namespace `gitzilla-alert` and handles 401/unreachable.
- [ ] Implement; both suites green; commit `feat: test alert and call setup in the installer`.

### Task 3: Mac profiles

**Files:** modify `bin/lib.sh`, `install.sh`, `launchd/*.plist.tmpl`, `README.md`; tests `tests/test_profile.sh`
(new) plus existing tests unchanged.

**Interfaces:**
- `GITZILLA_PROFILE` (env), validated `^[a-z0-9][a-z0-9-]{0,39}$` (invalid → die). Unset/empty = personal, paths as
  today. Set: `GITZILLA_CONFIG_DIR=~/.config/gitzilla/<p>`, `STATE=~/.local/state/gitzilla/<p>`,
  log in that state dir, mirrors under it.
- install.sh `LABEL_PREFIX="io.github.gitzilla"` personal; `io.github.gitzilla.<p>` with a profile. Plist templates
  get `@PROFILE@` in `EnvironmentVariables` (key omitted entirely for personal; render handles both).
- The hook: per-profile note routing is Task 6; in this task the hook step refuses to run in a profile
  (`the hook is installed by the personal profile`).

- [ ] Tests first: path selection both ways; invalid profile; launchd render with/without profile (plutil -lint);
  a profile install run (stubs) leaves the personal config/state untouched.
- [ ] Implement; suites green; commit `feat: profiles for running several gitzilla instances`.

### Task 4: Worker org mode — members, enrollment, admin commands

**Files:** modify `worker/src/index.js`, `worker/src/hub.js`, `worker/wrangler.toml` (vars `MODE = "personal"`,
`ORG = ""`, `ADMIN_PUBKEYS = ""`, `WEB_FLOW = "orange"`); create `worker/src/members.js`; tests
`worker/test/org-members.test.js`.

**Interfaces:**
- `verifyAny(sig, raw, namespace, keys[]) -> key|null` in index.js (wraps `verifySshSig`).
- Org mode = `env.MODE === "org"`. In org mode `/queue`, `/report`, `/alert` verify against `ADMIN_PUBKEYS`
  (newline- or comma-separated ssh public key lines, max 3) instead of `NOTE_PUBKEY`. Personal mode unchanged.
- `POST /enroll` (org mode only; 404 otherwise): body `{payload, sig}`, payload `{login, pubkey, ts, nonce}` where
  login `^[a-z0-9](?:[a-z0-9-]{0,38})$` (lowercased), pubkey an `ecdsa-sha2-nistp256` line; sig verifies with that
  pubkey in namespace `gitzilla-enroll`. Rate limit 10 per hour per `CF-Connecting-IP` (Hub key `rl:<ip>:<hour>`),
  max 200 pending (`pending:<login>:<fp>` → `{pubkey, ts}`, expiry 7 days). Response 202. Sends one orange alert
  `🟠 gitzilla: enrollment request` with `Login: <login>` and `Key: <SHA256 fingerprint>` (+ REVOKE line).
- `POST /admin` (org mode only): payload `{cmd, args, ts, nonce}` signed by an ADMIN key, namespace
  `gitzilla-admin`, skew 5 min, nonce single use. Commands: `approve {login, fingerprint}` (pending → `member:<login>`
  list entry `{pubkey, fp, added_ts, added_by: <admin fp>}`, 404 if no such pending), `revoke {login, fingerprint?}`,
  `list {}` → `{members:[{login, fps}], pending:[{login, fp, ts}], bots:[...]}`, `allow-bot {login}`,
  `disallow-bot {login}` (`bot:<login>`). Max 2000 members, 8 keys per member.
- `members.js`: `fingerprint(pubkeyLine) -> "SHA256:..."` (sha256 of the key blob, base64 without padding — same as
  `ssh-keygen -lf`), pure helpers for validation.

- [ ] Tests first: enroll happy path, bad sig, wrong namespace, bad login, rate limit, pending cap, personal mode 404;
  admin: approve/revoke/list/bots with admin key; member key cannot run admin commands; replayed nonce; approve of a
  non-pending key fails; queue auth uses admin keys in org mode and NOTE_PUBKEY in personal mode; fingerprint matches
  `ssh-keygen -lf` output for a fixture key.
- [ ] Implement; vitest green; commit `feat(worker): org mode members, enrollment and admin commands`.

### Task 5: Worker org mode — note binding and classification

**Files:** modify `worker/src/index.js`, `worker/src/hub.js`, `worker/src/classify.js`, `worker/src/notify.js`;
tests `worker/test/org-classify.test.js`.

**Interfaces:**
- Org-mode `/note`: verify against every active member key (`verifyAny`); store the note with the signer login:
  key `note:<repo>|<ref>|<sha>` value `{exp, logins:[...]}` (personal mode keeps today's value shape or a compatible
  one; update `#prune`). Unknown signer → 401.
- Webhook push (org mode) passes `sender: {login (lowercased), type}` and `webflow: commits.length > 0 &&
  every commit.committer.username === "web-flow"` to `receivePush`.
- `classifyOrg(push, ctx, recentUnnoted) -> {level, flags}` in classify.js, implementing the spec table in this
  order: noted by the sender's own login → silent; `sender.type === "Bot"` or allowlisted → silent `bot`;
  webflow → `WEB_FLOW === "silent"` ? silent `web-flow` : warning `web-flow`; else enrolled → `no-note`, not
  enrolled → `unenrolled`; then `forced`/`burst`/`created`/`deleted` as in `classify`, critical if forced or burst.
  Burst counts all non-silent pushes in the window.
- Events and alerts carry `pusher` (login) in org mode; `formatAlert` adds `Pusher: <login>` after `Ref:` when set.

- [ ] Tests first: every spec table row; **note by member A, push sender B → not silent**; note by enrolled B for
  B's push → silent; bot type and allowlist; web-flow orange by default and silent with `WEB_FLOW=silent`; forced
  unenrolled push → critical with call (Task 1 path); burst across members; personal mode tests untouched.
- [ ] Implement; vitest green; commit `feat(worker): org push classification bound to the pusher`.

### Task 6: Mac — join an org, note routing, admin CLI

**Files:** modify `bin/note`, `bin/lib.sh`, `install.sh`, `README.md`; create `bin/org`; tests
`tests/test_note.sh`, `tests/test_org.sh` (new), `tests/test_install.sh`.

**Interfaces:**
- Personal config gains `ORG_WORKERS` (`%q`-quoted, space-separated `<org-login>=<https-url>` pairs).
  `bin/note`: owner == OWNER → personal Worker (today); owner == an org in ORG_WORKERS → that Worker; else no note.
  `wd_send_note` takes the target URL as a parameter.
- `./install.sh --join-org <https-url>` (personal profile only): reads the org login from `GET <url>/health`
  (extend `/health` in org mode to return `{ok, mode:"org", org}`), signs and posts `/enroll`, appends to
  ORG_WORKERS, prints `Tell your gitzilla admin this fingerprint: SHA256:...`. Idempotent.
- `bin/org approve <login> <fingerprint> | revoke <login> [<fingerprint>] | list | allow-bot <login> |
  disallow-bot <login>`: runs in an org profile (requires `GITZILLA_PROFILE`), signs with the admin's push-note key
  (namespace `gitzilla-admin`) and calls `/admin`; prints the result readably.

- [ ] Tests first: note routing (own repo, org repo, other owner), join-org with stub worker, bin/org commands
  signing namespace and payloads, refusal outside a profile.
- [ ] Implement; suites green; commit `feat: join an org, route notes, admin commands`.

### Task 7: Mac — org install, restore/reconcile in org profile, docs

**Files:** modify `install.sh`, `bin/restore`, `bin/reconcile`, `README.md`, `tests/drill.md`; tests
`tests/test_install.sh`, `tests/test_reconcile.sh`, `tests/test_restore.sh`.

**Interfaces:**
- `./install.sh --org <org-login>` = profile `org-<org-login>` with steps `prereqs note-key worker github-app repos
  mirrors launchd self-test` (no hook, known-keys, first-rotation). Worker step deploys with
  `--var MODE:org --var ORG:<org> --var ADMIN_PUBKEYS:<admin push-note pub>` and Worker name `gitzilla-<org>`
  (`--name`); App name `gitzilla-<org>` (34-char rule); App settings say "install on the organization, all repos";
  drill repo lives in the org (`<org>/gitzilla-drill`, created on confirmation). repos step uses `gh repo list <org>`.
  OWNER in the org profile config is the org login. The org admin's push-note key is the same Secretive key.
- restore in an org profile: before pushing, check `gh api repos/<repo> --jq .permissions.push` (or admin) and
  report `no push permission` as a skip reason (add to the Worker's REPORT_REASONS).
- reconcile in an org profile: skip the account-key check, keep the missed-webhook check.
- README: "Organizations" section (admin install, member join, approve, bots, web-flow setting, what admins need:
  push + bypass for restore), alerts section updated with Pusher line; drill rows for org.

- [ ] Tests first for each behaviour above with stubs.
- [ ] Implement; suites green; commit `feat: org install and org profile behaviour`.

### Final: whole-branch review on the most capable model, one fix wave, scoped re-review.
