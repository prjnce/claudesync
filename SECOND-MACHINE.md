# Guide: bring your Claude history to another machine

**English** · [Tiếng Việt](SECOND-MACHINE.vi.md)

Use this once the first machine (for example `Office-PC`) has finished syncing and you want the same Claude Code history
on a second machine (for example the one at home). The same steps apply to a third and fourth machine.

## 0. What you need

| Item | Note |
|---|---|
| The same Google account | The account used on the first machine |
| The OAuth client file | `google_client_secret.json` from the Google Cloud project you created for claude-sync (or the Client ID + secret) |
| Bash 5, `curl`, `jq`, `gawk` | On Windows use Git Bash; on Linux/WSL install them with apt |
| The claude-sync code | `git pull` / `git clone` it onto the new machine |

> **Important:** the `drive.file` scope only sees files created by **that same OAuth client**. The new machine must use
> **exactly the same client**. If you create a new client, the new machine will not see the data that is already synced.

## 1. On the first machine: make sure everything is uploaded

```
claude-sync status
```

- No session is "waiting to upload", there are no errors, and the last run succeeded.
- If not, run `claude-sync run` and wait for it to finish (it shows progress as `[k/N - %]`).
- Only sessions that have reached Drive can be brought to the new machine.

## 2. On the second machine: run setup

```
cd <claude_sync folder>
bash bin/claude-sync setup
```

| Step | What to do |
|---|---|
| 0. Language | Pick `1` (English) |
| 1. Tools | Checked automatically; anything missing is reported |
| 2. OAuth client | Enter the path to `google_client_secret.json`. Or press Enter and type the Client ID and secret (the secret is not echoed; a malformed value is asked for again) |
| 3. Proxy | Press Enter if you do not use one |
| 4. Sign in | Open the URL, sign in with the **same Google account**, grant Drive access. See *Signing in on WSL/SSH* if the terminal does not pick the result up |
| 5. Root folder | Choose **the original root folder** on Drive; setup recognises it and reuses it instead of creating a new one |
| 6. This machine | Give it a name different from the old machine, for example `Home-PC` |
| 7. Transcript check | Automatic |
| 8. Projects | See the section below |
| 9. Retention | Keep or change `cleanupPeriodDays` (keep it large enough that Claude does not clean up old history) |
| Last | Installs the schedule and runs the first sync: sessions are downloaded into `~/.claude/projects/...` |

### Step 8: choose projects and map folders

This step lists the folders where Claude is used **on this machine**, numbered:

- Enter numbers separated by commas (for example `1,2`) to sync only those projects.
- Press Enter to sync all of them.
- Enter `0` (or `none`) if you do not want to sync any project from this machine.
- If the list is empty (no project has used Claude yet) the step is skipped.

Projects that exist on Drive but have no matching folder on this machine are **pending a mapping**. Map them so their
sessions get installed:

```
claude-sync projects pending                          # list the projects that are waiting
claude-sync projects map <project-name> <folder>      # point it at the real folder on this machine
```

The path on the new machine may differ from the old one (for example `D:\Projects\X` at the office, `/home/frank/X` at
home). After mapping, run `claude-sync run` to install right away.

## 3. Check that the history arrived

```
claude-sync status          # nothing "pending map", no errors
claude --resume             # you see the old sessions
```

Starting Claude with `claude-sync claude` pulls first and then opens Claude.

## 4. From then on

- Each machine syncs on its own schedule (every 5 minutes by default; change it with `claude-sync config set interval <1..1440>`).
- A new session on this machine shows up on the other one at its next sync, or run `claude-sync run` right away.
- Watch progress with `claude-sync run --progress`; read the log with `claude-sync logs -f`.

## Signing in on WSL/SSH

At step 4, if the browser does not open or the terminal does not pick up the result:

1. Open the printed URL in your own browser.
2. After you confirm, the browser shows a page with a **code** (or a "refused to connect" page).
3. Copy that **code** (or the whole address from the address bar), paste it into the terminal and press Enter.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `invalid_client` when signing in | The saved client secret is wrong: `claude-sync google client <file.json>`, then run `claude-sync setup` again |
| The new machine does not see the old data | Wrong OAuth client or wrong root folder. Check step 2 and step 5 |
| A project exists but its sessions do not arrive | The project is pending a mapping: `claude-sync projects pending`, then `projects map` |
| You want to redo the import on this machine from scratch | `claude-sync reset` (clears local state only, nothing on Drive), then `claude-sync run` |
| You need to see all commands | `claude-sync help` |

## Limits to know

- A session that Claude already cleaned up on the old machine because of `cleanupPeriodDays` no longer exists to be synced.
- The real three-machine scenario has not been tested by hand yet; the tests that simulate several machines all pass.
  Try it with a small project before relying on it completely.
