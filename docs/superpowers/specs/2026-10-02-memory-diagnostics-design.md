# Memory Diagnostics Design

## Goal

Give the user one picture of what slows the Mac down: next to disk cleanup, show which applications actually hold RAM and push the system into compression and swap, and let the user quit those applications safely.

The motivating case: 16 GB of RAM, 9.3 GB of swap, 6.8 GB compressed. Activity Monitor lists hundreds of processes (`Docker`, `Docker Desktop Helper`, `docker-agent`, `com.apple.Virtualization.VirtualMachine`, …), so the real source is hard to see. SpotlessMac must collapse them into the application responsible for them.

## Scope

In scope:

- live system memory summary: used, app memory, wired, compressed, cached files, swap used/total, memory pressure level;
- per-application grouping of processes with memory footprint and an estimate of memory pushed out of RAM;
- a short session history (swap, pressure, compressed) while the section is open;
- quitting user applications as a whole, with confirmation, and force-quit as a confirmed fallback;
- a memory card on the Care dashboard.

Out of scope (possible later work on the same data): app-specific recommendations (e.g. "lower Docker Desktop's memory limit"), background monitoring with notifications, a menu-bar agent, `purge` or any privileged action, changes to the health score.

## Sampling model

- Sampling runs only while the Memory section is visible: every 2 seconds, started from the view's `.task` and cancelled when the view disappears.
- History is an in-memory ring buffer of 150 samples (~5 minutes). Nothing is persisted.
- The Care dashboard takes one sample when it appears.

## Metrics

Per process (via `proc_pid_rusage`, `RUSAGE_INFO_V4` or later):

- **Memory** = `ri_phys_footprint`, the same number as Activity Monitor's "Memory" column.
- **Pushed out** = `max(0, ri_phys_footprint − ri_resident_size)`, an estimate of the part held compressed or in swap. macOS has no public per-process swap figure. The UI labels this as an estimate.
- Processes whose rusage cannot be read (typically other users and root without privileges) keep pid, name and path when available and are flagged `isPartial`. They are never dropped from the list.

System-wide (exact values):

- `host_statistics64(HOST_VM_INFO64)`: free, active, inactive, wired, compressor pages (`compressor_page_count`), purgeable, external (file-backed) pages. App memory = internal − purgeable; cached files = external + purgeable; used = app memory + wired + compressed. This matches Activity Monitor's breakdown.
- `sysctl vm.swapusage` (`struct xsw_usage`): swap total/used.
- `sysctl kern.memorystatus_vm_pressure_level`: 1 = normal, 2 = warning, 4 = critical.

The Care dashboard switches from `MemoryStatsService` to `MemoryMonitor`, and `MemoryStatsService` is deleted, so both screens show the same numbers.

## Attribution (process → source application)

`ProcessGrouper` is a pure function over `[ProcessMemorySample]` plus an optional responsibility lookup. For each process, it tries these in order:

Inputs: the process samples plus a snapshot of running applications (`NSWorkspace.runningApplications`: pid, bundle path, bundle id, whether `activationPolicy == .regular`). Every bundle path is normalized to its **outermost** `*.app` component, because Docker runs `Docker.app/Contents/MacOS/Docker Desktop.app` (bundle id `com.electron.dockerdesktop`) next to `Docker.app/Contents/MacOS/com.docker.backend`, and both must land in one Docker group.

For each process, attribution tries these in order:

1. **Responsible process.** `responsibility_get_pid_responsible_for_pid` is resolved once with `dlsym(RTLD_DEFAULT, …)`. If the symbol is missing, this step is skipped. The responsible pid is looked up first among running applications, then by its executable path. This puts the Docker VM under Docker and Chrome/Safari helpers under their browser. Chrome's main process runs from a code-sign clone (`/private/var/folders/…/Google Chrome.app.bundle`), so path matching alone would miss it, while the running-application lookup yields `/Applications/Google Chrome.app`.
2. **Own bundle.** The process's own pid among running applications, then the outermost `*.app` in its path.
3. **Parent chain.** Walk `ppid` (at most 32 steps, cycle-safe, stop at pid ≤ 1), applying step 2 to each ancestor.
4. **Fallback.** `.system` if the uid is not the current user's or the path is under `/System`, `/usr`, `/bin`, `/sbin`, `/Library/Apple`. Otherwise `.other`, grouped by executable name. The name comes from `argv[0]` (`KERN_PROCARGS2`) when it is readable, so Claude Code's versioned binaries (`~/.local/share/claude/versions/2.1.285`) group as `claude`. Otherwise it falls back to `proc_name`.

A resolved bundle becomes a `.userApp` group when it belongs to a running regular application (any path: Terminal, Activity Monitor and Safari live under `/System`), or when it is outside the system prefixes. Otherwise it goes into the single `.system` group. Grouping key: the outermost bundle path. Display name: the bundle file name without `.app`. Group totals are the sums of their processes' memory and pushed-out values.

## Components

New folder `SpotlessMac/Memory/`:

| Type | Kind | Responsibility |
|------|------|----------------|
| `SystemMemorySnapshot` | struct, Sendable | System-wide metrics + `MemoryPressure` enum (`normal`, `warning`, `critical`, `unknown`) |
| `ProcessMemorySample` | struct, Sendable | pid, ppid, uid, name, path, footprint, resident, `pushedOut`, `isPartial` |
| `AppMemoryGroup` | struct, Sendable, Identifiable | id (bundle id/path/name), displayName, bundleURL?, kind (`userApp`/`system`/`other`), processes, totals |
| `MemorySample` | struct, Sendable | timestamp + `SystemMemorySnapshot` + `[AppMemoryGroup]` |
| `SystemMemoryReader` | enum, static funcs | Reads system metrics; parses `xsw_usage`; never throws: missing values become 0 / `.unknown` |
| `ProcessMemoryReader` | enum, static funcs | Lists pids and reads per-process data |
| `ResponsibilityResolver` | struct, Sendable | Wraps the optional `dlsym` symbol; `responsiblePID(for:) -> pid_t?` |
| `ProcessGrouper` | enum, static pure func | Attribution described above |
| `ProcessSafetyRules` | enum | `canQuit(_ group:) -> QuitDecision` (`allowed` or `denied(reason)`) |
| `MemoryMonitor` | actor | `sample() async -> MemorySample` combining the readers and the grouper |
| `MemoryViewModel` | `@Observable @MainActor` | start/stop loop, latest sample, history, expanded groups, quit flow state; takes an injected `sample` closure and an injected app terminator for tests |

UI (`SpotlessMac/App/`):

- `MemoryView.swift`: the section.
- `MemoryQuitSheet.swift`: confirmation sheet.
- `AppTab.memory` (icon `memorychip`, label «Память»), placed after `.diskUsage` in the rail.
- A memory card in `CareDashboardView`'s status column.

## Memory section UI

1. **Summary.** Pressure indicator (green/yellow/red) with tiles: used, compressed, swap, cached files.
2. **History.** A small chart (Swift Charts) of swap used and compressed over the session, with the background tinted by pressure level.
3. **Verdict line.** One rule-generated sentence. Examples: «Своп 9,3 ГБ — система активно вытесняет память. Больше всего держат: Docker (5,1 ГБ), Chrome (2,4 ГБ).» / «Памяти достаточно.» No app-specific advice.
4. **Sources list.** `.userApp` groups sorted by memory descending. Each row shows icon, name, a bar for its share of physical RAM, Memory, Pushed out, and the process count. A row expands to its processes (name, PID, memory, partial marker). `.system` and `.other` appear as two collapsed groups at the bottom with no actions. Partial entries show the hint «нужны права администратора для точных данных».

The list keeps stable identity across samples (group id), so rows do not jump while a row is expanded. Re-sorting happens at most every 10 seconds, or when the user asks for it.

## Quitting applications

- Only `.userApp` groups with running applications inside their bundle (matched by outermost bundle path) get a «Завершить» button. The action targets the application as a whole, never an individual helper pid.
- The confirmation sheet lists the application and its process count, and shows the memory expected to be freed (current group total, marked approximate).
- Confirm → `NSRunningApplication.terminate()` for every running application inside the bundle. The app may ask to save documents.
- If the app is still running after 5 seconds, the sheet offers «Завершить принудительно». A second confirmation warns about unsaved data, then calls `forceTerminate()`.
- After quitting, the next samples show the real change. Nothing is claimed beyond them.
- No `kill(2)` anywhere in the subsystem.
- No license gate: quitting is not cleaning.

### ProcessSafetyRules (checked inside the quit path, not only in the UI)

Quitting is denied if any of these apply:

- the group kind is not `.userApp` (`.other` gets its own reason: command-line processes are ended where they were started);
- any process in the group has a uid other than `getuid()`;
- it is SpotlessMac itself (own bundle path or own pid);
- none of the group's running applications is quittable: a `.regular` app, or an `.accessory` (menu-bar) app whose bundle is outside the system prefixes;
- the name or bundle id is on the protected list: `kernel_task`, `launchd`, `WindowServer`, `loginwindow`, `Finder` (`com.apple.finder`), `Dock` (`com.apple.dock`), `SystemUIServer`, `ControlCenter`;
- no running application is found inside the group's bundle.

The sheet shows the denial reason instead of a button.

## Care dashboard

A «Память» card in the status column shows pressure, swap used, the top 3 sources with their memory, and a link to `.memory`. It is filled from a single `MemoryMonitor.sample()` on appear. The health score is unchanged.

## Error handling

- Reader failures never throw to the UI. Missing system metrics show «—», unreadable processes are marked partial.
- A `responsibility` symbol that is absent is silent and expected. Attribution falls back to bundle path and parent chain.
- If a sample takes longer than the interval, the next tick is skipped (no overlapping samples).
- If termination fails or the app is already gone, the sheet shows the result. The next sample reflects reality.

## Testing

Unit tests in `SpotlessMacTests/`:

- `ProcessGrouperTests`:
  - Docker helpers + `docker-agent` + the VM process (via a fake responsibility map) form one Docker group;
  - WebContent → Safari via responsibility;
  - without responsibility, helpers resolve through bundle path and the ppid chain;
  - root processes and `/usr/libexec` → `.system`;
  - unknown CLI process → `.other`;
  - ppid cycle terminates;
  - partial processes are kept.
- `ProcessSafetyRulesTests`: each denial rule, plus the allowed case.
- `SystemMemoryReaderTests`: `xsw_usage` conversion and pressure-level mapping (pure helpers). A smoke test that the live read returns total = physical memory.
- `MemoryViewModelTests` (fake `sample` closure and fake terminator):
  - start produces samples, and stop cancels them;
  - history is capped at 150;
  - restart does not leave two loops;
  - quit flow covers terminate → still running → force offer, and denial.

Manual check: compare the section against Activity Monitor on the same machine (Memory column, swap, compressed) while Docker Desktop is running.
