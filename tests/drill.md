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
