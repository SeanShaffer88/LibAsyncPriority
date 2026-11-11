# Changelog

All notable changes to LibAsyncPriority are recorded here.
Format follows Keep a Changelog; versions use semantic versioning.

## [1.0.0] - 2026-11-10

### Added

- Initial release of the `LibAsyncPriority-1.0` library for WoW Classic
  Forever (Interface 11507).
- `Schedule(priority, task, options)` with `"high"` / `"normal"` / `"low"`
  (or numeric 1–3) priorities, step-function tasks, and coroutine tasks,
  returning a cancellable handle (`Cancel`, `IsCancelled`, `IsComplete`,
  `IsFailed`).
- Single `OnUpdate` driver with a configurable per-frame budget
  (5 ms default) and an adaptive effective budget after overruns.
- `Chain(tasks)` for sequential tasks under one handle.
- `Yield(seconds)` for coroutine tasks.
- `Flush(priority)` to cancel queued/waiting work by priority or in full.
- `GetStats()` with queue counts, completion totals, and scheduler frame
  timings; `SetBudget` / `GetBudget`; `SetDebug`.
- Debug mode: `/libasyncpriority test` self-test plus `stats` and
  `flush` slash subcommands (`/lap` alias).
- Standalone addon packaging (`.toc`, bundled LibStub 1.0) and
  `embeds.xml` for embedding in other addons.
- Out-of-game logic checks in `tests/test_libasyncpriority.lua`.
