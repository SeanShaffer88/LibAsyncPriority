# LibAsyncPriority — Features

Version 1.0.0 · WoW Classic Forever · Interface 16001

## Scheduling

- Priority queues: **high**, **normal**, **low** (or numeric 1 / 2 / 3),
  always drained highest first, first-in-first-out inside a priority.
- Two task styles: step functions (return `true` to continue next frame)
  and coroutine tasks (thread, or function with `coroutine = true`).
- One step per task per frame, so no task can loop inside a single frame.
- Per-frame time budget, 5 ms by default, configurable with `SetBudget`;
  the effective budget adapts down after an overrun and recovers after.
- A single `OnUpdate` driver on one anonymous frame, installed only
  while work exists — zero per-frame cost when idle.

## Control

- Every task returns a handle: `Cancel()`, `IsCancelled()`,
  `IsComplete()`, `IsFailed()`, plus `state`, `steps`, `priority`, `name`.
- Cancellation works queued, waiting, or mid-step (takes effect when the
  current step returns), and fires `onCancel` exactly once.
- `Chain(tasks)` runs tasks strictly in sequence under one handle;
  cancelling the chain stops the current step and all later steps.
- `Yield(seconds)` pauses a coroutine task without holding frame budget.
- `Flush(priority)` cancels all queued/waiting work of one priority, or
  everything when called with no argument.
- Callbacks per task: `onComplete`, `onCancel`, `onError`. A step that
  errors ends the task as failed and is reported, never silently lost.

## Observability

- `GetStats()`: queued / waiting / running / active counts, totals for
  scheduled, completed, cancelled and failed tasks, and last / average /
  maximum scheduler frame time against the budget.
- Debug mode: `SetDebug(true)` prints each step; `/libasyncpriority test`
  schedules tasks at all three priorities, cancels one, and prints the
  execution order and timing.
- Slash commands: `/libasyncpriority` (or `/lap`) with `test`, `stats`,
  and `flush [priority]`.

## Integration

- LibStub library `LibAsyncPriority-1.0`, minor-version safe when several
  addons embed different copies.
- Also runs as a standalone addon (bundled LibStub 1.0 steps aside when a
  newer LibStub is already loaded).
- `embeds.xml` include for one-line embedding.
- Full LuaDoc comments on every public function and table.
- No dependencies, no SavedVariables, no taint: no hooks, no secure
  functions, no protected templates.
