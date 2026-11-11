--[[---------------------------------------------------------------------------
LibAsyncPriority-1.0 -- priority-based asynchronous task scheduler.
Spreads heavy work (bag scans, database builds, sorts) over many frames
under a small per-frame budget; high-priority user work always runs first
and any task can be cancelled.
Design: one anonymous driver frame, OnUpdate installed only while work
exists; no secure code touched, no protected function hooked (no taint);
only current APIs (GetTime, debugprofilestop, CreateFrame, SlashCmdList);
one handle table per task and no per-task closures (shared metatables);
a single step cannot be pre-empted, so keep steps short -- the budget is
checked between steps. Usage: local LAP = LibStub("LibAsyncPriority-1.0")
---------------------------------------------------------------------------]]

local MAJOR, MINOR = "LibAsyncPriority-1.0", 1
---@class LibAsyncPriority-1.0
---@field VERSION string Semantic version of this library release.
local lib
if _G.LibStub then
	lib = _G.LibStub:NewLibrary(MAJOR, MINOR)
	if not lib then return end -- a newer or equal copy is already loaded
else
	lib = {} -- standalone fallback: no LibStub present, expose one global
	_G[MAJOR] = lib
end
lib.MAJOR, lib.MINOR, lib.VERSION = MAJOR, MINOR, "1.0.0"
-- Localized globals (upvalues, faster and taint-safe).
local type, pcall, pairs, error, tostring, tonumber = type, pcall, pairs, error, tostring, tonumber
local setmetatable, geterrorhandler = setmetatable, geterrorhandler
local co_create, co_resume, co_status, co_running, co_yield =
	coroutine.create, coroutine.resume, coroutine.status, coroutine.running, coroutine.yield
local math_min, math_max = math.min, math.max
local str_format, str_lower = string.format, string.lower
local tbl_concat = table.concat
local GetTime, debugprofilestop, CreateFrame = GetTime, debugprofilestop, CreateFrame

local PRIORITIES = { "high", "normal", "low" } -- index 1 is highest
local PRIORITY_INDEX = { high = 1, normal = 2, low = 3 }
local NOOPTS = {} -- shared read-only empty options table (no per-call alloc)
-- Scheduler state.
local budgetMs, effectiveBudgetMs = 5, 5 -- per-frame budget (adaptive)
local queues = {} -- per-priority FIFO: { [head..tail] = handle }
for i = 1, #PRIORITIES do queues[PRIORITIES[i]] = { head = 1, tail = 0 } end
local waiting = {} -- handles parked by Yield(), array of { handle, wake }
local stats = { scheduled = 0, completed = 0, cancelled = 0, failed = 0,
	queued = 0, frames = 0, totalMs = 0, lastMs = 0, maxMs = 0 }
local driver, running = nil, nil -- driver frame, currently-stepping handle
local frameId = 0
-- Queue helpers ---------------------------------------------------------------
---@param q table FIFO queue table.
---@param h table Handle to append.
local function Enqueue(q, h)
	q.tail = q.tail + 1
	q[q.tail] = h
	h._inQueue = true
	stats.queued = stats.queued + 1
end
---@param q table FIFO queue table.
---@return table|nil Oldest handle, or nil when the queue is empty.
local function Dequeue(q)
	if q.head > q.tail then return nil end
	local h = q[q.head]
	q[q.head] = nil
	q.head = q.head + 1
	if q.head > q.tail then q.head, q.tail = 1, 0 end -- reset when drained
	if h and h._inQueue then h._inQueue = nil; stats.queued = stats.queued - 1 end
	return h
end
---@param priority string|number "high"/"normal"/"low" or 1/2/3 (1 = highest).
---@return string name, number index Normalized priority.
local function NormalizePriority(priority)
	if priority == nil then return "normal", 2 end
	if type(priority) == "number" then
		local idx = math_min(3, math_max(1, priority))
		return PRIORITIES[idx], idx
	end
	local idx = PRIORITY_INDEX[str_lower(tostring(priority))]
	if not idx then error("LibAsyncPriority: invalid priority " .. tostring(priority), 3) end
	return PRIORITIES[idx], idx
end
---@param fn function|nil Callback (onComplete / onCancel / onError).
---@param h table Handle passed to the callback.
---@param err string|nil Error text for onError callbacks.
local function Fire(fn, h, err)
	if not fn then return end
	local ok, e = pcall(fn, h, err)
	if not ok and geterrorhandler then geterrorhandler()(e) end
end
-- Task handle -----------------------------------------------------------------
---@class LibAsyncPriorityHandle
---@field name string|nil Optional task name from options.
---@field priority string "high", "normal" or "low".
---@field state string "queued", "waiting", "running", "complete",
--- "cancelled" or "failed".
---@field steps number Steps run so far.
local Handle = {}
Handle.__index = Handle
--- Cancels the task if it has not finished. A task cancelled while queued
--- or waiting never runs again; one cancelled during its own step stops
--- after that step returns. Fires onCancel exactly once.
--- @return boolean True when this call cancelled the task.
function Handle:Cancel()
	if self.state == "complete" or self.state == "cancelled" or self.state == "failed" then
		return false
	end
	if self._isChain then return self:_CancelChain() end
	if self.state == "running" then self._cancelRequested = true; return true end
	self.state = "cancelled"
	if self._inQueue then self._inQueue = nil; stats.queued = stats.queued - 1 end
	stats.cancelled = stats.cancelled + 1
	Fire(self.onCancel, self)
	return true
end
---@return boolean True when the task was cancelled.
function Handle:IsCancelled() return self.state == "cancelled" end
---@return boolean True when the task finished normally.
function Handle:IsComplete() return self.state == "complete" end
---@return boolean True when the task stopped with a Lua error.
function Handle:IsFailed() return self.state == "failed" end
-- Driver ----------------------------------------------------------------------

local RunFrame -- forward declaration
--- Creates the driver frame on first use and installs OnUpdate.
local function EnsureDriver()
	if not driver then
		driver = CreateFrame("Frame") -- anonymous: creates no global
		driver:Hide()
	end
	if not driver._lapActive then
		driver._lapActive = true
		driver:SetScript("OnUpdate", RunFrame)
		driver:Show()
	end
end
--- Stops the driver when no queued or waiting work remains.
local function StopDriverIfIdle()
	if stats.queued == 0 and #waiting == 0 and driver and driver._lapActive then
		driver._lapActive = false
		driver:SetScript("OnUpdate", nil)
		driver:Hide()
	end
end
--- Marks a handle finished (complete or failed) and fires its callback.
---@param h table Handle.
---@param state string "complete" or "failed".
---@param err string|nil Error text when failed.
local function Finish(h, state, err)
	h.state = state
	if state == "complete" then stats.completed = stats.completed + 1
	else stats.failed = stats.failed + 1 end
	if state == "complete" then Fire(h.onComplete, h)
	elseif h.onError then Fire(h.onError, h, err)
	elseif geterrorhandler then geterrorhandler()(err) end
end
--- Runs one step of a task and routes it afterwards (requeue, park, finish).
---@param h table Handle.
local function RunStep(h)
	running = h
	h.state = "running"
	h.steps = h.steps + 1
	h._stepFrame = frameId
	if lib._debug then print("|cff33ff99LibAsyncPriority:|r step " .. tostring(h.name or h.priority)) end
	local ok, result
	if h._co then ok, result = co_resume(h._co, h)
	else ok, result = pcall(h._task, h) end
	running = nil
	if h._cancelRequested then -- cancelled during its own step
		h._cancelRequested = nil
		h.state = "cancelled"
		stats.cancelled = stats.cancelled + 1
		Fire(h.onCancel, h)
		return
	end
	if not ok then Finish(h, "failed", result); return end
	if h._co then
		if co_status(h._co) == "dead" then Finish(h, "complete"); return end
		if type(result) == "number" and result > 0 then -- Yield(seconds)
			h.state = "waiting"
			waiting[#waiting + 1] = { handle = h, wake = GetTime() + result }
			return
		end
		h.state = "queued" -- yielded for next frame
		Enqueue(queues[h.priority], h)
	elseif result == true then -- plain task asks to continue next frame
		h.state = "queued"
		Enqueue(queues[h.priority], h)
	else
		Finish(h, "complete")
	end
end
--- OnUpdate driver: wakes due tasks, then steps tasks highest-priority
--- first until the effective budget is spent. Each task steps at most
--- once per frame, so a yielding task can never starve the frame.
---@param _ any Driver frame (unused).
---@param _elapsed number Unused; timing uses debugprofilestop().
RunFrame = function(_, _elapsed)
	frameId = frameId + 1
	local start = debugprofilestop()
	for i = #waiting, 1, -1 do -- wake due Yield() tasks
		local w = waiting[i]
		if w.handle.state == "cancelled" or w.wake <= GetTime() then
			waiting[i] = waiting[#waiting]; waiting[#waiting] = nil
			if w.handle.state ~= "cancelled" then
				w.handle.state = "queued"
				Enqueue(queues[w.handle.priority], w.handle)
			end
		end
	end
	local deferred = lib._deferred -- tasks already stepped this frame
	local deferredCount = 0
	while debugprofilestop() - start < effectiveBudgetMs do
		local h
		for p = 1, 3 do h = Dequeue(queues[PRIORITIES[p]]); if h then break end end
		if not h then break end
		if h.state == "cancelled" or h.state == "complete" or h.state == "failed" then
			-- lazy removal of cancelled handles: skip silently
		elseif h._stepFrame == frameId then
			deferredCount = deferredCount + 1
			deferred[deferredCount] = h -- put back after the loop
		else
			RunStep(h)
		end
	end
	for i = 1, deferredCount do
		local h = deferred[i]
		deferred[i] = nil
		if h.state == "queued" and not h._inQueue then Enqueue(queues[h.priority], h) end
	end
	local used = debugprofilestop() - start
	stats.frames = stats.frames + 1
	stats.totalMs, stats.lastMs = stats.totalMs + used, used
	if used > stats.maxMs then stats.maxMs = used end
	if used > budgetMs then -- adapt: shrink after an overrun, regrow slowly
		effectiveBudgetMs = math_max(1, effectiveBudgetMs * 0.5)
	elseif effectiveBudgetMs < budgetMs then
		effectiveBudgetMs = math_min(budgetMs, effectiveBudgetMs + 0.5)
	end
	StopDriverIfIdle()
end
-- Public API ------------------------------------------------------------------
--- Schedules a task. The task is called once per frame with its handle;
--- return true to be called again next frame, false/nil to finish. Pass a
--- coroutine (thread), or a function with options.coroutine = true, for a
--- coroutine task that may use LibAsyncPriority:Yield(seconds).
--- @param priority string|number "high", "normal", "low" or 1/2/3.
--- @param task function|thread Step function or coroutine.
--- @param options table|nil { name, onComplete = fn(handle),
---   onCancel = fn(handle), onError = fn(handle, err), coroutine = bool,
---   budget = number (advisory per-task ms budget, see README) }.
--- @return table Handle with :Cancel(), :IsCancelled(), :IsComplete().
function lib:Schedule(priority, task, options)
	local prioName, prioIdx = NormalizePriority(priority)
	local taskType = type(task)
	if taskType ~= "function" and taskType ~= "thread" then
		error("LibAsyncPriority: task must be a function or coroutine", 2)
	end
	options = options or NOOPTS
	local h = setmetatable({}, Handle)
	h.priority, h.priorityIndex = prioName, prioIdx
	h.name = options.name
	h.onComplete, h.onCancel, h.onError = options.onComplete, options.onCancel, options.onError
	h.budget = options.budget
	h.state, h.steps = "queued", 0
	if taskType == "thread" then h._co = task
	elseif options.coroutine then h._co = co_create(task)
	else h._task = task end
	stats.scheduled = stats.scheduled + 1
	Enqueue(queues[prioName], h)
	EnsureDriver()
	return h
end
--- Defers the calling coroutine task. Only valid inside a coroutine task
--- (a thread, or a function scheduled with options.coroutine = true).
--- @param seconds number|nil Delay in seconds; 0 or nil defers one frame.
function lib:Yield(seconds)
	if not co_running() then
		error("LibAsyncPriority: Yield must be called inside a coroutine task", 2)
	end
	return co_yield(seconds or 0)
end
--- Runs tasks one after another: each starts after the previous one
--- completes. Cancelling the chain handle cancels the current step and
--- prevents later steps; a cancelled/failed step stops the chain and
--- fires the chain's onCancel / onError.
--- @param tasks table Array of functions, coroutines, or entry tables
---   { task = fn, priority = ..., name = ..., onComplete = ..., ... }.
--- @param options table|nil { name, onComplete, onCancel, onError }.
--- @return table Chain handle (same methods as a task handle).
function lib:Chain(tasks, options)
	if type(tasks) ~= "table" or #tasks == 0 then
		error("LibAsyncPriority: Chain needs a non-empty array of tasks", 2)
	end
	options = options or NOOPTS
	local chain = setmetatable({}, Handle)
	chain._isChain, chain.state, chain.steps = true, "running", 0
	chain.priority, chain.priorityIndex = "normal", 2
	chain.name = options.name or "chain"
	chain.onComplete, chain.onCancel, chain.onError =
		options.onComplete, options.onCancel, options.onError
	chain._chainTasks, chain._chainIndex = tasks, 0
	stats.scheduled = stats.scheduled + 1
	local function startNext()
		if chain.state ~= "running" then return end
		chain._chainIndex = chain._chainIndex + 1
		local entry = tasks[chain._chainIndex]
		if entry == nil then
			chain.state = "complete"
			stats.completed = stats.completed + 1
			Fire(chain.onComplete, chain)
			return
		end
		local stepTask, stepOptions = entry, nil
		if type(entry) == "table" then
			stepTask, stepOptions = entry.task or entry[1], entry
		end
		local entryOptions = {}
		for k, v in pairs(stepOptions or NOOPTS) do entryOptions[k] = v end
		entryOptions.onComplete = function(stepHandle)
			Fire(stepOptions and stepOptions.onComplete, stepHandle)
			chain.steps = chain.steps + 1
			startNext()
		end
		entryOptions.onCancel = function(stepHandle)
			Fire(stepOptions and stepOptions.onCancel, stepHandle)
			if chain.state == "running" then
				chain.state = "cancelled"
				stats.cancelled = stats.cancelled + 1
				Fire(chain.onCancel, chain)
			end
		end
		entryOptions.onError = function(stepHandle, err)
			Fire(stepOptions and stepOptions.onError, stepHandle, err)
			if chain.state == "running" then
				chain.state = "failed"
				stats.failed = stats.failed + 1
				Fire(chain.onError, chain, err)
			end
		end
		chain._chainCurrent = self:Schedule(
			stepOptions and stepOptions.priority or "normal", stepTask, entryOptions)
	end
	chain._chainStart = startNext
	startNext()
	return chain
end
--- Cancels a chain handle: cancels its current step, runs no later steps.
---@return boolean True when this call cancelled the chain.
function Handle:_CancelChain()
	if self.state ~= "running" then return false end
	self.state = "cancelled"
	stats.cancelled = stats.cancelled + 1
	local current = self._chainCurrent
	if current and current.state ~= "complete" and current.state ~= "cancelled"
		and current.state ~= "failed" then
		current._lapChainCancel = true
		current:Cancel() -- its onCancel wrapper sees state ~= "running", no double fire
	end
	Fire(self.onCancel, self)
	return true
end
--- Cancels every queued or waiting task of one priority, or of all
--- priorities when called without an argument. A task that is mid-step
--- is not interrupted; it finishes its current step.
--- @param priority string|number|nil Priority to flush, or nil for all.
--- @return number How many tasks were cancelled.
function lib:Flush(priority)
	local wanted = nil
	if priority ~= nil then local name = NormalizePriority(priority); wanted = name end
	local count = 0
	local function flushQueue(name)
		local q = queues[name]
		for i = q.head, q.tail do
			local h = q[i]
			q[i] = nil
			if h and h.state == "queued" then h:Cancel(); count = count + 1 end
		end
		q.head, q.tail = 1, 0
	end
	for p = 1, 3 do
		if not wanted or wanted == PRIORITIES[p] then flushQueue(PRIORITIES[p]) end
	end
	for i = #waiting, 1, -1 do
		local h = waiting[i].handle
		if (not wanted or h.priority == wanted) and h.state == "waiting" then
			waiting[i] = waiting[#waiting]; waiting[#waiting] = nil
			h:Cancel(); count = count + 1
		end
	end
	StopDriverIfIdle()
	return count
end
--- Returns scheduler statistics in a fresh table.
--- @return table { queued, waiting, running, active, scheduled, completed,
---   cancelled, failed, frames, lastFrameMs, avgFrameMs, maxFrameMs,
---   budgetMs, effectiveBudgetMs }.
function lib:GetStats()
	local waitingCount = 0
	for i = 1, #waiting do
		if waiting[i].handle.state == "waiting" then waitingCount = waitingCount + 1 end
	end
	local runCount = running and 1 or 0
	return {
		queued = stats.queued, waiting = waitingCount, running = runCount,
		active = stats.queued + waitingCount + runCount,
		scheduled = stats.scheduled, completed = stats.completed,
		cancelled = stats.cancelled, failed = stats.failed,
		frames = stats.frames, lastFrameMs = stats.lastMs,
		avgFrameMs = stats.frames > 0 and stats.totalMs / stats.frames or 0,
		maxFrameMs = stats.maxMs,
		budgetMs = budgetMs, effectiveBudgetMs = effectiveBudgetMs,
	}
end
--- Sets the per-frame budget in ms (default 5). The budget is checked
--- between steps, so one long step can exceed it once; the adaptive
--- budget then shrinks for the following frames.
--- @param ms number Budget in ms, clamped to 1..50.
--- @return number The budget now in effect.
function lib:SetBudget(ms)
	budgetMs = math_min(50, math_max(1, tonumber(ms) or 5))
	effectiveBudgetMs = budgetMs
	return budgetMs
end
---@return number The configured per-frame budget in milliseconds.
function lib:GetBudget() return budgetMs end
--- Enables or disables debug prints (used by the self-test).
---@param enabled boolean True to print scheduler debug lines.
function lib:SetDebug(enabled) lib._debug = not not enabled end

lib._deferred = {} -- reusable per-frame buffer: no allocation in OnUpdate
-- Debug self-test ---------------------------------------------------------------
--- Runs the built-in self-test: schedules tasks at all three priorities,
--- cancels one before it finishes, and prints the execution order and
--- timing to chat. Also runs for "/libasyncpriority test".
function lib:RunTest()
	self:SetDebug(true)
	local order, pending = {}, 4
	local started = debugprofilestop()
	local function record(tag)
		order[#order + 1] = tag
		pending = pending - 1
		if pending == 0 then
			print("|cff33ff99LibAsyncPriority test:|r order = " .. tbl_concat(order, " > "))
			print(str_format("|cff33ff99LibAsyncPriority test:|r finished in %.1f ms, %d frames",
				debugprofilestop() - started, self:GetStats().frames))
		end
	end
	local function stepper(tag, steps)
		local n = 0
		return function()
			n = n + 1
			if n >= steps then record(tag); return false end
			return true
		end
	end
	print("|cff33ff99LibAsyncPriority test:|r scheduling high / normal / low + a victim to cancel")
	self:Schedule("low", stepper("low", 3), { name = "test-low" })
	self:Schedule("normal", stepper("normal", 2), { name = "test-normal" })
	self:Schedule("high", stepper("high", 1), { name = "test-high" })
	local victim = self:Schedule("normal", stepper("victim", 5), {
		name = "test-victim",
		onCancel = function() print("|cff33ff99LibAsyncPriority test:|r victim cancelled as planned") end,
	})
	record("scheduled") -- scheduling itself is step zero of the trace
	victim:Cancel()
end
-- Slash command (the SLASH_ global is required by the WoW slash system).
if _G.SlashCmdList then
	_G.SLASH_LIBASYNCPRIORITY1 = "/libasyncpriority"
	_G.SLASH_LIBASYNCPRIORITY2 = "/lap"
	_G.SlashCmdList["LIBASYNCPRIORITY"] = function(msg)
		local cmd, arg = str_format("%s", msg or ""):match("^%s*(%S+)%s*(%S*)")
		cmd = cmd and str_lower(cmd) or ""
		if cmd == "test" then
			lib:RunTest()
		elseif cmd == "stats" then
			local s = lib:GetStats()
			print(str_format("|cff33ff99LibAsyncPriority:|r queued %d, waiting %d, completed %d, cancelled %d, failed %d, avg frame %.2f ms (budget %d ms)",
				s.queued, s.waiting, s.completed, s.cancelled, s.failed, s.avgFrameMs, s.budgetMs))
		elseif cmd == "flush" then
			local n = lib:Flush(arg ~= "" and arg or nil)
			print(str_format("|cff33ff99LibAsyncPriority:|r flushed %d task(s)", n))
		else
			print("|cff33ff99LibAsyncPriority:|r /libasyncpriority test | stats | flush [priority]")
		end
	end
end

return lib
