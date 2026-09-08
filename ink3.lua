--[[
Ink Game v8.8.0 — cancellable input repair, 2026-09-08.
Derived from the attached v8.6.1. All automation starts OFF.
F5: hide/show. F6: unload. F7: stop all automation.
Virtual-input access is executor-dependent; successful input is NOT proof of
server acceptance. Minigame controllers use observable GUI/world heuristics.
No verified anti-cheat bypass is included. See accompanying repair notes.
]]
local TARGET_PLACE_ID = 99567941238278
local RUNTIME_KEY = "__InkUltimateRuntime"
local GUI_NAME = "InkUltimate_UI"
-- Stable runtime key + explicit cleanup of known prior builds.
local LEGACY_RUNTIME_KEYS = {
    "__InkUltimateRuntime",
    "__InkUltimateRuntime_v77",
    "__InkUltimateRuntime_v78",
    "__InkUltimateRuntime_v79",
    "__InkUltimateRuntime_v80",
    "__InkUltimateRuntime_v81",
    "__InkUltimateRuntime_v82",
    "__InkUltimateRuntime_v83",
    "__InkUltimateRuntime_v84",
    "__InkUltimateRuntime_v85",
    "__InkUltimateRuntime_v86",
    "__InkUltimateRuntime_v7_7",
    "__InkUltimateRuntime_v7_8",
    "__InkUltimateRuntime_v7_9",
}
-- Roblox resumes task.spawn immediately. Every startup cleanup is routed through
-- one real scheduler yield so reinjection can never execute an old, opaque
-- cleanup callback on the executor's launch stack.
local function deferAfterYield(callback)
    task.spawn(function()
        task.wait()
        callback()
    end)
end
local function quiesceLegacyRuntime(old)
    if type(old) ~= "table" then return end
    -- Scalar-only synchronous phase. Calling an arbitrary legacy panic/cleanup
    -- here can block the executor before Roblox gets its next frame.
    old.alive = false
    local shutdownAsync = old.shutdownAsync
    -- New runtimes own their private cleanup state and expose an idempotent,
    -- bounded shutdown protocol. Leave their arrays intact for that protocol.
    if old.cleanupProtocol == 2 and type(shutdownAsync) == "function" then
        deferAfterYield(function()
            pcall(shutdownAsync)
        end)
        return
    end
    local panicStop = old.panicStop
    local cleanups = old.cleanups
    local connections = old.connections
    local instances = old.instances
    -- Detach the lists immediately so a second reinjection cannot schedule the
    -- same public resources twice while the cooperative drain is running.
    old.cleanups = {}
    old.connections = {}
    old.instances = {}
    deferAfterYield(function()
        -- Legacy callbacks are no longer invoked on the launch stack. Panic and
        -- cleanup execution is serialized with a scheduler turn between calls,
        -- preserving private resources (notably GUI watchers) without recreating
        -- the old all-at-once reinjection stall.
        if type(panicStop) == "function" then
            pcall(panicStop)
            task.wait()
        end
        if type(cleanups) == "table" then
            for i = #cleanups, 1, -1 do
                local cleanup = cleanups[i]
                cleanups[i] = nil
                if type(cleanup) == "function" then
                    pcall(cleanup)
                end
                task.wait()
            end
        end
        if type(connections) == "table" then
            local i = #connections
            while i >= 1 do
                local stop = math.max(1, i - 15)
                for index = i, stop, -1 do
                    local c = connections[index]
                    connections[index] = nil
                    if c then
                        pcall(function() c:Disconnect() end)
                    end
                end
                i = stop - 1
                task.wait()
            end
        end
        if type(instances) == "table" then
            local i = #instances
            while i >= 1 do
                local stop = math.max(1, i - 7)
                for index = i, stop, -1 do
                    local obj = instances[index]
                    instances[index] = nil
                    if obj then
                        pcall(function()
                            if obj.Parent then obj:Destroy() end
                        end)
                    end
                end
                i = stop - 1
                task.wait()
            end
        end
    end)
end
local seenLegacyRuntimes = setmetatable({}, {__mode = "k"})
for i = 1, #LEGACY_RUNTIME_KEYS do
    local key = LEGACY_RUNTIME_KEYS[i]
    local old = rawget(_G, key)
    if type(old) == "table" and not seenLegacyRuntimes[old] then
        seenLegacyRuntimes[old] = true
        quiesceLegacyRuntime(old)
    end
    _G[key] = nil
end
local runtime = {
    alive = true,
    connections = {},
    instances = {},
    cleanups = {},
    -- Declare mutable runtime fields up front. Besides making their initial
    -- state explicit, this prevents strict Luau table inference from rejecting
    -- the later panic/input assignments in executors with live diagnostics.
    panicStop = function() end,
    shutdownAsync = function() end,
    inputEpoch = 0,
    inputBackend = "unresolved",
    nativeCall = "none",
    nativeStartedAt = 0,
    nativeMaxMs = 0,
    executorName = "unknown",
    executorVersion = "unknown",
    trace = function() end,
    requestInspection = true,
    resetAppliedEpoch = -1,
    resetPending = false,
    guiWorkEnabled = false,
    windowFocused = true,
    menuOpen = false,
    typing = false,
    suspended = false,
    lastError = "",
    inputFailures = 0,
    inputBlockedUntil = 0,
    heldKeys = {},
    mouseReleaseAt = nil,
    pointerBlocked = function() return false end,
    virtualMouseHeld = false,
    virtualMousePosition = Vector2.new(1, 1),
    cleanupStarted = false,
    guiWatchDrainRunning = false,
    -- Published as protocol 2 only after the real shutdown implementation is
    -- installed near the scheduler. A mid-construction error therefore cannot
    -- make the next reinjection trust this placeholder.
    cleanupProtocol = 0,
    bootPhase = "runtime-created",
}
local function trackConnection(c)
    if c then runtime.connections[#runtime.connections + 1] = c end
    return c
end
local function trackInstance(i)
    if i then runtime.instances[#runtime.instances + 1] = i end
    return i
end
local function addCleanup(f)
    if type(f) == "function" then runtime.cleanups[#runtime.cleanups + 1] = f end
end
function runtime.unload()
    runtime.shutdownAsync()
end
_G[RUNTIME_KEY] = runtime
-- --------------------------------------------------------------------------
-- Services
-- --------------------------------------------------------------------------
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local GuiService = game:GetService("GuiService")
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    runtime.alive = false
    runtime.bootPhase = "aborted-no-local-player"
    if rawget(_G, RUNTIME_KEY) == runtime then _G[RUNTIME_KEY] = nil end
    warn("[Ink v8.8.0] LocalPlayer is unavailable; bootstrap aborted safely.")
    return
end
local PlayerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
if not PlayerGui then
    runtime.bootPhase = "waiting-player-gui"
    PlayerGui = LocalPlayer:WaitForChild("PlayerGui", 10)
end
-- The wait above yields. A reinjection may have superseded this construction
-- while it was suspended; never let that old chunk resume and create orphaned
-- UI, scheduler tasks, or input connections.
if not runtime.alive then return end
if not PlayerGui then
    runtime.alive = false
    runtime.bootPhase = "aborted-no-player-gui"
    if rawget(_G, RUNTIME_KEY) == runtime then _G[RUNTIME_KEY] = nil end
    warn("[Ink v8.8.0] PlayerGui was unavailable after 10 seconds; bootstrap aborted safely.")
    return
end
runtime.bootPhase = "services-ready"
local CONFIG = {
    enabled = {
        autoQTE = false,
        autoDalgona = false,
        autoPentathlon = false,
        autoDodge = false,
        aimAssist = false,
        rebelAim = false,
        hideSeekESP = false,
        esp = false,
    },
    inspector = {enabled = true, autoSave = true, maxNodes = 1536, budget = 32, saveInterval = 12},
    stages = {ddakji = false, flying_stone = false, gonggi = false, spinning_top = false, jegi = false},
    dalgona = {speedPxPerSecond = 90, fearPause = 0.70, fearResume = 0.35, maxPoints = 256},
    espHealth = {low = 0.30, high = 0.75},
    aim = {
        fov = 320,
        smoothness = 0.11,
        updateInterval = 0.050,
        rebelUpdateInterval = 0.075,
    },
    qte = {
        minRepeat = 0.075,
        timingTolerance = 0.16,
        sequenceDelay = 0.035,
        scanInterval = 0, -- one timing observation per scheduler frame
    },
    dodge = {
        enemyRadius = 11.5,
        triggerRadius = 7.5,
        minRepeat = 0.40,
    },
    pentathlon = {
        ddakjiTarget = "yellow", -- current guides recommend roughly the yellow power band
        timingTolerance = 0.18,
        jegiHorizontalDeadzonePx = 18,
        jegiKickHeightPx = 78,
        windingLoops = 2.20,
        balanceDeadzonePx = 5,
    },
    performance = {
        guiSliceBudget = 48,
        guiNewEventBudget = 56,
        guiNewEventQueueLimit = 1024,
        guiIndexBudget = 28,
        guiMutationBudget = 48,
        guiMutationQueueLimit = 512,
        guiMutationOverflowLimit = 4608,
        guiPriorityBudget = 48,
        guiPriorityQueueLimit = 512,
        guiIndexLimit = 4096,
        guiWatchLimit = 4608,
        guiWatchRetryBudget = 12,
        guiWatchRetryLimit = 1536,
        guiHotLimit = 240,
        guiHotTtl = 1.40,
        guiRefreshInterval = 0.045,
        textBlobInterval = 0.120,
        modeInterval = 0.750,
        modeEvidenceTtl = 1.25,
        stageEvidenceTtl = 0.85,
        statusInterval = 0.500,
        dodgeInterval = 0.110,
        espInterval = 0.300,
        worldQueryMaxParts = 64,
        guardQueryRadius = 220,
        cooldownRetention = 12,
        schedulerInterval = 0.016,
        slowWorkerMs = 12.0,
    },
    debug = false,
}
if game.PlaceId ~= TARGET_PLACE_ID then
    warn(("[Ink v8.8.0] Expected place %d, running in %d. Heuristics may not match.")
        :format(TARGET_PLACE_ID, game.PlaceId))
end
-- --------------------------------------------------------------------------
-- Utility
-- --------------------------------------------------------------------------
local function lower(v)
    return string.lower(tostring(v or ""))
end
local function containsAny(s, patterns)
    s = lower(s)
    for i = 1, #patterns do
        if string.find(s, patterns[i], 1, true) then
            return true
        end
    end
    return false
end
local function livingCharacter(player)
    local char = player and player.Character
    if not char or not char.Parent then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return nil end
    return char
end
local function livingRoot(player)
    local char = livingCharacter(player)
    return char and char:FindFirstChild("HumanoidRootPart") or nil
end
local function isActuallyVisible(obj)
    if not obj or not obj.Parent then return false end
    local cursor = obj
    while cursor do
        if cursor:IsA("GuiObject") and not cursor.Visible then return false end
        if cursor:IsA("CanvasGroup") and cursor.GroupTransparency >= 0.995 then return false end
        if cursor:IsA("LayerCollector") and cursor.Enabled == false then return false end
        cursor = cursor.Parent
    end
    return true
end
local function centerOf(obj)
    local p, s = obj.AbsolutePosition, obj.AbsoluteSize
    return Vector2.new(p.X + s.X * 0.5, p.Y + s.Y * 0.5)
end
local function rectOf(obj)
    local p, s = obj.AbsolutePosition, obj.AbsoluteSize
    return p.X, p.Y, p.X + s.X, p.Y + s.Y
end
local function pointInside(point, obj, tolerance)
    tolerance = tolerance or 0
    local x1, y1, x2, y2 = rectOf(obj)
    return point.X >= x1 - tolerance and point.X <= x2 + tolerance
       and point.Y >= y1 - tolerance and point.Y <= y2 + tolerance
end
local function pointInteractableFor(obj, point)
    if not obj or not obj.Parent or not point then return false end
    local cam = Workspace.CurrentCamera
    if cam then
        local viewport = cam.ViewportSize
        if point.X < 0 or point.Y < 0
            or point.X > viewport.X or point.Y > viewport.Y then
            return false
        end
    end
    local cursor = obj
    while cursor do
        if cursor:IsA("GuiObject") then
            if cursor.Visible == false then return false end
            if cursor.ClipsDescendants and not pointInside(point, cursor, 0) then
                return false
            end
            if cursor:IsA("CanvasGroup") and cursor.GroupTransparency >= 0.995 then
                return false
            end
        elseif cursor:IsA("LayerCollector") and cursor.Enabled == false then
            return false
        end
        cursor = cursor.Parent
    end
    return true
end
local function rgb01(c)
    return c.R, c.G, c.B
end
local function greenScore(c)
    local r, g, b = rgb01(c)
    local dominance = g - math.max(r, b)
    return dominance * 2 + g
end
local function yellowScore(c)
    local r, g, b = rgb01(c)
    return math.min(r, g) - b * 0.65 + (r + g) * 0.25
end
local function redScore(c)
    local r, g, b = rgb01(c)
    return (r - math.max(g, b)) * 2 + r
end
local function objectColor(obj)
    if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
        return obj.ImageColor3
    end
    return obj.BackgroundColor3
end
local function textOf(obj)
    if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
        return tostring(obj.Text or "")
    end
    return ""
end
local function sameGuiRegion(a, b)
    if not a or not b then return false end
    if a.Parent == b.Parent then return true end
    local pa, pb = a.Parent, b.Parent
    for _ = 1, 3 do
        if not pa then break end
        pb = b.Parent
        for _ = 1, 3 do
            if pa == pb then return true end
            pb = pb and pb.Parent
        end
        pa = pa.Parent
    end
    return false
end
-- --------------------------------------------------------------------------
-- Input driver
-- --------------------------------------------------------------------------
-- Input driver v8.8: documented VirtualInput API; never enters legacy VIM.
local VIM = nil -- compatibility name for surrounding code; never resolved as a service
local vimResolved = false
local intentionalInputWaitMs = 0
local function virtualInputManager()
    if not vimResolved then
        vimResolved = true
        local ok, result = pcall(function() return UserInputService:CreateVirtualInput() end)
        if ok and result then
            VIM = result
            runtime.inputBackend = "VirtualInput"
        else
            runtime.inputBackend = "unavailable"
            runtime.lastError = "CreateVirtualInput unavailable: " .. tostring(result)
            runtime.trace("backend-unavailable", {error = runtime.lastError})
        end
    end
    return VIM
end
function runtime.canInput()
    return runtime.alive and not runtime.resetPending and not runtime.suspended
        and runtime.windowFocused and not runtime.menuOpen and not runtime.typing
        and os.clock() >= runtime.inputBlockedUntil
        and LocalPlayer.Parent ~= nil and PlayerGui.Parent ~= nil
end
function runtime.cancelInput(reason)
    runtime.inputEpoch = runtime.inputEpoch + 1
    runtime.resetPending = true
    runtime.cancelReason = reason
    runtime.trace("cancel", {reason = reason, epoch = runtime.inputEpoch})
end
local function sendInput(method, ...)
    local backend = virtualInputManager()
    if not backend then return false end
    local args = table.pack(...)
    local start = os.clock()
    runtime.nativeCall, runtime.nativeStartedAt = method, start
    runtime.trace("input-begin", {method = method})
    local ok, result = pcall(function()
        if method == "SendKeyEvent" then
            backend:SendKey(args[1], args[2], false)
        elseif method == "SendMouseButtonEvent" then
            backend:SendMouseButton(Vector2.new(args[1], args[2]), Enum.UserInputType.MouseButton1, args[4], 0)
        elseif method == "SendMouseMoveEvent" then
            backend:SendMousePosition(Vector2.new(args[1], args[2]))
        else error("Unsupported input operation") end
    end)
    runtime.nativeMaxMs = math.max(runtime.nativeMaxMs, (os.clock() - start) * 1000)
    runtime.nativeCall = "idle"
    runtime.trace("input-end", {method = method, ok = ok})
    if not ok then
        runtime.inputFailures = runtime.inputFailures + 1
        runtime.lastError = "VirtualInput: " .. tostring(result)
        runtime.inputBlockedUntil = os.clock() + math.min(5, runtime.inputFailures * 0.5)
    end
    return ok
end
local function keyUp(code)
    local hold = runtime.heldKeys[code]
    if not hold then return true end
    runtime.heldKeys[code] = nil
    return sendInput("SendKeyEvent", false, code, false, game)
end
local function releaseVirtualMouse()
    if not runtime.virtualMouseHeld then return true end
    local p = runtime.virtualMousePosition
    runtime.virtualMouseHeld, runtime.mouseReleaseAt = false, nil
    return sendInput("SendMouseButtonEvent", p.X, p.Y, 0, false, game, 0)
end
function runtime.flushInput(force)
    local now = os.clock()
    for code, hold in pairs(runtime.heldKeys) do
        if force or hold.epoch ~= runtime.inputEpoch or now >= hold.untilAt then keyUp(code) end
    end
    if runtime.virtualMouseHeld and (force or runtime.mouseEpoch ~= runtime.inputEpoch
        or (runtime.mouseReleaseAt and now >= runtime.mouseReleaseAt)) then releaseVirtualMouse() end
end
local function keyDown(code)
    if not runtime.canInput() then return false end
    if runtime.heldKeys[code] then return true end
    if not sendInput("SendKeyEvent", true, code, false, game) then return false end
    runtime.heldKeys[code] = {epoch = runtime.inputEpoch, untilAt = math.huge}
    return true
end
local function keyTap(code, duration)
    if not runtime.canInput() or runtime.heldKeys[code] then return false end
    if not keyDown(code) then return false end
    runtime.heldKeys[code].untilAt = os.clock() + math.clamp(duration or .018, .012, .2)
    return true
end
local function mouseClick(position)
    if not runtime.canInput() or runtime.virtualMouseHeld then return false end
    local cam = Workspace.CurrentCamera
    local p = position or (cam and cam.ViewportSize / 2)
    if not p or runtime.pointerBlocked(p) then return false end
    if not sendInput("SendMouseButtonEvent", p.X, p.Y, 0, true, game, 0) then return false end
    runtime.virtualMousePosition, runtime.virtualMouseHeld = p, true
    runtime.mouseEpoch, runtime.mouseReleaseAt = runtime.inputEpoch, os.clock() + .018
    return true
end
local function clickGuiButton(button)
    if not button or not button:IsA("GuiButton") or not button.Active or not isActuallyVisible(button) then return false end
    local p = centerOf(button)
    return pointInteractableFor(button, p) and mouseClick(p)
end
local function trackedInputWait(seconds)
    local started = os.clock()
    task.wait(seconds)
    intentionalInputWaitMs = intentionalInputWaitMs + (os.clock() - started) * 1000
end
local function dragCircle(center, radius, loops, pointsPerLoop, shouldContinue)
    if not runtime.canInput() or runtime.virtualMouseHeld then return false end
    local epoch = runtime.inputEpoch
    local count = math.clamp(math.floor((pointsPerLoop or 24) * (loops or 2)), 8, 160)
    local start = center + Vector2.new(radius, 0)
    if runtime.pointerBlocked(start) then return false end
    if not sendInput("SendMouseMoveEvent", start.X, start.Y, game) or not mouseClick(start) then return false end
    runtime.mouseReleaseAt = nil
    local completed = true
    for i = 1, count do
        if epoch ~= runtime.inputEpoch or not runtime.canInput() or (shouldContinue and not shouldContinue()) then completed = false; break end
        local angle = i / (pointsPerLoop or 24) * math.pi * 2
        local p = center + Vector2.new(math.cos(angle), math.sin(angle)) * radius
        if runtime.pointerBlocked(p) then completed = false; break end
        runtime.virtualMousePosition = p
        if not sendInput("SendMouseMoveEvent", p.X, p.Y, game) then completed = false; break end
        trackedInputWait(.016)
    end
    if runtime.mouseEpoch == epoch then releaseVirtualMouse() end
    return completed
end
addCleanup(function() runtime.flushInput(true) end)
-- Incremental GUI index
-- Incremental GUI index
-- --------------------------------------------------------------------------
-- SAFERCORE: event-driven wakeups + strict bounded fallback scanning.
-- No hot worker walks the complete PlayerGui tree.
local guiSet = setmetatable({}, {__mode = "k"})
local guiList = {}
local guiCursor = 1
local guiReplaceCursor = 1
local guiIndexStarted = false
local guiIndexBuilding = false
local guiIndexCompletionReported = false
-- Initial discovery has its own bounded queue. There is no second concurrent
-- breadth-first worker anymore: one scheduler epoch owns all GUI work.
local indexQueue = {}
local indexHead = 1
local indexTail = 0
local indexSet = setmetatable({}, {__mode = "k"})
-- DescendantAdded callbacks only enqueue here. New UI receives priority over
-- background indexing without attaching watchers inside the Roblox event stack.
local newGuiQueue = {}
local newGuiHead = 1
local newGuiTail = 0
local newGuiSet = setmetatable({}, {__mode = "k"})
local newGuiOverflow = false
-- Property watchers only enqueue mutations. They never perform subtree walks or
-- solver work inside Roblox property callbacks.
local guiWatch = setmetatable({}, {__mode = "k"})
local guiWatchCount = 0
local watchRetryQueue = {}
local watchRetryHead = 1
local watchRetryTail = 0
local watchRetrySet = setmetatable({}, {__mode = "k"})
local watchRetryOverflow = false
local mutationQueue = {}
local mutationHead = 1
local mutationTail = 0
local mutationState = setmetatable({}, {__mode = "k"})
local mutationOverflowQueue = {}
local mutationOverflowHead = 1
local mutationOverflowTail = 0
local mutationOverflowState = setmetatable({}, {__mode = "k"})
local mutationOverflowLatched = false
local promptGeneration = setmetatable({}, {__mode = "k"})
local subtreeGeneration = setmetatable({}, {__mode = "k"})
local canvasHiddenState = setmetatable({}, {__mode = "k"})
-- Pump budgets are maximum work per scheduler epoch, not per visibleObjects()
-- invocation. This guard prevents scheduler -> solver -> visibleObjects re-pump.
local schedulerEpoch = 0
local lastGuiPumpEpoch = -1
local guiStats = {
    indexedTotal = 0,
    watchersPeak = 0,
    mutationPeak = 0,
    priorityPeak = 0,
    indexPeak = 0,
    newGuiPeak = 0,
    newGuiOverflowCount = 0,
    processedThisTick = 0,
    processedPeak = 0,
    startupWorkerMaxMs = 0,
    repeatedContainerEnqueue = 0,
    mutationOverflowCount = 0,
    mutationOverflowPeak = 0,
    mutationScalarFallbackCount = 0,
    priorityOverflowCount = 0,
    watchRetryPeak = 0,
    queueGrowthStreak = 0,
    queueGrowthStreakPeak = 0,
    lastQueueTotal = 0,
    childSnapshotPeakMs = 0,
    childSnapshotPeakSize = 0,
    childSnapshotSlowCount = 0,
}
-- v8.8.0: semantic identity is deliberately insensitive to dynamic numeric
-- timer/counter text. Example: "Press Q - 1.0" and "Press Q - 0.9"
-- both resolve to "key:q". A real action change such as
-- Q -> E still produces a different identity and re-arms the prompt.
local promptSemantic = setmetatable({}, {__mode = "k"})
local promptSemanticDirty = setmetatable({}, {__mode = "k"})
local function semanticPromptText(text)
    local value = lower(text)
    value = value:gsub("–", "-"):gsub("—", "-")
    -- Key prompts are identified by the action itself, not by a timer/counter
    -- rendered in the same label.
    value = value:gsub("<[^>]->", "")
    local key = value:match("^press%s+([a-z]+)")
    if key and (key == "space" or key:match("^[qertfwasdzxcv]$")) then
        return "key:" .. key
    end
    if value:find("press space", 1, true) or value:find("jump", 1, true) then
        return "key:space"
    end
    -- Gonggi owns numeric-sequence identity separately. Keeping this semantic
    -- identity constant avoids fighting sequenceState/promptGeneration.
    local digits = value:gsub("%D", "")
    local nonNumericContent = value:gsub("[%d%s%p]", "")
    if #digits >= 3 and nonNumericContent == "" then
        return "digit-sequence"
    end
    -- Mask actual timer/counter forms while preserving meaningful integers in
    -- ordinary labels (e.g. different numbered actions/options).
    value = value:gsub("%d+%s*:%s*%d+", " # ")
    value = value:gsub("%d+[.,]%d+", " # ")
    value = value:gsub("%d+%s*/%s*%d+", " # ")
    if containsAny(value, {"press", "tap", "hit", "pull", "qte", "action", "perfect"}) then
        -- Strip only recognizable countdown suffixes. A bare trailing integer is
        -- semantic ("Action 1" -> "Action 2") and must remain in the identity.
        value = value:gsub("%s*[|%-]%s*%d+%s*[sm]?[s]?%s*$", "")
        value = value:gsub("%s+%d+%s*[sm][s]?%s*$", "")
    end
    value = value:gsub("[%[%]%(%){}<>:;,.!?_/%-]", " ")
    value = value:gsub("\\", " ")
    value = value:gsub("%s+", " ")
    return value:match("^%s*(.-)%s*$") or value
end
local function semanticPromptIdentity(obj)
    if obj and (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) then
        return semanticPromptText(textOf(obj))
    end
    return ""
end
local hotSet = setmetatable({}, {__mode = "k"})
local hotSeenAt = setmetatable({}, {__mode = "k"})
local hotList = {}
local hotReplaceCursor = 1
-- A visibility/enabled event on a container wakes only that subtree. Entries
-- retain their child-array cursor, so even a very large container is processed
-- over multiple ticks instead of in one client-blocking burst.
local priorityQueue = {}
local priorityHead = 1
local priorityTail = 0
local prioritySet = setmetatable({}, {__mode = "k"})
local priorityRecoveryNeeded = false
local visibleCache = {}
local visibleCacheAt = -math.huge
local textBlobCache = ""
local textBlobCacheAt = -math.huge
local LEGACY_GUI_NAMES = {
    [GUI_NAME] = true,
    ["InkUltimate_v77_UI"] = true,
    ["InkUltimate_v78_UI"] = true,
    ["InkUltimate_v79_UI"] = true,
    ["InkUltimate_v80_UI"] = true,
    ["InkUltimate_v81_UI"] = true,
    ["InkUltimate_v82_UI"] = true,
    ["InkUltimate_v83_UI"] = true,
    ["InkUltimate_v84_UI"] = true,
    ["InkUltimate_v85_UI"] = true,
}
local function isOwnGuiObject(obj)
    if not obj then return false end
    if obj:IsA("ScreenGui") and LEGACY_GUI_NAMES[obj.Name] == true then
        return true
    end
    local screenAncestor = obj:FindFirstAncestorOfClass("ScreenGui")
    return screenAncestor and LEGACY_GUI_NAMES[screenAncestor.Name] == true
end
local function relevantGuiClass(obj)
    return obj:IsA("GuiButton")
        or obj:IsA("TextLabel")
        or obj:IsA("TextBox")
        or obj:IsA("ImageLabel")
        or obj:IsA("Frame")
        or obj:IsA("ScrollingFrame")
        or obj:IsA("ViewportFrame")
        or obj:IsA("CanvasGroup")
end
local function isPriorityContainer(obj)
    return obj:IsA("LayerCollector")
        or obj:IsA("Frame")
        or obj:IsA("ScrollingFrame")
        or obj:IsA("ViewportFrame")
        or obj:IsA("CanvasGroup")
end
local function invalidateGuiCaches()
    visibleCacheAt = -math.huge
    textBlobCacheAt = -math.huge
end
local function likelyHotCandidate(obj)
    -- AbsoluteSize and color properties only exist on GuiObjects. This helper is
    -- deliberately total for arbitrary PlayerGui descendants.
    if not obj or not obj:IsA("GuiObject") or not obj.Parent or isOwnGuiObject(obj) then
        return false
    end
    if obj:IsA("GuiButton")
        or obj:IsA("TextLabel")
        or obj:IsA("TextBox") then
        return true
    end
    local size = obj.AbsoluteSize
    if size.X <= 0 or size.Y <= 0 then return false end
    local lname = lower(obj.Name)
    if containsAny(lname, {
        "qte", "prompt", "press", "tap", "hit", "action",
        "needle", "marker", "arrow", "cursor", "pointer",
        "target", "perfect", "success", "green", "yellow",
        "ddakji", "gonggi", "jegi", "paengi", "spin", "wind",
        "biseok", "stone", "dodge", "balance",
        "dalgona", "honeycomb", "cookie", "tracepoint", "checkpoint", "fear", "ring", "circle",
    }) then
        return true
    end
    local slender = (size.X <= 24 and size.Y >= 20)
        or (size.Y <= 24 and size.X >= 20)
    if slender then return true end
    if obj:IsA("Frame") or obj:IsA("ImageLabel") then
        local c = objectColor(obj)
        if greenScore(c) > 0.72 or yellowScore(c) > 0.72 then
            return true
        end
    end
    return false
end
local function markHot(obj, now)
    if not likelyHotCandidate(obj) then return end
    now = now or os.clock()
    hotSeenAt[obj] = now
    if hotSet[obj] then return end
    local limit = CONFIG.performance.guiHotLimit
    if #hotList < limit then
        hotList[#hotList + 1] = obj
        hotSet[obj] = true
        return
    end
    if hotReplaceCursor > #hotList then
        hotReplaceCursor = 1
    end
    local old = hotList[hotReplaceCursor]
    if old then
        hotSet[old] = nil
        hotSeenAt[old] = nil
    end
    hotList[hotReplaceCursor] = obj
    hotSet[obj] = true
    hotReplaceCursor = hotReplaceCursor + 1
end
local function resetMutationQueueIfEmpty()
    if mutationHead > mutationTail then
        table.clear(mutationQueue)
        mutationHead = 1
        mutationTail = 0
    end
end
local function resetMutationOverflowQueueIfEmpty()
    if mutationOverflowHead > mutationOverflowTail then
        table.clear(mutationOverflowQueue)
        mutationOverflowHead = 1
        mutationOverflowTail = 0
    end
end
local function newMutationState(
    expandSubtree,
    rearmPrompt,
    semanticCheck,
    subtreeRearm,
    overflowRecovery
)
    return {
        expand = expandSubtree == true,
        rearm = rearmPrompt and 1 or 0,
        semantic = semanticCheck == true,
        subtree = subtreeRearm and 1 or 0,
        overflow = overflowRecovery == true,
        semanticLoss = overflowRecovery == true and semanticCheck == true,
    }
end
local function mergeMutationState(state, expandSubtree, rearmPrompt, semanticCheck, subtreeRearm)
    if expandSubtree then state.expand = true end
    if rearmPrompt then state.rearm = state.rearm + 1 end
    if semanticCheck then
        state.semantic = true
        if state.overflow then state.semanticLoss = true end
    end
    if subtreeRearm then state.subtree = state.subtree + 1 end
end
local function applyMutationIdentity(
    obj,
    rearmCount,
    semanticCheck,
    subtreeCount,
    semanticLoss
)
    if semanticCheck then
        local nextSemantic = semanticPromptIdentity(obj)
        local previousSemantic = promptSemantic[obj]
        if promptSemanticDirty[obj] then
            -- The hard-cap scalar fallback already advanced this object's local
            -- generation. Reconcile its semantic baseline without advancing it
            -- a second time when normal queued processing resumes.
            promptSemanticDirty[obj] = nil
            promptSemantic[obj] = nextSemantic
        elseif previousSemantic == nil then
            promptSemantic[obj] = nextSemantic
        elseif previousSemantic ~= nextSemantic then
            promptSemantic[obj] = nextSemantic
            if not semanticLoss then
                rearmCount = rearmCount + 1
            end
        end
        if semanticLoss then
            -- Final-state comparison alone cannot observe a fast semantic ABA.
            -- Conservatively re-arm this object once per overflow-dirty batch.
            rearmCount = rearmCount + 1
        end
    end
    if rearmCount > 0 then
        promptGeneration[obj] = (promptGeneration[obj] or 0) + rearmCount
    end
    if subtreeCount > 0 then
        subtreeGeneration[obj] = (subtreeGeneration[obj] or 0) + subtreeCount
    end
end
local function queueGuiMutation(obj, expandSubtree, rearmPrompt, semanticCheck, subtreeRearm)
    -- Callback path: parent check, table lookups, scalar merges, and enqueue only.
    -- All semantic parsing, ancestry/visibility checks, and hot-set work happens
    -- later under processGuiMutations()' shared scheduler budget.
    if not runtime.alive or not runtime.guiWorkEnabled or not obj or not obj.Parent then
        return
    end
    local existing = mutationState[obj]
    if existing then
        mergeMutationState(existing, expandSubtree, rearmPrompt, semanticCheck, subtreeRearm)
        return
    end
    local overflowExisting = mutationOverflowState[obj]
    if overflowExisting then
        mergeMutationState(overflowExisting, expandSubtree, rearmPrompt, semanticCheck, subtreeRearm)
        return
    end
    local queued = mutationTail - mutationHead + 1
    if queued >= CONFIG.performance.guiMutationQueueLimit then
        if not mutationOverflowLatched then
            mutationOverflowLatched = true
            guiStats.mutationOverflowCount = guiStats.mutationOverflowCount + 1
        end
        local overflowQueued = mutationOverflowTail - mutationOverflowHead + 1
        if overflowQueued >= CONFIG.performance.guiMutationOverflowLimit then
            -- Absolute memory bound for pathological create/destroy churn. This
            -- fallback touches scalars only: it conservatively advances local
            -- identity and asks the bounded priority scanner for final state.
            if rearmPrompt then
                promptGeneration[obj] = (promptGeneration[obj] or 0) + 1
            end
            if semanticCheck and not promptSemanticDirty[obj] then
                promptSemanticDirty[obj] = true
                promptGeneration[obj] = (promptGeneration[obj] or 0) + 1
            end
            if subtreeRearm then
                subtreeGeneration[obj] = (subtreeGeneration[obj] or 0) + 1
            end
            priorityRecoveryNeeded = true
            guiStats.mutationScalarFallbackCount =
                guiStats.mutationScalarFallbackCount + 1
            return
        end
        local state = newMutationState(
            expandSubtree,
            rearmPrompt,
            semanticCheck,
            subtreeRearm,
            true
        )
        mutationOverflowState[obj] = state
        mutationOverflowTail = mutationOverflowTail + 1
        mutationOverflowQueue[mutationOverflowTail] = obj
        overflowQueued = mutationOverflowTail - mutationOverflowHead + 1
        if overflowQueued > guiStats.mutationOverflowPeak then
            guiStats.mutationOverflowPeak = overflowQueued
        end
        return
    end
    local state = newMutationState(
        expandSubtree,
        rearmPrompt,
        semanticCheck,
        subtreeRearm
    )
    mutationState[obj] = state
    mutationTail = mutationTail + 1
    mutationQueue[mutationTail] = obj
    queued = mutationTail - mutationHead + 1
    if queued > guiStats.mutationPeak then
        guiStats.mutationPeak = queued
    end
end
local function resetPriorityQueueIfEmpty()
    if priorityHead > priorityTail then
        table.clear(priorityQueue)
        priorityHead = 1
        priorityTail = 0
    end
end
local function enqueuePriority(obj)
    if not obj or not obj.Parent or isOwnGuiObject(obj) then
        return false
    end
    if prioritySet[obj] then
        guiStats.repeatedContainerEnqueue = guiStats.repeatedContainerEnqueue + 1
        return false
    end
    local queued = priorityTail - priorityHead + 1
    if queued >= CONFIG.performance.guiPriorityQueueLimit then
        guiStats.priorityOverflowCount = guiStats.priorityOverflowCount + 1
        priorityRecoveryNeeded = true
        return false
    end
    prioritySet[obj] = true
    priorityTail = priorityTail + 1
    priorityQueue[priorityTail] = {
        obj = obj,
        initialized = false,
        children = nil,
        childIndex = 1,
    }
    queued = priorityTail - priorityHead + 1
    if queued > guiStats.priorityPeak then
        guiStats.priorityPeak = queued
    end
    return true
end
local function resetIndexQueueIfEmpty()
    if indexHead > indexTail then
        table.clear(indexQueue)
        indexHead = 1
        indexTail = 0
    end
end
local function enqueueIndex(obj)
    if not obj or not obj.Parent or isOwnGuiObject(obj) or indexSet[obj] then
        return
    end
    indexSet[obj] = true
    guiIndexBuilding = true
    indexTail = indexTail + 1
    indexQueue[indexTail] = {
        obj = obj,
        initialized = false,
        children = nil,
        childIndex = 1,
    }
    local queued = indexTail - indexHead + 1
    if queued > guiStats.indexPeak then
        guiStats.indexPeak = queued
    end
end
local F = {}
F.toggleRenders = {}
F.stageRenders = {}
function F.anyPentathlonEnabled()
    if CONFIG.enabled.autoPentathlon then return true end
    for _, enabled in pairs(CONFIG.stages) do if enabled then return true end end
    return false
end
function F.stageEnabled(stage)
    return CONFIG.stages[stage] ~= nil and (CONFIG.enabled.autoPentathlon or CONFIG.stages[stage])
end
function F.setFeature(field, enabled)
    if CONFIG.enabled[field] == nil or not runtime.alive then return false end
    CONFIG.enabled[field] = enabled == true
    runtime.cancelInput("toggle:" .. field)
    -- Remaining resynchronization belongs to the scheduler, never this callback.
    runtime.guiWorkEnabled = false
    local render = F.toggleRenders[field]
    if render then render() end
    if field == "autoPentathlon" then
        for _, redraw in pairs(F.stageRenders) do redraw() end
    end
    return true
end
function F.stopAll()
    for field in pairs(CONFIG.enabled) do CONFIG.enabled[field] = false end
    for stage in pairs(CONFIG.stages) do CONFIG.stages[stage] = false end
    runtime.cancelInput("stop-all")
    runtime.guiWorkEnabled = false
    for _, render in pairs(F.toggleRenders) do render() end
    for _, render in pairs(F.stageRenders) do render() end
end
runtime.setFeature = F.setFeature
runtime.stopAll = F.stopAll

function F.queueNewGuiEvent(obj)
    if not runtime.alive or not runtime.guiWorkEnabled or not obj then return end
    if newGuiSet[obj] then return end
    local queued = newGuiTail - newGuiHead + 1
    if queued >= CONFIG.performance.guiNewEventQueueLimit then
        if not newGuiOverflow then
            newGuiOverflow = true
            guiStats.newGuiOverflowCount = guiStats.newGuiOverflowCount + 1
        end
        return
    end
    newGuiSet[obj] = true
    newGuiTail = newGuiTail + 1
    newGuiQueue[newGuiTail] = obj
    queued = newGuiTail - newGuiHead + 1
    if queued > guiStats.newGuiPeak then
        guiStats.newGuiPeak = queued
    end
end
function F.disconnectGuiWatch(obj)
    local bundle = guiWatch[obj]
    if not bundle then return end
    guiWatch[obj] = nil
    guiWatchCount = math.max(0, guiWatchCount - 1)
    for i = 1, #bundle do
        pcall(function()
            bundle[i]:Disconnect()
        end)
    end
end
function F.enqueueWatchRetry(obj)
    if not obj or not obj.Parent or isOwnGuiObject(obj)
        or guiWatch[obj] or watchRetrySet[obj] then
        return
    end
    local queued = watchRetryTail - watchRetryHead + 1
    if queued >= CONFIG.performance.guiWatchRetryLimit then
        watchRetryOverflow = true
        return
    end
    watchRetrySet[obj] = true
    watchRetryTail = watchRetryTail + 1
    watchRetryQueue[watchRetryTail] = obj
    queued = watchRetryTail - watchRetryHead + 1
    if queued > guiStats.watchRetryPeak then
        guiStats.watchRetryPeak = queued
    end
end
function F.onGuiMutation(
    obj,
    expandSubtree,
    rearmPrompt,
    semanticCheck,
    subtreeRearm,
    semanticLoss
)
    if not runtime.alive or not runtime.guiWorkEnabled or not obj or not obj.Parent or isOwnGuiObject(obj) then return end
    invalidateGuiCaches()
    -- A parent visibility/enabled epoch participates in descendant signatures.
    -- Descendants are re-armed logically without walking every child.
    applyMutationIdentity(
        obj,
        rearmPrompt,
        semanticCheck,
        subtreeRearm,
        semanticLoss
    )
    if obj:IsA("LayerCollector") then
        if obj.Enabled ~= false then
            enqueuePriority(obj)
        end
        return
    end
    if not relevantGuiClass(obj) then return end
    local size = obj.AbsoluteSize
    if size.X > 0 and size.Y > 0 and isActuallyVisible(obj) then
        markHot(obj)
        if expandSubtree then
            enqueuePriority(obj)
        end
    else
        hotSet[obj] = nil
        hotSeenAt[obj] = nil
    end
end
function F.processGuiMutations()
    local budget = CONFIG.performance.guiMutationBudget
    local processed = 0
    -- Reserve half the tick for overflow-dirty objects so neither queue can
    -- starve the other. These entries carry only merged scalar flags/counters;
    -- all object inspection begins here, inside the scheduler budget.
    local overflowShare = math.max(1, math.floor(budget * 0.5))
    while runtime.alive
        and processed < overflowShare
        and mutationOverflowHead <= mutationOverflowTail do
        local obj = mutationOverflowQueue[mutationOverflowHead]
        mutationOverflowQueue[mutationOverflowHead] = nil
        mutationOverflowHead = mutationOverflowHead + 1
        processed = processed + 1
        if obj then
            local state = mutationOverflowState[obj]
            mutationOverflowState[obj] = nil
            if state then
                F.onGuiMutation(
                    obj,
                    state.expand,
                    state.rearm,
                    state.semantic,
                    state.subtree,
                    state.semanticLoss
                )
            end
        end
    end
    while runtime.alive and processed < budget and mutationHead <= mutationTail do
        local obj = mutationQueue[mutationHead]
        mutationQueue[mutationHead] = nil
        mutationHead = mutationHead + 1
        processed = processed + 1
        if obj then
            local state = mutationState[obj]
            mutationState[obj] = nil
            if state then
                F.onGuiMutation(
                    obj,
                    state.expand,
                    state.rearm,
                    state.semantic,
                    state.subtree,
                    state.semanticLoss
                )
            end
        end
    end
    -- If the normal queue had less than its share, spend the remaining budget on
    -- overflow recovery rather than leaving capacity idle.
    while runtime.alive
        and processed < budget
        and mutationOverflowHead <= mutationOverflowTail do
        local obj = mutationOverflowQueue[mutationOverflowHead]
        mutationOverflowQueue[mutationOverflowHead] = nil
        mutationOverflowHead = mutationOverflowHead + 1
        processed = processed + 1
        if obj then
            local state = mutationOverflowState[obj]
            mutationOverflowState[obj] = nil
            if state then
                F.onGuiMutation(
                    obj,
                    state.expand,
                    state.rearm,
                    state.semantic,
                    state.subtree,
                    state.semanticLoss
                )
            end
        end
    end
    local queued = math.max(0, mutationTail - mutationHead + 1)
        + math.max(0, mutationOverflowTail - mutationOverflowHead + 1)
    if mutationOverflowLatched
        and queued <= math.floor(CONFIG.performance.guiMutationQueueLimit * 0.25) then
        mutationOverflowLatched = false
    end
    resetMutationQueueIfEmpty()
    resetMutationOverflowQueueIfEmpty()
    return processed
end
function F.watchGuiObject(obj)
    if not obj or guiWatch[obj] or isOwnGuiObject(obj) then return end
    if guiWatchCount >= CONFIG.performance.guiWatchLimit then
        F.enqueueWatchRetry(obj)
        return
    end
    local bundle = {}
    if obj:IsA("LayerCollector") then
        bundle[#bundle + 1] = obj:GetPropertyChangedSignal("Enabled"):Connect(function()
            queueGuiMutation(obj, true, false, false, true)
        end)
    elseif relevantGuiClass(obj) then
        local rearmDescendantsOnVisible = isPriorityContainer(obj)
        bundle[#bundle + 1] = obj:GetPropertyChangedSignal("Visible"):Connect(function()
            queueGuiMutation(
                obj,
                true,
                true,
                false,
                rearmDescendantsOnVisible
            )
        end)
        if obj:IsA("CanvasGroup") then
            canvasHiddenState[obj] = obj.GroupTransparency >= 0.995
            bundle[#bundle + 1] = obj:GetPropertyChangedSignal("GroupTransparency"):Connect(function()
                local hidden = obj.GroupTransparency >= 0.995
                if canvasHiddenState[obj] ~= hidden then
                    canvasHiddenState[obj] = hidden
                    queueGuiMutation(obj, true, true, false, true)
                end
            end)
        end
        -- Text changes are semantic-checked later. Timer/counter animation alone
        -- therefore does not create a new action identity.
        if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
            promptSemantic[obj] = semanticPromptIdentity(obj)
            bundle[#bundle + 1] = obj:GetPropertyChangedSignal("Text"):Connect(function()
                queueGuiMutation(obj, false, false, true, false)
            end)
        end
        if obj:IsA("GuiButton") then
            bundle[#bundle + 1] = obj:GetPropertyChangedSignal("Active"):Connect(function()
                queueGuiMutation(obj, false, true, false, false)
            end)
        end
        if obj:IsA("ImageButton") then
            bundle[#bundle + 1] = obj:GetPropertyChangedSignal("Image"):Connect(function()
                queueGuiMutation(obj, false, true, false, false)
            end)
        end
    else
        return
    end
    guiWatch[obj] = bundle
    watchRetrySet[obj] = nil
    guiWatchCount = guiWatchCount + 1
    if guiWatchCount > guiStats.watchersPeak then
        guiStats.watchersPeak = guiWatchCount
    end
end
function F.processWatchRetries()
    if guiWatchCount >= CONFIG.performance.guiWatchLimit then
        return 0
    end
    local budget = CONFIG.performance.guiWatchRetryBudget
    local processed = 0
    while runtime.alive
        and processed < budget
        and watchRetryHead <= watchRetryTail
        and guiWatchCount < CONFIG.performance.guiWatchLimit do
        local obj = watchRetryQueue[watchRetryHead]
        watchRetryQueue[watchRetryHead] = nil
        watchRetryHead = watchRetryHead + 1
        processed = processed + 1
        if obj then
            watchRetrySet[obj] = nil
            if obj.Parent and not guiWatch[obj] and not isOwnGuiObject(obj) then
                F.watchGuiObject(obj)
            end
        end
    end
    if watchRetryHead > watchRetryTail then
        table.clear(watchRetryQueue)
        watchRetryHead = 1
        watchRetryTail = 0
        -- If the bounded retry queue ever overflowed, restart one incremental
        -- discovery pass after capacity becomes available. Nothing is lost
        -- permanently just because watcher pressure was temporarily high.
        if watchRetryOverflow and guiWatchCount < CONFIG.performance.guiWatchLimit then
            watchRetryOverflow = false
            enqueueIndex(PlayerGui)
        end
    end
    return processed
end
function F.addGuiObject(obj, fromEvent)
    if not obj or isOwnGuiObject(obj) then return end
    if obj:IsA("LayerCollector") then
        if not guiSet[obj] then
            guiSet[obj] = true
            guiStats.indexedTotal = guiStats.indexedTotal + 1
        end
        F.watchGuiObject(obj)
        if fromEvent then
            enqueueIndex(obj)
            if obj.Enabled ~= false then
                enqueuePriority(obj)
            end
        end
        return
    end
    if not relevantGuiClass(obj) then return end
    if guiSet[obj] then
        if not guiWatch[obj] then
            F.watchGuiObject(obj)
        end
        if fromEvent then
            markHot(obj)
        end
        return
    end
    guiSet[obj] = true
    guiStats.indexedTotal = guiStats.indexedTotal + 1
    F.watchGuiObject(obj)
    -- guiList is only the bounded fallback scan ring. Evicting from this ring
    -- must NOT discard live tracking or disconnect the event watcher.
    local indexLimit = CONFIG.performance.guiIndexLimit
    if #guiList < indexLimit then
        guiList[#guiList + 1] = obj
    else
        if guiReplaceCursor > #guiList then
            guiReplaceCursor = 1
        end
        guiList[guiReplaceCursor] = obj
        guiReplaceCursor = guiReplaceCursor + 1
    end
    if fromEvent then
        -- Classification runs here under processNewGuiEvents()' budget, never
        -- inside DescendantAdded. markHot performs the classifier exactly once.
        markHot(obj)
        if isPriorityContainer(obj) then
            enqueueIndex(obj)
            enqueuePriority(obj)
        end
    end
end
function F.processNewGuiEvents()
    local budget = CONFIG.performance.guiNewEventBudget
    local processed = 0
    while runtime.alive and processed < budget and newGuiHead <= newGuiTail do
        local obj = newGuiQueue[newGuiHead]
        newGuiQueue[newGuiHead] = nil
        newGuiHead = newGuiHead + 1
        processed = processed + 1
        if obj then
            newGuiSet[obj] = nil
            if obj.Parent then
                F.addGuiObject(obj, true)
            end
        end
    end
    if newGuiHead > newGuiTail then
        table.clear(newGuiQueue)
        newGuiHead = 1
        newGuiTail = 0
        if newGuiOverflow then
            newGuiOverflow = false
            enqueueIndex(PlayerGui)
        end
    end
    return processed
end
function F.removeGuiObject(obj)
    guiSet[obj] = nil
    hotSet[obj] = nil
    hotSeenAt[obj] = nil
    mutationState[obj] = nil
    mutationOverflowState[obj] = nil
    prioritySet[obj] = nil
    indexSet[obj] = nil
    watchRetrySet[obj] = nil
    promptGeneration[obj] = nil
    promptSemantic[obj] = nil
    promptSemanticDirty[obj] = nil
    subtreeGeneration[obj] = nil
    canvasHiddenState[obj] = nil
    F.disconnectGuiWatch(obj)
    invalidateGuiCaches()
end
function F.ensureGuiIndexing()
    if guiIndexStarted or not PlayerGui then return end
    guiIndexStarted = true
    guiIndexBuilding = true
    guiIndexCompletionReported = false
    -- Startup does constant work only: connect two root events and enqueue one
    -- incremental discovery root. No synchronous hierarchy traversal.
    trackConnection(PlayerGui.DescendantAdded:Connect(function(obj)
        F.queueNewGuiEvent(obj)
    end))
    trackConnection(PlayerGui.DescendantRemoving:Connect(F.removeGuiObject))
    enqueueIndex(PlayerGui)
end
function runtime.snapshotGuiChildren(obj)
    local started = os.clock()
    local ok, children = pcall(function()
        return obj:GetChildren()
    end)
    local elapsedMs = (os.clock() - started) * 1000
    if elapsedMs > guiStats.childSnapshotPeakMs then
        guiStats.childSnapshotPeakMs = elapsedMs
    end
    if not ok or type(children) ~= "table" then
        if CONFIG.debug then
            warn("[Ink v8.8.0] GetChildren snapshot failed:", children)
        end
        return {}
    end
    if #children > guiStats.childSnapshotPeakSize then
        guiStats.childSnapshotPeakSize = #children
    end
    if elapsedMs >= CONFIG.performance.slowWorkerMs then
        guiStats.childSnapshotSlowCount = guiStats.childSnapshotSlowCount + 1
        if CONFIG.debug then
            warn(("[Ink v8.8.0] slow GetChildren snapshot: %.2fms (%d children)")
                :format(elapsedMs, #children))
        end
    end
    return children
end
function F.finishIndexEntry(entry)
    local obj = entry and entry.obj
    if obj then indexSet[obj] = nil end
    indexQueue[indexHead] = nil
    indexHead = indexHead + 1
end
function F.processIndexQueue()
    local budget = CONFIG.performance.guiIndexBudget
    local processed = 0
    local started = os.clock()
    while runtime.alive and processed < budget and indexHead <= indexTail do
        processed = processed + 1
        local entry = indexQueue[indexHead]
        if not entry then
            indexHead = indexHead + 1
        else
            local obj = entry.obj
            if not obj or not obj.Parent or isOwnGuiObject(obj) then
                F.finishIndexEntry(entry)
            else
                if not entry.initialized then
                    entry.initialized = true
                    F.addGuiObject(obj, false)
                    processed = processed + 1
                    -- GetChildren is one direct-container snapshot only. Its
                    -- descendants are consumed over future scheduler epochs.
                    entry.children = runtime.snapshotGuiChildren(obj)
                    entry.childIndex = 1
                end
                local children = entry.children or {}
                while processed < budget and entry.childIndex <= #children do
                    local child = children[entry.childIndex]
                    entry.childIndex = entry.childIndex + 1
                    processed = processed + 1
                    if child and child.Parent and not isOwnGuiObject(child) then
                        F.addGuiObject(child, false)
                        if child:IsA("GuiObject")
                            or child:IsA("LayerCollector")
                            or child:IsA("Folder") then
                            enqueueIndex(child)
                        end
                    end
                end
                if entry.childIndex > #children then
                    entry.children = nil
                    F.finishIndexEntry(entry)
                elseif processed >= budget then
                    break
                end
            end
        end
    end
    resetIndexQueueIfEmpty()
    local elapsedMs = (os.clock() - started) * 1000
    if elapsedMs > guiStats.startupWorkerMaxMs then
        guiStats.startupWorkerMaxMs = elapsedMs
    end
    if indexHead > indexTail then
        guiIndexBuilding = false
        if not guiIndexCompletionReported then
            guiIndexCompletionReported = true
            print(("[Ink v8.8.0] GUI index complete | indexed=%d watchers=%d " ..
                "queues(new/mut/pri)=%d/%d/%d maxIndexWorker=%.2fms growthPeak=%d")
                :format(
                    guiStats.indexedTotal,
                    guiWatchCount,
                    math.max(0, newGuiTail - newGuiHead + 1),
                    math.max(0, mutationTail - mutationHead + 1)
                        + math.max(0, mutationOverflowTail - mutationOverflowHead + 1),
                    math.max(0, priorityTail - priorityHead + 1),
                    guiStats.startupWorkerMaxMs,
                    guiStats.queueGrowthStreakPeak
                ))
        end
    end
    return processed
end
function F.finishPriorityEntry(entry)
    local obj = entry and entry.obj
    if obj then prioritySet[obj] = nil end
    priorityQueue[priorityHead] = nil
    priorityHead = priorityHead + 1
end
function F.processPriorityQueue()
    local budget = CONFIG.performance.guiPriorityBudget
    local processed = 0
    while runtime.alive and processed < budget and priorityHead <= priorityTail do
        processed = processed + 1
        local entry = priorityQueue[priorityHead]
        if not entry then
            priorityHead = priorityHead + 1
        else
            local obj = entry.obj
            if not obj or not obj.Parent or isOwnGuiObject(obj) then
                F.finishPriorityEntry(entry)
            else
                if not entry.initialized then
                    entry.initialized = true
                    F.addGuiObject(obj, false)
                    processed = processed + 1
                    local canExpand = true
                    if obj:IsA("LayerCollector") then
                        canExpand = obj.Enabled ~= false
                    elseif obj:IsA("GuiObject") then
                        canExpand = obj.Visible ~= false
                    end
                    if canExpand then
                        entry.children = runtime.snapshotGuiChildren(obj)
                        entry.childIndex = 1
                    else
                        entry.children = {}
                    end
                end
                local children = entry.children or {}
                while processed < budget and entry.childIndex <= #children do
                    local child = children[entry.childIndex]
                    entry.childIndex = entry.childIndex + 1
                    processed = processed + 1
                    if child and child.Parent and not isOwnGuiObject(child) then
                        F.addGuiObject(child, false)
                        if child:IsA("GuiObject") then
                            local size = child.AbsoluteSize
                            if size.X > 0 and size.Y > 0 and isActuallyVisible(child) then
                                markHot(child)
                            end
                        end
                        if isPriorityContainer(child) or child:IsA("Folder") then
                            enqueuePriority(child)
                        end
                    end
                end
                if entry.childIndex > #children then
                    entry.children = nil
                    F.finishPriorityEntry(entry)
                elseif processed >= budget then
                    break
                end
            end
        end
    end
    resetPriorityQueueIfEmpty()
    local queued = priorityTail - priorityHead + 1
    if priorityRecoveryNeeded
        and queued <= math.floor(CONFIG.performance.guiPriorityQueueLimit * 0.25)
        and not prioritySet[PlayerGui] then
        if enqueuePriority(PlayerGui) then
            priorityRecoveryNeeded = false
            invalidateGuiCaches()
        end
    end
    return processed
end
function F.pumpGuiEvents(epoch)
    if not guiIndexStarted or not runtime.guiWorkEnabled then return 0 end
    epoch = epoch or schedulerEpoch
    if lastGuiPumpEpoch == epoch then
        return 0
    end
    lastGuiPumpEpoch = epoch
    local processed = 0
    processed = processed + F.processNewGuiEvents()
    processed = processed + F.processIndexQueue()
    processed = processed + F.processGuiMutations()
    processed = processed + F.processWatchRetries()
    processed = processed + F.processPriorityQueue()
    guiStats.processedThisTick = processed
    if processed > guiStats.processedPeak then
        guiStats.processedPeak = processed
    end
    local queueTotal =
        math.max(0, indexTail - indexHead + 1)
        + math.max(0, newGuiTail - newGuiHead + 1)
        + math.max(0, mutationTail - mutationHead + 1)
        + math.max(0, mutationOverflowTail - mutationOverflowHead + 1)
        + math.max(0, priorityTail - priorityHead + 1)
        + math.max(0, watchRetryTail - watchRetryHead + 1)
    if queueTotal > guiStats.lastQueueTotal then
        guiStats.queueGrowthStreak = guiStats.queueGrowthStreak + 1
        if guiStats.queueGrowthStreak > guiStats.queueGrowthStreakPeak then
            guiStats.queueGrowthStreakPeak = guiStats.queueGrowthStreak
        end
    else
        guiStats.queueGrowthStreak = 0
    end
    guiStats.lastQueueTotal = queueTotal
    return processed
end
function F.refreshGuiSlice(force)
    if not guiIndexStarted then return end
    local now = os.clock()
    if not force and now - visibleCacheAt < CONFIG.performance.guiRefreshInterval then
        return
    end
    local total = #guiList
    if total == 0 then return end
    local budget = math.min(CONFIG.performance.guiSliceBudget, total)
    for _ = 1, budget do
        if guiCursor > #guiList then
            guiCursor = 1
        end
        local obj = guiList[guiCursor]
        guiCursor = guiCursor + 1
        if obj and guiSet[obj] and obj.Parent then
            if not guiWatch[obj] then
                F.watchGuiObject(obj)
            end
            local size = obj.AbsoluteSize
            if size.X > 0 and size.Y > 0 and isActuallyVisible(obj) then
                markHot(obj, now)
            end
        end
    end
end
function F.visibleObjects(force)
    if not guiIndexStarted then return {} end
    -- Event queues are pumped before cache checks so a reused prompt becomes
    -- visible to the solver on the very next bounded pass.
    F.pumpGuiEvents()
    local now = os.clock()
    if not force and now - visibleCacheAt < CONFIG.performance.guiRefreshInterval then
        return visibleCache
    end
    F.refreshGuiSlice(force)
    visibleCacheAt = now
    local out = {}
    local ttl = CONFIG.performance.guiHotTtl
    for i = 1, #hotList do
        local obj = hotList[i]
        local lastSeen = obj and hotSeenAt[obj]
        if obj
            and hotSet[obj]
            and obj.Parent
            and lastSeen
            and now - lastSeen <= ttl then
            local size = obj.AbsoluteSize
            if size.X > 0 and size.Y > 0 and isActuallyVisible(obj) then
                out[#out + 1] = obj
                hotSeenAt[obj] = now
            end
        end
    end
    visibleCache = out
    return out
end
function F.visibleTextBlob(force)
    local now = os.clock()
    if not force and now - textBlobCacheAt < CONFIG.performance.textBlobInterval then
        return textBlobCache
    end
    textBlobCacheAt = now
    local parts = {}
    local objects = F.visibleObjects(force)
    for i = 1, #objects do
        local obj = objects[i]
        local name = lower(obj.Name)
        if name ~= "" then
            parts[#parts + 1] = name
        end
        if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
            local t = lower(obj.Text)
            if t ~= "" then
                parts[#parts + 1] = t
            end
        end
    end
    textBlobCache = table.concat(parts, " ")
    return textBlobCache
end
function F.guiHotCount()
    local n = 0
    for i = 1, #hotList do
        local obj = hotList[i]
        if obj and hotSet[obj] and obj.Parent then
            n = n + 1
        end
    end
    return n
end
function F.disconnectAllGuiWatches()
    if runtime.guiWatchDrainRunning then return end
    runtime.guiWatchDrainRunning = true
    -- Detach in O(1). Callbacks already see runtime.alive == false, while the
    -- captured old bundles are disconnected incrementally below.
    local watches = guiWatch
    guiWatch = setmetatable({}, {__mode = "k"})
    guiWatchCount = 0
    -- No up-front pairs() snapshot and no immediate front batch. Both used to
    -- scale with the number of watched objects exactly when unload/reinjection
    -- was already under pressure. Always yield first, then disconnect 16 objects
    -- per scheduler turn directly from the weak map.
    deferAfterYield(function()
        local cursor = nil
        while true do
            local processed = 0
            while processed < 16 do
                -- Keep cursor strongly referenced and still present until next()
                -- returns the following entry. Deleting first and restarting at
                -- nil can repeatedly rescan hash slots and degrade quadratically.
                local obj, bundle = next(watches, cursor)
                if cursor then watches[cursor] = nil end
                if not obj then
                    runtime.guiWatchDrainRunning = false
                    return
                end
                cursor = obj
                if type(bundle) == "table" then
                    for i = 1, #bundle do
                        local connection = bundle[i]
                        if connection then
                            pcall(function() connection:Disconnect() end)
                        end
                    end
                end
                processed = processed + 1
            end
            task.wait()
        end
    end)
end
addCleanup(function()
    F.disconnectAllGuiWatches()
    -- Release potentially full queues/maps by swapping references. This keeps
    -- the cleanup callback constant-time; garbage collection can reclaim the
    -- detached storage later without a launch-frame traversal.
    mutationQueue = {}
    mutationOverflowQueue = {}
    mutationState = setmetatable({}, {__mode = "k"})
    mutationOverflowState = setmetatable({}, {__mode = "k"})
    promptSemanticDirty = setmetatable({}, {__mode = "k"})
    priorityQueue = {}
    indexQueue = {}
    newGuiQueue = {}
    watchRetryQueue = {}
    mutationHead, mutationTail = 1, 0
    mutationOverflowHead, mutationOverflowTail = 1, 0
    priorityHead, priorityTail = 1, 0
    indexHead, indexTail = 1, 0
    newGuiHead, newGuiTail = 1, 0
    watchRetryHead, watchRetryTail = 1, 0
end)
-- Live game-mode detection
-- --------------------------------------------------------------------------
local MODE_PATTERNS = {
    {"Pentathlon", {"pentathlon", "ddakji", "gonggi", "jegi", "spinning top", "flying stone", "biseok"}},
    {"HideAndSeek", {"hide and seek", "hide n seek", "hide & seek", "hider", "seeker"}},
    {"JumpRope", {"jump rope", "jumprope"}},
    {"TugOfWar", {"tug of war", "tugofwar", "pull rope"}},
    {"Dalgona", {"dalgona", "honeycomb", "cookie"}},
    {"GlassBridge", {"glass stepping", "glass bridge", "glassbridge"}},
    {"Mingle", {"mingle", "carousel"}},
    {"LightsOut", {"lights out", "lightsout"}},
    {"LastDinner", {"last dinner", "final dinner"}},
    {"SkySquid", {"sky squid", "skysquid", "square pillar"}},
    {"FinalFight", {"final fight", "squid game"}},
    {"Rebel", {"rebel", "rebellion"}},
    {"RedLightGreenLight", {"red light", "green light", "young-hee", "young hee"}},
}
local modeState = {
    current = "Unknown",
    changedAt = os.clock(),
    lastEvidenceAt = -math.huge,
}
local GAME_HINT_NAMES = {
    "CurrentGame", "CurrentMode", "GameMode",
    "RoundName", "CurrentRound", "GameName",
}
function F.modeFromText(value)
    if value == nil then return nil end
    local s = lower(value)
    for i = 1, #MODE_PATTERNS do
        local entry = MODE_PATTERNS[i]
        if containsAny(s, entry[2]) then
            return entry[1]
        end
    end
    return nil
end
function F.scalarGameHint()
    local containers = {Workspace, ReplicatedStorage}
    for ci = 1, #containers do
        local container = containers[ci]
        for ni = 1, #GAME_HINT_NAMES do
            local attrName = GAME_HINT_NAMES[ni]
            local byAttribute = F.modeFromText(container:GetAttribute(attrName))
            if byAttribute then return byAttribute end
            -- Direct child only. Never recursively search Workspace.
            local valueObj = container:FindFirstChild(attrName)
            if valueObj then
                if valueObj:IsA("StringValue") then
                    local found = F.modeFromText(valueObj.Value)
                    if found then return found end
                elseif valueObj:IsA("ObjectValue") then
                    local found = F.modeFromText(valueObj.Value and valueObj.Value.Name)
                    if found then return found end
                end
            end
        end
    end
    return nil
end
function F.detectModeEvidence()
    if F.inspectorModeEvidence then
        local observed = F.inspectorModeEvidence()
        if observed then return observed end
    end
    local hint = F.scalarGameHint()
    if hint then return hint end
    if guiIndexStarted then
        local blob = F.visibleTextBlob()
        for i = 1, #MODE_PATTERNS do
            local entry = MODE_PATTERNS[i]
            if containsAny(blob, entry[2]) then
                return entry[1]
            end
        end
    end
    return nil
end
function F.refreshMode()
    local now = os.clock()
    local found = F.detectModeEvidence()
    if found then
        modeState.lastEvidenceAt = now
        if found ~= modeState.current then
            modeState.current = found
            modeState.changedAt = now
            if CONFIG.debug then
                print("[Ink v8.8.0] Mode ->", found)
            end
        end
        return modeState.current
    end
    if modeState.current ~= "Unknown"
        and now - modeState.lastEvidenceAt > CONFIG.performance.modeEvidenceTtl then
        modeState.current = "Unknown"
        modeState.changedAt = now
        if CONFIG.debug then
            print("[Ink v8.8.0] Mode -> Unknown (evidence timeout)")
        end
    end
    return modeState.current
end
-- Prompt classification
-- --------------------------------------------------------------------------
local KEY_MAP = {
    q = Enum.KeyCode.Q, e = Enum.KeyCode.E, r = Enum.KeyCode.R, t = Enum.KeyCode.T, f = Enum.KeyCode.F,
    w = Enum.KeyCode.W, a = Enum.KeyCode.A, s = Enum.KeyCode.S, d = Enum.KeyCode.D,
    z = Enum.KeyCode.Z, x = Enum.KeyCode.X, c = Enum.KeyCode.C, v = Enum.KeyCode.V,
    ["space"] = Enum.KeyCode.Space, ["jump"] = Enum.KeyCode.Space,
}
local DIGIT_KEYS = {
    ["0"] = Enum.KeyCode.Zero, ["1"] = Enum.KeyCode.One, ["2"] = Enum.KeyCode.Two,
    ["3"] = Enum.KeyCode.Three, ["4"] = Enum.KeyCode.Four, ["5"] = Enum.KeyCode.Five,
    ["6"] = Enum.KeyCode.Six, ["7"] = Enum.KeyCode.Seven, ["8"] = Enum.KeyCode.Eight,
    ["9"] = Enum.KeyCode.Nine,
}
local handled = setmetatable({}, {__mode = "k"})
local sequenceState = setmetatable({}, {__mode = "k"})
local sequenceBusy = false
local sequenceRunToken = 0
-- Forward-declared here so an asynchronous Gonggi sequence can validate that
-- it still belongs to the active Pentathlon stage before every emitted digit.
local lastPentathlonStage = "unknown"
function F.cancelDigitSequence()
    sequenceRunToken = sequenceRunToken + 1
    sequenceBusy = false
end
local lastActionAt = {}
function F.normalizedPromptText(text)
    text = lower(text)
    text = text:gsub("[%[%]%(%){}<>:;,.!?]", " ")
    text = text:gsub("%s+", " ")
    return text:match("^%s*(.-)%s*$") or text
end
function F.keyFromPrompt(text)
    local t = F.normalizedPromptText(tostring(text):gsub("<[^>]->", ""))
    if KEY_MAP[t] then return KEY_MAP[t] end
    if #t > 40 then return nil end
    local key = t:match("^press%s+([a-z]+)%f[%A]") or t:match("^press%s+([a-z]+)$")
    return key and KEY_MAP[key] or nil
end
local DIGIT_CONTEXT_WORDS = {
    "gonggi", "sequence", "input", "press", "code", "qte", "type", "enter",
}
function F.hasDigitSequenceContext(obj, raw, owner)
    if owner == "gonggi" then
        return modeState.current == "Pentathlon"
            and lastPentathlonStage == "gonggi"
    end
    local normalized = lower(raw)
    if containsAny(normalized, DIGIT_CONTEXT_WORDS) then
        return true
    end
    -- Generic Auto QTE requires a positive prompt/container signal. A naked
    -- score, user ID, counter, or other 4–6 digit label is never enough.
    local cursor = obj and obj.Parent
    for _ = 1, 4 do
        if not cursor then break end
        local descriptor = lower(cursor.Name)
        if cursor:IsA("TextLabel") or cursor:IsA("TextButton") or cursor:IsA("TextBox") then
            descriptor = descriptor .. " " .. lower(textOf(cursor))
        end
        if containsAny(descriptor, DIGIT_CONTEXT_WORDS) then
            return true
        end
        cursor = cursor.Parent
    end
    return false
end
function F.extractDigitSequence(text, obj, owner)
    local raw = tostring(text or "")
    if raw:match("%d+%s*:%s*%d+") then return nil end
    local compact = raw:gsub("%D", "")
    if #compact < 4 or #compact > 6 then return nil end
    local normalized = lower(raw)
    if #raw > 28 and not containsAny(normalized, DIGIT_CONTEXT_WORDS) then
        return nil
    end
    if not F.hasDigitSequenceContext(obj, raw, owner) then
        return nil
    end
    return compact
end
function F.ancestorVisibilityEpoch(obj)
    local epoch = 0
    local cursor = obj and obj.Parent
    -- GUI ancestry is shallow. Summing monotonic epochs is stable and avoids
    -- touching every descendant when a parent Frame/ScreenGui is reused.
    while cursor do
        epoch = epoch + (subtreeGeneration[cursor] or 0)
        if cursor == PlayerGui then
            break
        end
        cursor = cursor.Parent
    end
    return epoch
end
function F.signature(obj)
    local imageIdentity = obj:IsA("ImageButton") and tostring(obj.Image or "") or ""
    local semanticIdentity = semanticPromptIdentity(obj)
    if promptSemanticDirty[obj] then
        promptSemanticDirty[obj] = nil
        promptSemantic[obj] = semanticIdentity
    end
    -- Action identity contains semantics/state only. Position and AbsoluteSize
    -- are presentation properties and cannot re-arm a pulsing/moving prompt.
    return table.concat({
        obj.ClassName,
        obj.Name,
        semanticIdentity,
        imageIdentity,
        tostring(promptGeneration[obj] or 0),
        tostring(F.ancestorVisibilityEpoch(obj)),
    }, "|")
end
local lastFailureAt = {}
local lastCooldownPruneAt = -math.huge
function F.pruneActionState(now)
    if now - lastCooldownPruneAt < 5 then return end
    lastCooldownPruneAt = now
    local cutoff = now - CONFIG.performance.cooldownRetention
    for key, stamp in pairs(lastActionAt) do
        if stamp < cutoff then lastActionAt[key] = nil end
    end
    for key, stamp in pairs(lastFailureAt) do
        if stamp < cutoff then lastFailureAt[key] = nil end
    end
end
function F.actionAllowed(key, interval)
    local now = os.clock()
    F.pruneActionState(now)
    local lastSuccess = lastActionAt[key] or -math.huge
    if now - lastSuccess < interval then return false end
    -- Failed virtual input gets only a tiny backoff; it must not consume the
    -- real gameplay cooldown.
    local lastFailure = lastFailureAt[key] or -math.huge
    if now - lastFailure < 0.25 then return false end
    return true
end
function F.commitAction(key)
    lastActionAt[key] = os.clock()
end
function F.failAction(key)
    lastFailureAt[key] = os.clock()
end
function F.tryAction(key, interval, fn)
    if not runtime.canInput() or not F.actionAllowed(key, interval) then
        return false
    end
    local ok, result = pcall(fn)
    local success = ok and result == true
    if success then
        F.commitAction(key)
    else
        F.failAction(key)
    end
    return success
end
function F.likelyActionButton(obj, words)
    if not obj:IsA("GuiButton") or obj.Active == false or not isActuallyVisible(obj) then return false end
    local s = lower(obj.Name .. " " .. textOf(obj))
    return containsAny(s, words)
end
function F.clickFirstAction(words, cooldownKey, cooldown)
    local objects = F.visibleObjects()
    for i = 1, #objects do
        local obj = objects[i]
        if F.likelyActionButton(obj, words) then
            if cooldownKey then
                return F.tryAction(cooldownKey, cooldown or 0.15, function()
                    return clickGuiButton(obj)
                end)
            end
            return clickGuiButton(obj)
        end
    end
    return false
end
-- Find a moving marker whose center is currently inside a green/yellow target.
-- This handles the game's timing meters without relying on object names.
function F.solveTimingBar(preferYellow)
    if modeState.current ~= "Pentathlon" then return false end
    local objects = F.visibleObjects()
    local targets = {}
    local movers = {}
    for i = 1, #objects do
        local obj = objects[i]
        local size = obj.AbsoluteSize
        if F.qteContext(obj) and size.X >= 8 and size.Y >= 4 and size.X <= 800 and size.Y <= 500 then
            local c = objectColor(obj)
            local lname = lower(obj.Name)
            local score = preferYellow and yellowScore(c) or greenScore(c)
            if containsAny(lname, preferYellow and {"yellow", "target", "perfect", "success"} or {"green", "target", "perfect", "success"}) then
                score = score + 1.25
            end
            if score > 0.72 and obj.BackgroundTransparency < 0.98 then
                targets[#targets + 1] = {obj = obj, score = score}
            end
            local slender = (size.X <= 18 and size.Y >= 22) or (size.Y <= 18 and size.X >= 22)
            if slender or containsAny(lname, {"needle", "marker", "arrow", "cursor", "line", "pointer"}) then
                movers[#movers + 1] = obj
            end
        end
    end
    table.sort(targets, function(a, b) return a.score > b.score end)
    for ti = 1, math.min(#targets, 18) do
        local target = targets[ti].obj
        local targetSize = target.AbsoluteSize
        local tolerance = -math.min(2, math.min(targetSize.X, targetSize.Y) * 0.1)
        for mi = 1, math.min(#movers, 32) do
            local mover = movers[mi]
            if mover ~= target and sameGuiRegion(target, mover) then
                local p = centerOf(mover)
                if pointInside(p, target, tolerance) then
                    local key = "timing:" .. tostring(target) .. ":" .. tostring(mover)
                    local clickPoint = centerOf(target)
                    if pointInteractableFor(target, clickPoint)
                        and F.tryAction(key, 0.20, function()
                            return mouseClick(clickPoint)
                        end) then
                        return true, target, mover
                    end
                end
            end
        end
    end
    return false
end
F.ringSamples = setmetatable({}, {__mode = "k"})
F.linearSamples = setmetatable({}, {__mode = "k"})
F.geometrySamples = setmetatable({}, {__mode = "k"})
runtime.qteStatus = "Waiting for a timed prompt"
function F.isCombatQTEKey(code)
    return code == Enum.KeyCode.Q or code == Enum.KeyCode.E or code == Enum.KeyCode.R
        or code == Enum.KeyCode.F or code == Enum.KeyCode.T
end
function F.qteContext(obj)
    local cursor = obj
    local positive = false
    for _ = 1, 7 do
        if not cursor or cursor == PlayerGui then break end
        local name = lower(cursor.Name)
        if containsAny(name, {"chat", "backpack", "shop", "inventory", "settings", "playerlist"}) then return false end
        if containsAny(name, {"qte", "quicktime", "quick_time", "powerhold", "power hold", "clash",
            "beatdown", "timing", "skillcheck", "gonggi", "ddakji", "biseok", "pentathlon", "dalgona",
            "flyingstone", "spinningtop", "jegi", "honeycomb", "cookie"}) then positive = true end
        cursor = cursor.Parent
    end
    local key = F.keyFromPrompt(textOf(obj))
    return positive or (key ~= nil and F.isCombatQTEKey(key) and #textOf(obj) <= 24)
end
function F.timingObjects()
    return F.qteNeighborhood or (F.inspector and F.inspector.nodes) or F.visibleObjects()
end
function F.collectPromptNeighborhood()
    -- Inspect the actual local hierarchy around recognized letters. This also
    -- finds rings named simply "ImageLabel" under an unnamed prompt container.
    local nodes, seen, roots, queue = {}, {}, {}, {}
    for _, obj in ipairs(F.visibleObjects()) do
        local key = F.keyFromPrompt(textOf(obj))
        if key and F.isCombatQTEKey(key) and F.qteContext(obj) then
            local root = obj.Parent
            if root and root.Parent and root.Parent:IsA("GuiObject")
                and root.Parent.AbsoluteSize.X <= 600 and root.Parent.AbsoluteSize.Y <= 600 then root = root.Parent end
            if root and root:IsA("GuiObject") and not roots[root] and #queue < 8 then
                roots[root] = true
                queue[#queue + 1] = {obj = root, depth = 0}
            end
        end
    end
    local head = 1
    while head <= #queue and #nodes < 160 do
        local entry = queue[head]; head = head + 1
        if not seen[entry.obj] then
            seen[entry.obj] = true
            if entry.obj:IsA("GuiObject") then nodes[#nodes + 1] = entry.obj end
            if entry.depth < 3 then
                local children = entry.obj:GetChildren()
                for i = 1, math.min(#children, 64) do
                    if #queue >= 192 then break end
                    local child = children[i]
                    if child:IsA("GuiObject") then queue[#queue + 1] = {obj = child, depth = entry.depth + 1} end
                end
            end
        end
    end
    F.qteNeighborhood = nodes
    return nodes
end
function F.sampleQTEGeometry()
    local now = os.clock()
    local objects = F.collectPromptNeighborhood()
    local used, frame = 0, {}
    for i = 1, #objects do
        local obj = objects[i]
        if obj.Parent and obj:IsA("GuiObject") and isActuallyVisible(obj) then
            used = used + 1
            if used > 256 then break end
            local p, size = centerOf(obj), obj.AbsoluteSize
            local old = F.geometrySamples[obj]
            if not old then
                F.geometrySamples[obj] = {position = p, size = size.X, time = now, velocity = 0, speed = 0, samples = 1, cycle = 0}
            elseif now > old.time then
                local dt = now - old.time
                if dt > .15 then
                    old.samples, old.velocity, old.speed = 1, 0, 0
                else
                    if size.X > old.size + math.max(5, old.size * .15) then old.cycle = old.cycle + 1 end
                    old.velocity = (size.X - old.size) / dt
                    old.speed = (p - old.position).Magnitude / dt
                    old.samples = math.min(20, old.samples + 1)
                end
                old.position, old.size, old.time = p, size.X, now
            end
            if #frame < 24 then
                frame[#frame + 1] = {name = obj.Name, parent = obj.Parent.Name, class = obj.ClassName,
                    text = textOf(obj):sub(1, 12), x = p.X, y = p.Y, w = size.X, h = size.Y,
                    velocity = F.geometrySamples[obj].velocity}
            end
        end
    end
    if F.inspector and #frame > 0 then
        local inspect = F.inspector
        inspect.frames[inspect.frameCursor] = {time = now, nodes = frame}
        inspect.frameCursor = inspect.frameCursor % 24 + 1
    end
end
function F.samePromptGroup(a, b)
    -- A whole ScreenGui is too broad: unrelated prompts must not be paired.
    local cursor = a.Parent
    for _ = 1, 3 do
        if not cursor or cursor:IsA("LayerCollector") then break end
        local other = b.Parent
        for _ = 1, 3 do
            if not other or other:IsA("LayerCollector") then break end
            if cursor == other then return true end
            other = other.Parent
        end
        cursor = cursor.Parent
    end
    return false
end
function F.isCircleCandidate(obj)
    if not obj:IsA("GuiObject") or obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then return false end
    local size = obj.AbsoluteSize
    if size.X < 12 or size.X > 500 or math.abs(size.X - size.Y) > size.X * .12 then return false end
    if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then return true end
    if containsAny(obj.Name, {"ring", "circle", "outer", "inner"}) then return true end
    local corner = obj:FindFirstChildOfClass("UICorner")
    return corner ~= nil and (corner.CornerRadius.Scale >= .45 or corner.CornerRadius.Offset >= size.X * .45)
end
function F.promptTiming(obj)
    local center = centerOf(obj)
    local objects = F.timingObjects()
    local shrinking, stationary, markers, targets = {}, {}, {}, {}
    for i = 1, #objects do
        local candidate = objects[i]
        if candidate ~= obj and candidate.Parent and candidate:IsA("GuiObject")
            and isActuallyVisible(candidate) and F.samePromptGroup(obj, candidate) then
            local sample = F.geometrySamples[candidate]
            if sample and sample.samples >= 3 and os.clock() - sample.time <= .08 then
                if F.isCircleCandidate(candidate) and (centerOf(candidate) - center).Magnitude <= 8 then
                    if sample.velocity < -3 then
                        if #shrinking < 12 then shrinking[#shrinking + 1] = candidate end
                    elseif math.abs(sample.velocity) < 3 then
                        if #stationary < 12 then stationary[#stationary + 1] = candidate end
                    end
                end
                if sample.speed > 3 and containsAny(candidate.Name, {"needle", "marker", "pointer"}) then markers[#markers + 1] = candidate end
                if containsAny(candidate.Name, {"perfect", "successzone", "targetzone", "greenzone"}) then targets[#targets + 1] = candidate end
            end
        end
    end
    if #stationary > 1 then
        local first = stationary[1].AbsoluteSize.X
        for i = 2, #stationary do
            if math.abs(stationary[i].AbsoluteSize.X - first) > first * .06 then
                runtime.qteStatus = "Ambiguous target circles; inspector collecting geometry"
                return false, 0
            end
        end
    end
    for _, ring in ipairs(shrinking) do
        local moving = F.geometrySamples[ring]
        for _, target in ipairs(stationary) do
            local diameter = target.AbsoluteSize.X
            local ratio = ring.AbsoluteSize.X / diameter
            local state = F.ringSamples[obj]
            if not state or state.ring ~= ring or state.target ~= target or state.cycle ~= moving.cycle then
                state = {ring = ring, target = target, cycle = moving.cycle, fired = false}
                F.ringSamples[obj] = state
            end
            -- Compare two observed circles, NEVER the text label's rectangle.
            runtime.qteStatus = ("Ring %.3f; waiting for alignment"):format(ratio)
            if ratio >= .97 and ratio <= 1.035 and not state.fired then
                runtime.qteStatus = ("Observed ring alignment %.3f"):format(ratio)
                return true, state.cycle
            end
        end
    end
    for mi = 1, math.min(#markers, 8) do
        for ti = 1, math.min(#targets, 8) do
            local inside = pointInside(centerOf(markers[mi]), targets[ti], -1)
            local state = F.linearSamples[obj] or {cycle = 0, inside = false, fired = false}
            if inside and not state.inside then state.cycle = state.cycle + 1; state.fired = false end
            state.inside = inside
            F.linearSamples[obj] = state
            runtime.qteStatus = inside and "Observed meter alignment" or "Waiting for meter alignment"
            return inside and not state.fired, state.cycle
        end
    end
    if #shrinking == 0 or #stationary == 0 then
        runtime.qteStatus = "Timing geometry unresolved; inspector collecting UI"
    end
    return false, 0
end
function F.commitPromptTiming(obj)
    local ring, linear = F.ringSamples[obj], F.linearSamples[obj]
    if ring then ring.fired = true end
    if linear then linear.fired = true end
end
function F.solveKeyPrompts()
    runtime.qteStatus = "Watching for a timed Q/E/R/F/T prompt"
    local objects = F.visibleObjects()
    for i = 1, #objects do
        local obj = objects[i]
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            local key = F.keyFromPrompt(textOf(obj))
            if key and (modeState.current == "Pentathlon" or F.isCombatQTEKey(key)) and F.qteContext(obj) then
                local ready, cycle = F.promptTiming(obj)
                local sig = F.signature(obj) .. ":" .. tostring(cycle)
                local oldSig = handled[obj]
                local cooldownKey = "key:" .. sig
                if ready and oldSig ~= sig
                    and F.tryAction(cooldownKey, CONFIG.qte.minRepeat, function()
                        return keyTap(key)
                    end) then
                    handled[obj] = sig
                    F.commitPromptTiming(obj)
                    runtime.trace("qte-input", {key = tostring(key), reason = runtime.qteStatus})
                    -- One solver pass emits at most one logical action.
                    return true
                end
            end
        end
    end
    return false
end
function F.solveDigitSequences(owner)
    if sequenceBusy or not runtime.canInput() then return false end
    local sequenceOwner = owner or "qte"
    for _, obj in ipairs(F.visibleObjects()) do
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            local seq = F.extractDigitSequence(textOf(obj), obj, sequenceOwner)
            if seq then
                local generation = promptGeneration[obj] or 0
                local epoch = F.ancestorVisibilityEpoch(obj)
                local old = sequenceState[obj]
                if old and old.seq == seq and old.generation == generation and old.ancestorEpoch == epoch then
                    continue
                end
                local cooldown = "seq:" .. tostring(obj) .. ":" .. seq .. ":" .. generation .. ":" .. epoch
                if not F.actionAllowed(cooldown, 0.3) then continue end
                sequenceRunToken = sequenceRunToken + 1
                local token, inputEpoch = sequenceRunToken, runtime.inputEpoch
                local record = {seq = seq, generation = generation, ancestorEpoch = epoch, token = token}
                sequenceState[obj] = record
                sequenceBusy = true
                task.spawn(function()
                    local function valid()
                        if not runtime.canInput() or runtime.inputEpoch ~= inputEpoch or token ~= sequenceRunToken
                            or not obj.Parent or not isActuallyVisible(obj)
                            or (promptGeneration[obj] or 0) ~= generation or F.ancestorVisibilityEpoch(obj) ~= epoch
                            or F.extractDigitSequence(textOf(obj), obj, sequenceOwner) ~= seq then return false end
                        if sequenceOwner == "gonggi" then
                            return F.stageEnabled("gonggi") and modeState.current == "Pentathlon" and lastPentathlonStage == "gonggi"
                        end
                        return CONFIG.enabled.autoQTE and not (F.anyPentathlonEnabled() and modeState.current == "Pentathlon")
                    end
                    local ok, completed = pcall(function()
                        for i = 1, #seq do
                            if not valid() or not keyTap(DIGIT_KEYS[seq:sub(i, i)]) then return false end
                            if i < #seq then trackedInputWait(CONFIG.qte.sequenceDelay) end
                        end
                        return valid()
                    end)
                    if token == sequenceRunToken then sequenceBusy = false end
                    -- Identity comparison prevents an old cancelled worker from
                    -- clearing or committing state belonging to a newer run.
                    if sequenceState[obj] == record then
                        if ok and completed then F.commitAction(cooldown)
                        else
                            sequenceState[obj] = nil
                            F.failAction(cooldown)
                            if not ok then runtime.lastError = "Sequence: " .. tostring(completed) end
                        end
                    end
                end)
                return true
            end
        end
    end
    return false
end
function F.solveVisibleQTEButtons()
    local objects = F.visibleObjects()
    local words = {"qte", "press", "tap", "hit", "pull", "perfect", "action"}
    for i = 1, #objects do
        local obj = objects[i]
        if obj:IsA("GuiButton") then
            local descriptor = lower(obj.Name .. " " .. textOf(obj))
            local oneChar = F.normalizedPromptText(textOf(obj)):match("^[qertfwasdzxcv]$") ~= nil
            if (oneChar or containsAny(descriptor, words)) and F.qteContext(obj) then
                local ready, cycle = F.promptTiming(obj)
                local sig = F.signature(obj) .. ":" .. tostring(cycle)
                local cooldownKey = "btn:" .. sig
                if ready and handled[obj] ~= sig
                    and F.tryAction(cooldownKey, CONFIG.qte.minRepeat, function()
                        return clickGuiButton(obj)
                    end) then
                    handled[obj] = sig
                    F.commitPromptTiming(obj)
                    runtime.trace("qte-click", {reason = runtime.qteStatus})
                    return true
                end
            end
        end
    end
    return false
end
F.dalgona = {root = nil, points = {}, index = 1, position = nil, lastAt = 0, paused = false,
    status = "Waiting for Dalgona", generation = 0, done = false, scanAt = 0}
function F.resetDalgona()
    local d = F.dalgona
    d.root, d.points, d.position = nil, {}, nil
    d.index, d.lastAt, d.done, d.paused = 1, 0, false, false
    d.generation = d.generation + 1
    d.status = "Inspecting Dalgona contour"
    d.pathBuild = nil
end
function runtime.setDalgonaPath(root, normalizedPoints)
    -- Optional adapter for a known cookie asset. Points must describe its real
    -- contour in [0,1] coordinates relative to root; never invent shape paths.
    if typeof(root) ~= "Instance" or not root:IsA("GuiObject") or not root:IsDescendantOf(PlayerGui)
        or type(normalizedPoints) ~= "table" or #normalizedPoints < 2
        or #normalizedPoints > CONFIG.dalgona.maxPoints then return false, "Invalid path" end
    local copy = {}
    for i, point in ipairs(normalizedPoints) do
        if typeof(point) ~= "Vector2" or point.X ~= point.X or point.Y ~= point.Y
            or point.X < 0 or point.X > 1 or point.Y < 0 or point.Y > 1 then
            return false, "Path coordinates must be finite values in [0,1]"
        end
        copy[i] = point
    end
    F.resetDalgona()
    F.dalgona.root, F.dalgona.points = root, copy
    F.dalgona.status = "Contour ready"
    return true
end
F.inspector = {nodes = {}, set = setmetatable({}, {__mode = "k"}), cursor = 1,
    queue = {}, head = 1, tail = 0, scanAt = -math.huge, events = {}, eventCursor = 1,
    saveAt = -math.huge, saveBusy = false, saves = 0, lastFile = "", reason = "Waiting for UI",
    frames = {}, frameCursor = 1}
function runtime.trace(kind, data)
    local inspect = F.inspector
    local i = inspect.eventCursor
    inspect.events[i] = {time = os.clock(), kind = kind, data = data}
    inspect.eventCursor = i % 96 + 1
end
function F.inspectorExcluded(obj)
    if isOwnGuiObject(obj) then return true end
    local current = obj
    for _ = 1, 10 do
        if not current or current == PlayerGui then break end
        if containsAny(current.Name, {"chat", "playerlist", "settings", "inventory", "backpack", "shop"}) then return true end
        current = current.Parent
    end
    return false
end
function F.inspectObserve(obj)
    local inspect = F.inspector
    if not obj or not obj.Parent or inspect.set[obj] or F.inspectorExcluded(obj) then return end
    if not obj:IsA("GuiObject") and not obj:IsA("Path2D") then return end
    if #inspect.nodes < CONFIG.inspector.maxNodes then
        inspect.nodes[#inspect.nodes + 1] = obj
    else
        local old = inspect.nodes[inspect.cursor]
        inspect.set[old] = nil
        inspect.nodes[inspect.cursor] = obj
        inspect.cursor = inspect.cursor % CONFIG.inspector.maxNodes + 1
    end
    inspect.set[obj] = true
end
function F.inspectorRows()
    local rows = {}
    for _, obj in ipairs(F.inspector.nodes) do
        if #rows >= 240 then break end
        if obj.Parent and not F.inspectorExcluded(obj) and not obj:IsA("TextBox") and F.qteContext(obj) then
            local row = {name = obj.Name, class = obj.ClassName, parent = obj.Parent.Name,
                path = obj:GetFullName():gsub("^Players%.[^%.]+%.", "LocalPlayer.")}
            if obj:IsA("GuiObject") then
                local p, size = obj.AbsolutePosition, obj.AbsoluteSize
                row.x, row.y, row.w, row.h = p.X, p.Y, size.X, size.Y
                row.visible = isActuallyVisible(obj)
                row.rotation, row.layoutOrder = obj.Rotation, obj.LayoutOrder
                row.text = textOf(obj):sub(1, 96)
                if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then row.image = tostring(obj.Image):sub(1, 128) end
                local sample = F.geometrySamples[obj]
                if sample then row.velocity, row.samples = sample.velocity, sample.samples end
            end
            rows[#rows + 1] = row
        end
    end
    return rows
end
function F.inspectorModeEvidence()
    local mode, visited = nil, 0
    for _, obj in ipairs(F.inspector.nodes) do
        if obj.Parent and obj:IsA("GuiObject") and isActuallyVisible(obj) then
            visited = visited + 1
            if visited > 64 then break end
            local cursor = obj
            for _ = 1, 5 do
                if not cursor or cursor == PlayerGui then break end
                local found = F.modeFromText(cursor.Name)
                if found then
                    if mode and mode ~= found then return nil end
                    mode = found
                end
                cursor = cursor.Parent
            end
        end
    end
    return mode
end
function runtime.inspectionReport()
    local inspect = F.inspector
    local events = {}
    for step = 0, 95 do
        local item = inspect.events[(inspect.eventCursor + step - 1) % 96 + 1]
        if item then events[#events + 1] = item end
    end
    return game:GetService("HttpService"):JSONEncode({version = "8.8.0", executor = runtime.executorName,
        executorVersion = runtime.executorVersion, backend = runtime.inputBackend,
        qte = runtime.qteStatus, dalgona = F.dalgona.status, mode = modeState.current,
        lastError = runtime.lastError, nativeCall = runtime.nativeCall, nativeMaxMs = runtime.nativeMaxMs,
        nodes = F.inspectorRows(), events = events, recentFrames = inspect.frames})
end
function F.saveInspection()
    local inspect = F.inspector
    if inspect.saveBusy then return end
    if type(writefile) ~= "function" then
        inspect.reason = "Use runtime.inspectionReport(); file API unavailable"
        return
    end
    inspect.saveBusy = true
    -- Capture scalars now; delayed file I/O cannot touch a destroyed GUI tree.
    local ok, report = pcall(runtime.inspectionReport)
    if not ok then inspect.saveBusy = false; inspect.reason = tostring(report); return end
    local name = "InkGame_diagnostics_" .. tostring(inspect.saves % 2 + 1) .. ".json"
    task.defer(function()
        local saved, err = pcall(writefile, name, report)
        inspect.saveBusy = false
        if saved then
            inspect.lastFile, inspect.saves = name, inspect.saves + 1
            inspect.reason = "Saved " .. name
        else inspect.reason = "Report write failed: " .. tostring(err) end
    end)
end
function F.inspectorTick()
    local inspect, now = F.inspector, os.clock()
    if inspect.head > inspect.tail and now - inspect.scanAt >= 1 then
        inspect.queue, inspect.head, inspect.tail = {{obj = PlayerGui}}, 1, 1
        inspect.scanAt = now
    end
    local processed, started = 0, os.clock()
    while inspect.head <= inspect.tail and processed < CONFIG.inspector.budget and os.clock() - started < .002 do
        processed = processed + 1
        local entry = inspect.queue[inspect.head]
        if not entry.obj or not entry.obj.Parent or F.inspectorExcluded(entry.obj) then
            inspect.queue[inspect.head] = nil; inspect.head = inspect.head + 1
        else
            if not entry.children then
                F.inspectObserve(entry.obj)
                entry.children, entry.index = entry.obj:GetChildren(), 1
            end
            local child = entry.children[entry.index]
            if child then
                entry.index = entry.index + 1
                if not F.inspectorExcluded(child) and inspect.tail - inspect.head < 2048 then
                    inspect.tail = inspect.tail + 1
                    inspect.queue[inspect.tail] = {obj = child}
                end
            else
                entry.children = nil; inspect.queue[inspect.head] = nil; inspect.head = inspect.head + 1
            end
        end
    end
    if inspect.head > inspect.tail then inspect.completedAt = now end
    if CONFIG.inspector.autoSave and now - inspect.saveAt >= CONFIG.inspector.saveInterval then
        inspect.saveAt = now
        F.saveInspection()
    end
    if runtime.requestInspection and inspect.head > inspect.tail then
        runtime.requestInspection = false
        F.saveInspection()
    end
end

function F.dalgonaContext(obj)
    local cursor = obj
    for _ = 1, 8 do
        if not cursor or cursor == PlayerGui then return false end
        if containsAny(cursor.Name, {"dalgona", "cookie", "honeycomb"}) then return true end
        cursor = cursor.Parent
    end
    return false
end
function F.discoverDalgonaPath()
    local d, inspect = F.dalgona, F.inspector
    if d.pathBuild then
        local build = d.pathBuild
        if not build.path.Parent or build.path.Visible == false or not build.root.Parent then d.pathBuild = nil; return false end
        local size = build.root.AbsoluteSize
        for _ = 1, 12 do
            if build.index > build.count then
                local ok, reason = runtime.setDalgonaPath(build.root, build.points)
                if not ok then d.status = "Path rejected: " .. tostring(reason); d.pathBuild = nil end
                return ok
            end
            local ok, position = pcall(function() return build.path:GetPositionOnCurve((build.index - 1) / (build.count - 1)) end)
            if not ok then d.pathBuild = nil; d.status = "Path sampling unavailable: " .. tostring(position); return false end
            build.points[build.index] = Vector2.new(position.X.Scale + position.X.Offset / math.max(1, size.X),
                position.Y.Scale + position.Y.Offset / math.max(1, size.Y))
            build.index = build.index + 1
        end
        d.status = ("Reading contour %d/%d"):format(build.index - 1, build.count)
        return false
    end
    if os.clock() - d.scanAt < .3 then return false end
    d.scanAt = os.clock()
    -- A partially scanned list can look like a complete but truncated contour.
    if not inspect.completedAt then d.status = "Inspector mapping cookie UI"; return false end
    local groups, paths = {}, {}
    for _, obj in ipairs(inspect.nodes) do
        if obj.Parent and F.dalgonaContext(obj) then
            if obj:IsA("Path2D") and obj.Visible ~= false and obj.Parent:IsA("GuiObject") and isActuallyVisible(obj.Parent) then
                paths[#paths + 1] = obj
            elseif obj:IsA("GuiObject") and isActuallyVisible(obj) and obj.Parent:IsA("GuiObject") then
                local name = lower(obj.Name)
                local pointLike = containsAny(name, {"point", "node", "checkpoint"})
                    or (name:match("^%d+$") and containsAny(obj.Parent.Name, {"contour", "trace", "points", "path"}))
                if pointLike then
                    local order = obj:GetAttribute("PointIndex") or obj:GetAttribute("Index")
                        or tonumber(name:match("(%d+)$")) or (obj.LayoutOrder > 0 and obj.LayoutOrder or nil)
                    if type(order) == "number" and order == math.floor(order) and order >= 0 and order < 4096 then
                        local group = groups[obj.Parent] or {}
                        groups[obj.Parent] = group
                        group[#group + 1] = {index = order, obj = obj}
                    end
                end
            end
        end
    end
    if #paths == 1 then
        local path = paths[1]
        local ok, controls = pcall(function() return path:GetControlPoints() end)
        if ok and #controls >= 2 then
            d.pathBuild = {path = path, root = path.Parent, points = {}, index = 1, count = 192}
            d.status = "Reading exposed Path2D contour"
            return false
        end
    elseif #paths > 1 then
        d.status = "Multiple paths; inspector needs to identify cookie outline"
        return false
    end
    for guiRoot, nodes in pairs(groups) do
        if #nodes >= 3 and #nodes <= CONFIG.dalgona.maxPoints then
            table.sort(nodes, function(a, b) return a.index < b.index end)
            local points, size, origin = {}, guiRoot.AbsoluteSize, guiRoot.AbsolutePosition
            local contiguous = size.X > 0 and size.Y > 0 and (nodes[1].index == 0 or nodes[1].index == 1)
            for i, node in ipairs(nodes) do
                if i > 1 and node.index ~= nodes[i - 1].index + 1 then contiguous = false end
                local p = centerOf(node.obj) - origin
                points[i] = Vector2.new(p.X / math.max(1, size.X), p.Y / math.max(1, size.Y))
            end
            if contiguous and runtime.setDalgonaPath(guiRoot, points) then return true end
        end
    end
    d.status = "No readable contour; automatic diagnostic report records UI/assets"
    return false
end
function F.dalgonaFear()
    for _, obj in ipairs(F.visibleObjects()) do
        if F.qteContext(obj) and containsAny(obj.Name .. " " .. textOf(obj), {"fear", "stress"}) then
            local percentage = textOf(obj):match("(%d+)%s*%%")
            if percentage then return math.clamp(tonumber(percentage) / 100, 0, 1) end
        end
    end
    return nil
end
function F.solveDalgona()
    local d = F.dalgona
    if not CONFIG.enabled.autoDalgona or modeState.current ~= "Dalgona" or not runtime.canInput() then return false end
    if not d.root then return F.discoverDalgonaPath() end
    if not d.root.Parent or not isActuallyVisible(d.root) then
        releaseVirtualMouse()
        F.resetDalgona()
        return false
    end
    if d.done then return false end
    local fear = F.dalgonaFear()
    if fear and fear >= CONFIG.dalgona.fearPause then d.paused = true end
    if d.paused then
        releaseVirtualMouse()
        d.status = "Fear high: tracing paused"
        if fear and fear <= CONFIG.dalgona.fearResume then d.paused = false end
        d.lastAt = os.clock()
        return false
    end
    local now = os.clock()
    local delta = math.clamp(now - d.lastAt, 0, 0.05)
    d.lastAt = now
    local size, origin = d.root.AbsoluteSize, d.root.AbsolutePosition
    local normalized = d.points[d.index]
    if not normalized then
        releaseVirtualMouse()
        d.done = true
        d.status = "Contour traversed; awaiting game result"
        return false
    end
    local target = origin + Vector2.new(normalized.X * size.X, normalized.Y * size.Y)
    local p = d.position or target
    local distance = (target - p).Magnitude
    local step = CONFIG.dalgona.speedPxPerSecond * delta
    local nextIndex = d.index
    if distance <= step then p = target; nextIndex = d.index + 1
    elseif distance > 0 then p = p + (target - p).Unit * step end
    if not pointInteractableFor(d.root, p) or runtime.pointerBlocked(p) then
        releaseVirtualMouse()
        d.status = "Trace covered: move or hide panel (F5)"
        return false
    end
    if not sendInput("SendMouseMoveEvent", p.X, p.Y, game) then return false end
    if not runtime.virtualMouseHeld then
        if not mouseClick(p) then return false end
        runtime.mouseReleaseAt = nil
    end
    runtime.virtualMousePosition = p
    d.index = nextIndex
    d.position = p
    d.status = ("Tracing %d/%d"):format(math.min(d.index, #d.points), #d.points)
    return true
end

function F.solveGenericQTE()
    if not runtime.canInput() then return false end
    -- Combat QTEs require an observed timing window. Numeric prompts belong to
    -- Gonggi only, and generic colored widgets must not trigger fallback clicks.
    if modeState.current == "Pentathlon" and lastPentathlonStage == "gonggi" then
        return F.solveDigitSequences("gonggi")
    end
    if F.solveKeyPrompts() then return true end
    return F.solveVisibleQTEButtons()
end
-- --------------------------------------------------------------------------
-- Pentathlon — real-mechanic controllers
-- --------------------------------------------------------------------------
local stageState = {
    current = "unknown",
    lastEvidenceAt = -math.huge,
}
function F.detectPentathlonStage()
    local blob = F.visibleTextBlob()
    if containsAny(blob, {"ddakji"}) then return "ddakji" end
    if containsAny(blob, {"flying stone", "biseok", "biseokchigi"}) then return "flying_stone" end
    if containsAny(blob, {"gonggi"}) then return "gonggi" end
    if containsAny(blob, {"spinning top", "paengi"}) then return "spinning_top" end
    if containsAny(blob, {"jegi"}) then return "jegi" end
    return nil
end
function F.pentathlonStage()
    local now = os.clock()
    local found = F.detectPentathlonStage()
    if found then
        stageState.current = found
        stageState.lastEvidenceAt = now
        return found
    end
    if now - stageState.lastEvidenceAt > CONFIG.performance.stageEvidenceTtl then
        stageState.current = "unknown"
    end
    return stageState.current
end
local lastWindingAt = -math.huge
local windingBusy = false
local topPhase = "wind"
local windingToken = 0
function F.resetTopPhase()
    windingToken = windingToken + 1
    topPhase = "wind"
    windingBusy = false
end
function F.solveSpinningTopWinding()
    if topPhase ~= "wind"
        or windingBusy
        or os.clock() - lastWindingAt < 1.20 then
        return false
    end
    local objects = F.visibleObjects()
    local best, bestArea = nil, 0
    for i = 1, #objects do
        local obj = objects[i]
        local descriptor = lower(obj.Name .. " " .. textOf(obj))
        if containsAny(descriptor, {
            "top", "paengi", "spin", "string", "thread", "rope", "wind",
        }) then
            local s = obj.AbsoluteSize
            local area = s.X * s.Y
            if s.X >= 50 and s.Y >= 50 and area > bestArea then
                best = obj
                bestArea = area
            end
        end
    end
    if not best then
        return false
    end
    lastWindingAt = os.clock()
    windingBusy = true
    windingToken = windingToken + 1
    local myToken = windingToken
    local size = best.AbsoluteSize
    local radius = math.max(18, math.min(size.X, size.Y) * 0.28)
    local center = centerOf(best)
    task.spawn(function()
        local callOk, dragOk = pcall(function()
            return dragCircle(
                center,
                radius,
                CONFIG.pentathlon.windingLoops,
                24,
                function()
                    return runtime.canInput() and myToken == windingToken
                        and F.stageEnabled("spinning_top") and best.Parent and isActuallyVisible(best)
                end
            )
        end)
        if myToken == windingToken then
            windingBusy = false
            -- pcall success is not winding success. Advance only when the drag
            -- itself completed and released the virtual mouse cleanly.
            if runtime.alive and callOk and dragOk == true then
                topPhase = "balance"
            else
                topPhase = "wind"
            end
        end
    end)
    return true
end
local jegiOverlap = OverlapParams.new()
jegiOverlap.FilterType = Enum.RaycastFilterType.Exclude
jegiOverlap.MaxParts = CONFIG.performance.worldQueryMaxParts
function F.worldJegiPart()
    local root = livingRoot(LocalPlayer)
    if not root then return nil end
    jegiOverlap.FilterDescendantsInstances = LocalPlayer.Character and {LocalPlayer.Character} or {}
    local best, bestDist = nil, 60
    local nearby = Workspace:GetPartBoundsInRadius(root.Position, 60, jegiOverlap)
    for i = 1, #nearby do
        local obj = nearby[i]
        if containsAny(obj.Name, {"jegi", "shuttle", "kick"}) then
            local d = (obj.Position - root.Position).Magnitude
            if d < bestDist then
                best, bestDist = obj, d
            end
        end
    end
    return best
end
local jegiHeldKey = nil
local lastJegiWorldScanAt = -math.huge
local cachedJegiPart = nil
function F.releaseJegiDirection()
    if jegiHeldKey then
        keyUp(jegiHeldKey)
        jegiHeldKey = nil
    end
end
function F.solveJegi()
    local now = os.clock()
    if now - lastJegiWorldScanAt > 0.5 or not cachedJegiPart or not cachedJegiPart.Parent then
        lastJegiWorldScanAt = now
        cachedJegiPart = F.worldJegiPart()
    end
    local root = livingRoot(LocalPlayer)
    local cam = Workspace.CurrentCamera
    local part = cachedJegiPart
    if not root or not cam then
        F.releaseJegiDirection()
        return false
    end
    if not part then
        F.releaseJegiDirection()
        if F.clickFirstAction({"jegi", "kick", "jump", "start"}, "jegi-fallback", 0.35) then
            return true
        end
        if F.tryAction("jegi-start-space", 0.55, function()
            return keyTap(Enum.KeyCode.Space)
        end) then
            return true
        end
        return false
    end
    local partScreen, partOnScreen = cam:WorldToViewportPoint(part.Position)
    local footWorld = root.Position - Vector3.new(0, 2.55, 0)
    local footScreen, footOnScreen = cam:WorldToViewportPoint(footWorld)
    if not partOnScreen or not footOnScreen then
        F.releaseJegiDirection()
        return false
    end
    local dx = partScreen.X - footScreen.X
    local dy = math.abs(partScreen.Y - footScreen.Y)
    local dead = CONFIG.pentathlon.jegiHorizontalDeadzonePx
    local wanted = nil
    if dx > dead then wanted = Enum.KeyCode.D
    elseif dx < -dead then wanted = Enum.KeyCode.A end
    if wanted ~= jegiHeldKey then
        F.releaseJegiDirection()
        if wanted then
            if keyDown(wanted) then jegiHeldKey = wanted end
        end
    end
    if dy <= CONFIG.pentathlon.jegiKickHeightPx
        and F.tryAction("jegi-kick", 0.12, function()
            return keyTap(Enum.KeyCode.Space)
        end) then
        return true
    end
    return wanted ~= nil
end
function F.solveGonggi()
    -- Once a sequence starts, it owns input until all digits are emitted.
    -- Prevent concurrent button/key solvers from corrupting the sequence.
    if sequenceBusy then return true end
    if F.solveDigitSequences("gonggi") then return true end
    if F.solveVisibleQTEButtons() then return true end
    if F.solveKeyPrompts() then return true end
    -- Fallback: click the strongest-highlighted small interactive item.
    local objects = F.visibleObjects()
    local best, bestScore = nil, -math.huge
    for i = 1, #objects do
        local obj = objects[i]
        if obj:IsA("GuiButton") then
            local s = obj.AbsoluteSize
            if s.X >= 18 and s.Y >= 18 and s.X <= 180 and s.Y <= 180 then
                local c = objectColor(obj)
                local score = greenScore(c) + yellowScore(c) * 0.5
                local stroke = obj:FindFirstChildOfClass("UIStroke")
                if stroke and stroke.Enabled then score = score + (1 - stroke.Transparency) * 1.5 end
                if score > bestScore then
                    best, bestScore = obj, score
                end
            end
        end
    end
    if best and bestScore > 0.7 then
        return F.tryAction("gonggi-target", 0.08, function()
            return clickGuiButton(best)
        end)
    end
    return false
end
local topBalanceHeldKey = nil
function F.releaseTopBalance()
    if topBalanceHeldKey then
        keyUp(topBalanceHeldKey)
        topBalanceHeldKey = nil
    end
end
function F.solveSpinningTopBalance()
    local objects = F.visibleObjects()
    local bestTarget, bestTargetScore = nil, -math.huge
    local movers = {}
    for i = 1, #objects do
        local obj = objects[i]
        local s = obj.AbsoluteSize
        if s.X >= 8 and s.Y >= 4 and s.X <= 700 and s.Y <= 420 then
            local lname = lower(obj.Name)
            local c = objectColor(obj)
            local score = greenScore(c)
            if containsAny(lname, {"green", "balance", "safe", "target", "perfect"}) then
                score = score + 1.0
            end
            if score > bestTargetScore and score > 0.72 and obj.BackgroundTransparency < 0.98 then
                bestTarget, bestTargetScore = obj, score
            end
            local slender = (s.X <= 24 and s.Y >= 20) or (s.Y <= 24 and s.X >= 20)
            if slender or containsAny(lname, {"needle", "marker", "arrow", "cursor", "pointer"}) then
                movers[#movers + 1] = obj
            end
        end
    end
    if not bestTarget then
        F.releaseTopBalance()
        return false
    end
    local targetCenter = centerOf(bestTarget)
    local bestMover, bestDistance = nil, math.huge
    for i = 1, #movers do
        local mover = movers[i]
        if mover ~= bestTarget and sameGuiRegion(bestTarget, mover) then
            local p = centerOf(mover)
            local d = (p - targetCenter).Magnitude
            if d < bestDistance then
                bestMover, bestDistance = mover, d
            end
        end
    end
    if not bestMover then
        F.releaseTopBalance()
        return false
    end
    local marker = centerOf(bestMover)
    local dx = marker.X - targetCenter.X
    local dead = CONFIG.pentathlon.balanceDeadzonePx
    local wanted = nil
    -- If the marker is right of center, steer left; if left, steer right.
    if dx > dead then
        wanted = Enum.KeyCode.A
    elseif dx < -dead then
        wanted = Enum.KeyCode.D
    end
    if wanted ~= topBalanceHeldKey then
        F.releaseTopBalance()
        if wanted then
            if keyDown(wanted) then topBalanceHeldKey = wanted end
        end
    end
    return true
end
function F.solveDdakjiPlacement()
    local objects = F.visibleObjects()
    local best, bestScore = nil, -math.huge
    for i = 1, #objects do
        local obj = objects[i]
        local s = obj.AbsoluteSize
        if s.X >= 28 and s.Y >= 28 and s.X <= 520 and s.Y <= 520 then
            local descriptor = lower(obj.Name .. " " .. textOf(obj))
            local score = redScore(objectColor(obj))
            if containsAny(descriptor, {"ddakji", "dakji", "red", "target", "tile", "card"}) then
                score = score + 0.75
            end
            if score > bestScore and score > 1.05 then
                best, bestScore = obj, score
            end
        end
    end
    if not best then return false end
    local p = centerOf(best)
    local s = best.AbsoluteSize
    -- Current player guides recommend a slightly off-centre placement rather
    -- than dead centre after choosing roughly yellow power.
    local aimPoint = p + Vector2.new(math.min(14, s.X * 0.08), math.min(8, s.Y * 0.05))
    if pointInteractableFor(best, aimPoint) then
        return F.tryAction("ddakji-place:" .. tostring(best), 0.35, function()
            return mouseClick(aimPoint)
        end)
    end
    return false
end
lastPentathlonStage = "unknown"
function F.resetPentathlonInputs()
    F.releaseJegiDirection()
    F.releaseTopBalance()
    lastPentathlonStage = "unknown"
    stageState.current = "unknown"
    stageState.lastEvidenceAt = -math.huge
    F.resetTopPhase()
end
function F.solvePentathlon()
    local stage = F.pentathlonStage()
    if not F.stageEnabled(stage) then
        F.resetPentathlonInputs()
        F.cancelDigitSequence()
        return false
    end
    if stage ~= lastPentathlonStage then
        if lastPentathlonStage == "jegi" then
            F.releaseJegiDirection()
        elseif lastPentathlonStage == "spinning_top" then
            F.releaseTopBalance()
        elseif lastPentathlonStage == "gonggi" then
            F.cancelDigitSequence()
        end
        if stage == "spinning_top" then
            F.resetTopPhase()
        end
        lastPentathlonStage = stage
    end
    if stage ~= "jegi" then
        F.releaseJegiDirection()
    end
    if stage ~= "spinning_top" then
        F.releaseTopBalance()
    end
    if stage == "ddakji" then
        if F.clickFirstAction({"start", "ready"}, "ddakji-start", 0.45) then return true end
        local preferYellow = CONFIG.pentathlon.ddakjiTarget == "yellow"
        if F.solveTimingBar(preferYellow) then
            return true
        end
        return F.solveDdakjiPlacement()
    elseif stage == "flying_stone" then
        if F.clickFirstAction({"start", "ready"}, "stone-start", 0.45) then return true end
        return F.solveTimingBar(false)
    elseif stage == "gonggi" then
        return F.solveGonggi()
    elseif stage == "spinning_top" then
        if windingBusy then
            return true
        end
        -- Correct mechanic order: wind first, then A/D balance.
        if topPhase == "wind" and F.solveSpinningTopWinding() then
            return true
        end
        -- If the game already advanced manually, balance is still allowed.
        if F.solveSpinningTopBalance() then
            topPhase = "balance"
            return true
        end
        return F.clickFirstAction({"start", "spin", "throw"}, "top-action", 0.45)
    elseif stage == "jegi" then
        return F.solveJegi()
    end
    -- During transitions, do nothing instead of spraying generic inputs.
    return false
end
-- --------------------------------------------------------------------------
-- Hide & Seek dodge
-- --------------------------------------------------------------------------
function F.playerLooksLikeSeeker(player)
    if not player or player == LocalPlayer then return false end
    local team = player.Team
    if team and containsAny(team.Name, {"seeker", "red"}) then return true end
    local char = livingCharacter(player)
    if not char then return false end
    for _, child in ipairs(char:GetChildren()) do
        if child:IsA("Tool") and containsAny(child.Name, {"knife", "blade", "dagger"}) then
            return true
        end
    end
    return false
end
function F.localLooksLikeHider()
    local team = LocalPlayer.Team
    if team then
        if containsAny(team.Name, {"hider", "blue"}) then return true end
        if containsAny(team.Name, {"seeker", "red"}) then return false end
    end
    return containsAny(F.visibleTextBlob(), {"hider", "you are hiding", "dodge"})
end
function F.findLocalDodgeTool()
    local char = LocalPlayer.Character
    if char then
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("Tool") and containsAny(child.Name, {"dodge"}) then
                return child
            end
        end
    end
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if child:IsA("Tool") and containsAny(child.Name, {"dodge"}) then
                return child
            end
        end
    end
    return nil
end
function F.performDodge()
    if not runtime.canInput() or not CONFIG.enabled.autoDodge or sequenceBusy then return false end
    -- Hide & Seek currently gives Hiders a DODGE! tool. Prefer activating the
    -- actual local tool over guessing a keyboard bind.
    local tool = F.findLocalDodgeTool()
    if tool then
        local char = LocalPlayer.Character
        if char and tool.Parent ~= char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                pcall(function() hum:EquipTool(tool) end)
            end
        end
        if not char or tool.Parent ~= char or not tool.Enabled then return false end
        local ok = pcall(function() tool:Activate() end)
        if ok then return true end
    end
    local objects = F.visibleObjects()
    for i = 1, #objects do
        local obj = objects[i]
        local descriptor = lower(obj.Name .. " " .. textOf(obj))
        if containsAny(descriptor, {"dodge"}) then
            if obj:IsA("GuiButton") then
                return clickGuiButton(obj)
            elseif obj:IsA("TextLabel") then
                local key = F.keyFromPrompt(textOf(obj))
                if key then return keyTap(key) end
            end
        end
    end
    -- Q is documented as Dash, not Dodge, so no Q fallback is used.
    return false
end
function F.autoDodgeTick()
    if modeState.current ~= "HideAndSeek" or not F.localLooksLikeHider() then return end
    local myRoot = livingRoot(LocalPlayer)
    if not myRoot then return end
    for _, player in ipairs(Players:GetPlayers()) do
        if F.playerLooksLikeSeeker(player) then
            local root = livingRoot(player)
            if root then
                local distance = (root.Position - myRoot.Position).Magnitude
                if distance <= CONFIG.dodge.enemyRadius
                    and distance <= CONFIG.dodge.triggerRadius then
                    if F.tryAction("auto-dodge", CONFIG.dodge.minRepeat, F.performDodge) then
                        return
                    end
                end
            end
        end
    end
end
-- --------------------------------------------------------------------------
-- Aim / ESP
-- --------------------------------------------------------------------------
function F.cameraLerpToward(cam, targetPosition, interval, smoothness)
    local desired = CFrame.new(cam.CFrame.Position, targetPosition)
    local tau = math.max(smoothness or 0.10, 0.01)
    local alpha = 1 - math.exp(-math.max(interval, 0.001) / tau)
    cam.CFrame = cam.CFrame:Lerp(desired, math.clamp(alpha, 0.05, 1))
end
function F.aimTick()
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local screenCenter = cam.ViewportSize / 2
    local best, bestDist = nil, CONFIG.aim.fov
    local players = Players:GetPlayers()
    local myTeam = LocalPlayer.Team
    for i = 1, #players do
        local p = players[i]
        if p ~= LocalPlayer then
            local root = livingRoot(p)
            local enemy = root and (not myTeam or p.Team ~= myTeam
                or modeState.current == "LightsOut"
                or modeState.current == "FinalFight"
                or modeState.current == "SkySquid")
            if enemy then
                local pos, onScreen = cam:WorldToViewportPoint(root.Position + Vector3.new(0, 1.35, 0))
                if onScreen then
                    local d = (Vector2.new(pos.X, pos.Y) - screenCenter).Magnitude
                    if d < bestDist then
                        best, bestDist = root, d
                    end
                end
            end
        end
    end
    if best then
        F.cameraLerpToward(
            cam,
            best.Position + Vector3.new(0, 1.2, 0),
            CONFIG.aim.updateInterval,
            CONFIG.aim.smoothness
        )
    end
end
local lastGuardScan = -math.huge
local guardModels = {}
local guardOverlap = OverlapParams.new()
guardOverlap.FilterType = Enum.RaycastFilterType.Exclude
guardOverlap.MaxParts = CONFIG.performance.worldQueryMaxParts
function F.scanGuards()
    if os.clock() - lastGuardScan < 0.75 then return end
    lastGuardScan = os.clock()
    table.clear(guardModels)
    local myRoot = livingRoot(LocalPlayer)
    if not myRoot then return end
    guardOverlap.FilterDescendantsInstances = LocalPlayer.Character and {LocalPlayer.Character} or {}
    local parts = Workspace:GetPartBoundsInRadius(
        myRoot.Position,
        CONFIG.performance.guardQueryRadius,
        guardOverlap
    )
    local seen = {}
    for i = 1, #parts do
        local obj = parts[i]
        local model = obj:FindFirstAncestorOfClass("Model")
        if model and not seen[model] and containsAny(model.Name, {"guard", "security"}) then
            seen[model] = true
            local hum = model:FindFirstChildOfClass("Humanoid")
            local root = model:FindFirstChild("HumanoidRootPart")
            if hum and hum.Health > 0 and root then
                guardModels[#guardModels + 1] = model
            end
        end
    end
end
function F.rebelAimTick()
    F.scanGuards()
    local cam = Workspace.CurrentCamera
    local myRoot = livingRoot(LocalPlayer)
    if not cam or not myRoot then return end
    local best, bestDist = nil, math.huge
    local players = Players:GetPlayers()
    for i = 1, #players do
        local p = players[i]
        if p ~= LocalPlayer and p.Team and containsAny(p.Team.Name, {"guard"}) then
            local root = livingRoot(p)
            if root then
                local d = (root.Position - myRoot.Position).Magnitude
                if d < bestDist then best, bestDist = root, d end
            end
        end
    end
    for i = 1, #guardModels do
        local model = guardModels[i]
        local hum = model:FindFirstChildOfClass("Humanoid")
        local root = model:FindFirstChild("HumanoidRootPart")
        if hum and hum.Health > 0 and root then
            local d = (root.Position - myRoot.Position).Magnitude
            if d < bestDist then best, bestDist = root, d end
        end
    end
    if best then
        F.cameraLerpToward(
            cam,
            best.Position + Vector3.new(0, 1.0, 0),
            CONFIG.aim.rebelUpdateInterval,
            0.08
        )
        F.tryAction("rebel-fire", 0.10, function()
            return mouseClick(cam.ViewportSize / 2)
        end)
    end
end
local espObjects = setmetatable({}, {__mode = "k"})
function F.clearESP(kind)
    for player, bundle in pairs(espObjects) do
        if not kind or bundle.kind == kind then
            if bundle.object then pcall(function() bundle.object:Destroy() end) end
            espObjects[player] = nil
        end
    end
end
function F.espTick(hideSeekOnly)
    local live = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local char = livingCharacter(p)
            if char then
                live[p] = true
                local bundle = espObjects[p]
                local desiredKind = hideSeekOnly and "hns" or "all"
                if not bundle
                    or not bundle.object
                    or not bundle.object.Parent
                    or bundle.kind ~= desiredKind
                    or bundle.character ~= char then
                    if bundle and bundle.object then pcall(function() bundle.object:Destroy() end) end
                    local hl = Instance.new("Highlight")
                    hl.Name = hideSeekOnly and "InkHnsESP_v85" or "InkESP_v85"
                    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.FillTransparency = 0.55
                    hl.OutlineTransparency = 0
                    hl.Adornee = char
                    hl.Parent = char
                    bundle = {
                        object = hl,
                        kind = desiredKind,
                        character = char,
                    }
                    espObjects[p] = bundle
                end
                local hl = bundle.object
                local hum = char:FindFirstChildOfClass("Humanoid")
                local ratio = hum and hum.MaxHealth > 0 and math.clamp(hum.Health / hum.MaxHealth, 0, 1) or 0
                local blend = math.clamp((ratio - CONFIG.espHealth.low) / (CONFIG.espHealth.high - CONFIG.espHealth.low), 0, 1)
                hl.FillColor = Color3.fromRGB(255, 55, 65):Lerp(Color3.fromRGB(55, 125, 255), blend)
                hl.OutlineColor = hl.FillColor
            end
        end
    end
    for p, bundle in pairs(espObjects) do
        if not live[p] then
            if bundle.object then pcall(function() bundle.object:Destroy() end) end
            espObjects[p] = nil
        end
    end
end
addCleanup(function()
    F.resetPentathlonInputs()
    F.cancelDigitSequence()
    F.clearESP()
end)
-- --------------------------------------------------------------------------
-- UI
-- --------------------------------------------------------------------------
function F.destroyOldGui(parent)
    if not parent then return end
    local retired = {}
    for name in pairs(LEGACY_GUI_NAMES) do
        local oldGui = parent:FindFirstChild(name)
        if oldGui then
            pcall(function()
                if oldGui:IsA("LayerCollector") then
                    oldGui.Enabled = false
                end
            end)
            retired[#retired + 1] = oldGui
        end
    end
    if #retired == 0 then return end
    -- Destroy may synchronously traverse the entire old UI subtree and fire its
    -- removal callbacks. Capture only the pre-existing instances now, but defer
    -- destruction until after launch and destroy at most one root per turn.
    deferAfterYield(function()
        for i = 1, #retired do
            local oldGui = retired[i]
            pcall(function()
                if oldGui and oldGui.Parent then oldGui:Destroy() end
            end)
            task.wait()
        end
    end)
end
pcall(function()
    F.destroyOldGui(CoreGui)
end)
F.destroyOldGui(PlayerGui)
local screen = Instance.new("ScreenGui")
screen.Name = GUI_NAME
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.IgnoreGuiInset = false
screen.Parent = PlayerGui
trackInstance(screen)
local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.new(0, 430, 0, 520)
frame.Position = UDim2.new(0, 20, 0.5, -260)
frame.BackgroundColor3 = Color3.fromRGB(16, 18, 27)
frame.BorderSizePixel = 0
frame.Parent = screen
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 14)
corner.Parent = frame
local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(88, 114, 255)
stroke.Thickness = 1.3
stroke.Transparency = 0.15
stroke.Parent = frame
local top = Instance.new("Frame")
top.Size = UDim2.new(1, 0, 0, 58)
top.BackgroundColor3 = Color3.fromRGB(29, 35, 58)
top.BorderSizePixel = 0
top.Parent = frame
local topCorner = Instance.new("UICorner")
topCorner.CornerRadius = UDim.new(0, 14)
topCorner.Parent = top
local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 14, 0, 7)
title.Size = UDim2.new(1, -28, 0, 25)
title.Font = Enum.Font.GothamBold
title.TextSize = 18
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.Text = "Ink ULTIMATE v8.8.0 CANCELLABLE"
title.Parent = top
local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Position = UDim2.new(0, 14, 0, 32)
status.Size = UDim2.new(1, -28, 0, 18)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextColor3 = Color3.fromRGB(182, 195, 255)
status.Text = "Mode: detecting..."
status.Parent = top
local list = Instance.new("ScrollingFrame")
list.BackgroundTransparency = 1
list.Position = UDim2.new(0, 10, 0, 110)
list.Size = UDim2.new(1, -20, 1, -120)
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.ScrollBarThickness = 4
list.BorderSizePixel = 0
list.Parent = frame
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 7)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list
function F.toggleRow(label, field)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 40)
    row.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
    row.BorderSizePixel = 0
    row.Parent = list
    local rc = Instance.new("UICorner")
    rc.CornerRadius = UDim.new(0, 10)
    rc.Parent = row
    local text = Instance.new("TextLabel")
    text.BackgroundTransparency = 1
    text.Position = UDim2.new(0, 12, 0, 0)
    text.Size = UDim2.new(1, -104, 1, 0)
    text.Font = Enum.Font.GothamSemibold
    text.TextSize = 12
    text.TextXAlignment = Enum.TextXAlignment.Left
    text.TextColor3 = Color3.fromRGB(235, 239, 255)
    text.Text = label
    text.Parent = row
    local button = Instance.new("TextButton")
    button.AnchorPoint = Vector2.new(1, 0.5)
    button.Position = UDim2.new(1, -9, 0.5, 0)
    button.Size = UDim2.new(0, 72, 0, 27)
    button.AutoButtonColor = false
    button.Font = Enum.Font.GothamBold
    button.TextSize = 11
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.Parent = row
    local bc = Instance.new("UICorner")
    bc.CornerRadius = UDim.new(1, 0)
    bc.Parent = button
    local function render()
        local on = CONFIG.enabled[field]
        button.Text = on and "ON" or "OFF"
        button.BackgroundColor3 = on and Color3.fromRGB(62, 173, 107) or Color3.fromRGB(91, 43, 55)
    end
    render()
    trackConnection(button.Activated:Connect(function()
        F.setFeature(field, not CONFIG.enabled[field])
        render()
    end))
    F.toggleRenders[field] = render
end
F.toggleRow("Auto QTE / timed prompts", "autoQTE")
F.toggleRow("Auto Dalgona (visible contour)", "autoDalgona")
F.toggleRow("Hide & Seek Auto Dodge", "autoDodge")
F.toggleRow("Aim Assist", "aimAssist")
F.toggleRow("Rebel Guard Aim", "rebelAim")
F.toggleRow("Hide & Seek HP ESP", "hideSeekESP")
F.toggleRow("Player HP ESP (red to blue)", "esp")
local mainPage = list
local pentathlonPage = Instance.new("ScrollingFrame")
pentathlonPage.BackgroundTransparency = 1
pentathlonPage.BorderSizePixel = 0
pentathlonPage.Position, pentathlonPage.Size = list.Position, list.Size
pentathlonPage.CanvasSize = UDim2.new()
pentathlonPage.AutomaticCanvasSize = Enum.AutomaticSize.Y
pentathlonPage.ScrollBarThickness = 4
pentathlonPage.Visible = false
pentathlonPage.Parent = frame
local stageLayout = Instance.new("UIListLayout")
stageLayout.Padding = UDim.new(0, 7)
stageLayout.SortOrder = Enum.SortOrder.LayoutOrder
stageLayout.Parent = pentathlonPage
list = pentathlonPage
F.toggleRow("Enable all five stages", "autoPentathlon")
list = mainPage
for order, stage in ipairs({{"ddakji", "Ddakji"}, {"flying_stone", "Flying Stone"},
    {"gonggi", "Gonggi"}, {"spinning_top", "Spinning Top"}, {"jegi", "Jegi"}}) do
    local key, label = stage[1], stage[2]
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1, -4, 0, 45)
    button.LayoutOrder = order
    button.TextColor3 = Color3.fromRGB(240, 242, 255)
    button.Font, button.TextSize = Enum.Font.GothamSemibold, 13
    button.Parent = pentathlonPage
    local round = Instance.new("UICorner")
    round.CornerRadius = UDim.new(0, 8)
    round.Parent = button
    local function render()
        local armed = F.stageEnabled(key)
        button.Text = "Auto Complete game: " .. label .. (armed and " [ARMED]" or " [OFF]")
        button.BackgroundColor3 = armed and Color3.fromRGB(40, 115, 80) or Color3.fromRGB(30, 35, 52)
    end
    F.stageRenders[key] = render
    render()
    trackConnection(button.Activated:Connect(function()
        if CONFIG.enabled.autoPentathlon then
            -- Switching one stage off changes from master mode to per-stage
            -- selection while preserving the other four effective selections.
            CONFIG.enabled.autoPentathlon = false
            for name in pairs(CONFIG.stages) do CONFIG.stages[name] = true end
            F.toggleRenders.autoPentathlon()
        end
        CONFIG.stages[key] = not CONFIG.stages[key]
        runtime.cancelInput("stage:" .. key)
        runtime.guiWorkEnabled = false
        for _, redraw in pairs(F.stageRenders) do redraw() end
    end))
end
local inspectButton = Instance.new("TextButton")
inspectButton.Name = "SaveDiagnostics"
inspectButton.Size = UDim2.new(1, -4, 0, 40)
inspectButton.LayoutOrder = 8
inspectButton.Text = "Inspect live UI / save diagnostic report"
inspectButton.Font, inspectButton.TextSize = Enum.Font.GothamSemibold, 12
inspectButton.BackgroundColor3 = Color3.fromRGB(45, 55, 85)
inspectButton.TextColor3 = Color3.fromRGB(255, 255, 255)
inspectButton.Parent = mainPage
trackConnection(inspectButton.Activated:Connect(function()
    runtime.requestInspection = true
    inspectButton.Text = "Inspection requested; report saves automatically"
end))
local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -5, 0, 66)
hint.LayoutOrder = 9
hint.BackgroundTransparency = 1
hint.TextColor3 = Color3.fromRGB(175, 188, 215)
hint.Font, hint.TextSize = Enum.Font.Gotham, 12
hint.TextWrapped = true
hint.Text = "Armed buttons wait for that stage. Completion depends on the live game UI. F5: hide panel. F6: unload. F7: stop all."
hint.Parent = pentathlonPage
for i, name in ipairs({"Main", "Auto Pentathlon", "STOP"}) do
    local button = Instance.new("TextButton")
    button.Position = UDim2.new(0, 10 + (i - 1) * 136, 0, 68)
    button.Size = UDim2.new(0, 130, 0, 32)
    button.BackgroundColor3 = i == 3 and Color3.fromRGB(140, 40, 55) or Color3.fromRGB(45, 55, 85)
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.Font, button.TextSize, button.Text = Enum.Font.GothamBold, 12, name
    button.Parent = frame
    trackConnection(button.Activated:Connect(function()
        if i == 3 then F.stopAll(); return end
        mainPage.Visible = i == 1
        pentathlonPage.Visible = i == 2
    end))
end
-- Dragging
runtime.pointerBlocked = function(point)
    return screen.Enabled and frame.Visible and pointInside(point, frame, 4)
end
local dragging = false
local dragStart, frameStart, dragInput
local dragEndConnection = nil
function F.clearDragEndConnection()
    if dragEndConnection then
        pcall(function() dragEndConnection:Disconnect() end)
        dragEndConnection = nil
    end
end
addCleanup(function()
    dragging = false
    F.clearDragEndConnection()
end)
trackConnection(top.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        frameStart = frame.Position
        F.clearDragEndConnection()
        dragEndConnection = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
                F.clearDragEndConnection()
            end
        end)
    end
end))
trackConnection(top.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end))
trackConnection(UserInputService.InputChanged:Connect(function(input)
    if dragging and input == dragInput then
        local d = input.Position - dragStart
        frame.Position = UDim2.new(frameStart.X.Scale, frameStart.X.Offset + d.X, frameStart.Y.Scale, frameStart.Y.Offset + d.Y)
    end
end))
trackConnection(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F5 then
        screen.Enabled = not screen.Enabled
    elseif input.KeyCode == Enum.KeyCode.F6 then
        runtime.unload()
    elseif input.KeyCode == Enum.KeyCode.F7 then
        F.stopAll()
    end
end))
-- --------------------------------------------------------------------------
-- Scheduler
-- --------------------------------------------------------------------------
local clocks = {
    mode = -math.huge,
    qte = -math.huge,
    pentathlon = -math.huge,
    dodge = -math.huge,
    aim = -math.huge,
    rebel = -math.huge,
    esp = -math.huge,
    status = -math.huge,
    dalgona = -math.huge,
}
local perf = {
    emaMs = 0,
    peakMs = 0,
    wallPeakMs = 0,
    slowWorkers = 0,
}
function F.every(name, interval, now)
    if now - clocks[name] < interval then return false end
    clocks[name] = now
    return true
end
function F.profiledCall(name, fn)
    local started = os.clock()
    local waitBefore = intentionalInputWaitMs
    local ok, result = pcall(fn)
    local wallMs = (os.clock() - started) * 1000
    local intentionalMs = math.max(0, intentionalInputWaitMs - waitBefore)
    local computeMs = math.max(0, wallMs - intentionalMs)
    perf.emaMs = perf.emaMs == 0
        and computeMs
        or (perf.emaMs * 0.92 + computeMs * 0.08)
    if computeMs > perf.peakMs then
        perf.peakMs = computeMs
    end
    if wallMs > perf.wallPeakMs then
        perf.wallPeakMs = wallMs
    end
    if computeMs >= CONFIG.performance.slowWorkerMs then
        perf.slowWorkers = perf.slowWorkers + 1
        if CONFIG.debug then
            warn(("[Ink v8.8.0] slow CPU worker %s: %.2fms (wall %.2fms)")
                :format(name, computeMs, wallMs))
        end
    end
    if not ok then
        runtime.lastError = tostring(name) .. ": " .. tostring(result)
    end
    if not ok and CONFIG.debug then
        warn("[Ink v8.8.0] worker error [" .. tostring(name) .. "]:", result)
    end
    return ok, result
end
function F.anyFeatureEnabled()
    if F.anyPentathlonEnabled() then return true end
    for _, enabled in pairs(CONFIG.enabled) do
        if enabled then
            return true
        end
    end
    return false
end
function F.needsModeDetection()
    return CONFIG.enabled.autoQTE or CONFIG.enabled.autoDalgona or F.anyPentathlonEnabled()
        or CONFIG.enabled.autoDodge
        or CONFIG.enabled.aimAssist
        or CONFIG.enabled.rebelAim
        or CONFIG.enabled.hideSeekESP
end
function F.needsGuiIndexing()
    return CONFIG.enabled.autoDalgona or F.anyPentathlonEnabled()
        or CONFIG.enabled.autoQTE
        or CONFIG.enabled.autoDodge
        or CONFIG.enabled.aimAssist
        or CONFIG.enabled.rebelAim
        or CONFIG.enabled.hideSeekESP
end
function F.queueCount(head, tail)
    return math.max(0, tail - head + 1)
end
function runtime.getStats()
    return {
        version = "8.8.0",
        inputEpoch = runtime.inputEpoch,
        inputBackend = runtime.inputBackend,
        executorName = runtime.executorName,
        executorVersion = runtime.executorVersion,
        nativeCall = runtime.nativeCall,
        nativeMaxMs = runtime.nativeMaxMs,
        qteStatus = runtime.qteStatus,
        inspectorNodes = F.inspector and #F.inspector.nodes or 0,
        inspectorFile = F.inspector and F.inspector.lastFile or "",
        inputFailures = runtime.inputFailures,
        lastError = runtime.lastError,
        paused = runtime.suspended,
        dalgonaStatus = F.dalgona.status,
        indexedObjects = guiStats.indexedTotal,
        activeWatchers = guiWatchCount,
        mutationQueue = F.queueCount(mutationHead, mutationTail),
        mutationOverflowQueue = F.queueCount(mutationOverflowHead, mutationOverflowTail),
        priorityQueue = F.queueCount(priorityHead, priorityTail),
        indexQueue = F.queueCount(indexHead, indexTail),
        newGuiQueue = F.queueCount(newGuiHead, newGuiTail),
        watchRetryQueue = F.queueCount(watchRetryHead, watchRetryTail),
        processedThisTick = guiStats.processedThisTick,
        processedPeak = guiStats.processedPeak,
        startupWorkerMaxMs = guiStats.startupWorkerMaxMs,
        repeatedContainerEnqueue = guiStats.repeatedContainerEnqueue,
        mutationOverflowCount = guiStats.mutationOverflowCount,
        mutationOverflowQueuePeak = guiStats.mutationOverflowPeak,
        mutationScalarFallbackCount = guiStats.mutationScalarFallbackCount,
        priorityOverflowCount = guiStats.priorityOverflowCount,
        mutationQueuePeak = guiStats.mutationPeak,
        priorityQueuePeak = guiStats.priorityPeak,
        indexQueuePeak = guiStats.indexPeak,
        newGuiQueuePeak = guiStats.newGuiPeak,
        newGuiOverflowCount = guiStats.newGuiOverflowCount,
        watcherPeak = guiStats.watchersPeak,
        watchRetryPeak = guiStats.watchRetryPeak,
        childSnapshotPeakMs = guiStats.childSnapshotPeakMs,
        childSnapshotPeakSize = guiStats.childSnapshotPeakSize,
        childSnapshotSlowCount = guiStats.childSnapshotSlowCount,
        queueGrowthStreak = guiStats.queueGrowthStreak,
        queueGrowthStreakPeak = guiStats.queueGrowthStreakPeak,
        cpuEmaMs = perf.emaMs,
        cpuPeakMs = perf.peakMs,
        wallPeakMs = perf.wallPeakMs,
        guiIndexStarted = guiIndexStarted,
        guiIndexBuilding = guiIndexBuilding,
    }
end
function runtime.panicStop()
    runtime.cancelInput("panic")
    runtime.flushInput(true)
    F.resetDalgona()
    F.cancelDigitSequence()
    F.resetPentathlonInputs()
    F.clearESP()
end
function runtime.shutdownAsync()
    if runtime.cleanupStarted then return end
    -- The synchronous half is intentionally O(1): stop every worker, detach the
    -- public resource lists, and remove the registry entry. Actual cleanup begins
    -- only after Roblox receives another scheduler turn.
    runtime.cancelInput("unload")
    runtime.guiWorkEnabled = false
    runtime.cleanupStarted = true
    runtime.alive = false
    runtime.bootPhase = "shutdown-pending"
    local cleanups = runtime.cleanups
    local connections = runtime.connections
    local instances = runtime.instances
    runtime.cleanups = {}
    runtime.connections = {}
    runtime.instances = {}
    if rawget(_G, RUNTIME_KEY) == runtime then
        _G[RUNTIME_KEY] = nil
    end
    deferAfterYield(function()
        pcall(runtime.panicStop)
        if type(cleanups) == "table" then
            for i = #cleanups, 1, -1 do
                local cleanup = cleanups[i]
                cleanups[i] = nil
                if type(cleanup) == "function" then
                    pcall(cleanup)
                end
                -- A cleanup callback is never followed by another callback in
                -- the same frame, even when the list is short.
                task.wait()
            end
        end
        if type(connections) == "table" then
            local i = #connections
            while i >= 1 do
                local stop = math.max(1, i - 15)
                for index = i, stop, -1 do
                    local c = connections[index]
                    connections[index] = nil
                    if c then
                        pcall(function() c:Disconnect() end)
                    end
                end
                i = stop - 1
                task.wait()
            end
        end
        if type(instances) == "table" then
            local i = #instances
            while i >= 1 do
                local stop = math.max(1, i - 7)
                for index = i, stop, -1 do
                    local obj = instances[index]
                    instances[index] = nil
                    if obj then
                        pcall(function()
                            if obj.Parent then obj:Destroy() end
                        end)
                    end
                end
                i = stop - 1
                task.wait()
            end
        end
        runtime.bootPhase = "unloaded"
    end)
end
runtime.cleanupProtocol = 2
runtime.bootPhase = "running"
-- Lifecycle callbacks change state only. Scheduler owns actual cleanup/input.
trackConnection(UserInputService.WindowFocusReleased:Connect(function()
    runtime.windowFocused = false
    runtime.cancelInput("focus-lost")
end))
trackConnection(UserInputService.WindowFocused:Connect(function()
    runtime.windowFocused = true
    runtime.cancelInput("focus-restored")
end))
trackConnection(UserInputService.TextBoxFocused:Connect(function()
    runtime.typing = true
    runtime.cancelInput("typing")
end))
trackConnection(UserInputService.TextBoxFocusReleased:Connect(function()
    runtime.typing = false
    runtime.cancelInput("typing-ended")
end))
pcall(function()
    runtime.menuOpen = GuiService.MenuIsOpen
    trackConnection(GuiService.MenuOpened:Connect(function()
        runtime.menuOpen = true
        runtime.cancelInput("menu-open")
    end))
    trackConnection(GuiService.MenuClosed:Connect(function()
        runtime.menuOpen = false
        runtime.cancelInput("menu-close")
    end))
end)
trackConnection(LocalPlayer.CharacterRemoving:Connect(function()
    runtime.cancelInput("character-removing")
end))
trackConnection(LocalPlayer.CharacterAdded:Connect(function()
    runtime.cancelInput("character-added")
end))
trackConnection(LocalPlayer.OnTeleport:Connect(function(state)
    if state == Enum.TeleportState.Started or state == Enum.TeleportState.InProgress then
        runtime.unload()
    end
end))
trackConnection(Players.PlayerRemoving:Connect(function(player)
    if player == LocalPlayer then runtime.unload() end
end))
trackConnection(screen.Destroying:Connect(function() runtime.unload() end))
if type(identifyexecutor) == "function" then
    local ok, name, version = pcall(identifyexecutor)
    if ok then runtime.executorName, runtime.executorVersion = tostring(name), tostring(version) end
end
runtime.typing = UserInputService:GetFocusedTextBox() ~= nil

function F.applyPendingReset()
    if not runtime.resetPending then return end
    runtime.flushInput(true)
    F.cancelDigitSequence()
    F.resetPentathlonInputs()
    F.resetDalgona()
    handled = setmetatable({}, {__mode = "k"})
    sequenceState = setmetatable({}, {__mode = "k"})
    F.ringSamples = setmetatable({}, {__mode = "k"})
    F.linearSamples = setmetatable({}, {__mode = "k"})
    F.geometrySamples = setmetatable({}, {__mode = "k"})
    invalidateGuiCaches()
    runtime.resetPending = false
    runtime.resetAppliedEpoch = runtime.inputEpoch
end
function runtime.captureGui()
    -- A bounded local diagnostic: no remote requests, writes, or script source.
    local snapshot = {version = "8.8.0", mode = modeState.current, objects = {}, stats = runtime.getStats()}
    for i, obj in ipairs(F.visibleObjects(true)) do
        if i > 240 then break end
        local p, size = obj.AbsolutePosition, obj.AbsoluteSize
        snapshot.objects[#snapshot.objects + 1] = {path = obj:GetFullName(), class = obj.ClassName,
            text = textOf(obj):sub(1, 160), x = p.X, y = p.Y, width = size.X, height = size.Y}
    end
    return game:GetService("HttpService"):JSONEncode(snapshot)
end
function F.tick()
    runtime.nativeCall = "tick:reset"
    F.applyPendingReset()
    runtime.nativeCall = "tick:release"
    runtime.flushInput(false)
    runtime.nativeCall = "tick:ready"
    if not LocalPlayer.Parent or not PlayerGui.Parent or not screen.Parent then runtime.unload(); return end
    if type(isrbxactive) == "function" then
        local ok, focused = pcall(isrbxactive)
        if ok then runtime.windowFocused = focused == true end
    end
    runtime.suspended = not runtime.windowFocused or runtime.menuOpen or runtime.typing
    local active = F.anyFeatureEnabled() and not runtime.suspended
    runtime.guiWorkEnabled = active and F.needsGuiIndexing()
    schedulerEpoch = schedulerEpoch + 1
    local now = os.clock()
    if runtime.guiWorkEnabled then
        if not guiIndexStarted then F.ensureGuiIndexing() end
        F.profiledCall("gui-events", function() F.pumpGuiEvents(schedulerEpoch) end)
    end
    if active and F.needsModeDetection() and F.every("mode", CONFIG.performance.modeInterval, now) then
        F.profiledCall("mode", F.refreshMode)
    end
    if CONFIG.inspector.enabled and (active or runtime.requestInspection) then
        F.profiledCall("inspector", F.inspectorTick)
    end
    if active then F.sampleQTEGeometry() end
    local pentathlonActive = active and F.anyPentathlonEnabled() and modeState.current == "Pentathlon"
    if pentathlonActive and F.every("pentathlon", 0.035, now) then
        F.profiledCall("pentathlon", F.solvePentathlon)
    elseif active and not pentathlonActive and not sequenceBusy and F.every("qte", CONFIG.qte.scanInterval, now) then
        local qteActed = false
        if CONFIG.enabled.autoQTE or (CONFIG.enabled.autoDalgona and modeState.current == "Dalgona") then
            local ok, result = F.profiledCall("qte", F.solveGenericQTE)
            qteActed = ok and result == true
        end
        if CONFIG.enabled.autoDalgona and modeState.current == "Dalgona" then
            if qteActed then releaseVirtualMouse()
            else F.profiledCall("dalgona", F.solveDalgona) end
        elseif F.dalgona.root then releaseVirtualMouse(); F.resetDalgona() end
    end
    if not pentathlonActive and lastPentathlonStage ~= "unknown" then F.resetPentathlonInputs() end
    if active and CONFIG.enabled.autoDodge and not sequenceBusy and not pentathlonActive
        and F.every("dodge", CONFIG.performance.dodgeInterval, now) then F.profiledCall("dodge", F.autoDodgeTick) end
    if active and CONFIG.enabled.aimAssist and F.every("aim", CONFIG.aim.updateInterval, now) then F.profiledCall("aim", F.aimTick) end
    if active and CONFIG.enabled.rebelAim and modeState.current == "Rebel"
        and F.every("rebel", CONFIG.aim.rebelUpdateInterval, now) then F.profiledCall("rebel", F.rebelAimTick) end
    if active and (CONFIG.enabled.esp or CONFIG.enabled.hideSeekESP) and F.every("esp", CONFIG.performance.espInterval, now) then
        F.profiledCall("esp", function()
            if CONFIG.enabled.esp or modeState.current == "HideAndSeek" then F.espTick(CONFIG.enabled.hideSeekESP)
            else F.clearESP() end
        end)
    elseif not CONFIG.enabled.esp and not CONFIG.enabled.hideSeekESP and next(espObjects) then F.clearESP() end
    if F.every("status", CONFIG.performance.statusInterval, now) then
        local state = runtime.suspended and "PAUSED" or (active and "ARMED" or "OFF")
        local detail = runtime.lastError ~= "" and runtime.lastError
            or (CONFIG.enabled.autoDalgona and F.dalgona.status or (CONFIG.enabled.autoQTE and runtime.qteStatus) or "F5 hide | F6 unload | F7 stop")
        status.Text = ("%s | %s | %s"):format(state, modeState.current, detail)
    end
end
task.spawn(function()
    while runtime.alive do
        local ok, err = pcall(F.tick)
        if not ok then
            runtime.lastError = "Scheduler: " .. tostring(err)
            runtime.cancelInput("scheduler-error")
            runtime.flushInput(true)
            warn("[Ink v8.8.0] " .. runtime.lastError)
        end
        -- No catch-up loops after a stall; each frame gets one bounded pass.
        task.wait(runtime.suspended and 0.15 or (F.anyFeatureEnabled() and CONFIG.performance.schedulerInterval or 0.05))
    end
end)
print("[Ink v8.8.0] Modern VirtualInput only. No legacy VIM fallback. Reports: InkGame_diagnostics_*.json in executor workspace.")
print("[Ink v8.8.0] Loaded with all automations OFF. GUI indexing is idle until a dependent feature is enabled.")
print("[Ink v8.8.0] Runtime stats: _G.__InkUltimateRuntime.getStats()")
