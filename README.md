<p align="center"><img src="docs/logo.png" alt="claude-sync" width="160"></p>

<h1 align="center">claude-sync</h1>

<p align="center">Keep your Claude Code sessions in sync across Windows, Linux and WSL through your own Google Drive.</p>

<p align="center"><b>English</b> · <a href="README.vi.md">Tiếng Việt</a></p>

---

> **Status: early development (v0.1.0-dev).** Setup, sign-in, project mapping, legacy-data repair and the
> first version of the sync engine work and are tested, but automatic background sync, Claude Code hooks
> and conflict handling are not finished. **Do not rely on it for real syncing yet.** See [Status](#status).

## What it does

You start a Claude Code session on one machine and want to continue it on another. claude-sync copies
your sessions through a folder in your own Google Drive so that, within one sync cycle:

- the session shows up in `/resume` (CLI and VS Code) on every other machine,
- `claude --resume <id>` continues it exactly as on the original machine, and
- no transcript line is ever lost — even when two machines kept writing while offline.

Paths are translated between machines: a session started in `D:\Projects\TransFlow` on Windows resumes
in `~/projects/TransFlowX` on Ubuntu, with its working directory, file history and memory pointing at the
right places.

It is a plain Bash application (Git Bash on Windows, Bash on Linux) that talks to the Google Drive API
with `curl` — no daemon, no rclone, no server of its own.

## How it works

- **One folder on your Drive.** `Claude Sync/` holds a marker file and one area per machine
  (`machines/<machine-id>/`). Each machine writes only to its own area and reads the others.
- **Canonical form.** Before upload, machine-specific paths inside transcripts are replaced by tokens
  (`{P:<project>}`, `{R:…}`, `{MEM:…}`, `{CFG}`); the receiving machine replaces them with its own paths.
  Only path-valued JSON keys are touched; every other byte is kept as is.
- **Append-only segments.** A transcript version is a chain of gzipped segments identified by a hash
  chain. Normally only the newly appended lines travel; a machine continuing another machine's session
  references that machine's segments.
- **Manifests.** Each machine publishes a small `manifest.json.gz` listing its sessions and versions.
  A sync cycle downloads changed manifests, installs newer versions, then publishes local changes.
- **Safe writes.** Installs write a temporary file, check it, then rename it over the target only if
  neither the file nor Claude's running-session registry changed meanwhile. Open sessions are never
  overwritten. Nothing is ever deleted permanently on Drive.

The full design is in [docs/SPEC.md](docs/SPEC.md) (Vietnamese).

## Requirements

| | Windows | Ubuntu / WSL |
|---|---|---|
| Shell | Git for Windows (Git Bash, bash ≥ 4.4) | bash ≥ 4.4 |
| Tools | `jq`, `curl`, `perl`, `openssl`, `gzip`, `iconv` (Git for Windows ships most; jq: `winget install jqlang.jq`) | `sudo apt install curl jq` (the rest is in the base system) |
| Sign-in listener | PowerShell (built in) | `python3` (otherwise you paste the final browser URL) |
| Repair of old data | `node` or `python3` | `node` or `python3` |
| Google | A personal Google account and your own OAuth client (below) | same |

Both `gawk` and `mawk` work. WSL counts as a separate machine.

## Install

There is no installer yet. Clone the repository and run the entry point directly:

```bash
git clone https://github.com/prjnce/claudesync.git
cd claudesync
bash bin/claude-sync --version
```

Optionally put `bin/` on your `PATH` or create an alias.

## One-time: create a Google OAuth client

claude-sync uses your own OAuth client, so no third party ever sees your data. Create it once and copy
the same JSON file to every machine.

1. Open <https://console.cloud.google.com> and create a project, e.g. `claude-sync`.
2. **APIs & Services** → enable **Google Drive API**.
3. **Google Auth Platform → Branding**: app name and support email.
4. **Audience**: *External*, add yourself as a test user, then **Publish app**. While the app is in
   *Testing*, sign-ins expire after 7 days.
5. **Data access**: add the scope `https://www.googleapis.com/auth/drive.file` (the app can only see
   files it created).
6. **Clients → Create client → Desktop app**, and download the JSON right away.

Keep the JSON out of version control (this repository's `.gitignore` already ignores
`*client_secret*.json`).

## Quick start

```bash
# 1. Language, OAuth client, proxy, Google sign-in, root folder, machine name
bash bin/claude-sync setup

# 2. See which folders have Claude sessions and choose what to sync
bash bin/claude-sync projects list
bash bin/claude-sync projects select        # or: projects map <name> <folder>

# 3. Check the local Claude data; fix legacy damage if doctor reports any
bash bin/claude-sync doctor
bash bin/claude-sync repair --dry-run       # read-only report
bash bin/claude-sync repair                 # asks before changing anything; backs up first
```

Run `setup` on every machine with the same OAuth client JSON. The first machine creates the
`Claude Sync` folder; the others find it automatically.

## Commands

| Command | | What it does |
|---|---|---|
| `setup [--step NAME]` | ✅ steps 0–6 | Wizard: language, dependencies, OAuth client, proxy, sign-in, root folder, machine name. Re-runnable. |
| `login [--client FILE]` / `logout` | ✅ | Sign in to Google Drive / revoke the token. |
| `folder [show]` | ✅ | Account, root folder link and the machines that joined. |
| `projects list\|select\|map\|unmap\|mode\|exclude\|include\|dirs` | ✅ | Map local folders to projects; choose what is synced. |
| `doctor` | ✅ basic | Dependencies, Claude config dir, sessions, junk folders, duplicate ids, retention. |
| `repair [--dry-run] [--yes] [--project X]` | ✅ | Fix legacy transcripts (CRLF, re-serialized JSON, WSL/Windows paths, stray backup folders). |
| `run` / `sync [--dry-run]` | 🚧 | One sync cycle. Append-only sessions only; see Status. |
| `status`, `conflicts`, `restore`, `service`, `hooks`, `config`, `machines`, `claude`, `logs`, `uninstall` | ⏳ | Not implemented yet. |

Exit codes: `0` ok · `1` error · `2` usage · `3` sign-in required · `4` offline · `5` another run in
progress · `6` repair needed.

## Configuration

| | |
|---|---|
| `~/.claude-sync/` | claude-sync's own data (Windows: `%USERPROFILE%\.claude-sync`): `config`, token, state, logs, backups. Override with `CLAUDE_SYNC_HOME`. |
| Claude config dir | `CLAUDE_CONFIG_DIR` if set, else `~/.claude` — the same rule Claude Code uses. |
| Language | English or Vietnamese, chosen in `setup`; `CLAUDE_SYNC_LANG=en\|vi` overrides. Logs are always English. |
| Proxy | Stored by `setup` and exported as `HTTPS_PROXY`. |

## Privacy and safety

- **Scope `drive.file`:** the app sees only files it created, never the rest of your Drive.
- **Tokens:** DPAPI-encrypted on Windows (only your Windows account can decrypt them), a mode-600 file
  on Linux. Tokens, codes and secrets are never written to logs.
- **Transcripts are plain text** and may contain secrets that tools printed. Keep the Drive folder private.
- **Never synced:** Claude's running-session registry, credentials, `~/.claude.json`, caches and temporary
  files.
- **Git remotes** are used only to suggest project mappings; only a hash of the normalized
  `host/owner/repo` (credentials stripped first) is ever uploaded.
- **Deletions are not propagated** between machines, Drive objects are only moved to the trash, and
  `repair` backs up every file it changes (`~/.claude-sync/backups/`).

## Status

Done and tested: environment bootstrap, Windows/Linux path handling, local session scan, OAuth and
token storage, Google Drive client (verified against real Drive), root folder and machine identity,
`setup` steps 0–6, project mapping, path translation, legacy repair (used on real data), version chains
and manifests, English/Vietnamese UI, and a first sync engine for append-only sessions between
simulated machines.

Not done yet: first sync without a shared base and transcript rewrites, conflict forks, open-session
handling and `live.json`, subagent/file-history/memory/plan sync, garbage collection, status and logs
commands, background scheduling (systemd / Task Scheduler), Claude Code hooks, the `claude` wrapper,
the rest of `setup`, and end-to-end tests on real machines. Work is tracked as tickets in
[.scratch/claude-sync-v1/](.scratch/claude-sync-v1/spec.md).

## Development

```
bin/claude-sync        entry point and command dispatch
lib/*.sh               modules (core, platform, claude, transform, drive/gdrive/auth, store,
                       version/manifest, projects, repair, root/setup, engine, i18n, ui)
lib/transform.awk      byte-exact path rewriting (POSIX awk: mawk and gawk)
test/*.bats            bats-core tests (vendored in test/vendor/)
test/run-all.sh        local stand-in for CI: Git Bash + WSL (gawk and mawk) + shellcheck, in parallel
docs/SPEC.md           the specification; docs/research/ holds the evidence behind it
```

```bash
test/vendor/bats-core/bin/bats test             # all tests on the current shell
test/vendor/bats-core/bin/bats test/engine.bats # one suite
test/run-all.sh                                 # the whole matrix (Windows host with WSL)
CS_TEST_GDRIVE=1 test/vendor/bats-core/bin/bats test/drive_contract.bats   # against real Drive
```

CI (`.github/workflows/test.yml`) runs Ubuntu with gawk, Ubuntu with mawk (shellcheck too) and Windows
with Git Bash. Engine tests simulate several machines on one shared fake Drive (`test/sim_helper.bash`),
so no network is needed.

Conventions:

- Line endings are never converted (`.gitattributes`: `* -text`); scripts must be LF — a lint test checks.
- Executables need mode `100755` in git (`git update-index --chmod=+x` on Windows).
- Code comments are in English; specs and tickets are in Vietnamese.
- Test names must be ASCII (bats on the Windows runner cannot look up other names).
- Transcripts are never rewritten with `jq`; awk does the byte work, jq only reads.
