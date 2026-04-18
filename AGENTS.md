# AGENTS

## Product Intent

`batmon` is a Linux laptop power observability product, not a tuning tool. The UI should help a user understand:

- how battery percentage changed over the day
- when the system was charging
- when the system was suspended or the collector was offline
- how discharge speed changed with activity
- which apps and processes likely consumed the most battery
- which current system power settings and hardware states are likely affecting power draw

No part of the product should mutate system power settings.

## Current Host Topology

- The current interactive development host is a desktop PC, not a laptop.
- Do not expect local `/sys/class/power_supply` to contain a real battery on the current host.
- Real battery-backed validation is available over SSH at `erikf@192.168.50.126`.
- The remote laptop's login shell is `fish`, so scripted SSH commands should use `bash -lc '...'`.
- Verified remote battery characteristics so far:
  - `BAT1` exists and is a charge-based battery exposed through the standard Linux `power_supply` class
  - `BAT1` reports `status`, `capacity`, `charge_now`, `charge_full`, `charge_full_design`, `current_now`, `voltage_now`, and `cycle_count`
  - `BAT1` does not expose `energy_now`, `energy_full`, `energy_full_design`, or `power_now`
  - `ACAD` exists as the mains supply
  - multiple `ucsi-source-psy-*` USB power-supply objects also exist, so collectors must filter by `type`, not by name heuristics alone
  - the machine can report `status=Not charging` while `ACAD/online=1`; treat AC-online and charging as distinct states
  - `current_now` may be `0` while on AC and not charging, so instantaneous battery-derived watts are not guaranteed outside charge/discharge intervals
  - `org.freedesktop.login1` is available on the system bus
  - `nix` is installed on the laptop
  - `upower` and `powerprofilesctl` were not installed in the current remote environment during validation
  - current power-state files expose:
    - `platform_profile=balanced`
    - `scaling_driver=amd-pstate-epp`
    - `scaling_governor=powersave`
    - `energy_performance_preference=balance_performance`
    - no populated `powercap` tree was observed

## Runtime Architecture

- `batmond` is the background collector and the only database writer.
- `batmon` is the TUI and opens the database read-only.
- SQLite is the only persistent store in v1.
- Portable Linux interfaces are the baseline:
  - `/sys/class/power_supply`
  - `/proc`
  - CPU/sysfs configuration files
  - backlight and rfkill sysfs
  - runtime PM summaries from sysfs
- Suspend is currently inferred from `CLOCK_BOOTTIME` vs `CLOCK_MONOTONIC`.

## Source Priority And Portability Findings

- Battery and line-power collection should remain rooted in the Linux `power_supply` class. This is the portable baseline used across ordinary laptops, including the remote Framework AMD laptop.
- Enumerate power supplies by their exported `type` and capabilities, not just by names like `BAT0`/`BAT1`/`AC*`.
  - Battery objects can be symlinked sysfs entries.
  - USB-C and charger-related `power_supply` entries may also appear and should not be misclassified as laptop batteries.
- Charge-based batteries are standard and must be handled as first-class hardware, not as an oddity.
  - When only `charge_*` and `voltage_now` are available, derive energy in Wh from charge and voltage.
  - When only `current_now` and `voltage_now` are available, derive instantaneous watts from current and voltage.
- Do not treat `ac_online` as equivalent to `charging`.
  - A battery can be `not_charging` or `full` while external power is online.
  - Charging overlays in the UI must reflect actual battery charge state, not just cable presence.
- Prefer `org.freedesktop.login1.Manager.PrepareForSleep` for suspend/resume eventing once D-Bus support lands.
  - The current boottime-vs-monotonic inference is a fallback, not the ideal long-term source.
- Treat UPower as an optional abstraction and enrichment layer.
  - It can provide normalized battery properties plus `GetHistory()` and `GetStatistics()`.
  - It must not replace direct `power_supply` sampling as the product’s primary source of truth.
- Framework-specific EC telemetry is real and richer than generic sysfs, but it is vendor-specific.
  - `framework_tool --power` exposes charger voltage/current, battery SoC, LFCC, design capacity, present rate, and cycle count through Framework’s EC stack.
  - Keep this as an optional future enrichment path, not a baseline dependency for batmon.

## Data Model

The database currently stores:

- `battery_samples`
- `events`
- `bucket_live_samples`
- `process_live_samples`
- `bucket_impact_samples`
- `process_impact_samples`
- `state_latest`

Important semantic rules:

- Battery share is only attributed during discharge intervals.
- Sleep and collector gaps are explicit events and must not be interpolated away.
- App/process energy is always estimated.
- `unattributed` is a first-class bucket and must remain visible.

## Bucketing Rules

- Favor a meaningful cgroup, service, or app scope when one exists.
- Otherwise prefer executable identity over raw parent PID trees.
- Avoid collapsing attribution into generic wrappers:
  - `systemd`
  - shells
  - `flatpak`
  - `bwrap`
  - `python`
  - `node`
  - `java`
  - Electron helpers

The default user-facing view is `Apps`. Raw process-level views are for debugging and detailed inspection.

## UI Contract

The battery graph is the center of the product. Do not regress into a generic dashboard layout.

Required elements:

- top header with current battery state and sensor confidence
- main battery graph over the selected range
- aligned event lanes for charging, sleep, collector gaps, and anomalies
- aligned discharge-rate graph below the main graph
- lower-pane tabs:
  - `Impact`
  - `Live`
  - `State`
  - `Events`

The TUI is keyboard-first and read-only.

## Toolchain Policy

- Primary compiler target is Zig `0.16.0` from nixpkgs, pinned via `flake.lock`.
- Dependencies are managed with `flake.nix` and `build.zig.zon`.
- `zig build` is the canonical build entrypoint. The flake is dependency and packaging glue, not a replacement build system.
- SQLite is the only intentional C-facing dependency. Environment access, clocks, terminal control, terminal sizing, and local timezone formatting should use Zig stdlib instead of ad hoc libc imports.
- The current flake deliberately uses nixpkgs `master` so the lock file can pin a commit that contains `zig_0_16` and `zls_0_16`.
- The previous Zig `master` plus custom ZLS path is intentionally kept commented in `flake.nix` for reference, but it is not the active toolchain path.
- Update the pinned compiler intentionally with `nix flake update`.
- The flake dev shell should stay minimal: provide Zig plus required native libraries and let `zig build` infer the native target on its own.

## Testing Strategy

- Use the desktop host for fast build and schema validation:
  - `nix develop`
  - `zig build`
  - `zig build test`
  - `./zig-out/bin/batmond sample-once --database-path /tmp/batmon-local.db`
- The built-in Zig test suite should cover:
  - TUI frame rendering against empty and seeded SQLite databases
  - collector event emission such as AC changes, sleep detection, and anomaly insertion
  - discharge attribution fallbacks such as `unattributed` impact rows and power-based energy estimation
- On the desktop host, a healthy smoke test currently means:
  - the collector creates the SQLite database successfully
  - `battery_samples` stays at `0`
  - `state_latest` is populated
  - process/live tables may remain empty on a single one-shot sample
- Use the remote laptop for all battery-specific validation:
  - sysfs battery parsing
  - charge/discharge transitions
  - AC-online with `status=Not charging`
  - suspend/resume detection
  - anomaly detection against real discharge behavior
  - TUI graph correctness with actual battery history
- Preferred remote workflow for future sessions:
  - sync the working tree to `/tmp/batmon-src` over SSH using a tar pipe
  - run `cd /tmp/batmon-src && nix develop -c bash -lc 'zig build -Doptimize=ReleaseSafe'`
  - run `./zig-out/bin/batmond sample-once --database-path /tmp/batmon-remote.db`
  - inspect the DB with `sqlite3` inside the dev shell
- Remote validation checklist:
  - `battery_samples` should become nonzero after `sample-once`
  - `state_latest` should populate
  - battery status should reflect charging vs discharging correctly
  - battery status should preserve `not_charging` instead of collapsing it into `charging` or `unknown`
  - AC presence should not be rendered as charging activity
  - derived power/energy paths should work on charge-based hardware that lacks `energy_*` or `power_now`
  - `power_supply` enumeration should ignore non-battery USB-C source entries
  - a longer `run` session should be used to verify live process attribution and event generation
- For suspend/resume testing on the remote laptop:
  - run `batmond run`
  - suspend the machine manually
  - resume it after a short gap
  - confirm that a sleep event is recorded rather than interpolating across the gap
- For TUI smoke tests on the remote laptop:
  - use a real terminal with color support, typically `TERM=xterm-256color`
  - point `batmon` at the same remote database path used by the collector
  - verify the main battery graph, event lanes, and lower panes on both wide and narrow terminal sizes

## Current Implementation Gaps

The current repo implements the core collector, storage layer, and TUI, but several plan items remain for later iterations:

- D-Bus integration for `logind`, `UPower`, and `power-profiles-daemon`
- richer confidence scoring and provenance display
- higher-fidelity anomaly detection
- optional GPU and vendor telemetry
- libvaxis-backed renderer
- broader automated test coverage

## Working Guidelines

- Prefer portable Linux interfaces first; layer enrichments on top.
- Keep the UI honest about estimate quality and unavailable sensors.
- Preserve the read-only product boundary.
- If you change storage schema, update both the collector and TUI queries in the same change.
