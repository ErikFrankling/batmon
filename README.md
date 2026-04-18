# batmon

`batmon` is a read-only power observability tool for Linux laptops. It is built around a persistent collector and a graph-first terminal UI so you can answer the useful question quickly: where did the battery go today?

The flake is convenience for Nix users. The canonical build entrypoint is still `zig build`.

The project currently ships two binaries:

- `batmond`: background collector for battery history, sleep and gap detection, live process activity sampling, and power-state snapshots.
- `batmon`: terminal UI with a central battery graph, a discharge-rate graph, event lanes, app and process impact views, live estimated power, and a read-only state pane.

## Current Implementation

- Persistent SQLite history with WAL.
- Battery and charger sampling from `/sys/class/power_supply`.
- Sleep detection from monotonic vs boottime gaps.
- Collector gap detection on startup.
- Process sampling from `/proc`, with app bucketing heuristics that avoid collapsing everything into `systemd`.
- Estimated app and process power attribution from CPU and I/O activity.
- TUI with:
  - central battery graph
  - charging, sleep, gap, and anomaly lanes
  - discharge-rate graph
  - impact, live, state, and events panes

## Limitations

- Per-process and per-app energy numbers are estimates, not direct hardware measurements.
- The current implementation uses portable Linux sysfs and `/proc` interfaces first; richer D-Bus and vendor telemetry integrations are not implemented yet.
- Hardware support varies. Some laptops expose energy and power data directly, others only expose enough to derive it.
- The TUI renderer is custom ANSI today. The architecture keeps the graph-first contract needed for a future libvaxis-backed renderer.

## Development

On NixOS, enter the flake dev shell and use plain `zig build`. The shell provides pinned nixpkgs Zig `0.16.0`, matching `zls_0_16`, and SQLite headers/libs; all build logic stays in `build.zig`.

Outside Nix, install Zig `0.16.0` plus SQLite development headers/libs and use the same `zig build` commands.

```bash
nix develop
zig build
zig build test
```

`zig build test` now exercises the TUI frame renderer against real SQLite fixture databases and daemon-side battery/event attribution logic.

Run the collector once:

```bash
zig build run-batmond -- sample-once
```

Run the collector continuously:

```bash
zig build run-batmond -- run
```

Run the TUI:

```bash
zig build run-batmon
```

Override the database path:

```bash
zig build run-batmond -- run --database-path /tmp/batmon.db
zig build run-batmon -- --database-path /tmp/batmon.db
```

The flake also exposes a package for Nix users:

```bash
nix build .#batmon
```

## Service Setup

- System service template: [packaging/batmond.service](/home/erikf/projects/personal/batmon/packaging/batmond.service)
- User service template: [packaging/batmond-user.service](/home/erikf/projects/personal/batmon/packaging/batmond-user.service)
- NixOS module: `nixosModules.default` in `flake.nix`

Recommended deployment is a privileged system `batmond` service so sensor access and full-day history are available even when the TUI is closed.
