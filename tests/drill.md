# Live drill

Run after `install.sh` has completed every step, in your drill repo (default `gitzilla-drill`; the name is `DRILL_REPO`
in `~/.config/gitzilla/config`), with the owner present. For each row, note the time from `git push` returning to the alert arriving on the phone (ntfy), and
fill in the Result column (pass/fail, time, notes). A failed row needs a fix task before the watchdog counts as done.

The payload sample is `tests/fixtures/stager.js.b64`. Outside the automated tests (which decode it into temp repos), base64-decode it inside the drill clone only (for example as
`vite.config.js`), and never anywhere else.

| # | Action | Pass when | Result |
|---|---|---|---|
| 1 | Signed push from this Mac | No alert; the queue event is `silent` | |
| 2 | `git push --no-verify` | 🟠 on the phone (and in Slack, if set) | |
| 3 | From a second clone with `core.hooksPath=/dev/null`, force-push an unsigned commit that adds the payload sample | 🔴 on the phone within 30 s. The Mac incident flags include `forced`, `unsigned` and `payload`. **Restore** returns the branch to the previous SHA | |
| 4 | Repeat row 3, push one more commit on top, then **Restore** | The ref is skipped with `ref moved since the incident`; nothing is overwritten | |
| 5 | Five un-noted branch pushes within 1 min | `burst`, 🔴 | |
| 6 | Remove your drill repo from the app installation (re-add it afterwards) | 🔴 `disarmed` | |
| 7 | Push an annotated tag from this Mac, then run `bin/reconcile public` twice, ≥ 10 min apart | No alert. The webhook `after` equals the tag-object SHA the note signed (queue event `silent`), and reconcile reports no mismatch for the tag | |
| 8 | From the second clone (hooks off), push a **new branch** whose only new commit adds the payload sample | 🔴; the Mac incident has `payload`. This exercises the real `scan.sh range 0000… <sha>` path | |
| 9 | `bin/rotate check` from launchd when rotation is due (or make it due), then choose **Rotate now** | The Terminal flow opens. Allow the macOS Automation (TCC) prompt for Terminal the first time | |
| 10 | Notification and restore dialog from the launchd agent job (not from a Terminal) | The macOS notification and the Restore / Details / Ignore dialog both appear while the job runs under launchd | |
| 11 | `bin/reconcile all` when it is due | Exactly one Touch ID for the whole private-repo pass | |
| 12 | Lost-event alert after a gap beyond the Mac's queue cursor | Manual note only, not simulated against the live Worker: if the Mac ever reports "N event(s) were lost while this Mac was offline", record it here with the date and what `reconcile all` found | |
| 13 | With calls set up, trigger a red alert (for example by repeating row 3); `bin/notify-test` checks the call on its own | The red alert rings the phone and the English voice names what happened (no SHAs); ntfy push and Slack arrive too. A second red alert within 10 min does not ring again | |

## Organization drill

Run after `./install.sh --org <org>` has completed, in the org's drill repo `<org>/gitzilla-drill`, with the admin and
two members present: member A and member B, each on their own Mac with their personal gitzilla installed. Use the
org's phone subscription (ntfy topic of the org Worker) and its Slack channel, if set. Every org push alert carries a
`Pusher:` line; check it in each row.

| # | Action | Pass when | Result |
|---|---|---|---|
| O1 | Member A runs `./install.sh --join-org <org Worker URL>` and tells the admin the fingerprint in person; the admin runs `GITZILLA_PROFILE=org-<org> bin/org list`, then `bin/org approve <a-login> <fingerprint>` | `list` shows A as pending with the same fingerprint A was shown; a normal push by A while still pending raises 🟠 `unenrolled` (a pending key never silences anything); after `approve`, `list` shows A as a member and no pending entry | |
| O2 | Member A (approved) makes a signed commit and pushes it normally | No alert; the org queue event is `silent` | |
| O3 | Member B makes commit C (A fetches it from B) and sends only the note for it, without pushing: `printf 'refs/heads/o3 <C> refs/heads/o3 0000000000000000000000000000000000000000\n' \| bin/note origin git@github.com:<org>/gitzilla-drill.git` on B's Mac. Then member A pushes C to `o3` with `git push --no-verify origin <C>:refs/heads/o3` | 🟠 `no-note` with `Pusher: <a-login>`: a note signed by B never silences a push whose sender is A | |
| O4 | Someone not enrolled (or a member whose key was revoked with `bin/org revoke`) pushes to the drill repo | 🟠 `unenrolled`, `Pusher: <their login>` | |
| O5 | From a second clone with hooks off, a member force-pushes an unsigned commit (calls set up for the org Worker) | 🔴 with `forced`, `Pusher:` line; the phone rings once (no second call within 10 min); the admin's restore dialog appears, and **Restore** puts the branch back (the admin needs push and bypass rights; without push the ref is skipped with `no push permission`) | |
| O6 | `bin/org allow-bot dependabot[bot]`, then let Dependabot push a branch; then `bin/org disallow-bot dependabot[bot]` and let it push again | First push silent (`bot`); after `disallow-bot` the next one is 🟠. A forced push by the bot is never silent | |
| O7 | Merge a pull request or edit a file in GitHub's web UI, first with the default `WEB_FLOW=orange`, then after `GITZILLA_WEB_FLOW=silent ./install.sh --org <org> --from-step worker` (Enter keeps the secrets) | 🟠 `web-flow` with the default; no alert with `silent` | |
