# LibAsyncPriority

## TL;DR

**LibAsyncPriority-1.0** is a small library for **WoW Classic Forever**
(Interface **11507**) that runs heavy addon work a little at a time, spread
across frames, so the game stays responsive. Tasks run by priority —
**high** first, then **normal**, then **low** — under a per-frame time
budget (5 ms by default), and any task can be cancelled. Use it embedded in
your addon through LibStub, or install it standalone. Version **1.0.0**,
MIT license, no dependencies.

**Docs:** [Features](FEATURES.md) · [Description](DESCRIPTION.md) · [Changelog](CHANGELOG.md)

**Requirements:** a WoW Classic Forever client (Interface **11507**).
Nothing else — no other addons, no libraries to install first; LibStub is
bundled for standalone use and steps aside when a newer LibStub is
already loaded.

```lua
local LAP = LibStub("LibAsyncPriority-1.0")

local handle = LAP:Schedule("low", function()
    -- do one small chunk of work
    return true  -- true = call me again next frame; nil/false = done
end, { name = "background-scan" })

handle:Cancel()  -- stop it at any time
```

## Why

Scanning every bag slot, rebuilding a database, or sorting a big list in
one go freezes the game for that frame. Splitting the work into small
steps fixes the freeze, but then every addon hand-rolls the same queue,
the same OnUpdate driver, and the same "stop when the user closes the
window" logic — and a slow background job can still delay the one thing
the user just clicked. LibAsyncPriority is that shared machinery, once,
with priorities and cancellation built in.

## Installation

### Standalone (to try it, or to share one copy between addons)

1. Download this repository (or the release zip) and unzip it.
2. Rename / keep the folder as **`LibAsyncPriority-1.0`** — the folder name
   must match the `.toc` file name or the game will not load it.
3. Move the folder into `World of Warcraft\_classic_\Interface\AddOns\`
   so the path reads `AddOns\LibAsyncPriority-1.0\LibAsyncPriority-1.0.toc`.
4. Start the game (or `/reload` is not enough for a new addon — restart,
   or log out to the character screen and enable it in the AddOns list).
5. Tick **LibAsyncPriority-1.0** in the AddOns list. Other addons that use
   the library will now find it through LibStub.

### Embedded in your addon (the usual way for libraries)

1. Copy `LibStub.lua`, `LibAsyncPriority-1.0.lua`, and `embeds.xml` into
   your addon, for example under `YourAddon\libs\LibAsyncPriority-1.0\`.
   (If your addon already loads LibStub, keep yours — the bundled copy
   steps aside when LibStub is already present and newer.)
2. Include the folder's `embeds.xml` from your addon's own `embeds.xml`,
   or list the two Lua files in your `.toc` before your own files:

   ```xml
   <Include file="libs\LibAsyncPriority-1.0\embeds.xml"/>
   ```

3. In your code: `local LAP = LibStub("LibAsyncPriority-1.0")`.

Embedding is version-safe: when two addons embed different copies, LibStub
keeps the newest minor version and older copies quietly do not load.

## API

All public functions carry LuaDoc comments in
[`LibAsyncPriority-1.0.lua`](LibAsyncPriority-1.0.lua).

### `LAP:Schedule(priority, task, options)` → handle

Schedules a task and returns its handle.

| Argument | Meaning |
|---|---|
| `priority` | `"high"`, `"normal"`, or `"low"` — or a number: `1` = high, `2` = normal, `3` = low. Missing means `"normal"`. |
| `task` | A step function, or a coroutine (see below). |
| `options` | Optional table, see below. |

A **step function** is called once per frame with its handle as its only
argument:

- return `true` — "not finished, call me again next frame";
- return `false` or nothing — the task is complete.

A **coroutine task** runs until it returns. Pass a thread created with
`coroutine.create(...)`, or pass a function with `options.coroutine = true`.
Inside a coroutine task, yield in either of two ways:

- `LAP:Yield(seconds)` — pause for that many seconds (`0` or no argument
  pauses until the next frame);
- plain `coroutine.yield(seconds)` — the same, using the yielded number.

**Options:**

| Field | Meaning |
|---|---|
| `name` | Label for debugging and stats prints. |
| `onComplete` | `fn(handle)` — runs once when the task finishes normally. |
| `onCancel` | `fn(handle)` — runs once when the task is cancelled. |
| `onError` | `fn(handle, err)` — runs once if a step errors. Without it, errors go to the standard error handler. An errored task ends and never runs again. |
| `coroutine` | `true` treats a function task as a coroutine body. |
| `budget` | Advisory per-task budget in ms. The scheduler checks time between steps, so this is stored on the handle for stepped tasks that want to self-limit (read `handle.budget`); it does not pre-empt a running step. |

### Handle methods

| Method | Meaning |
|---|---|
| `handle:Cancel()` | Cancels the task if it has not finished; returns `true` when this call cancelled it. Fires `onCancel` once. A task cancelled while queued or waiting never runs again; a task cancelled during its own step stops after that step returns. |
| `handle:IsCancelled()` | `true` after cancellation. |
| `handle:IsComplete()` | `true` after the task finished normally. |
| `handle:IsFailed()` | `true` after the task stopped with an error. |
| `handle.state` | `"queued"`, `"waiting"`, `"running"`, `"complete"`, `"cancelled"`, or `"failed"`. |
| `handle.steps` | How many steps have run. |
| `handle.priority` / `handle.name` | The normalized priority and the option name. |

### `LAP:Chain(tasks, options)` → chain handle

Runs tasks one after another — each starts only after the previous one
completes. Entries are step functions, coroutines, or tables
`{ task = fn, priority = ..., name = ..., onComplete = ... }` (any
`Schedule` option works per step). The returned handle has the same
methods as a task handle: cancelling it cancels the current step and
prevents all later steps. If a step is cancelled or fails, the chain stops
and the chain's `onCancel` / `onError` (from `options`) fires.

### `LAP:Yield(seconds)`

Coroutine tasks only — see `Schedule`. Errors when called outside a
coroutine task.

### `LAP:Flush(priority)` → number cancelled

Cancels every queued or waiting task of the given priority, or of **all**
priorities when called with no argument. A task that is in the middle of
a step is not interrupted; it finishes that step. Returns how many tasks
were cancelled. Typical use: a window closes, so its low-priority refresh
work goes away — `LAP:Flush("low")`, or flush from the task handle if
only one job should stop.

### `LAP:GetStats()` → table

Returns a fresh table:

| Field | Meaning |
|---|---|
| `queued` / `waiting` / `running` / `active` | Live task counts (waiting = parked in `Yield`). |
| `scheduled` / `completed` / `cancelled` / `failed` | Totals since load. |
| `frames` | Driver frames that did work. |
| `lastFrameMs` / `avgFrameMs` / `maxFrameMs` | Time the scheduler itself spent per frame. |
| `budgetMs` / `effectiveBudgetMs` | Configured budget and the current adaptive budget. |

### `LAP:SetBudget(ms)` / `LAP:GetBudget()`

Sets the per-frame budget (default **5 ms**, clamped to 1–50). Returns the
budget now in effect.

### `LAP:SetDebug(enabled)` and `LAP:RunTest()`

`SetDebug(true)` prints one line per task step. `RunTest()` runs the
built-in self-test described below.

### Version

`LAP.VERSION` is `"1.0.0"`; `LAP.MAJOR` is `"LibAsyncPriority-1.0"` and
`LAP.MINOR` is the LibStub minor version.

## Examples

### Example 1 — simple: a low-priority bag scan

A step function that walks one bag per frame, at the lowest priority, so
it only ever uses spare frame time:

```lua
local LAP = LibStub("LibAsyncPriority-1.0")

local function ScanBags()
    local bag = -1 -- start before the first bag
    local found = {}
    return LAP:Schedule("low", function(handle)
        bag = bag + 1
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                found[info.itemID] = (found[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
        if bag < NUM_BAG_SLOTS then
            return true -- more bags to go: continue next frame
        end
        print("Scan done:", next(found) and "items counted" or "bags empty")
        -- returning nothing finishes the task
    end, { name = "bag-scan" })
end
```

### Example 2 — advanced: a user action pre-empts background work

A slow background index rebuild runs at low priority. The moment the user
clicks "Sell all greys", that job is scheduled at high priority **and**
the background task is cancelled, so the click feels instant; the rebuild
restarts afterwards through a chain:

```lua
local LAP = LibStub("LibAsyncPriority-1.0")
local background -- handle of the running rebuild, kept so we can cancel it

local function StartRebuild()
    local step = 0
    background = LAP:Schedule("low", function()
        step = step + 1
        -- ... rebuild chunk number `step` ...
        return step < 200 -- 200 chunks, one per frame
    end, {
        name = "index-rebuild",
        onCancel = function() print("Rebuild paused for a user action.") end,
    })
    return background
end

StartRebuild()

-- In the Sell button's OnClick:
local function OnSellClicked()
    if background then background:Cancel() end
    LAP:Chain({
        { task = function()
              -- sell pass: one quick, complete step at high priority
              SellAllGreyItems()
          end,
          priority = "high", name = "sell-greys" },
        { task = function() StartRebuild() end, -- then rebuild again
          priority = "low", name = "restart-rebuild" },
    })
end
```

Because the scheduler always drains the high-priority queue first, a
high-priority task scheduled while low-priority work is queued runs on
the very next step — it never waits behind background chunks.

### Example 3 — coroutine task with Yield

```lua
LAP:Schedule("normal", function()
    RebuildCache()
    LAP:Yield(0.5)          -- wait half a second, using no frame budget
    RefreshDisplay()
    coroutine.yield()       -- or just pause to the next frame
    PlaySound(SOUNDKIT.READY_CHECK)
end, { coroutine = true, name = "staged-refresh" })
```

## Testing

### In game

1. Install standalone (above) and log in.
2. Type **`/libasyncpriority test`** (or `/lap test`).
3. Expected chat output: a scheduling line, one step line per task step
   (debug printing turns itself on for the test), a "victim cancelled as
   planned" line, then a summary line of the form
   `order = scheduled > high > normal > low` followed by the finish time
   and frame count. The exact step interleaving can vary by one frame;
   what must hold is: **high finishes before normal, normal before low,
   and the victim never appears in the order.**
4. **`/libasyncpriority stats`** prints queued/completed counts and the
   average scheduler frame time.
5. **`/libasyncpriority flush`** (optionally with a priority,
   e.g. `/lap flush low`) cancels pending work and reports how many
   tasks it cancelled.

### Outside the game

`tests/test_libasyncpriority.lua` is a plain-Lua harness that stubs the
handful of WoW functions the library touches (frame creation, timers,
the slash-command table) and then checks priority order, multi-step
tasks, cancellation, chaining, `Yield`, `Flush`, error handling, and
stats. Run it with any Lua 5.1 interpreter:

```sh
lua5.1 tests/test_libasyncpriority.lua
```

It prints one line per check and a final PASS line. (These checks prove
the scheduler's logic; only the in-game test proves behavior in the real
Forever client.)

## Performance notes

- **One driver.** A single anonymous frame exists per library, and its
  `OnUpdate` script is installed only while work is queued or waiting —
  an idle library costs no per-frame time at all.
- **Budgeted, adaptive.** The driver stops stepping tasks once the frame
  budget (5 ms default) is spent, measured with `debugprofilestop()`.
  When a frame overruns, the effective budget halves (down to 1 ms) and
  then grows back — a hitch does not turn into a spiral.
- **One step per task per frame.** A task that asks to continue is never
  called twice in the same frame, so a yielding task cannot starve
  higher-priority work or loop inside one frame.
- **Low allocation.** Scheduling creates one handle table per task and no
  closures; step dispatch goes through a shared metatable, queues are
  reused ring buffers, and the driver's scratch buffer is allocated once.
  (`Chain` is the exception by nature: it wraps each step's callbacks.)
- **Keep steps small.** Lua cannot pre-empt a running step. A step that
  itself takes 20 ms will blow the frame no matter what the budget says —
  split the work, not the blame.

## Troubleshooting

- **The addon does not appear in the AddOns list.** The folder name must
  be exactly `LibAsyncPriority-1.0`, sitting directly in
  `Interface\AddOns\`, with `LibAsyncPriority-1.0.toc` inside it — not
  nested in a second folder from unzipping. A brand-new addon also needs
  a game restart (or a trip back to the character screen), not just
  `/reload`.
- **`Cannot find a library instance of "LibAsyncPriority-1.0"`.** The
  library was not loaded before your addon ran. If you embedded it, check
  that the `embeds.xml` include (or the `.toc` file lines) comes *before*
  your addon's own files, and list LibStub before the library file.
- **`/libasyncpriority test` does nothing.** The standalone addon is not
  enabled on that character — tick it in the AddOns list. The slash
  command is registered by whichever copy of the library loads with the
  slash system available, but the simplest fix is to enable the
  standalone addon for the test.
- **An old embedded copy seems to win over a new one.** LibStub keeps the
  highest minor version it has seen this session; a full `/reload` after
  updating the files resolves it.
- **A task runs slower than expected.** Remember the two hard rules: one
  step per task per frame, and the 5 ms frame budget shared by all
  tasks. Make each step do a bigger batch, or raise the budget with
  `SetBudget` — and check `/libasyncpriority stats` to see the real
  frame times.

## Privacy

None, in the best sense: the library collects nothing, stores nothing
(no SavedVariables), and talks to nothing. It only runs the tasks other
addons hand it, in memory, for as long as the game session lasts.

## Screenshots

The library has no windows of its own — its only visible output is the
chat text from `/libasyncpriority test` and `/libasyncpriority stats`.
A real capture of that test output from the Forever client will be added
here after the first in-game run; no placeholder image is used in its
place.

## Known limitations

- **No pre-emption inside a step.** The budget is checked between steps
  only. Long single steps still cause a hitch (see above).
- **Priorities are strict, not fair.** An endless supply of high-priority
  tasks will starve low-priority ones indefinitely. That is the point of
  priorities — but do not schedule recurring work as `"high"`.
- **One step per frame per task.** A task cannot do two steps in one
  frame, so a task with 600 tiny steps takes at least 600 frames
  (~10 seconds). For bulk-but-tiny steps, make each step do a batch.
- **`Yield` waits are frame-checked.** Wake-ups are tested once per
  frame, so a `Yield(0.05)` can land up to one frame late, and timers do
  not run while the game is logged out or the driver has no other work
  pending a wake check — waiting tasks keep the driver alive precisely
  so their wake check still runs.
- **Errors end tasks.** A step that errors finishes that task as
  `"failed"`; there is no automatic retry. Use `onError` to reschedule
  if a retry is wanted.
- **`options.budget` is advisory only** (see the API table). The real,
  enforced budget is the scheduler-wide one from `SetBudget`.
- **No persistence.** Queues live in memory only; a reload clears them.
  Nothing is written to SavedVariables.
- **Not a thread pool.** Everything runs on the game's main thread, in
  the frame loop — that is the only place addon Lua can run.

## Compatibility notes (Classic Forever)

- Targets **Interface 11507** (Classic Era 1.15.7 line, the Classic
  Forever client). The library uses only APIs present there: `GetTime`,
  `debugprofilestop`, `CreateFrame`, `SlashCmdList`, and the `C_Container`
  namespace in the examples.
- **No deprecated or removed APIs**, no `this`/`arg` globals, no XML
  frame definitions.
- **No taint:** the library creates one anonymous frame, hooks nothing,
  touches no secure or protected function, and calls no secure template.
  Its only globals are the LibStub registration and the `SLASH_`
  entries the slash-command system requires.
- **Coexists with other LibStub libraries** and with multiple embedded
  copies of itself (newest minor wins, per LibStub rules).
- Should also load on other 1.15.x Era-based clients, but it is built
  and checked against 11507; behavior in the live Forever client is
  verified by the `/libasyncpriority test` run, not assumed.

## Files

| File | Purpose |
|---|---|
| `LibAsyncPriority-1.0.lua` | The library (under 500 lines). |
| `LibStub.lua` | Bundled LibStub 1.0, for standalone use. |
| `LibAsyncPriority-1.0.toc` | Standalone addon metadata, Interface 11507. |
| `embeds.xml` | Include file for embedding in another addon. |
| `tests/test_libasyncpriority.lua` | Out-of-game logic checks (Lua 5.1). |
| `FEATURES.md` / `DESCRIPTION.md` / `CHANGELOG.md` | Feature list, store-style description, history. |

## License

MIT — see [`LICENSE`](LICENSE).
