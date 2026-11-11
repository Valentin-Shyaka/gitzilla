# Phone calls and org monitoring — design

Status: draft for review, 2026-11-11. Builds on `docs/design.md` (gitzilla was called account-watchdog there).

Two features, built in this order because org monitoring reuses the first:

- **A. Phone calls**: a red alert also places a voice call to one or more phone numbers, through ntfy.
- **B. Org monitoring**: a security team watches every repo of a GitHub organization. Members' pushes are vouched
  for by their own Macs; anything else alerts the org's Slack, ntfy and phone numbers.

Decisions taken with the owner (2026-11-11):

| Question | Decision |
|---|---|
| Call provider | ntfy phone calls (ntfy Pro, numbers verified in that ntfy account) |
| Org model | One org Worker + one org GitHub App; developers enroll their push-note key |
| Deep checks / restore for org repos | One admin's Mac runs agent, reconcile and restore for the org |
| Pushes from people or bots without gitzilla | Allowlisted bots silent; unenrolled members orange |

## A. Phone calls

### Behaviour

- Only **critical (red)** alerts that pass through the Worker call: force-push or burst without a note, disarmed,
  new account key. Orange alerts never call. (Alerts the Mac raises only locally, such as "lost events", do not.)
- One call per number per alarm run (alerts are already aggregated per run), and **at most one call per number
  every 10 minutes**. Suppressed calls are logged in the Worker, and the push/Slack alerts still go out.
- The call goes through ntfy's publish API: JSON to `https://ntfy.sh` with `call: "<+E164 number>"`, an
  `Authorization: Bearer <token>` header, and a separate topic (`<NTFY_TOPIC>-call`) so the call does not
  duplicate the phone push. ntfy speaks the message up to three times, in English only.
- Spoken text is short and contains no SHAs: `gitzilla critical alert. Possible stolen GitHub credential.
  <N> event(s) in <repo>, <repo> and <k> more. Check Slack or the ntfy app, and revoke tokens if this was not you.`
  Repo names are capped (3 names, 60 chars each) and reduced to `[a-z0-9._/-]`.

### Configuration

New Worker secrets, all optional; calls are off unless both are set:

| Secret | Value |
|---|---|
| `NTFY_CALL_TOKEN` | ntfy access token (`tk_` + 29 chars), from the ntfy Pro account that verified the numbers |
| `NTFY_CALL_NUMBERS` | comma-separated `+E164` numbers, max 5 (kept secret: phone numbers are personal data) |

Installer, worker step: after the Slack prompt, "Phone numbers for red-alert calls (ntfy Pro, optional)". Input is
hidden, validated (`^\+[1-9][0-9]{6,14}$` per number, max 5), and piped to `wrangler secret put`; the token is read
hidden and must start with `tk_`. Empty skips both. Same keep/rotate rules as the other secrets.

### Test call

`POST /alert` gains `kind: "test"` (signed by the push-note key in the existing `gitzilla-alert` namespace, same
nonce/ts rules). It sends a test alert to every channel, **including a call**, bypassing the 10-minute call limit
once per hour. `bin/notify-test` (new, small) sends it; the installer's self-test offers it as an optional row.

### Failure modes

- ntfy returns 4xx (unverified number, no Pro plan, quota used up): logged with the status; other channels unaffected.
- Token stolen: the attacker can place calls and use the call quota of that ntfy account. They cannot read code.
  Added to the security model table.

## B. Org monitoring

### Roles

- **Org admin** (security team): deploys the org Worker and org GitHub App, approves enrollments, runs the org's
  deep checks and restores from their Mac.
- **Member** (developer): already runs gitzilla for their own account; joins the org once.

### Pieces

```
member Mac  pre-push hook ── note (signed by member's push-note key) ──┐
                                                                      ├──▶ org Worker ── match by pusher ──▶ silent
GitHub org  org App (read-only, all repos) ── push webhook ───────────┘                └─ no ──▶ org Slack/ntfy/calls
admin Mac   org profile: agent · reconcile · restore for org repos (mirrors, admin's Secretive key)
```

The org Worker is the same Worker code in **org mode** (`MODE = "org"` var, plus `ORG` = org login). Personal
Workers keep working unchanged (`MODE` absent or `"personal"`).

### Keys and enrollment

- `ADMIN_PUBKEYS` var: the push-note public keys of 1–3 admins (from their Secretive). Admin commands are signed
  with these, namespace `gitzilla-admin`, with ts/nonce like notes.
- Member keys live in the org Hub (Durable Object storage): `member:<login>` → list of `{key, added_ts, added_by}`.
- **Enrollment**:
  1. Member runs `./install.sh --join-org <org-worker-url>`. It posts `{login, pubkey}` to `POST /enroll`, signed
     with the member's push-note key in namespace `gitzilla-enroll` (proves possession of the key). The `login` comes
     from `gh api user`; it is a claim the admin confirms, not a proof.
  2. The org Worker stores it as `pending:<login>:<fingerprint>` (max 200 pending, 7-day expiry, 10/hour/IP) and
     posts an orange "enrollment request" to the org channels with login and fingerprint.
  3. The member tells the admin their fingerprint out of band (the installer prints it). The admin runs
     `bin/org approve <login> <fingerprint>` on their Mac (signed admin command). Only then is the key active.
  4. `bin/org list | revoke <login> [<fingerprint>] | allow-bot <login> | disallow-bot <login>` complete the set.
  Pending requests can never make a push silent.
- Member Mac config gains `ORG_WORKERS="<org-login>=<url> ..."`. `bin/note` sends the note to the org Worker when
  the repo's owner is that org, and to the personal Worker when it is the member's own login. One note per ref, same
  push-note key, same payload.

### Classification (org mode)

The org Worker matches a webhook push to a note by `repo, ref, new sha` **and** requires that the note was signed by a
key enrolled for the push's `sender.login`. Then:

| Push | Level | Flags |
|---|---|---|
| matching note from the pusher's enrolled key | silent | |
| `sender.type == "Bot"`, or sender on the bot allowlist | silent (logged) | `bot` |
| all new commits committed by GitHub's web-flow (UI merge/edit) | **orange** | `web-flow` |
| sender enrolled, no matching note | orange; red if forced or burst | `no-note` (+ `forced`, `burst`) |
| sender not enrolled | orange; red if forced or burst | `unenrolled` (+ `forced`, `burst`) |
| org App uninstalled, suspended, or repos removed | red | `disarmed` |

**Deviation from the agreed answer:** web-UI merges were to stay silent. They are orange instead, because a stolen
token can create commits through the REST contents API and those commits look exactly like web-UI commits
(committer `web-flow`). The `web-flow` flag lets people tell them apart at a glance. An org that merges through the
UI all day can set `WEB_FLOW = "silent"` to accept that risk.

Burst detection is per org (≥ 3 repos or ≥ 5 refs without a matching note within 10 minutes, as today).

### Admin Mac: org profile

The Mac scripts get **profiles** so one Mac can run its personal gitzilla and an org's:

- `GITZILLA_PROFILE=<name>` selects `~/.config/gitzilla/<name>/` and `~/.local/state/gitzilla/<name>/`; launchd
  labels become `io.github.gitzilla.<name>.<job>`. No profile = today's paths (personal), unchanged.
- `./install.sh --org <org-login>` runs an org install as profile `org-<org-login>`: org Worker deploy (org mode,
  admin key, secrets incl. calls), org App creation (installed on the org, all repos), repos (`gh repo list <org>`),
  mirrors + seed, launchd. It skips known-keys and first-rotation (those are about the admin's own account).
- agent, restore and reconcile work as today against the org's repos. Restore pushes with the admin's key, so the
  admin needs push rights and must be allowed to bypass branch protection on the affected branches; the installer
  checks `gh api repos/<org>/<repo>` permissions for a sample and warns.
- reconcile's account-key check is skipped in org profile (no org equivalent in scope; see Out of scope).

### Alerts

Org alerts use the same format, with the pusher added: `Pusher: <login>` (and `Flags:` as above). They go to the
org Worker's channels: Slack (typically an org-wide channel), ntfy topic, and calls (feature A) for red.

### Security

| Credential | Where | If stolen |
|---|---|---|
| Admin push-note keys | admins' Secure Enclaves | Not exportable. Malware on an admin's Mac could approve a key. |
| Member push-note keys | members' Secure Enclaves | Not exportable. Malware on a member's Mac could sign notes for that member's pushes. |
| Org App private key | **not kept** (deleted after install, as today) | nothing |
| Org Worker secrets | Worker | webhook secret: fake alerts; ntfy/Slack/call: read alerts, place calls |

No stored credential can push. The org App is read-only (Contents, Metadata; Members: read to resolve logins is not
needed: the webhook carries `sender.login`).

## Testing

- Worker: unit tests for call formatting and limits; org-mode classification table above row by row; enrollment
  (signature, pending cap, rate limit, approve/revoke by admin only, member key used for the right login only);
  note-to-pusher binding (a note signed by member A does not silence a push sent by member B).
- Mac: profile path selection, `note` routing to org vs personal Worker, `install.sh --org` and `--join-org` steps
  with stubs, `bin/org` commands, the call-number and token validation in the worker step.
- Live drill additions: a red alert rings the phone; an org push by an enrolled member is silent; by an unenrolled
  member is orange; a forced push without note is red with a call.

## Out of scope (now)

- SMS (ntfy does not send SMS; would need another provider).
- Watching org settings (new owners, new org webhooks, deploy keys) and members' account keys from the org side.
- Multiple orgs per Worker; GitHub Enterprise Server.
- Automatic enrollment through SSO or GitHub org membership.
