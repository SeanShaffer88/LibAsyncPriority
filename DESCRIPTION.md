# LibAsyncPriority-1.0

**Heavy work, spread thin — the game never notices.**

LibAsyncPriority is a tiny scheduler library for WoW Classic Forever
addons. Instead of running a big job all at once and freezing a frame,
addons hand the job to LibAsyncPriority as a series of small steps. The
library runs those steps a few at a time, inside a 5 ms per-frame budget,
always working on the most important job first:

- **High** priority for whatever the user just clicked.
- **Normal** for ordinary refresh work.
- **Low** for background scans and rebuilds that can take their time.

Any job can be cancelled — when a window closes, when a newer request
replaces it, or when a user action needs the frame *now*. Jobs can be
chained so one starts when the previous finishes, coroutine jobs can
sleep with `Yield`, and `GetStats` shows exactly how much frame time the
scheduler is using.

For addon authors: embed it through LibStub in one include line, or
install it standalone and share one copy. Under 500 lines, no
dependencies, no SavedVariables, no taint, full LuaDoc on the whole API,
and a built-in self-test (`/libasyncpriority test`) that shows the
priority order working in your chat frame.

For players: you will never see this addon do anything on its own. It is
the quiet machinery inside other addons that keeps their big jobs from
stuttering your game.
