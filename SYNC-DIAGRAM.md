# How history is synced between machines

**English** · [Tiếng Việt](SYNC-DIAGRAM.vi.md)

This document shows how claude-sync syncs Claude Code history (sessions) between several machines, using **4 machines** as the example:

| Name used here | Kind | Note |
|---|---|---|
| **Win-Office** | Windows (Git Bash) | the machine at the office |
| **Win-Home** | Windows (Git Bash) | the machine at home |
| **WSL-Office** | WSL Ubuntu | on the same physical PC as Win-Office but **a separate machine** (its own `~/.claude`, its own `machine_id`) |
| **WSL-Home** | WSL Ubuntu | on the same physical PC as Win-Home, also a separate machine |

Source: `lib/engine.sh` (`cs_run_cycle`, `cs_eng_pick`, `cs_eng_install`, `cs_eng_publish`, `cs_fork_resolve`).
The core idea: there is **no central server** and **no machine is the "main" one**. Each machine writes only to its own area on Google Drive and reads the areas of the other machines.

---

## 1. The big picture

```mermaid
flowchart TB
    subgraph WO["Win-Office (Windows)"]
        WO_C["~/.claude/projects/<br/>D--Projects-TransFlow/"]
        WO_E["claude-sync engine<br/>(Task Scheduler, every 5 min)"]
        WO_C <--> WO_E
    end
    subgraph WH["Win-Home (Windows)"]
        WH_C["~/.claude/projects/<br/>C--dev-TransFlow/"]
        WH_E["claude-sync engine<br/>(Task Scheduler, every 5 min)"]
        WH_C <--> WH_E
    end
    subgraph LO["WSL-Office (Ubuntu)"]
        LO_C["~/.claude/projects/<br/>-home-frank-work-TransFlow/"]
        LO_E["claude-sync engine<br/>(systemd timer, every 5 min)"]
        LO_C <--> LO_E
    end
    subgraph LH["WSL-Home (Ubuntu)"]
        LH_C["~/.claude/projects/<br/>-home-frank-src-tf-server/"]
        LH_E["claude-sync engine<br/>(systemd timer, every 5 min)"]
        LH_C <--> LH_E
    end

    subgraph DRV["Google Drive - folder 'Claude Sync'"]
        D_WO["machines/Win-Office/<br/>manifest + segments"]
        D_WH["machines/Win-Home/<br/>manifest + segments"]
        D_LO["machines/WSL-Office/<br/>manifest + segments"]
        D_LH["machines/WSL-Home/<br/>manifest + segments"]
    end

    WO_E -- "write (publish)" --> D_WO
    WH_E -- "write (publish)" --> D_WH
    LO_E -- "write (publish)" --> D_LO
    LH_E -- "write (publish)" --> D_LH

    D_WH -. "read (install)" .-> WO_E
    D_LO -. "read (install)" .-> WO_E
    D_LH -. "read (install)" .-> WO_E
    D_WO -. "read (install)" .-> WH_E
    D_LO -. "read (install)" .-> WH_E
    D_LH -. "read (install)" .-> WH_E
    D_WO -. "read (install)" .-> LO_E
    D_WH -. "read (install)" .-> LO_E
    D_LH -. "read (install)" .-> LO_E
    D_WO -. "read (install)" .-> LH_E
    D_WH -. "read (install)" .-> LH_E
    D_LO -. "read (install)" .-> LH_E
```

Key points:

- **Each machine writes only to `machines/<its own machine_id>/`**, so two machines never overwrite each other on Drive.
- The same project can live at a **different path, even under a different folder name**, on each machine (for example `TransFlow` and `tf-server`). You map it once with `claude-sync projects map`; after that claude-sync translates paths automatically (see §3).
- Each machine runs its own engine on a cycle. Whichever machine is on syncs by itself; the others do not need to be online.

---

## 2. Data layout on Drive

```mermaid
flowchart LR
    ROOT["Claude Sync/<br/>.claude-sync-root (marker)"]
    ROOT --> MA["machines/"]
    MA --> M1["Win-Office/"]
    MA --> M2["Win-Home/"]
    MA --> M3["WSL-Office/"]
    MA --> M4["WSL-Home/"]

    M1 --> MF["manifest.json.gz<br/>session list + segment chain + head"]
    M1 --> LV["live.json<br/>sessions that are open (heartbeat)"]
    M1 --> SEG["t-sid-seq-sha16.jsonl.gz<br/>transcript segment, never modified"]
    M1 --> SF["s/sid/f/...<br/>bundle files, file-history, tasks"]
    M1 --> SA["s/sid/sa/agent-id/...<br/>subagent transcripts"]
    M1 --> MEM["mem/project_id/*.md<br/>memory"]
    M1 --> PL["plans/*.md"]
```

- The **manifest** is one machine's "table of contents": each session has a `head` (its current version), a list of `segs` (transcript pieces, each with `m` = the machine that owns it), `from` (the versions replaced when it was rewritten) and `forked`.
- A **segment** is an **appended** piece of transcript, with paths normalised, gzip-compressed and named after its hash, so it is never modified.
- Other machines only download the manifest (comparing `md5Checksum`, downloading only when it changed) and then fetch exactly the segments they are missing.

---

## 3. Translating paths between machines

A transcript `.jsonl` has fields that hold paths (`cwd`, `relocatedCwd`, `trackingPath`...). When **pushing**, this machine's paths are turned into neutral tokens; when **installing**, the tokens are turned into the receiving machine's paths.

```mermaid
flowchart LR
    A["Win-Office<br/>D:\Projects\TransFlow\apps\server"]
    B["Win-Home<br/>C:\dev\TransFlow\apps\server"]
    C["WSL-Office<br/>/home/frank/work/TransFlow/apps/server"]
    D["WSL-Home<br/>/home/frank/src/tf-server/apps/server"]
    T(("Canonical form<br/>P:3fa1c2d9 / apps/server"))

    A -- "canonicalize" --> T
    B -- "canonicalize" --> T
    C -- "canonicalize" --> T
    D -- "canonicalize" --> T
    T -- "localize" --> A
    T -- "localize" --> B
    T -- "localize" --> C
    T -- "localize" --> D
```

Each machine stores a session in the **slug folder of that machine's own path**, because `/resume` only lists sessions that sit in the slug folder of the directory Claude is started in:

| Machine | Project root | Slug folder in `~/.claude/projects/` |
|---|---|---|
| Win-Office | `D:\Projects\TransFlow` | `D--Projects-TransFlow` |
| Win-Home | `C:\dev\TransFlow` | `C--dev-TransFlow` |
| WSL-Office | `/home/frank/work/TransFlow` | `-home-frank-work-TransFlow` |
| WSL-Home | `/home/frank/src/tf-server` | `-home-frank-src-tf-server` |

---

## 4. One sync cycle on each machine

Each machine runs `claude-sync run` on a timer (5 minutes by default), at logon, on resume from sleep, or when the `SessionEnd` hook wakes it. The order is **pull first, push second**.

```mermaid
flowchart TD
    S(["Start: timer / logon / resume / kick"]) --> L{"Got the<br/>sync.lock?"}
    L -- "no" --> X1(["Exit: another run is active"])
    L -- "yes" --> J["Handle an unfinished journal<br/>(the previous run was interrupted)"]
    J --> N{"Network up?"}
    N -- "no" --> X2(["OFFLINE state<br/>wait with backoff, at most 30 min"])
    N -- "yes" --> T{"Token still usable?"}
    T -- "no" --> X3(["LOGIN_REQUIRED"])
    T -- "yes" --> R["Download the other machines' manifests<br/>(only the ones whose md5 changed)"]
    R --> SC["Scan local sessions<br/>compare with the DB state/sessions.tsv"]
    SC --> D["Decide each session<br/>(see §5)"]
    D --> I["1. INSTALL new versions from other machines"]
    I --> P["2. PUBLISH this machine's new part"]
    P --> B["3. Sync bundles, subagents,<br/>memory, plans"]
    B --> LV["4. Write live.json,<br/>write the manifest, GC"]
    LV --> ST(["Write status.json, done"])
```

Soft deadline of 7 minutes: past it, no new work is started and the unfinished part is picked up on the next cycle.

---

## 5. The decision for each session

For each session the engine compares the local copy (`L`) with the version it already knows (`base`) and the versions other machines have published (the candidates).

```mermaid
flowchart TD
    A["A session S"] --> B{"Is the session open<br/>on this machine?"}
    B -- "yes, another machine has a newer version" --> BH["Do NOT install.<br/>Mark it behind;<br/>a hook warns the user"]
    B -- "yes, only local changed" --> TH["Publish only the appended part,<br/>at most once every 15 minutes"]
    B -- "no" --> C{"Did local change<br/>since base?"}

    C -- "no" --> D{"Does another machine have<br/>a version newer than base?"}
    D -- "no" --> N1(["Do nothing"])
    D -- "yes (base is an ancestor)" --> INS["INSTALL the newest version<br/>(download only the missing segments)"]

    C -- "yes" --> E{"Does another machine have<br/>a newer version?"}
    E -- "no" --> PUB["PUBLISH:<br/>add one new segment"]
    E -- "yes" --> FORK["FORK<br/>(see §7)"]
```

For a session that never had a `base` (a new machine, a lost DB), the engine compares the bytes of the local file with each candidate and picks `equal` (identical), `publish` (local is longer), `install` (local is the older copy) or `conflict` (unrelated, goes to the fork branch).

---

## 6. The normal case: 4 machines take turns on one session

Win-Office chats first, then WSL-Home continues, then Win-Home continues. Each "continue" produces **one new segment**; the new machine **references** the previous machine's segments instead of uploading them again.

```mermaid
sequenceDiagram
    autonumber
    participant WO as Win-Office
    participant DR as Google Drive
    participant WH as Win-Home
    participant LO as WSL-Office
    participant LH as WSL-Home

    Note over WO: Chat in session S, the transcript grows
    WO->>DR: 5-minute cycle: upload segment 0 (t-S-0-...)
    WO->>DR: Update the manifest (head = v1)

    WH->>DR: Cycle: download Win-Office's manifest (md5 changed)
    WH->>DR: Download segment 0, check the sha
    Note over WH: Localize paths, write a temp file, verify,<br/>mv into C--dev-TransFlow, set the original mtime
    LO->>DR: Cycle: download the manifest, then segment 0
    Note over LO: Installed into -home-frank-work-TransFlow
    LH->>DR: Cycle: download the manifest, then segment 0
    Note over LH: Installed into -home-frank-src-tf-server

    Note over LH: /resume shows session S, keep chatting
    LH->>DR: Upload segment 1 (only the new part), manifest head = v2
    Note over LH: The manifest references Win-Office's segment 0,<br/>it is not uploaded again

    WO->>DR: Cycle: sees that v2 descends from v1
    WO->>DR: Download only segment 1
    Note over WO: Append to the local file, then install
    WH->>DR: Same, download only segment 1
    LO->>DR: Same, download only segment 1

    Note over WH: Keep chatting in S
    WH->>DR: Upload segment 2, manifest head = v3
    Note over WO,LH: The other three machines pick up v3 on their next cycle
```

### A version is a chain of segments

```mermaid
flowchart LR
    V0["cum0<br/>sha256 of claude-sync + sid"] --> S0["segment 0<br/>owner: Win-Office"]
    S0 --> V1["cum1 = v1"]
    V1 --> S1["segment 1<br/>owner: WSL-Home"]
    S1 --> V2["cum2 = v2"]
    V2 --> S2["segment 2<br/>owner: Win-Home"]
    S2 --> V3["cum3 = v3 = head"]
```

`version_id` is the cumulative hash of the segments up to that point. So the engine only has to check "is a in b's chain" to tell whether a version is an ancestor or a different branch, without comparing whole files.

---

## 7. Conflict: two machines continue one session while offline

Example: Win-Office and WSL-Home are both at version `v2`, both lose the network, and both keep chatting in session S.

```mermaid
sequenceDiagram
    autonumber
    participant WO as Win-Office
    participant DR as Google Drive
    participant LH as WSL-Home

    Note over WO,LH: Both are at v2, offline
    Note over WO: Chats at 10:00 (the first chat line after the fork point)
    Note over LH: Chats at 10:05

    WO->>DR: Back online: publishes v3a (a child of v2)
    LH->>DR: Back online: sees v3a, local also changed, neither is the other's ancestor
    Note over LH: Picks the winning branch by a deterministic rule:<br/>the branch whose first chat line after the fork point has the earlier timestamp wins.<br/>Win-Office 10:00 wins, WSL-Home loses

    Note over LH: Only the machine that owns the losing branch creates the split session:<br/>fork_sid is computed from sha256 of the sid and the fork line's uuid,<br/>so running again never makes a duplicate
    LH->>LH: Creates a new session "[conflict WSL-Home] old title"<br/>holding the shared part and the losing branch's part
    LH->>LH: Installs the winning branch (v3a) into the original session S
    LH->>DR: Publishes the split session (fork) and records forked in the manifest

    WO->>DR: Next cycle: receives the split session as a new session
    Note over WO,LH: Result: no line is lost.<br/>S keeps its original ID with the winning branch, the losing branch is a separate session, both can be opened
```

Detailed rules:

- The fork point is the first line where the two branches differ.
- If one branch's part after the fork point is **only metadata** (no chat lines), that branch loses quietly and **no** split session is made; a copy is kept in `backups/`. Merely **reopening** a session (the `SessionStart:resume` hook, the notice about an unfinished background task, `cost-state`...) also counts as metadata, so opening a session on a second machine does not create a `[conflict]`.
- The title of a split session is taken in this order: the name you gave with `/rename`, then the name Claude chose itself (`aiTitle`), then "(untitled)".
- On equal timestamps the smaller `machine_id` wins. Every machine computes the same result, so no machine has to coordinate.

---

## 8. A session that is open on the receiving machine

The engine **never replaces a transcript file under a running Claude** (this has been reproduced to lose lines).

```mermaid
sequenceDiagram
    autonumber
    participant WO as Win-Office
    participant DR as Google Drive
    participant WH as Win-Home
    participant HK as Claude's hook on Win-Home

    WO->>DR: Publishes a new version of session S
    Note over WH: Session S is open on Win-Home<br/>(the sessions/pid.json registry entry is alive)
    WH->>DR: Cycle: sees a new version
    WH->>WH: Does NOT install. Sets status = behind,<br/>updates status.json
    HK->>WH: SessionStart / UserPromptSubmit read status.json
    HK-->>WH: Warns or blocks: "This tab is stale, S has N more lines on Win-Office"
    Note over WH: The user closes the session
    WH->>DR: Next cycle: the session is no longer open, so INSTALL the new version
    WH->>WH: Clears the behind flag
```

In addition, each machine's `live.json` says which sessions are open on that machine. Other machines read it to show "this session is open on Win-Office". Freshness is measured by Drive's server time, not by the machine clock.

---

## 9. The lifecycle of a session's state on one machine

```mermaid
stateDiagram-v2
    [*] --> new: A local or remote session is found
    new --> unmapped: The folder is not mapped to any project yet
    unmapped --> new: The user maps the project
    new --> synced: First publish, or install finished
    synced --> synced: Appended to, every 5-minute cycle
    synced --> behind: Another machine has a newer copy but the session is open
    behind --> synced: Session closed, new copy installed
    synced --> conflict: Two branches forked and cannot be handled yet
    conflict --> synced: Fork done, the winning branch is installed
    synced --> needs_repair: Same session id in a different folder
    needs_repair --> synced: claude-sync repair
    synced --> local_absent_retention: File vanished because Claude cleaned it up by retention
    synced --> local_absent_user: File vanished because the user deleted it
    local_absent_retention --> synced: A newer version arrives or the restore command
    local_absent_user --> synced: A newer version arrives or the restore command
```

---

## 10. Special situations

### 10.1 A machine comes back after being off for a long time (catch-up sync)

```mermaid
flowchart TD
    A(["Win-Home is turned on after a few days"]) --> B["Task Scheduler runs at logon<br/>trigger = logon"]
    B --> C["Wait for the network with a 5s to 30s backoff"]
    C --> D["Download the manifests of the other 3 machines"]
    D --> E["Install all new versions<br/>(pull first, push second)"]
    E --> F{"Did you open Claude before<br/>the catch-up finished?"}
    F -- "no" --> G(["Every session is already in /resume"])
    F -- "yes" --> H["The SessionStart hook warns<br/>or the claude-sync claude wrapper pulls that project first"]
```

### 10.2 Deletion and retention (not propagated)

```mermaid
flowchart LR
    A["A session is deleted on Win-Office<br/>or Claude cleans it up by retention"] --> B["The other machines' manifests still hold the session"]
    B --> C["The other machines are NOT deleted along with it"]
    A --> D["On Win-Office: state<br/>local_absent_user or local_absent_retention"]
    D --> E["It is not downloaded again by itself,<br/>unless a newer version arrives<br/>or you run claude-sync restore sid"]
```

Conversely, a session whose `mtime` is older than the receiving machine's `cleanupPeriodDays` threshold is **not installed** (so Claude does not clean it up right away); it stays on Drive and can be installed with `restore`. Setup suggests `cleanupPeriodDays = 3650` on every machine.

### 10.3 A new folder, or a project that is not mapped on one machine

```mermaid
flowchart TD
    A["Win-Office creates a new project 'Foo'"] --> B["Publishes sessions with the project_id in the manifest"]
    B --> C["WSL-Home reads the manifest:<br/>this project_id is not in projects.tsv yet"]
    C --> D["Records it in pending_map.tsv<br/>and suggests candidate folders"]
    D --> E["status, the SessionStart hook and the wrapper<br/>remind the user"]
    E --> F["claude-sync projects map<br/>(the user confirms the folder)"]
    F --> G["The next cycle installs the sessions that were waiting"]
```

Candidate suggestions are ordered by confidence: an equivalent path (`D:\a\b` and `/mnt/d/a/b`), a local folder where Claude has already run, the same git remote (compared by hash, the URL is not uploaded), and only then a similar folder name. It is never mapped automatically, except in `all` mode when it meets a completely new local folder.

---

## 11. Summary of the invariants

| Invariant | Mechanism |
|---|---|
| No transcript line is lost | Segments are immutable; a conflict forks, it never overwrites |
| No two machines write to the same place | Each machine writes only to its own `machines/<id>/` |
| No overwriting an open session | Check the registry before installing, and compare-and-swap right before `mv` |
| Safe file install | Write a temp file, check the line count and that there is no CR, then `mv -f` |
| Each session ID is exactly one file per machine | Duplicate check across all `projects/*/`; a duplicate becomes `needs_repair` |
| Running again makes no duplicate | Drive file IDs are allocated up front and journaled; `fork_sid` is deterministic |
| Resume works correctly on another machine | Path translation + the right slug folder + the original `mtime` kept |

Limits of v1: two machines chatting at the same time in the same session in real time is not supported (if it happens the result is a fork as in §7), there is no end-to-end encryption, and settings/skills/CLAUDE.md are not synced.
