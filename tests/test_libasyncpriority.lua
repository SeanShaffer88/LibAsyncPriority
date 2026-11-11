-- Out-of-game logic checks for LibAsyncPriority-1.0 (plain Lua 5.1).
-- Stubs the WoW functions the library touches, loads the real library
-- files, and drives the OnUpdate handler by hand.
-- Run from the repo root:  lua5.1 tests/test_libasyncpriority.lua

local realPrint = print
local scriptDir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
local root = scriptDir .. "/.."

-- Simulated environment -------------------------------------------------------
local simTime, simMs = 0, 0
local frames, capturedPrints, capturedErrors = {}, {}, {}

_G.GetTime = function() return simTime end
_G.debugprofilestop = function() simMs = simMs + 0.05; return simMs end
_G.strmatch = string.match -- WoW global alias used by LibStub
_G.SlashCmdList = {}
_G.geterrorhandler = function()
	return function(err) capturedErrors[#capturedErrors + 1] = tostring(err) end
end
_G.print = function(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
	capturedPrints[#capturedPrints + 1] = table.concat(parts, " ")
end
_G.CreateFrame = function(_kind)
	local frame = { _scripts = {} }
	function frame:SetScript(name, fn) self._scripts[name] = fn end
	function frame:GetScript(name) return self._scripts[name] end
	function frame:Show() self._shown = true end
	function frame:Hide() self._shown = false end
	frames[#frames + 1] = frame
	return frame
end

dofile(root .. "/LibStub.lua")
dofile(root .. "/LibAsyncPriority-1.0.lua")

local LAP = LibStub("LibAsyncPriority-1.0")

local function pump(count)
	local driver = frames[1] -- the library's driver is the first frame created
	for _ = 1, count or 1 do
		local handler = driver and driver._scripts.OnUpdate
		if handler then handler(driver, 0.016) end
	end
end

local failures = 0
local function check(name, cond)
	realPrint((cond and "ok   - " or "FAIL - ") .. name)
	if not cond then failures = failures + 1 end
end
local function seq(list) return table.concat(list, ",") end

-- 1. Priority order inside one frame ------------------------------------------
local order = {}
local function oneStep(tag)
	return function() order[#order + 1] = tag; return false end
end
LAP:Schedule("low", oneStep("low"))
LAP:Schedule("normal", oneStep("normal"))
LAP:Schedule("high", oneStep("high"))
pump(1)
check("priority order high > normal > low", seq(order) == "high,normal,low")

-- 2. Multi-step task: one step per frame ---------------------------------------
local steps = 0
local multi = LAP:Schedule("normal", function()
	steps = steps + 1
	return steps < 3
end)
pump(1)
check("multi-step ran once in first frame", steps == 1 and not multi:IsComplete())
pump(2)
check("multi-step completed after 3 frames", steps == 3 and multi:IsComplete())

-- 3. Cancel while queued --------------------------------------------------------
local victimRan, victimCancels = false, 0
local victim = LAP:Schedule("low", function() victimRan = true; return true end, {
	onCancel = function() victimCancels = victimCancels + 1 end,
})
check("cancel returns true", victim:Cancel() == true)
check("second cancel returns false", victim:Cancel() == false)
pump(3)
check("cancelled task never ran", not victimRan)
check("onCancel fired exactly once", victimCancels == 1 and victim:IsCancelled())

-- 4. Cancel between steps --------------------------------------------------------
local steps4 = 0
local h4 = LAP:Schedule("normal", function() steps4 = steps4 + 1; return true end)
pump(1)
h4:Cancel()
pump(3)
check("cancel between steps stops the task", steps4 == 1 and h4:IsCancelled())

-- 5. Self-cancel during a step ---------------------------------------------------
local steps5, h5 = 0, nil
h5 = LAP:Schedule("normal", function(handle)
	steps5 = steps5 + 1
	handle:Cancel()
	return true
end)
pump(3)
check("self-cancel takes effect after the step", steps5 == 1 and h5:IsCancelled())

-- 6. Chain runs in sequence under one handle --------------------------------------
local chainOrder = {}
local function chainStep(tag)
	return function() chainOrder[#chainOrder + 1] = tag; return false end
end
local chain = LAP:Chain({ chainStep("a"), chainStep("b"), chainStep("c") })
pump(5)
check("chain order a,b,c", seq(chainOrder) == "a,b,c")
check("chain completes", chain:IsComplete())

local chain2Order = {}
local chain2 = LAP:Chain({
	function() chain2Order[#chain2Order + 1] = "x"; return false end,
	function() chain2Order[#chain2Order + 1] = "y"; return false end,
})
chain2:Cancel()
pump(3)
check("cancelled chain runs nothing", #chain2Order == 0 and chain2:IsCancelled())

-- 7. Coroutine tasks and Yield -----------------------------------------------------
local coLog = {}
LAP:Schedule("normal", function()
	coLog[#coLog + 1] = "start"
	LAP:Yield(0.5)
	coLog[#coLog + 1] = "after-yield"
	coroutine.yield()
	coLog[#coLog + 1] = "after-frame"
end, { coroutine = true })
pump(1)
check("coroutine paused at Yield", seq(coLog) == "start")
simTime = simTime + 0.25
pump(1)
check("coroutine still waiting before wake time", seq(coLog) == "start")
simTime = simTime + 0.5
pump(1)
check("coroutine resumed after Yield(0.5)", seq(coLog) == "start,after-yield")
pump(1)
check("coroutine finished after frame yield", seq(coLog) == "start,after-yield,after-frame")

local threadLog = {}
LAP:Schedule("low", coroutine.create(function()
	threadLog[#threadLog + 1] = "thread-ran"
end))
pump(1)
check("thread task ran", seq(threadLog) == "thread-ran")

-- 8. Flush -------------------------------------------------------------------------
local flushed = {}
local function endless(tag)
	return function() flushed[#flushed + 1] = tag; return true end
end
local fLow1 = LAP:Schedule("low", endless("low1"))
local fLow2 = LAP:Schedule("low", endless("low2"))
local fHigh = LAP:Schedule("high", endless("high"))
local flushedCount = LAP:Flush("low")
check("Flush(low) cancelled both low tasks", flushedCount == 2
	and fLow1:IsCancelled() and fLow2:IsCancelled() and not fHigh:IsCancelled())
check("Flush() cancels the rest", LAP:Flush() == 1 and fHigh:IsCancelled())
pump(2)
check("flushed tasks never ran", #flushed == 0)

-- 9. Errors end the task, scheduler survives ---------------------------------------
local errText = nil
local bad = LAP:Schedule("normal", function() error("boom") end, {
	onError = function(_, err) errText = tostring(err) end,
})
local afterError = false
LAP:Schedule("normal", function() afterError = true; return false end)
pump(2)
check("errored task is failed", bad:IsFailed())
check("onError received the error", errText ~= nil and errText:find("boom") ~= nil)
check("later task still ran after an error", afterError)

-- 10. Pre-emption: high priority scheduled later still goes first -------------------
local preempt = {}
local lowSteps = 0
LAP:Schedule("low", function()
	lowSteps = lowSteps + 1
	preempt[#preempt + 1] = "low" .. lowSteps
	return lowSteps < 3
end)
pump(1)
LAP:Schedule("high", function() preempt[#preempt + 1] = "high"; return false end)
pump(1)
check("high pre-empts low on the next frame", seq(preempt) == "low1,high,low2")
pump(2)

-- 11. Numeric priorities and budget --------------------------------------------------
local nHigh = LAP:Schedule(1, oneStep("n1"))
local nLow = LAP:Schedule(3, oneStep("n3"))
check("numeric priority 1 = high", nHigh.priority == "high")
check("numeric priority 3 = low", nLow.priority == "low")
pump(1)
check("SetBudget returns the new budget", LAP:SetBudget(10) == 10 and LAP:GetBudget() == 10)
LAP:SetBudget(5)

-- 12. Stats and slash command ---------------------------------------------------------
local stats = LAP:GetStats()
check("stats counts completions", stats.completed >= 8)
check("stats counts cancellations", stats.cancelled >= 5)
check("stats counts failures", stats.failed >= 1)
check("stats frame timing present", stats.frames > 0 and stats.avgFrameMs >= 0)
check("queue drained at the end", stats.queued == 0 and stats.active == 0)
check("slash handler registered", type(_G.SlashCmdList["LIBASYNCPRIORITY"]) == "function")
_G.SlashCmdList["LIBASYNCPRIORITY"]("stats")
check("slash stats printed a line", #capturedPrints > 0)

realPrint(failures == 0 and "PASS - all LibAsyncPriority checks passed"
	or ("FAIL - " .. failures .. " check(s) failed"))
os.exit(failures == 0 and 0 or 1)
