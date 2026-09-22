-- Pure timing logic. Sizes are compared as ratios to survive resolution/UIScale changes.
local Core = {}
local LETTERS = {Q = true, E = true, R = true, F = true, T = true}
function Core.key(text)
    if type(text) ~= "string" or #text > 160 then return nil end
    local clean = text:gsub("<[^>]*>", ""):gsub("%s", ""):upper()
    clean = clean:gsub("^%[([QERFT])%]$", "%1")
    return LETTERS[clean] and clean or nil
end

function Core.newCycle(key, moving, target)
    return {key = key, moving = moving, target = target, samples = 0,
        armed = false, fired = false, missed = false, velocity = 0, cycle = 1}
end

function Core.advance(state, ratio, now, options)
    local target = options.targetRatio
    local tolerance = options.tolerance
    if ratio ~= ratio or ratio < .05 or ratio > 20 then return false, "invalid geometry" end
    local previous, previousTime = state.ratio, state.time
    state.ratio, state.time = ratio, now
    if previous and ratio - previous > .14 then
        -- Reused controls may spend seconds idle between approaches. Detect
        -- their reset before treating that elapsed time as a sampling gap.
        state.cycle += 1
        state.samples, state.armed, state.fired, state.missed = 1, false, false, false
        state.velocity = 0
        return false, "new cycle"
    end
    if not previous or now <= previousTime then
        -- No extrapolation across a stall; a new approach must be observed.
        state.samples, state.velocity, state.armed = 1, 0, false
        return false, "sampling"
    end
    local dt = now - previousTime
    if state.fired then return false, "already sent" end
    if state.queued then return false, "queued" end
    if state.missed then return false, "window passed" end
    local velocity = (ratio - previous) / dt
    if dt>.12 then
        -- A fresh measurement inside the window can be used after a stall.
        -- Never extrapolate a stale velocity or accept an already expired ring.
        state.velocity=0;state.samples=1
        if state.armed and ratio<previous and ratio>=target-tolerance and ratio<=target+tolerance then
            return true,"aligned after gap"
        end
        state.armed=false
        return false,"sampling after gap"
    end
    state.velocity = state.samples <= 1 and velocity or state.velocity * .35 + velocity * .65
    state.samples += 1
    if previous > target-tolerance and velocity < -.015 then state.armed = true end
    if ratio < target - tolerance then
        state.missed = true
        return false, "window passed"
    end
    if not state.armed or state.samples < 2 or velocity >= -.005 then
        return false, "waiting for an approach"
    end
    -- Pick the frame nearest the target crossing. Lead is bounded to half a
    -- frame and 18ms; it cannot turn a far-away ring into an immediate press.
    local lead = math.min(dt * .5, .018) + options.leadSeconds
    local projected = ratio + state.velocity * lead
    -- Prediction chooses among valid frames; it never widens the hit window.
    if ratio <= target+tolerance and projected <= target + tolerance then
        return true, "aligned"
    end
    return false, "tracking"
end

function Core.red(color)
    return color and color.R >= .45 and color.R > color.G * 1.45 and color.R > color.B * 1.30
end

-- Ink Game QTE + Hide and Seek ESP + Smooth Aim + Bridge ESP 8.9.3.
-- G: panel visibility | P: Auto QTE toggle | Z: Smooth Aim toggle.
-- Bridge colors: red unsafe/broken, blue fragile, green safe, gray unknown.
-- Exact root observed in the supplied diagnostics: ImpactFrames.QTEHolder.
local VERSION = "8.9.3-qte-esp-aim-bridge"
local SETTINGS = {
    inputMode = "Auto", -- Auto, VirtualInput, ExecutorKeys, VirtualInputManager
    targetRatio = 1.0,
    tolerance = .025,
    leadSeconds = 0, -- Leave at zero until real prompt captures justify calibration.
    maxNodes = 192,
    maxTreeNodes = 320,
    maxPrompts = 12,
    captureFrames = 100,
}
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
assert(player, "Auto QTE must run on the client")
local env = type(getgenv) == "function" and getgenv() or _G
local GLOBAL = "__InkAutoQTE"
local previous = rawget(env, GLOBAL)
if type(previous) == "table" and type(previous.destroy) == "function" then previous.destroy() end

local old = rawget(_G, "__InkUltimateRuntime")
local legacyPending = false
if type(old) == "table" and old.bootPhase ~= "unloaded" and (old.alive or old.cleanupProtocol == 2) then
    if old.cleanupProtocol ~= 2 or type(old.shutdownAsync) ~= "function" then
        warn("[Ink QTE] Join a fresh Roblox session before replacing this older build.")
        return
    end
    old.alive, old.guiWorkEnabled = false, false
    legacyPending = true
    task.defer(function()
        task.wait()
        local ok, err = pcall(old.shutdownAsync)
        if not ok then warn("[Ink QTE] Previous build cleanup: " .. tostring(err)) end
    end)
end

local R = {
    version = VERSION, enabled = false, alive = true, epoch = 0,
    status = "OFF", backend = "not checked", backendState = "idle", lastError = "",
    connections = {}, rootConnections = {}, uiConnections = {}, nodes = {}, samples = {}, cycles = {},
    root = nil, dirty = false, scan = nil, pending = nil, held = nil, heldKeys={},
    phase = "idle", nativeStartedAt = 0, backendChecked = false,
    presses = 0, releases = 0, observedInputs = 0, maxTickMs = 0, emaTickMs = 0,
    events = {}, eventHead = 0, captures = {}, currentCapture = nil,
    captureDirty = false, reportRequested = false, reportSerial = 0,
    reportBusy = false, reportStatus = "", maxNodeCount = 0,
    focused = true, nextRootCheck = 0, nextUI = 0, nextFocusCheck = 0,
    nextReport = 0, shuttingDown = false, destroying = false, overLimit = false,
    treeGeneration = 0, captureGeneration = -1, uiHidden=false, hotkeyTimes={},
}
env[GLOBAL] = R
local backend, ui, ESP, updateESP, Aim, Bridge
local function event(kind, details)
    R.eventHead = R.eventHead % 64 + 1
    R.events[R.eventHead] = {time = os.clock(), kind = kind, details = details}
end
local function connect(signal, fn, list)
    local connection = signal:Connect(fn)
    table.insert(list or R.connections, connection)
    return connection
end
local function disconnect(list)
    for _, connection in ipairs(list) do connection:Disconnect() end
    table.clear(list)
end
local function stop(reason)
    -- Called by UI/hotkeys/focus handlers: scalar writes ONLY. Never traverse
    -- instances, send key-up, wait, cancel coroutines, or invoke old callbacks.
    R.enabled = false
    R.epoch += 1
    R.status = reason or "OFF"
end
function R.setEnabled(value)
    if not R.alive or R.destroying then return end
    R.enabled = value == true
    R.epoch += 1
    R.status = R.enabled and "Starting" or "OFF"
end
function R.destroy()
    stop("Unloading")
    if Aim then Aim.enabled=false end
    if Bridge then Bridge.bridge=false end
    R.destroying = true
end
function R.saveReport() R.reportRequested = true end

local function playerGui()
    return player:FindFirstChildOfClass("PlayerGui")
end
local function findRoot()
    local pg = playerGui()
    local impact = pg and pg:FindFirstChild("ImpactFrames")
    return impact and impact:FindFirstChild("QTEHolder") or nil
end
local function finishCapture()
    if not R.currentCapture then return end
    local capture = R.currentCapture
    R.currentCapture = nil
    if #capture.frames > 0 then
        capture.endedAt = os.clock()
        table.insert(R.captures, capture)
        if #R.captures > 3 then table.remove(R.captures, 1) end
        R.captureDirty = true
    end
end
local function unbind()
    disconnect(R.rootConnections) -- at most two connections
    finishCapture()
    R.root, R.scan, R.dirty = nil, nil, false
    R.nodes, R.samples, R.cycles = {}, {}, {}
    R.overLimit = false
end
local function bind(root)
    if root == R.root then return end
    unbind()
    if not root then return end
    R.root, R.dirty = root, true
    connect(root.DescendantAdded, function() R.dirty = true end, R.rootConnections)
    connect(root.DescendantRemoving, function() R.dirty = true end, R.rootConnections)
    event("root-bound", {path = "PlayerGui.ImpactFrames.QTEHolder"})
end

local function rebuild()
    if not R.scan then
        if not R.dirty then return end
        R.dirty = false
        R.scan = {queue = {R.root}, head = 1, nodes = {}, visited = 0, limit = false}
    end
    local scan, start = R.scan, os.clock()
    local count = 0
    while scan.head <= #scan.queue and count < 24 and os.clock() - start < .0007 do
        local obj = scan.queue[scan.head]
        scan.head += 1
        scan.visited += 1
        count += 1
        if obj == R.root or obj:IsDescendantOf(R.root) then
            if obj ~= R.root and obj:IsA("GuiObject") then
                if #scan.nodes >= SETTINGS.maxNodes then scan.limit = true; break end
                table.insert(scan.nodes, obj)
            end
            local children = obj:GetChildren()
            for i = 1, #children do
                if #scan.queue >= SETTINGS.maxTreeNodes then scan.limit = true; break end
                table.insert(scan.queue, children[i])
            end
            if scan.limit then break end
        end
    end
    if scan.limit or scan.head > #scan.queue then
        -- Keep only samples of the current bounded tree; no tombstones accumulate.
        local samples, cycles = {}, {}
        for _, obj in ipairs(scan.nodes) do
            samples[obj], cycles[obj] = R.samples[obj], R.cycles[obj]
        end
        R.nodes, R.samples, R.cycles = scan.nodes, samples, cycles
        R.maxNodeCount = math.max(R.maxNodeCount, #R.nodes)
        R.overLimit, R.scan = scan.limit, nil
        R.treeGeneration += 1
    end
end

local function visible(obj)
    if not obj.Parent or not R.root or not obj:IsDescendantOf(R.root) then return false end
    local cursor, depth = obj, 0
    while cursor and depth < 24 do
        if cursor:IsA("GuiObject") then
            if not cursor.Visible then return false end
            if cursor:IsA("CanvasGroup") and cursor.GroupTransparency >= .99 then return false end
        elseif cursor:IsA("LayerCollector") and not cursor.Enabled then return false end
        cursor, depth = cursor.Parent, depth + 1
    end
    local p, s = obj.AbsolutePosition, obj.AbsoluteSize
    if s.X < 4 or s.Y < 4 then return false end
    local camera = Workspace.CurrentCamera
    if camera then
        local viewport = camera.ViewportSize
        if p.X + s.X <= 0 or p.Y + s.Y <= 0 or p.X >= viewport.X or p.Y >= viewport.Y then return false end
    end
    return true
end
local function textOf(obj)
    if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then return obj.Text end
    return ""
end
local function circle(obj, sample)
    if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then return false end
    if sample.w < 12 or sample.w > 650 or math.abs(sample.w - sample.h) > sample.w * .12 then return false end
    if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
        return obj.Image ~= "" and obj.ImageTransparency < .99
    end
    local corner = obj:FindFirstChildOfClass("UICorner")
    return corner ~= nil and (corner.CornerRadius.Scale >= .45 or corner.CornerRadius.Offset >= sample.w * .45)
end
local function targetScore(obj)
    local red = false
    if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then red = Core.red(obj.ImageColor3) end
    if obj.BackgroundTransparency < .99 then red = red or Core.red(obj.BackgroundColor3) end
    local stroke = obj:FindFirstChildOfClass("UIStroke")
    if stroke and stroke.Enabled and stroke.Transparency < .99 then red = red or Core.red(stroke.Color) end
    local name = obj.Name:lower()
    local named = name:find("target", 1, true) or name:find("red", 1, true)
        or name:find("inner", 1, true) or name:find("goal", 1, true)
    return red and 10 or (named and 3 or 0)
end
local function sampleObjects(now)
    local keys, circles = {}, {}
    for _, obj in ipairs(R.nodes) do
        if visible(obj) then
            local p, size = obj.AbsolutePosition, obj.AbsoluteSize
            local prior = R.samples[obj]
            local sample = {
                x = p.X + size.X * .5, y = p.Y + size.Y * .5, w = size.X, h = size.Y,
                time = now, count = 1, stable = false,
            }
            if prior and now - prior.time <= .12 then
                sample.previousWidth,sample.previousTime=prior.w,prior.time
                sample.count = prior.count + 1
                sample.velocity = (sample.w - prior.w) / math.max(.001, now - prior.time)
                sample.stable = math.abs(sample.velocity) <= math.max(.5, sample.w * .008)
            end
            R.samples[obj] = sample
            local key = Core.key(textOf(obj))
            if key and size.X <= 350 and size.Y <= 350 and #keys < SETTINGS.maxPrompts then
                table.insert(keys, {obj = obj, key = key, sample = sample})
            elseif circle(obj, sample) and #circles < 48 then
                table.insert(circles, {obj = obj, sample = sample, score = targetScore(obj)})
            end
        else
            R.samples[obj], R.cycles[obj] = nil, nil
        end
    end
    return keys, circles
end
local function near(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy <= math.max(8, math.min(a.w, b.w) * .10) ^ 2
end
local function selectPair(prompt, circles)
    local cached=R.cycles[prompt.obj]
    if cached and cached.key==prompt.key and visible(cached.moving) and visible(cached.target) then
        local moving,target=R.samples[cached.moving],R.samples[cached.target]
        if moving and target and near(prompt.sample,moving) and near(moving,target)
            and math.abs(target.w-(cached.targetWidth or target.w))<=target.w*.02 then
            local ratio=moving.w/target.w
            if ratio>=.05 and ratio<=5 then
                return {moving={obj=cached.moving,sample=moving},target={obj=cached.target,sample=target},ratio=ratio,score=100},"tracking"
            end
        end
    end
    local stationary, moving = {}, {}
    for _, candidate in ipairs(circles) do
        local s = candidate.sample
        if near(prompt.sample, s) and s.count >= 2 then
            if s.stable then table.insert(stationary, candidate)
            elseif (s.velocity or 0) < -1 then table.insert(moving, candidate) end
        end
    end
    local best, ambiguous
    for _, target in ipairs(stationary) do
        for _, ring in ipairs(moving) do
            local ratio = ring.sample.w / target.sample.w
            if ratio >= .85 and ratio <= 5 and near(ring.sample, target.sample) then
                local score = target.score + (ring.obj.Parent == target.obj.Parent and 1 or 0)
                if not best or score > best.score then
                    best, ambiguous = {moving = ring, target = target, ratio = ratio, score = score}, false
                elseif score == best.score and (ring.obj ~= best.moving.obj
                    or math.abs(target.sample.w - best.target.sample.w) > target.sample.w * .04) then
                    ambiguous = true
                end
            end
        end
    end
    if ambiguous then return nil, "Multiple target rings; capture retained" end
    return best, best and "tracking" or "Waiting for a shrinking ring and its target"
end

local function canPress()
    return R.alive and R.enabled and not R.destroying and R.focused and not legacyPending
        and not GuiService.MenuIsOpen and UIS:GetFocusedTextBox() == nil
end
local function resolveBackend()
    if R.backendChecked or R.phase ~= "idle" then return end
    R.backendChecked, R.backendState, R.phase = true, "checking", "resolve"
    R.nativeStartedAt = os.clock()
    task.defer(function()
        if not R.enabled or R.destroying then
            R.backendChecked, R.backendState, R.phase = false, "idle", "idle"
            return
        end
        local mode, errors = SETTINGS.inputMode, {}
        local press = env.keypress or keypress
        local release = env.keyrelease or keyrelease
        -- Probe capabilities only. No key is sent during backend selection.
        if (mode == "Auto" or mode == "ExecutorKeys") and type(press) == "function" and type(release) == "function" then
            backend = function(down, key) if down then press(string.byte(key)) else release(string.byte(key)) end end
            R.backend = "ExecutorKeys"
        end
        if not backend and (mode == "Auto" or mode == "VirtualInput") then
            local ok, result = pcall(function() return UIS:CreateVirtualInput() end)
            if ok and result then
                backend = function(down, key) result:SendKey(down, Enum.KeyCode[key], false) end
                R.backend = "VirtualInput"
            else table.insert(errors, "VirtualInput: " .. tostring(result)) end
        end
        if not backend and (mode == "Auto" or mode == "VirtualInputManager") then
            local ok, result = pcall(function() return game:GetService("VirtualInputManager") end)
            if ok and result then
                backend = function(down, key) result:SendKeyEvent(down, Enum.KeyCode[key], false, game) end
                R.backend = "VirtualInputManager"
            else table.insert(errors, "VirtualInputManager: " .. tostring(result)) end
        end
        R.phase = "idle"
        R.backendState = backend and "selected; delivery unverified" or "unavailable"
        event("backend", {name = R.backend, state = R.backendState})
        if not backend then
            R.lastError = #errors > 0 and table.concat(errors, " | ") or "Requested keyboard functions are unavailable"
            stop("No keyboard input method is available; save report")
            R.reportRequested = true
        end
    end)
end
local function dispatch(due)
    if R.pending or R.phase~="idle" or not backend or not canPress() then return false end
    local batch,used={},{}
    for _,item in ipairs(due) do
        local prompt,pair,state=item.prompt,item.pair,item.state
        if not used[prompt.key] and not state.fired and not state.queued then
            used[prompt.key]=true;state.queued=true
            table.insert(batch,{epoch=R.epoch,key=prompt.key,obj=prompt.obj,moving=pair.moving.obj,
                target=pair.target.obj,state=state,cycle=state.cycle,at=os.clock()})
        end
    end
    if #batch==0 then return false end
    R.pending,R.phase=batch,"queued"
    task.defer(function()
        local held={}
        for _,request in ipairs(batch) do
            local state=request.state
            local valid=request.epoch==R.epoch and canPress() and state.cycle==request.cycle
                and os.clock()-request.at<=.10 and visible(request.obj)
                and visible(request.moving) and visible(request.target)
                and Core.key(textOf(request.obj))==request.key
            local ratio
            if valid then
                ratio=request.moving.AbsoluteSize.X/math.max(1,request.target.AbsoluteSize.X)
                valid=ratio>=SETTINGS.targetRatio-SETTINGS.tolerance and ratio<=SETTINGS.targetRatio+SETTINGS.tolerance
            end
            state.queued=false
            if valid then
                -- All distinct aligned keys go down before the hold delay.
                -- Each attempted down receives exactly one release, even on OFF/error.
                state.fired=true
                table.insert(held,request.key);R.heldKeys[request.key]=true
                R.held,R.phase,R.nativeStartedAt=request.key,"key-down",os.clock()
                event("input-begin",{key=request.key,ratio=ratio,backend=R.backend,queueMs=(os.clock()-request.at)*1000})
                local ok,err=pcall(backend,true,request.key)
                if ok then R.presses+=1;R.backendState="call returned; check event count"
                else
                    R.lastError="Key-down: "..tostring(err);stop("Keyboard call failed; save report");R.reportRequested=true
                end
            else
                -- Cancellation is not a completed press. A still-valid later
                -- sample may retry without a permanently latched fired flag.
                event("input-cancelled",{key=request.key})
            end
        end
        if #held>0 then
            R.phase="holding";task.wait(.016)
            for _,key in ipairs(held) do
                R.phase,R.nativeStartedAt="key-up",os.clock()
                local ok,err=pcall(backend,false,key)
                R.heldKeys[key]=nil
                if ok then R.releases+=1
                else R.lastError="Key-up: "..tostring(err);stop("Key release failed; save report");R.reportRequested=true end
                event("input-end",{key=key,upOK=ok})
            end
        end
        R.held,R.pending,R.phase=nil,nil,"idle"
    end)
    return true
end

local function capture(now, keys)
    -- Capture all QTE children, including unnamed images/hidden templates. Never
    -- inspect dialogue, quest lists, player names, chat, or the rest of PlayerGui.
    if #R.nodes == 0 then finishCapture(); return end
    if #keys == 0 and not R.currentCapture and R.captureGeneration == R.treeGeneration then return end
    if not R.currentCapture then
        R.captureGeneration = R.treeGeneration
        R.currentCapture = {startedAt = now, root = "PlayerGui.ImpactFrames.QTEHolder",
            nodes = {}, frames = {}, ids = {}, head = 0, lastFrameAt = 0}
    end
    local c = R.currentCapture
    if now - c.lastFrameAt < .025 then return end
    c.lastFrameAt = now
    local frame = {time = now, geometry = {}, status = R.status}
    for _, obj in ipairs(R.nodes) do
        local id = c.ids[obj]
        if not id and #c.nodes < SETTINGS.maxTreeNodes then
            id = #c.nodes + 1
            c.ids[obj] = id
            local relativePath = obj.Name
            local cursor = obj.Parent
            for _ = 1, 16 do
                if not cursor or cursor == R.root then break end
                relativePath = cursor.Name .. "." .. relativePath
                cursor = cursor.Parent
            end
            local description = {id = id, path = relativePath, class = obj.ClassName, text = textOf(obj):sub(1, 160)}
            if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
                description.image = obj.Image
                description.imageColor = {obj.ImageColor3.R, obj.ImageColor3.G, obj.ImageColor3.B}
            end
            table.insert(c.nodes, description)
        end
        if id then
            local p, size = obj.AbsolutePosition, obj.AbsoluteSize
            table.insert(frame.geometry, {id, p.X, p.Y, size.X, size.Y, obj.Rotation,
                obj.Visible and 1 or 0, textOf(obj):sub(1, 16)})
        end
    end
    c.head = c.head % SETTINGS.captureFrames + 1
    c.frames[c.head] = frame
    -- Retain completed sequences; do not let empty idle frames overwrite them.
    if (#keys == 0 and now - c.startedAt > .7) or now - c.startedAt > 6 then finishCapture() end
end
local function copyCapture(c)
    local frames = table.clone(c.frames)
    table.sort(frames, function(a, b) return a.time < b.time end)
    return {startedAt = c.startedAt, endedAt = c.endedAt, root = c.root, nodes = table.clone(c.nodes), frames = frames}
end
function R.getStats()
    return {version = VERSION, placeId = game.PlaceId, enabled = R.enabled, status = R.status,
        rootBound = R.root ~= nil, guiNodes = #R.nodes, peakGuiNodes = R.maxNodeCount,
        rootWatchers = #R.rootConnections, connections = #R.connections + #R.rootConnections + #R.uiConnections,
        backend = R.backend, backendState = R.backendState, phase = R.phase,
        presses = R.presses, releases = R.releases, inputEventsObserved = R.observedInputs,
        maxTickMs = R.maxTickMs, emaTickMs = R.emaTickMs, lastError = R.lastError,
        truncated = R.overLimit, legacyCleanupPending = legacyPending,hideSeek=ESP and ESP.report(),aim=Aim and Aim.report(),bridge=Bridge and Bridge.report(),panelHidden=R.uiHidden}
end
local function saveReport()
    if R.reportBusy then return end
    local writer = env.writefile or writefile
    R.reportRequested = false
    R.nextReport = os.clock() + 15
    R.reportBusy = true
    -- Detach a bounded snapshot. Encoding/disk I/O never run in a GUI callback.
    local captures = {}
    for _, c in ipairs(R.captures) do table.insert(captures, copyCapture(c)) end
    if R.currentCapture then table.insert(captures, copyCapture(R.currentCapture)) end
    local events = table.clone(R.events)
    table.sort(events, function(a, b) return a.time < b.time end)
    local report = {stats = R.getStats(), settings = SETTINGS, events = events, captures = captures,
        geometryColumns = {"id", "x", "y", "width", "height", "rotation", "visible", "text"}}
    R.lastReport = report
    R.captureDirty = false
    if type(writer) ~= "function" then
        R.reportStatus = "writefile unavailable; report retained in memory"
        R.reportBusy = false
        return
    end
    task.defer(function()
        R.reportSerial += 1
        local stamp=DateTime and DateTime.now().UnixTimestampMillis or math.floor(os.clock()*1000)
        local filename = "InkGame_QTE_v893_"..tostring(stamp).."_"..R.reportSerial..".json"
        local ok, err = pcall(function() writer(filename, HttpService:JSONEncode(report)) end)
        R.reportStatus = ok and ("Saved " .. filename) or ("Report failed: " .. tostring(err))
        R.reportBusy = false
        if ok then print("[Ink QTE] " .. R.reportStatus) end
    end)
end

-- Role-only overlays: no world scans or gameplay mutations. Unknown players
-- are left unclassified instead of being silently treated as hiders.
ESP={hider=false,seeker=false,entries={},roster={},cursor=1,nextRoster=0,roles={},lastError=""}
local ROLE_COLORS={hider=Color3.fromRGB(50,145,255),seeker=Color3.fromRGB(255,65,75)}
local ROLE_KEYS={"HideAndSeekRole","HideSeekRole","HideAndSeekTeam","HNSRole","Role","PlayerRole"}
local function normalized(value)
    return type(value)=="string" and value:lower():gsub("[^a-z]","") or ""
end
local function roleValue(value,colors)
    local n=normalized(value)
    if n=="hider" or n=="hiders" or n=="hiding" or n=="hiderteam" then return "hider" end
    if n=="seeker" or n=="seekers" or n=="seeking" or n=="seekerteam" then return "seeker" end
    if colors then
        if n=="blueteam" or n=="blue" then return "hider" end
        if n=="redteam" or n=="red" then return "seeker" end
    end
end
local function readRole(subject)
    local character=subject.Character
    local role,source,conflict
    local function offer(found,why)
        if not found then return end
        if role and role~=found then conflict=true else role,source=found,why end
    end
    for _,obj in ipairs(character and {subject,character} or {subject}) do
        for _,key in ipairs(ROLE_KEYS) do
            offer(roleValue(obj:GetAttribute(key),key~="Role" and key~="PlayerRole"),"attribute:"..key)
            local child=obj:FindFirstChild(key)
            if child and child:IsA("StringValue") then offer(roleValue(child.Value,true),"value:"..key) end
        end
        for _,key in ipairs({"Hider","IsHider","Seeker","IsSeeker"}) do
            local value=obj:GetAttribute(key)
            local child=obj:FindFirstChild(key)
            if value==true or (child and child:IsA("BoolValue") and child.Value) then
                offer(key:find("Hider",1,true) and "hider" or "seeker","flag:"..key)
            end
        end
    end
    if conflict then return nil,"conflicting role flags" end
    if role then return role,source end
    if subject.Team and subject.Neutral~=true then
        local teamRole=roleValue(subject.Team.Name,true)
        if teamRole then return teamRole,"team:"..subject.Team.Name end
    end
    -- Inspect only tools replicated to this client, never infer a role from
    -- ordinary clothes or the absence of a weapon.
    local backpack=subject:FindFirstChildOfClass("Backpack")
    for _,container in ipairs(character and {character,backpack} or {backpack}) do
        if container then
            for _,tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") then
                    local name=normalized(tool.Name)
                    if name=="dodge" then offer("hider","tool:"..tool.Name)
                    elseif name=="knife" or name=="seekerknife" then offer("seeker","tool:"..tool.Name) end
                end
            end
        end
    end
    if conflict then return nil,"conflicting role tools" end
    return role,source or "role unavailable"
end
function R.setESP(role,enabled)
    if R.destroying or (role~="hider" and role~="seeker") then return end
    ESP[role]=enabled==true;ESP.nextRoster=0
end
local function removeESP(subject)
    local entry=ESP.entries[subject]
    if entry then
        entry.highlight:Destroy();entry.label:Destroy();ESP.entries[subject]=nil
    end
    ESP.roles[subject]=nil
end
local function showESP(subject,character,role,source)
    local root=character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Head")
    if not root then removeESP(subject);return end
    local entry=ESP.entries[subject]
    if entry and (entry.character~=character or not entry.highlight.Parent or not entry.label.Parent) then removeESP(subject);entry=nil end
    if not entry then
        local highlight=Instance.new("Highlight")
        highlight.Name="InkHideSeekOutline";highlight.Adornee=character
        highlight.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop
        highlight.FillTransparency=.65;highlight.OutlineTransparency=.05;highlight.Parent=character
        local label=Instance.new("BillboardGui")
        label.Name="InkHideSeekRole";label.Adornee=root;label.AlwaysOnTop=true
        label.Size=UDim2.new(0,180,0,24);label.StudsOffset=Vector3.new(0,3.5,0);label.MaxDistance=2500
        local text=Instance.new("TextLabel")
        text.Size=UDim2.new(1,0,1,0);text.BackgroundTransparency=1;text.Font=Enum.Font.Code
        text.TextSize=13;text.TextStrokeTransparency=.25;text.Parent=label
        label.Parent=playerGui()
        entry={character=character,highlight=highlight,label=label,text=text};ESP.entries[subject]=entry
    end
    entry.role=role;entry.label.Adornee=root
    entry.highlight.FillColor=ROLE_COLORS[role];entry.highlight.OutlineColor=ROLE_COLORS[role]
    entry.text.TextColor3=ROLE_COLORS[role]
    entry.text.Text=(role=="hider" and "HIDER" or "SEEKER").." | "..(subject.DisplayName or subject.Name)
    ESP.roles[subject]={role=role,source=source}
end
updateESP=function(now)
    -- Cleanup also runs when QTE is OFF; toggling one feature never freezes or
    -- enables another. Work is capped independently of the timing controller.
    for subject,entry in pairs(ESP.entries) do
        if R.destroying or not ESP[entry.role] or not subject.Parent or subject.Character~=entry.character then removeESP(subject) end
    end
    if R.destroying or not (ESP.hider or ESP.seeker) then
        ESP.roster={};ESP.roles={};ESP.cursor=1;return
    end
    if ESP.nextRoster==0 or (now>=ESP.nextRoster and ESP.cursor>#ESP.roster) then
        ESP.nextRoster=now+.3
        ESP.roster=Players:GetPlayers();ESP.cursor=1
        local present={};for _,subject in ipairs(ESP.roster) do present[subject]=true end
        for subject in pairs(ESP.roles) do if not present[subject] then removeESP(subject) end end
    end
    local started=os.clock()
    for _=1,4 do
        if os.clock()-started>.0006 then break end
        local subject=ESP.roster[ESP.cursor];ESP.cursor+=1
        if not subject then break end
        if subject~=player then
            local character=subject.Character
            local humanoid=character and character:FindFirstChildOfClass("Humanoid")
            if not character or not character.Parent or not humanoid or humanoid.Health<=0 then removeESP(subject)
            else
                local role,source=readRole(subject)
                if role and ESP[role] then showESP(subject,character,role,source)
                else removeESP(subject);ESP.roles[subject]={role=role,source=source} end
            end
        end
    end
end
function ESP.report()
    local rows={}
    for subject,result in pairs(ESP.roles) do
        if #rows>=128 then break end
        table.insert(rows,{userId=subject.UserId,role=result.role,source=result.source,team=subject.Team and subject.Team.Name})
    end
    return {hider=ESP.hider,seeker=ESP.seeker,lastError=ESP.lastError,players=rows}
end

local AimMath={}
function AimMath.dot(a,b) return a.X*b.X+a.Y*b.Y+a.Z*b.Z end
function AimMath.angle(a,b) return math.acos(math.clamp(AimMath.dot(a,b),-1,1)) end
function AimMath.finite(v)
    return v.X==v.X and v.Y==v.Y and v.Z==v.Z and math.abs(v.X)<1e8 and math.abs(v.Y)<1e8 and math.abs(v.Z)<1e8
end
function AimMath.limit(v,maximum)
    local length=v.Magnitude
    return length>maximum and v*(maximum/length) or v
end
function AimMath.smooth(from,to,dt,response,maxRadians)
    dt=math.clamp(dt,0,1/15)
    local angle=AimMath.angle(from,to)
    if angle<.00001 then return to end
    local alpha=math.min(1-math.exp(-response*dt),maxRadians*dt/angle)
    local sine=math.sin(angle)
    if math.abs(sine)<.00001 then return from end
    return (from*(math.sin((1-alpha)*angle)/sine)+to*(math.sin(alpha*angle)/sine)).Unit
end

-- Z toggles camera tracking. No clicks, attacks, character movement, or
-- server calls. Same-team players remain eligible in free-for-all rounds.
Aim={enabled=false,status="Aim OFF",target=nil,direction=nil,velocity=nil,lastPoint=nil,
    camera=nil,localCharacter=nil,search=nil,index=1,nextSearch=0,nextFocus=0,lastZ=-1,
    blockedAt=nil,profile=2,fovIndex=2,lastError="",maxTickMs=0,writes=0,bound=false}
local AIM_PROFILES={{name="Soft",response=8,speed=160},{name="Balanced",response=12,speed=240},
    {name="Strong",response=18,speed=320}}
local AIM_FOV={{name="Narrow",degrees=16},{name="Medium",degrees=28},{name="Wide",degrees=40}}
local AIM_SETTINGS={maxDistance=160,checkTeams=false,prediction=.025,maxLead=1.25,
    maxCandidates=128,searchInterval=.10,blockedGrace=.14}
local AIM_BIND="InkSmoothAim_"..tostring(R):gsub("%W","")
local aimRay=RaycastParams.new()
aimRay.FilterType=Enum.RaycastFilterType.Exclude
aimRay.IgnoreWater=true
local function clearAim(status)
    Aim.target,Aim.direction,Aim.velocity,Aim.lastPoint=nil,nil,nil,nil
    Aim.search,Aim.index,Aim.nextSearch,Aim.blockedAt=nil,1,0,nil
    Aim.status=status or "No visible target"
end
function R.setAimEnabled(enabled)
    if R.destroying or not R.alive then return end
    if enabled and not Aim.bound then Aim.status="Aim unavailable: save report";return end
    Aim.enabled=enabled==true;Aim.lastError=""
    clearAim(Aim.enabled and "Finding a target" or "Aim OFF")
end
function R.cycleAimProfile()
    Aim.profile=Aim.profile%#AIM_PROFILES+1
end
function R.cycleAimFOV()
    Aim.fovIndex=Aim.fovIndex%#AIM_FOV+1
    clearAim(Aim.enabled and "Finding a target" or "Aim OFF")
end
local function aimExcluded(subject,character)
    for _,obj in ipairs({subject,character}) do
        for _,name in ipairs({"Spectating","IsSpectator","Spectator","Eliminated","Dead"}) do
            if obj:GetAttribute(name)==true then return true end
        end
    end
    local team=subject.Team
    local name=team and team.Name:lower():gsub("[^a-z]","") or ""
    return name=="spectator" or name=="spectators" or name=="lobby" or name=="dead"
end
local function aimCharacter(subject)
    local character=subject and subject.Character
    if not character or not character:IsDescendantOf(Workspace) then return nil end
    local humanoid=character:FindFirstChildOfClass("Humanoid")
    local root=character:FindFirstChild("HumanoidRootPart")
    if not humanoid or humanoid.Health<=0 or not root or not root:IsA("BasePart") then return nil end
    return character,humanoid,root
end
local function measureAim(subject,camera,localRoot,retained)
    if subject==player or not subject.Parent then return nil end
    local character,_,root=aimCharacter(subject)
    if not character or aimExcluded(subject,character) then return nil end
    if AIM_SETTINGS.checkTeams and player.Team and subject.Team==player.Team and not player.Neutral and not subject.Neutral then return nil end
    local part=character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
        or character:FindFirstChild("Head") or root
    if not part:IsA("BasePart") or (part~=root and part.Transparency>=.99) then return nil end
    local point=part.Position
    if not AimMath.finite(point) then return nil end
    local distance=(root.Position-localRoot.Position).Magnitude
    if distance>AIM_SETTINGS.maxDistance then return nil end
    local delta=point-camera.CFrame.Position
    if delta.Magnitude<.1 then return nil end
    local projected,onScreen=camera:WorldToViewportPoint(point)
    if not onScreen or projected.Z<=0 then return nil end
    local angle=AimMath.angle(camera.CFrame.LookVector,delta.Unit)
    local fov=math.rad(AIM_FOV[Aim.fovIndex].degrees)*(retained and 1.4 or 1)
    if angle>fov then return nil end
    return {subject=subject,character=character,part=part,root=root,point=point,
        distance=distance,angle=angle,score=angle/fov+distance/AIM_SETTINGS.maxDistance*.08}
end
local function sight(camera,measurement,localCharacter)
    aimRay.FilterDescendantsInstances={localCharacter,camera}
    local origin=camera.CFrame.Position
    local result=Workspace:Raycast(origin,measurement.point-origin,aimRay)
    return not result or result.Instance:IsDescendantOf(measurement.character)
end
local function startAimSearch(camera,localRoot,now)
    local candidates={}
    for i,subject in ipairs(Players:GetPlayers()) do
        if i>AIM_SETTINGS.maxCandidates then break end
        local measurement=measureAim(subject,camera,localRoot,false)
        if measurement then table.insert(candidates,measurement) end
    end
    table.sort(candidates,function(a,b)
        if math.abs(a.score-b.score)<.00001 then return a.subject.UserId<b.subject.UserId end
        return a.score<b.score
    end)
    Aim.search,Aim.index,Aim.nextSearch=candidates,1,now+AIM_SETTINGS.searchInterval
end
function Aim.step(dt)
    if R.destroying or not R.alive or not Aim.enabled then return end
    local now=os.clock()
    if now>=Aim.nextFocus then
        Aim.nextFocus=now+.15
        local active=env.isrbxactive or isrbxactive
        if type(active)=="function" then local ok,value=pcall(active);if ok then R.focused=value==true end end
    end
    if not R.focused or GuiService.MenuIsOpen or UIS:GetFocusedTextBox()~=nil then clearAim("Aim paused: focus or menu");return end
    if R.pending or R.held then clearAim("Aim paused: QTE");return end
    if R.enabled and R.root then
        -- This also covers the first sample, before a prompt has a cycle.
        for _,obj in ipairs(R.nodes) do
            if Core.key(textOf(obj)) and visible(obj) then clearAim("Aim paused: QTE");return end
        end
    end
    local character,humanoid,root=aimCharacter(player)
    if not character or aimExcluded(player,character) then clearAim("Aim paused: waiting for your character");return end
    local camera=Workspace.CurrentCamera
    if not camera then clearAim("Aim paused: no camera");return end
    if camera.CameraType==Enum.CameraType.Scriptable then clearAim("Aim paused: cutscene camera");return end
    local cameraSubject=camera.CameraSubject
    if cameraSubject and cameraSubject~=humanoid and cameraSubject~=character and not cameraSubject:IsDescendantOf(character) then
        clearAim("Aim paused: spectating");return
    end
    if camera~=Aim.camera or character~=Aim.localCharacter then
        clearAim("Finding a target");Aim.camera,Aim.localCharacter=camera,character
    end
    local measurement=Aim.target and measureAim(Aim.target.subject,camera,root,true)
    if Aim.target and (not measurement or measurement.character~=Aim.target.character) then clearAim("Finding a target");measurement=nil end
    if measurement and not sight(camera,measurement,character) then
        Aim.blockedAt=Aim.blockedAt or now
        Aim.direction=nil;Aim.velocity=nil
        if now-Aim.blockedAt<AIM_SETTINGS.blockedGrace then Aim.status="Target behind cover";return end
        clearAim("Finding a visible target");measurement=nil
    end
    if not measurement then
        if not Aim.search and now>=Aim.nextSearch then startAimSearch(camera,root,now) end
        if Aim.search then
            -- At most four acquisition rays per render. Continue through the
            -- shortlist on following frames instead of rescanning from the top.
            for _=1,4 do
                local candidate=Aim.search[Aim.index];Aim.index+=1
                if not candidate then Aim.search=nil;break end
                local current=measureAim(candidate.subject,camera,root,false)
                if current and sight(camera,current,character) then
                    measurement=current;Aim.target=current;Aim.search=nil
                    Aim.direction=camera.CFrame.LookVector;Aim.velocity=Vector3.new(0,0,0)
                    Aim.lastPoint=current.point
                    break
                end
            end
        end
        if not measurement then Aim.status="No visible target inside aim FOV";return end
    end
    Aim.blockedAt=nil
    local elapsed=math.clamp(type(dt)=="number" and dt or 1/60,0,1/15)
    if type(dt)~="number" or dt>.15 then Aim.direction=camera.CFrame.LookVector;elapsed=1/60 end
    local velocity=measurement.root.AssemblyLinearVelocity
    if not velocity or not AimMath.finite(velocity) then velocity=Vector3.new(0,0,0) end
    velocity=AimMath.limit(velocity,70)
    if Aim.lastPoint and (measurement.point-Aim.lastPoint).Magnitude>12 then velocity=Vector3.new(0,0,0);Aim.velocity=velocity end
    Aim.velocity=(Aim.velocity or velocity)+(velocity-(Aim.velocity or velocity))*(1-math.exp(-12*elapsed))
    Aim.lastPoint=measurement.point
    local lead=AimMath.limit(Aim.velocity*AIM_SETTINGS.prediction,AIM_SETTINGS.maxLead)
    local delta=measurement.point+lead-camera.CFrame.Position
    if delta.Magnitude<.1 then delta=measurement.point-camera.CFrame.Position end
    local desired=delta.Unit
    local profile=AIM_PROFILES[Aim.profile]
    Aim.direction=AimMath.smooth(Aim.direction or camera.CFrame.LookVector,desired,elapsed,profile.response,math.rad(profile.speed))
    -- Keep the smoothed direction across camera-controller updates. Resetting
    -- interpolation from the game's base rotation each frame can stall tracking.
    local position=camera.CFrame.Position
    camera.CFrame=CFrame.lookAt(position,position+Aim.direction,Vector3.new(0,1,0))
    Aim.writes+=1
    Aim.status="Tracking "..(measurement.subject.DisplayName or measurement.subject.Name)
end
function Aim.destroy()
    Aim.enabled=false;clearAim("Aim OFF")
    if Aim.bound then RunService:UnbindFromRenderStep(AIM_BIND);Aim.bound=false end
end
function Aim.report()
    return {enabled=Aim.enabled,status=Aim.status,profile=AIM_PROFILES[Aim.profile].name,
        fovDegrees=AIM_FOV[Aim.fovIndex].degrees,targetId=Aim.target and Aim.target.subject.UserId,
        maxTickMs=Aim.maxTickMs,writes=Aim.writes,lastError=Aim.lastError}
end
local aimBound,aimBindError=pcall(function()
    RunService:BindToRenderStep(AIM_BIND,Enum.RenderPriority.Camera.Value+1,function(dt)
        local start=os.clock()
        local ok,err=pcall(Aim.step,dt)
        Aim.maxTickMs=math.max(Aim.maxTickMs,(os.clock()-start)*1000)
        if not ok then
            Aim.enabled=false;clearAim("Aim error: save report");Aim.lastError=tostring(err)
            event("aim-error",{error=Aim.lastError})
        end
    end)
end)
Aim.bound=aimBound
if not aimBound then Aim.lastError=tostring(aimBindError);Aim.status="Aim render binding unavailable" end

-- Reuses the previously tested Bridge renderer/classifier in an isolated scope.
Bridge = (function()
    local State = {bridge=false, glassStatus="Glass ESP OFF", lastError=""}
    local World = Workspace
    local Core = {}
    local function normalize(text) return text:lower():gsub("[^a-z0-9]", "") end
    local function excluded(name)
        local n=normalize(name)
        return n:find("chat",1,true) or n:find("dialogue",1,true) or n:find("odds",1,true)
            or n:find("shop",1,true) or n:find("backpack",1,true) or n:find("inventory",1,true)
            or n:find("inkauto",1,true) or n:find("inkpentbridge",1,true) or n:find("playerlist",1,true)
    end
    function Core.glass(evidence)
    if evidence.broken == true then return "unsafe", "BROKEN" end
    -- An animation/delay must be explicit. CanCollide, transparency, panel
    -- ordering and the opposite panel's status cannot establish safety.
    if evidence.fragile == true or (type(evidence.breakDelay) == "number" and evidence.breakDelay > 0
        and (evidence.unsafe == true or evidence.safe == false))
        or evidence.breaking == true then
        return "fragile", "FRAGILE"
    end
    if evidence.safe == true and evidence.unsafe ~= true then return "safe", "SAFE" end
    if evidence.unsafe == true or evidence.safe == false then return "unsafe", "UNSAFE" end
    return "unknown", "UNKNOWN"
end

    local function scanNew(root, depth, limit, accept)
    return {queue={{obj=root, depth=0}}, head=1, result={}, maxDepth=depth, limit=limit, accept=accept, done=false, truncated=false}
end
local function scanStep(scan)
    local start, steps = os.clock(), 0
    while scan.head <= #scan.queue and steps < 24 and os.clock()-start < .0007 do
        local entry = scan.queue[scan.head]; scan.head += 1; steps += 1
        local obj = entry.obj
        if obj and not excluded(obj.Name) then
            if not scan.accept or scan.accept(obj, entry.depth) then table.insert(scan.result, obj) end
            if entry.depth < scan.maxDepth then
                local children = obj:GetChildren()
                for i = 1, #children do
                    if #scan.queue >= scan.limit then scan.truncated = true; break end
                    table.insert(scan.queue, {obj=children[i], depth=entry.depth+1})
                end
            end
        end
    end
    scan.done = scan.head > #scan.queue
    return scan.done
end

    local Glass = {root=nil, discovery=nil, scan=nil, parts={}, entries={}, cursor=1, nextDiscover=0,
    counts={safe=0,unsafe=0,fragile=0,unknown=0}, folder=nil, connections={}, dirty=false, retired={}}
local COLORS = {unsafe=Color3.fromRGB(245,55,65),fragile=Color3.fromRGB(40,135,255),
    safe=Color3.fromRGB(55,220,125),unknown=Color3.fromRGB(165,171,185)}
local function glassRootName(name)
    local n=normalize(name)
    return n:find("glassbridge",1,true) or n:find("glassstepping",1,true)
end
local function glassValues(part)
    local values, cursor={},part
    for _=1,4 do
        if not cursor or cursor==Glass.root then break end
        for k,v in pairs(cursor:GetAttributes()) do
            local key=normalize(k)
            if values[key]==nil and (type(v)=="boolean" or type(v)=="number" or type(v)=="string") then values[key]=v end
        end
        for _,child in ipairs(cursor:GetChildren()) do
            if child:IsA("BoolValue") or child:IsA("NumberValue") or child:IsA("StringValue") or child:IsA("IntValue") then
                local key=normalize(child.Name)
                if values[key]==nil then values[key]=child.Value end
            end
        end
        cursor=cursor.Parent
    end
    return values
end
local function glassEvidence(part)
    local values=glassValues(part)
    local function first(names)
        for _,key in ipairs(names) do if values[key]~=nil then return values[key] end end
        return nil
    end
    local data={safe=first({"safe","issafe","tempered","istempered","correct","iscorrect"}),
        unsafe=first({"unsafe","isunsafe","wrong","iswrong"}),
        fragile=first({"fragile","isfragile","delayedbreak","delayedbreaking"}),
        breaking=first({"breaking","isbreaking","cracking","iscracking"}),
        broken=first({"broken","isbroken","shattered","isshattered"}),
        breakDelay=first({"breakdelay","shatterdelay","breakdelayseconds"})}
    local state=first({"glassstate","panelstate","glasstype","state"})
    if type(state)=="string" then
        state=normalize(state)
        if state=="safe" or state=="tempered" or state=="correct" then data.safe=true
        elseif state=="unsafe" or state=="bad" or state=="wrong" then data.unsafe=true
        elseif state=="fragile" then data.fragile=true
        elseif state=="breaking" or state=="cracking" then data.breaking=true
        elseif state=="broken" or state=="shattered" then data.broken=true end
    end
    -- Exact per-panel metadata from the 24-panel live report, September 9.
    if values.glasspart==true then
        if values.actuallykilling==true then data.broken=true
        elseif values.delayedbreaking==true then data.fragile=true
        elseif values.exploitingisevil==true then data.unsafe=true
        elseif values.exploitingisevil==false then data.safe=true
        else
            local model=part.Parent
            local pair=model and model.Parent
            local name=model and normalize(model.Name)
            local peer=pair and pair~=Glass.root and pair:FindFirstChild(name=="glassmodel1" and "glassmodel2" or "glassmodel1")
            local other=peer and peer:FindFirstChild("glasspart")
            if (name=="glassmodel1" or name=="glassmodel2") and other and other:IsA("BasePart") then
                local ov=glassValues(other)
                if ov.glasspart==true and (ov.exploitingisevil==true or ov.delayedbreaking==true or ov.actuallykilling==true) then
                    data.safe=true;data.source="paired Ink glass flags"
                end
            end
        end
    end
    return data,values
end
local function panel(part)
    if not part:IsA("BasePart") then return false end
    local s=part.Size
    if math.max(s.X,s.Z)<2 or math.min(s.X,s.Z)<1 or s.Y>math.min(s.X,s.Z)*.7 then return false end
    if part.Material==Enum.Material.Glass or normalize(part.Name):find("glass",1,true) then return true end
    local evidence=glassEvidence(part)
    return evidence.safe~=nil or evidence.unsafe~=nil or evidence.fragile~=nil
end
local function clearGlass()
    disconnect(Glass.connections)
    for _,entry in pairs(Glass.entries) do
        table.insert(Glass.retired,entry.highlight)
        if entry.box then table.insert(Glass.retired,entry.box) end
        table.insert(Glass.retired,entry.labelGui)
    end
    if Glass.folder then table.insert(Glass.retired,1,Glass.folder) end
    Glass.folder=nil
    Glass.parts,Glass.entries={},{}
    Glass.root,Glass.scan,Glass.discovery=nil,nil,nil
    Glass.counts={safe=0,unsafe=0,fragile=0,unknown=0}
end
local function drainGlass()
    for _=1,8 do
        local obj=table.remove(Glass.retired)
        if not obj then break end
        obj:Destroy()
    end
end
local function bindGlass(root)
    if Glass.root==root then return end
    clearGlass()
    Glass.root,Glass.dirty=root,root~=nil
    if root then
        connect(root.DescendantAdded,function() Glass.dirty=true end,Glass.connections)
        connect(root.DescendantRemoving,function() Glass.dirty=true end,Glass.connections)
    end
end
local function drawGlass(part, state, text)
    local entry=Glass.entries[part]
    if not entry then
        if not Glass.folder then
            Glass.folder=Instance.new("Folder");Glass.folder.Name="InkPentBridge_ESP";Glass.folder.Parent=World
        end
        local highlight=Instance.new("Highlight")
        highlight.Name="GlassState";highlight.Adornee=part;highlight.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop
        highlight.FillTransparency=.72;highlight.OutlineTransparency=.08;highlight.Parent=Glass.folder
        -- Highlights can disappear on translucent glass and share the engine's
        -- highlight allocation. An independent adornment makes every panel visible.
        local box=Instance.new("BoxHandleAdornment")
        box.Name="InkGlassTint";box.Adornee=part;box.AlwaysOnTop=true;box.ZIndex=5
        box.Size=part.Size+Vector3.new(.03,.03,.03);box.Transparency=.55;box.Parent=Glass.folder
        local billboard=Instance.new("BillboardGui")
        billboard.Name="InkPentBridge_Label";billboard.Adornee=part;billboard.Size=UDim2.new(0,100,0,22)
        billboard.StudsOffset=Vector3.new(0,.5,0);billboard.AlwaysOnTop=true;billboard.MaxDistance=600
        local label=Instance.new("TextLabel")
        label.Size=UDim2.new(1,0,1,0);label.BackgroundTransparency=.35;label.BackgroundColor3=Color3.fromRGB(15,18,25)
        label.BorderSizePixel=0;label.TextSize=11;label.Font=Enum.Font.Code;label.Parent=billboard
        billboard.Parent=player:FindFirstChildOfClass("PlayerGui")
        entry={highlight=highlight,box=box,labelGui=billboard,label=label,state=state};Glass.entries[part]=entry
    end
    entry.state=state
    entry.highlight.FillColor,entry.highlight.OutlineColor=COLORS[state],COLORS[state]
    entry.box.Color3=COLORS[state];entry.box.Size=part.Size+Vector3.new(.03,.03,.03)
    entry.label.TextColor3,entry.label.Text=COLORS[state],text
end
local function updateGlass(now)
    if not State.bridge then
        if Glass.root or Glass.folder or Glass.discovery then clearGlass() end
        State.glassStatus="Glass ESP OFF";return
    end
    if Glass.root and not Glass.root.Parent then bindGlass(nil) end
    if not Glass.root then
        -- All four bridge captures identify this direct Workspace child.
        -- Resolve it before scanning the rest of the scene.
        local direct = World:FindFirstChild("GlassBridge")
        if direct and (direct:IsA("Model") or direct:IsA("Folder")) then
            bindGlass(direct)
        end
    end
    if not Glass.root then
        if not Glass.discovery and now>=Glass.nextDiscover then
            Glass.nextDiscover=now+3
            Glass.discovery=scanNew(World,5,3000,function(obj) return glassRootName(obj.Name)~=nil end)
        end
        if Glass.discovery and scanStep(Glass.discovery) then
            local roots=Glass.discovery.result
            Glass.discovery=nil
            if #roots>0 then bindGlass(roots[1]) end
        end
        State.glassStatus="Waiting for the Glass Bridge model";return
    end
    if Glass.dirty and not Glass.scan then
        Glass.dirty=false
        Glass.scan=scanNew(Glass.root,12,2500,panel)
    end
    if Glass.scan and scanStep(Glass.scan) then
        local found=Glass.scan.result
        local retained={}
        Glass.parts={}
        for i=1,math.min(#found,128) do table.insert(Glass.parts,found[i]);retained[found[i]]=true end
        for part,entry in pairs(Glass.entries) do
            if not retained[part] then entry.highlight:Destroy();entry.box:Destroy();entry.labelGui:Destroy();Glass.entries[part]=nil end
        end
        Glass.truncated=Glass.scan.truncated or #found>128
        Glass.cursor,Glass.scan=1,nil
    end
    local start, count=os.clock(),0
    while #Glass.parts>0 and count<12 and os.clock()-start<.0007 do
        if Glass.cursor>#Glass.parts then Glass.cursor=1;break end
        local part=Glass.parts[Glass.cursor];Glass.cursor+=1;count+=1
        if part.Parent and part:IsDescendantOf(Glass.root) then
            local evidence=glassEvidence(part)
            local state,text=Core.glass(evidence)
            drawGlass(part,state,text)
        end
    end
    local counts={safe=0,unsafe=0,fragile=0,unknown=0}
    for part,entry in pairs(Glass.entries) do if part.Parent then counts[entry.state]+=1 end end
    Glass.counts=counts
    State.glassStatus=("Glass: %d safe | %d unsafe | %d fragile | %d unknown"):format(counts.safe,counts.unsafe,counts.fragile,counts.unknown)
    if Glass.truncated then State.glassStatus..=" | scan limited" end
end

    function State.tick(now)
        if R.destroying then State.bridge=false end
        if State.bridge and #Glass.retired>0 then
            drainGlass()
            return false
        end
        local ok,err=pcall(updateGlass,now)
        if not ok then
            State.bridge=false
            State.lastError=tostring(err)
            clearGlass()
            event("bridge-error",{error=State.lastError})
        end
        -- Retirement is bounded, including during OFF/unload and rapid reloads.
        drainGlass()
        return not State.bridge and not Glass.root and #Glass.retired==0
    end
    function State.report()
        return {enabled=State.bridge,status=State.glassStatus,lastError=State.lastError,
            rootBound=Glass.root~=nil,panels=#Glass.parts,counts=table.clone(Glass.counts),
            watchers=#Glass.connections,retired=#Glass.retired,truncated=Glass.truncated==true}
    end
    return State
end)()
function R.setBridgeEnabled(value)
    if not R.alive or R.destroying then return end
    Bridge.bridge=value==true
    if Bridge.bridge then Bridge.lastError="" end
end


local function makeUI(pg)
    disconnect(R.uiConnections)
    local screen = Instance.new("ScreenGui")
    screen.Name, screen.ResetOnSpawn, screen.DisplayOrder = "InkAutoQTE_v893", false, 10000
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screen.Enabled = not R.uiHidden
    local frame = Instance.new("Frame")
    frame.Name, frame.Size, frame.Position = "Panel", UDim2.new(0, 410, 0, 400), UDim2.new(0, 18, 0, 130)
    frame.BackgroundColor3, frame.BorderSizePixel, frame.Parent = Color3.fromRGB(19, 22, 30), 0, screen
    local function label(name, y, height, text, size)
        local obj = Instance.new("TextLabel")
        obj.Name, obj.Position, obj.Size = name, UDim2.new(0, 12, 0, y), UDim2.new(1, -24, 0, height)
        obj.BackgroundTransparency, obj.TextColor3 = 1, Color3.fromRGB(227, 233, 244)
        obj.TextXAlignment, obj.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Center
        obj.Font, obj.TextSize, obj.TextWrapped, obj.Text = Enum.Font.Code, size or 13, true, text
        obj.Parent = frame
        return obj
    end
    label("Title", 8, 24, "INK / QTE + ESP + AIM 8.9.3", 16)
    local status = label("Status", 39, 39, "OFF", 14)
    local stats = label("Stats", 79, 43, "", 12)
    local report = label("Report", 354, 38, "G: hide | P: QTE | Z: aim | F6: unload", 11)
    local function button(text, x, width, fn, y)
        local obj = Instance.new("TextButton")
        obj.Size, obj.Position = UDim2.new(0, width, 0, 30), UDim2.new(0, x, 0, y or 126)
        obj.Text, obj.TextSize, obj.Font = text, 13, Enum.Font.Code
        obj.TextColor3, obj.BackgroundColor3 = Color3.fromRGB(245, 248, 255), Color3.fromRGB(43, 52, 72)
        obj.BorderSizePixel, obj.Parent = 0, frame
        connect(obj.Activated, fn, R.uiConnections)
        return obj
    end
    local toggle = button("QTE [P]: OFF", 12, 152, function() R.setEnabled(not R.enabled) end)
    button("Save report", 172, 124, R.saveReport)
    button("Unload", 304, 94, R.destroy)
    local hider=button("Hider ESP: OFF",12,189,function() R.setESP("hider",not ESP.hider) end,166)
    local seeker=button("Seeker ESP: OFF",209,189,function() R.setESP("seeker",not ESP.seeker) end,166)
    local aimToggle=button("Aim [Z]: OFF",12,142,function() R.setAimEnabled(not Aim.enabled) end,205)
    local aimSmooth=button("",162,138,R.cycleAimProfile,205)
    local aimFov=button("",308,90,R.cycleAimFOV,205)
    local aimStatus=label("AimStatus",241,29,"Aim OFF",12)
    local bridgeToggle=button("Bridge ESP: OFF",12,152,function() R.setBridgeEnabled(not Bridge.bridge) end,276)
    local legend=label("BridgeLegend",276,30,"Red: bad | Blue: fragile\nGreen: safe | Gray: unknown",11)
    legend.Position,legend.Size=UDim2.new(0,172,0,276),UDim2.new(0,226,0,30)
    local bridgeStatus=label("BridgeStatus",310,38,"Glass ESP OFF",11)
    screen.Parent = pg
    ui = {screen = screen, status = status, stats = stats, toggle = toggle, report = report,hider=hider,seeker=seeker,
        aimToggle=aimToggle,aimSmooth=aimSmooth,aimFov=aimFov,aimStatus=aimStatus,bridgeToggle=bridgeToggle,bridgeStatus=bridgeStatus}
end
local function updateUI()
    local pg = playerGui()
    if not pg then return end
    if not ui or not ui.screen.Parent then makeUI(pg) end
    ui.status.Text = R.status
    ui.toggle.Text = R.enabled and "QTE [P]: ON" or "QTE [P]: OFF"
    ui.toggle.BackgroundColor3 = R.enabled and Color3.fromRGB(27, 100, 76) or Color3.fromRGB(43, 52, 72)
    ui.hider.Text=ESP.hider and "Hider ESP: ON" or "Hider ESP: OFF"
    ui.seeker.Text=ESP.seeker and "Seeker ESP: ON" or "Seeker ESP: OFF"
    ui.hider.BackgroundColor3=ESP.hider and Color3.fromRGB(30,90,160) or Color3.fromRGB(43,52,72)
    ui.seeker.BackgroundColor3=ESP.seeker and Color3.fromRGB(150,42,50) or Color3.fromRGB(43,52,72)
    ui.aimToggle.Text=Aim.enabled and "Aim [Z]: ON" or "Aim [Z]: OFF"
    ui.aimToggle.BackgroundColor3=Aim.enabled and Color3.fromRGB(27,100,76) or Color3.fromRGB(43,52,72)
    ui.aimSmooth.Text="Smooth: "..AIM_PROFILES[Aim.profile].name
    ui.aimFov.Text="FOV: "..AIM_FOV[Aim.fovIndex].name
    ui.aimStatus.Text=Aim.status
    ui.bridgeToggle.Text=Bridge.bridge and "Bridge ESP: ON" or "Bridge ESP: OFF"
    ui.bridgeToggle.BackgroundColor3=Bridge.bridge and Color3.fromRGB(27,100,76) or Color3.fromRGB(43,52,72)
    ui.bridgeStatus.Text=Bridge.lastError~="" and ("Bridge error: "..Bridge.lastError) or Bridge.glassStatus
    ui.stats.Text = ("%s | UI nodes: %d | root watchers: %d\nSent: %d | releases: %d | events: %d | %.2fms")
        :format(R.backend, #R.nodes, #R.rootConnections, R.presses, R.releases, R.observedInputs, R.emaTickMs)
    ui.report.Text = R.reportStatus ~= "" and R.reportStatus or "G: hide | P: QTE | Z: aim | F6: unload"
end
local function togglePanel()
    R.uiHidden=not R.uiHidden
    if ui then ui.screen.Enabled=not R.uiHidden end
end
connect(UIS.WindowFocused, function() R.focused = true end)
connect(UIS.WindowFocusReleased, function() R.focused = false; R.epoch += 1 end)
connect(UIS.InputBegan, function(input, processed)
    for key in pairs(R.heldKeys) do if input.KeyCode==Enum.KeyCode[key] then R.observedInputs+=1;break end end
    if not R.alive or R.destroying or UIS:GetFocusedTextBox() then return end
    if input.KeyCode==Enum.KeyCode.G or input.KeyCode==Enum.KeyCode.P then
        if GuiService.MenuIsOpen or not R.focused then return end
        local key,now=input.KeyCode,os.clock()
        if now-(R.hotkeyTimes[key] or -math.huge)<.18 then return end
        R.hotkeyTimes[key]=now
        if key==Enum.KeyCode.G then togglePanel() else R.setEnabled(not R.enabled) end
        return
    end
    if input.KeyCode==Enum.KeyCode.Z then
        if not GuiService.MenuIsOpen and R.focused and os.clock()-Aim.lastZ>.18 then Aim.lastZ=os.clock();R.setAimEnabled(not Aim.enabled) end
        return
    end
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F7 then stop("OFF")
    elseif input.KeyCode == Enum.KeyCode.F6 then R.destroy()
    elseif input.KeyCode == Enum.KeyCode.F5 then togglePanel() end
end)

local function tick()
    local now = os.clock()
    if not R.alive then return end
    if R.destroying then
        Aim.destroy()
        updateESP(now)
        local bridgeClean=Bridge.tick(now)
        if not R.shuttingDown then
            unbind()
            R.shuttingDown = true
        end
        if R.phase == "idle" and not R.reportBusy and bridgeClean then
            R.alive = false
            disconnect(R.connections)
            disconnect(R.uiConnections)
            if ui then ui.screen:Destroy() end
            if rawget(env, GLOBAL) == R then env[GLOBAL] = nil end
        end
        return
    end
    if R.phase ~= "idle" and R.phase ~= "queued" and now - R.nativeStartedAt > 1 then
        if R.enabled then
            stop("Input call is stalled; save report")
            event("input-watchdog", {phase = R.phase})
            R.reportRequested = true
        end
    end
    if legacyPending then
        legacyPending = old.bootPhase ~= "unloaded"
        if legacyPending and R.enabled then R.status = "Waiting for the previous build to unload" end
    end
    if not R.enabled then
        if R.root then unbind() end
    elseif not legacyPending then
        if not R.backendChecked then resolveBackend() end
        if now >= R.nextFocusCheck then
            R.nextFocusCheck = now + .20
            local active = env.isrbxactive or isrbxactive
            if type(active) == "function" then
                local ok, value = pcall(active)
                if ok then R.focused = value == true end
            end
        end
        if now >= R.nextRootCheck or (R.root and not R.root.Parent) then
            R.nextRootCheck = now + .25
            bind(findRoot())
        end
        if not R.root then R.status = "Waiting for ImpactFrames.QTEHolder"
        else
            rebuild()
            local keys, circles = sampleObjects(now)
            if R.overLimit then R.status = "QTE tree exceeded limit; save report"
            elseif not canPress() then R.status = "Paused while unfocused, typing, or in the menu"
            elseif not backend then R.status = "Checking keyboard input"
            elseif #keys == 0 then R.status = "Armed; waiting for a Q/E/R/F/T prompt"
            else
                local duePrompts, reason = {}, nil
                for _, prompt in ipairs(keys) do
                    local pair, why = selectPair(prompt, circles)
                    reason = why
                    if pair then
                        local state = R.cycles[prompt.obj]
                        if not state or state.key ~= prompt.key or state.moving ~= pair.moving.obj or state.target ~= pair.target.obj then
                            state = Core.newCycle(prompt.key, pair.moving.obj, pair.target.obj)
                            local m,t=pair.moving.sample,pair.target.sample
                            if m.previousWidth and t.previousWidth and m.previousTime==t.previousTime then
                                state.ratio,state.time=m.previousWidth/t.previousWidth,m.previousTime
                                state.samples=1
                            end
                            R.cycles[prompt.obj] = state
                        end
                        local due, phase = Core.advance(state, pair.ratio, now, SETTINGS)
                        state.targetWidth=pair.target.sample.w
                        reason = ("%s | ring %.3f | %s"):format(prompt.key, pair.ratio, phase)
                        if due then table.insert(duePrompts,{prompt=prompt,pair=pair,state=state,
                            deadline=(pair.ratio-SETTINGS.targetRatio+SETTINGS.tolerance)/math.max(.001,-state.velocity)}) end
                    end
                end
                R.status = reason or "Waiting for timing geometry"
                table.sort(duePrompts,function(a,b) return a.deadline<b.deadline end)
                if dispatch(duePrompts) then R.status="Sending aligned QTE inputs" end
            end
            capture(now, keys)
        end
    end
    local espOK,espError=pcall(updateESP,now)
    if not espOK then ESP.lastError=tostring(espError);ESP.hider,ESP.seeker=false,false;event("esp-error",{error=ESP.lastError}) end
    Bridge.tick(now)
    if R.reportRequested or (R.captureDirty and now >= R.nextReport and R.phase == "idle") then saveReport() end
    if now >= R.nextUI then R.nextUI = now + .20; updateUI() end
end
connect(RunService.RenderStepped, function()
    local start = os.clock()
    local ok, err = pcall(tick)
    local elapsed = (os.clock() - start) * 1000
    R.maxTickMs, R.emaTickMs = math.max(R.maxTickMs, elapsed), R.emaTickMs * .95 + elapsed * .05
    if not ok then
        R.lastError = tostring(err)
        stop("QTE error; save report")
        event("runtime-error", {error = R.lastError})
        warn("[Ink QTE] " .. R.lastError)
    end
end)
updateUI()
print("[Ink QTE " .. VERSION .. "] All features loaded OFF. G: hide/show | P: Auto QTE | Z: Smooth Aim.")
print("[Ink QTE] Current place " .. tostring(game.PlaceId) .. ". Reports: InkGame_QTE_v893_*.json")
