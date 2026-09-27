-- Ink Auto Shoot 1.1.0 | standalone, client input only.
-- Z: auto-shoot ON/OFF. G: hide/show. Starts OFF; use an equipped firearm.
-- Retaliation uses NEW LastHitFrom/LastHitTime changes, never old combat history.
-- No hooks, remotes, anti-cheat changes or camera/character property writes.
-- RLGL needs an explicit live phase; green/unknown always stops shooting.
-- If the game exposes no phase, use Mark GREEN then Mark RED once to calibrate
-- a discovered doll Head orientation. Calibration is cleared on a map change.
-- Mouse input cannot bypass weapon cooldown, reloads, latency or server rules.
local Config = {
    FOV = 400, -- screen-pixel radius for Rebel and red-glow acquisition
    RLGLFullField = true, -- turn toward any visible red-phase offender, even outside the screen
    MaxDistance = 1800,
    SmoothResponse = 42, RLGLResponse = 42,
    MaxMousePixelsPerSecond = 4800,
    MouseDegreesPerPixel = .12, InvertY = false,
    AutoScope = false, ScopeSettle = .10,
    SniperInterval = 1.0, WeaponInterval = .14, ClickHold = .035,
    MotionDistance = .22, MotionSpeed = 1.2, RotationDegrees = 8,
    MovementSample = .04, RedGrace = .06,
    Backend = "Auto", -- Auto, VirtualInput, ExecutorMouse
    WeaponMode = "Auto", -- Auto, Sniper, Gun; override only for custom viewmodel weapons
    IncludeNPCGuards = true,
    TurnToTarget = true, -- false = crosshair-only trigger, without turning
    RetaliationSeconds = 3, RetaliationFullField = true,
    AutoEquip = true, -- press the observed hotbar number, then wait for equipped Tool
    AcquireInterval = .05, StateInterval = .15, DiscoveryBudget = .00065,
    DollCalibrationTolerance = 12, -- degrees from a user-marked pose

    StateRoots = {"Values","GameState","RoundState","GameValues","GameData","RLGL","RedLightGreenLight"},
    LightNames = {"LightState","CurrentLight","RLGLState","TrafficLight","Light"},
    RedNames = {"RedLight","IsRedLight","RLGLRedLight"},
    GreenNames = {"GreenLight","IsGreenLight","RLGLGreenLight"},
    ModeNames = {"CurrentGame","GameMode","CurrentMinigame","RoundType","CurrentEvent","RoundName"},
    RebelNames = {"RebelMode","RebellionActive","RebelActive","IsRebelMode"},
    RLGLNames = {"RLGLActive","PlayingRLGL","InRLGL"},
    EndNames = {"RLGLEnded","RLGLOVER"}, -- observed in your Workspace captures
    RoleNames = {"Role","CurrentRole","PlayerRole","GameRole","Faction","GuardRole"},
    GuardNames = {"IsGuard","Guard","PlayingAsGuard"},
    RebelRoleNames = {"IsRebel","Rebel","Rebelling"},
}
local Logic = {}
function Logic.norm(value)
    return type(value)=="string" and value:lower():gsub("<[^>]+>",""):gsub("[^a-z0-9]","") or ""
end
function Logic.phase(value)
    local n=Logic.norm(value)
    if n=="red" or n=="redlight" then return "red" end
    if n=="green" or n=="greenlight" then return "green" end
end
function Logic.mode(value)
    local n=Logic.norm(value)
    if n=="rlgl" or n=="redlightgreenlight" then return "rlgl" end
    if n=="rebel" or n=="rebels" or n=="rebellion" or n=="rebelmode" then return "rebel" end
    if n~="" then return "other" end
end
function Logic.role(value)
    local n=Logic.norm(value)
    if n=="guard" or n=="guards" or n=="soldier" or n=="manager" or n=="worker" or n=="frontman" then return "guard" end
    if n=="rebel" or n=="rebels" or n=="rebelling" then return "rebel" end
    if n=="player" or n=="players" or n=="contestant" or n=="contestants" then return "player" end
end
function Logic.red(color)
    return color and color.R>=.6 and color.R>color.G*1.65 and color.R>color.B*1.65
end
function Logic.context(bits)
    local ended=bits.ended==true
    local rlgl
    if ended then rlgl=false
    elseif bits.rlgl then rlgl=true
    elseif bits.rebel then rlgl=false
    elseif bits.red or bits.green then rlgl=true
    elseif bits.modeOther then rlgl=false end
    return {rlgl=rlgl,rebel=bits.rebel==true,
        light=bits.green and "green" or (bits.red and "red" or "unknown"),source=bits.source or "No live signal"}
end
function Logic.eligible(context,ownRole,targetRole,friendly,glow,violated,attacker)
    if friendly then return nil end
    -- This guard precedes EVERY mode, including red-glow targeting.
    if context.rlgl==true then
        if context.light~="red" or ownRole~="guard" or targetRole=="guard" then return nil end
        return (violated or glow or attacker) and "RLGL" or nil
    end
    if ownRole=="guard" and context.rlgl==nil and not context.rebel then return nil end
    if attacker then return "Retaliate" end
    if context.rebel then
        if ownRole=="guard" and (targetRole=="rebel" or targetRole=="player") then return "Rebel" end
        if (ownRole=="rebel" or ownRole=="player") and targetRole=="guard" then return "Rebel" end
    end
    return glow and "Red glow" or nil
end
function Logic.motion(previous,position,look,now,phaseSerial)
    if not previous or previous.serial~=phaseSerial or now-previous.time>.3 then
        return {position=position,look=look,time=now,serial=phaseSerial},false
    end
    local dt=now-previous.time
    if dt<Config.MovementSample then return previous,false end
    local distance=(position-previous.position).Magnitude
    local dot=look.X*previous.look.X+look.Y*previous.look.Y+look.Z*previous.look.Z
    local rotated=math.deg(math.acos(math.clamp(dot,-1,1)))>=Config.RotationDegrees
    local moved=distance>=Config.MotionDistance and distance/dt>=Config.MotionSpeed
    return {position=position,look=look,time=now,serial=phaseSerial},moved or rotated
end
function Logic.delta(error,dt,focal,response)
    local gain=1-math.exp(-response*math.clamp(dt,0,1/20))
    local dx=math.deg(math.atan2(error.X,focal))/Config.MouseDegreesPerPixel*gain
    local dy=math.deg(math.atan2(error.Y,focal))/Config.MouseDegreesPerPixel*gain
    if Config.InvertY then dy=-dy end
    local delta=Vector2.new(dx,dy)
    local cap=Config.MaxMousePixelsPerSecond*math.clamp(dt,0,1/20)
    if delta.Magnitude>cap then delta=delta*(cap/delta.Magnitude) end
    return delta
end
function Logic.angularDelta(error,dt,response)
    local gain=1-math.exp(-response*math.clamp(dt,0,1/20))
    local scale=180/math.pi/Config.MouseDegreesPerPixel*gain
    local delta=Vector2.new(error.X*scale,error.Y*scale*(Config.InvertY and -1 or 1))
    local cap=Config.MaxMousePixelsPerSecond*math.clamp(dt,0,1/20)
    if delta.Magnitude>cap then delta=delta*(cap/delta.Magnitude) end
    return delta
end

local Players=game:GetService("Players")
local UIS=game:GetService("UserInputService")
local RunService=game:GetService("RunService")
local Workspace=game:GetService("Workspace")
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local GuiService=game:GetService("GuiService")
local HttpService=game:GetService("HttpService")
local LocalPlayer=Players.LocalPlayer
assert(LocalPlayer,"Run this script on the Roblox client")
local Env=type(getgenv)=="function" and getgenv() or _G
local KEY="__InkGuardAim"
local previous=rawget(Env,KEY)
if type(previous)=="table" and type(previous.destroy)=="function" then previous.destroy() end
local R={enabled=false,alive=true,destroying=false,epoch=0,hidden=false,focused=true,
    status="OFF",error="",backendName="Not checked",connections={},uiConnections={},
    target=nil,context={light="unknown"},phaseSerial=0,wasRed=false,redSince=0,
    motion={},violated={},attempts=0,lastShot=-math.huge,nextUI=0,lastKeys={},
    inputBusy=false,inputStarted=0,held={},releaseAt=0,scopeAt=0,resolvePending=false,
    backend=nil,nextAcquire=0,roster={},nextRoster=0,reportRequested=false,reportSerial=0,suppressPriorAim=true}
Env[KEY]=R
local ui
local function connect(signal,callback,list)
    local c=signal:Connect(callback);table.insert(list or R.connections,c);return c
end
local function disconnect(list)
    for _,c in ipairs(list) do c:Disconnect() end
    table.clear(list)
end
function R.setEnabled(value)
    if R.destroying or not R.alive then return end
    R.enabled=value==true;R.epoch+=1;R.target=nil;R.suppressPriorAim=true
    R.status=R.enabled and "Auto Shoot armed" or "OFF"
    R.attacker=nil;R.refreshIndex=R.enabled or R.refreshIndex
    if R.enabled then R.error="" end
end
function R.destroy()
    R.setEnabled(false);R.destroying=true
end
local function attr(obj,name) return obj and obj:GetAttribute(name) end
local function value(obj,name)
    if not obj then return nil end
    local a=obj:GetAttribute(name)
    if a~=nil then return a end
    local child=obj:FindFirstChild(name)
    if child and (child:IsA("StringValue") or child:IsA("BoolValue") or child:IsA("NumberValue") or child:IsA("IntValue")) then return child.Value end
    return nil -- one nil result, not zero results passed into type(...)
end
local function first(obj,names)
    for _,name in ipairs(names) do local v=value(obj,name);if v~=nil then return v end end
    return nil
end
local function role(subject,character)
    for _,obj in ipairs({subject or character,character}) do
        if first(obj,Config.GuardNames)==true then return "guard" end
        if first(obj,Config.RebelRoleNames)==true then return "rebel" end
        local r=Logic.role(first(obj,Config.RoleNames));if r then return r end
    end
    if subject and subject.Team then local teamRole=Logic.role(subject.Team.Name);if teamRole then return teamRole end end
    -- The captures use IsPlayer on live contestant characters and IsGuard on
    -- guard Players. Guard detection above must take precedence over IsPlayer.
    if subject and attr(character,"IsPlayer")==true then return "player" end
    if not subject and character then
        return Logic.role(character.Name) or (character.Parent and Logic.role(character.Parent.Name))
    end
end
local function friendly(subject,ownRole,targetRole)
    if ownRole=="guard" and targetRole=="guard" then return true end
    if R.context.rebel and ownRole and targetRole and ownRole~="guard" and targetRole~="guard" then return true end
    if ownRole and targetRole and (ownRole=="guard")~=(targetRole=="guard") then return false end
    if subject and subject.Team and subject.Team==LocalPlayer.Team and not subject.Neutral and not LocalPlayer.Neutral then
        local n=Logic.norm(subject.Team.Name)
        return n~="players" and n~="player" and n~="alive" and n~="contestants"
    end
    return false
end
local function living(character,subject)
    if not character or not character:IsDescendantOf(Workspace) then return nil end
    for _,name in ipairs({"Dead","Eliminated","Spectating","Spectator","IsSpectator"}) do
        if attr(character,name)==true or attr(subject,name)==true then return nil end
    end
    local h=character:FindFirstChildOfClass("Humanoid")
    local root=character:FindFirstChild("HumanoidRootPart")
    if not h or h.Health<=0 or not root or not root:IsA("BasePart") then return nil end
    if subject and subject.Team then
        local n=Logic.norm(subject.Team.Name)
        if n=="spectators" or n=="spectator" or n=="lobby" or n=="dead" then return nil end
    end
    return h,root
end
local function visible(obj)
    if not obj or not obj.Parent then return false end
    local p=obj
    for _=1,24 do
        if not p then return false end
        if p:IsA("GuiObject") and not p.Visible then return false end
        if p:IsA("CanvasGroup") and p.GroupTransparency>=.99 then return false end
        if p:IsA("LocalScript") or p:IsA("ModuleScript") or p:IsA("Script") then return false end
        if p:IsA("ScreenGui") then return p.Enabled and p.Parent==LocalPlayer:FindFirstChildOfClass("PlayerGui") end
        p=p.Parent
    end
    return false
end

-- Discover only the live round, HUD and actor effects. Never walk asset storage.
local Index={sources={},values={},labels={},phaseLabels={},highlights={},npcs={},probes={},
    heads={},seen=setmetatable({},{__mode="k"}),pending={},head=1,lanes={},nextScan=0,
    truncated=false,scanCounts={},connections={},labelConnections={},watched={},visits=0}
local signalNames,rootNames={},{}
for _,name in ipairs(Config.StateRoots) do rootNames[name]=true end
for _,names in ipairs({Config.LightNames,Config.RedNames,Config.GreenNames,Config.ModeNames,
    Config.RebelNames,Config.RLGLNames,Config.EndNames}) do
    for _,name in ipairs(names) do signalNames[name]=true end
end
local function ownObjectName(n)
    return n:sub(1,3)=="ink" or n=="drawing"
end
local function skip(obj)
    if obj:IsA("LuaSourceContainer") or obj:IsA("LocalScript") or obj:IsA("ModuleScript")
        or obj:IsA("Script") then return true end
    local n=Logic.norm(obj.Name)
    return ownObjectName(n) or n:find("shop",1,true) or n:find("inventory",1,true)
        or n:find("leaderboard",1,true) or n:find("donation",1,true)
        or n:find("emote",1,true) or n:find("settings",1,true)
        or n:find("reward",1,true) or n=="assets" or n=="templates" or n=="preloading"
        or n=="consolesupport" or n=="modules" or n=="animations"
end
local function add(list,obj,limit)
    if table.find(list,obj) then return end
    if #list<limit then table.insert(list,obj) else Index.truncated=true end
end
local function phaseLabel(obj)
    if Logic.phase(obj.Text) or table.find(Config.LightNames,obj.Name)
        or Logic.phase(obj.Name) then add(Index.phaseLabels,obj,32) end
end
local function inspect(obj,kind)
    if not obj.Parent or skip(obj) or Index.seen[obj] then return end
    Index.seen[obj]=true;Index.visits+=1
    if kind=="round" then
        local a=obj:GetAttributes()
        if (obj.Parent==Workspace or obj.Parent==ReplicatedStorage) and rootNames[obj.Name] then
            add(Index.sources,obj,16)
        else
            for name in pairs(a) do if signalNames[name] then add(Index.sources,obj,16);break end end
        end
        if signalNames[obj.Name] and (obj:IsA("StringValue") or obj:IsA("BoolValue")) then add(Index.values,obj,32) end
        if next(a) or obj:IsA("StringValue") or obj:IsA("BoolValue") or obj:IsA("Sound")
            or obj:IsA("Motor6D") then add(Index.probes,obj,256) end
    end
    if kind=="hud" and (obj:IsA("TextLabel") or obj:IsA("TextButton")) then
        if #Index.labels<256 then
            add(Index.labels,obj,256);phaseLabel(obj)
            Index.labelConnections[obj]=connect(obj:GetPropertyChangedSignal("Text"),function()
                if R.enabled and obj.Parent then phaseLabel(obj) end
            end,Index.connections)
        else Index.truncated=true end
    end
    if obj:IsA("Highlight") and not ownObjectName(Logic.norm(obj.Name)) then add(Index.highlights,obj,192) end
    if Config.IncludeNPCGuards and obj:IsA("Humanoid") then add(Index.npcs,obj,128) end
    if obj:IsA("BasePart") and obj.Name=="Head" then
        local p=obj.Parent
        for _=1,4 do
            if not p or p==Workspace then break end
            local n=Logic.norm(p.Name)
            if n:find("doll",1,true) or n:find("younghee",1,true) then add(Index.heads,obj,8);break end
            p=p.Parent
        end
    end
end
local function startLane(root,kind,limit)
    if not root or Index.watched[root] then return end
    local connections={}
    Index.watched[root]=connections
    table.insert(Index.lanes,{queue={root},head=1,count=0,root=root,kind=kind,limit=limit})
    table.insert(connections,root.DescendantAdded:Connect(function(obj)
        if R.enabled and #Index.pending-Index.head<512 then
            Index.pending[#Index.pending+1]={obj,kind}
        end
    end))
end
local function indexTick(now)
    if R.refreshIndex then
        R.refreshIndex=false
        disconnect(Index.connections)
        for _,connections in pairs(Index.watched) do disconnect(connections) end
        Index.watched={};Index.lanes={};Index.pending={};Index.head=1;Index.nextScan=0
        Index.seen=setmetatable({},{__mode="k"});Index.labelConnections={}
        for _,name in ipairs({"sources","values","labels","phaseLabels","highlights","npcs","probes","heads"}) do Index[name]={} end
    end
    Index.pg=LocalPlayer:FindFirstChildOfClass("PlayerGui")
    Index.roundRoot=Workspace:FindFirstChild("RedLightGreenLight")
    if now>=Index.nextScan then
        Index.nextScan=now+1
        for _,owner in ipairs({Workspace,ReplicatedStorage}) do
            for _,name in ipairs(Config.StateRoots) do
                local root=owner:FindFirstChild(name)
                if root then startLane(root,"round",3500) end
            end
        end
        startLane(Index.pg,"hud",4500)
        for _,p in ipairs(Players:GetPlayers()) do startLane(p.Character,"actors",180) end
        -- NPC folders and doll models are small, explicit roots; scenery is excluded.
        for _,child in ipairs(Workspace:GetChildren()) do
            local n=Logic.norm(child.Name)
            if n=="guards" or n=="npcs" or n=="live" or n:find("doll",1,true) or (child:IsA("Model") and role(nil,child)=="guard") then startLane(child,"actors",1800) end
            if child:IsA("Highlight") then inspect(child,"actors") end
        end
        for _,name in ipairs({"sources","values","labels","phaseLabels","highlights","npcs","probes","heads"}) do
            local list=Index[name]
            for i=#list,1,-1 do if not list[i].Parent then
                local c=Index.labelConnections[list[i]]
                if c then c:Disconnect();Index.labelConnections[list[i]]=nil end
                table.remove(list,i)
            end end
        end
        for root,connections in pairs(Index.watched) do
            if not root.Parent then disconnect(connections);Index.watched[root]=nil end
        end
    end
    local began=os.clock();local visits=0
    while Index.pending[Index.head] and visits<12 and os.clock()-began<Config.DiscoveryBudget do
        local item=Index.pending[Index.head];Index.pending[Index.head]=false;Index.head+=1
        -- Check ancestry for events from a skipped script/template container.
        local parent=item[1];local allowed=true
        for _=1,24 do
            if not parent or parent==Index.pg or parent==Workspace or parent==ReplicatedStorage then break end
            if skip(parent) then allowed=false;break end;parent=parent.Parent
        end
        if allowed then inspect(item[1],item[2]) end
        visits+=1
    end
    if Index.head>#Index.pending then Index.pending={};Index.head=1 end
    -- Round-robin one object per lane. Character effects cannot sit behind HUDs.
    local pass=0
    while #Index.lanes>0 and visits<48 and os.clock()-began<Config.DiscoveryBudget do
        pass=pass%#Index.lanes+1
        local scan=Index.lanes[pass];local obj=scan.queue[scan.head]
        if not obj or not scan.root.Parent then
            Index.scanCounts[scan.kind]={visited=scan.count,done=true,limited=scan.limited or false}
            table.remove(Index.lanes,pass);pass-=1
        else
            scan.queue[scan.head]=false;scan.head+=1;scan.count+=1;visits+=1
            if not skip(obj) then
                inspect(obj,scan.kind)
                for _,child in ipairs(obj:GetChildren()) do
                    if #scan.queue>=scan.limit then scan.limited=true;Index.truncated=true;break end
                    if not skip(child) then table.insert(scan.queue,child) end
                end
            end
            Index.scanCounts[scan.kind]={visited=scan.count,done=false,limited=scan.limited or false}
        end
    end
end
local function clearIndex()
    disconnect(Index.connections)
    for _,connections in pairs(Index.watched) do disconnect(connections) end
    Index.watched={};Index.lanes={};Index.pending={}
end

-- Constant-time filter for short-lived effects outside actor folders. No world crawl.
connect(Workspace.DescendantAdded,function(obj)
    if not R.enabled then return end
    if obj:IsA("Highlight") then
        if #Index.pending-Index.head<512 then table.insert(Index.pending,{obj,"actors"}) end
    elseif obj:IsA("Humanoid") and obj.Parent and role(nil,obj.Parent)=="guard" then
        startLane(obj.Parent,"actors",180)
    end
end)

local function consume(bits,name,v,source)
    local function has(names) return table.find(names,name)~=nil end
    if has(Config.EndNames) and v==true then bits.ended=true end
    if has(Config.ModeNames) then
        local mode=Logic.mode(v)
        if mode=="rlgl" then bits.rlgl=true elseif mode=="rebel" then bits.rebel=true elseif mode=="other" then bits.modeOther=true end
    elseif has(Config.RebelNames) and v==true then bits.rebel=true
    elseif has(Config.RLGLNames) and v==true then bits.rlgl=true
    elseif has(Config.LightNames) then local p=Logic.phase(v);if p then bits[p]=true;bits.source=source end
    elseif has(Config.RedNames) and type(v)=="boolean" then bits[v and "red" or "green"]=true;bits.source=source
    elseif has(Config.GreenNames) and v==true then bits.green=true;bits.source=source end
end
local stateCache,nextState={},0
local calibration={}
local function record(kind,message)
    R.events=R.events or {}
    if #R.events>=80 then table.remove(R.events,1) end
    table.insert(R.events,{at=os.clock(),kind=kind,message=message})
end
local function calibratedPhase()
    if calibration.map~=Index.roundRoot or not calibration.green or not calibration.red then return nil end
    local phase
    for head,g in pairs(calibration.green) do
        local r=calibration.red[head]
        if r and head.Parent then
            local look=head.CFrame.LookVector
            local function dot(a,b) return a.X*b.X+a.Y*b.Y+a.Z*b.Z end
            if dot(g,r)<-.5 then -- both manually marked poses must differ by at least 120 degrees
                local threshold=math.cos(math.rad(Config.DollCalibrationTolerance))
                local detected=dot(look,r)>=threshold and "red" or (dot(look,g)>=threshold and "green" or nil)
                if not detected then return nil end -- turning is unknown, never permission to fire
                if phase and phase~=detected then return nil end
                phase=detected
            end
        end
    end
    return phase
end
function R.markPhase(phase)
    R.noticeUntil=os.clock()+4
    if phase~="red" and phase~="green" then return end
    if R.context.rlgl~=true then R.notice="Reach RLGL before marking its doll pose";return end
    if #Index.heads==0 then R.notice="No doll Head found; save a report during RLGL";return end
    if calibration.map~=Index.roundRoot then calibration={map=Index.roundRoot} end
    local sample={}
    for _,head in ipairs(Index.heads) do if head.Parent then sample[head]=head.CFrame.LookVector end end
    calibration[phase]=sample;nextState=0
    R.notice="Marked "..phase:upper().." pose"
    if calibration.green and calibration.red then
        R.notice=calibratedPhase() and "Doll calibration ready" or "No distinct doll poses; save a report"
    end
    record("calibration",R.notice)
end
local function context(force)
    local now=os.clock()
    if force or now>=nextState then
        nextState=now+Config.StateInterval
        stateCache={}
        local roots={Workspace,ReplicatedStorage,LocalPlayer}
        for _,root in ipairs({Workspace,ReplicatedStorage}) do
            local values=root:FindFirstChild("Values");if values then table.insert(roots,values) end
        end
        for _,root in ipairs(Index.sources) do if root.Parent then table.insert(roots,root) end end
        local seen={}
        for _,root in ipairs(roots) do if not seen[root] then
            seen[root]=true
            for name in pairs(signalNames) do
                -- Phase is read fresh below, never copied from the slower round cache.
                if not table.find(Config.LightNames,name) and not table.find(Config.RedNames,name) and not table.find(Config.GreenNames,name) then
                    local v=value(root,name);if v~=nil then consume(stateCache,name,v,root.Name.."."..name) end
                end
            end
        end end
        if not stateCache.modeOther and role(LocalPlayer,LocalPlayer.Character)=="rebel" then stateCache.rebel=true end
        R.contextRefreshes=(R.contextRefreshes or 0)+1
    end
    local bits=table.clone(stateCache)
    local roots={Workspace,ReplicatedStorage,LocalPlayer}
    for _,root in ipairs(Index.sources) do if root.Parent then table.insert(roots,root) end end
    local seen={}
    for _,root in ipairs(roots) do if not seen[root] then
        seen[root]=true
        for _,names in ipairs({Config.LightNames,Config.RedNames,Config.GreenNames}) do
            for _,name in ipairs(names) do
                local v=value(root,name);if v~=nil then consume(bits,name,v,root.Name.."."..name) end
            end
        end
        -- An ended flag must also cancel an already queued shot immediately.
        for _,name in ipairs(Config.EndNames) do if value(root,name)==true then bits.ended=true end end
    end end
    for _,obj in ipairs(Index.values) do if obj.Parent then consume(bits,obj.Name,obj.Value,obj.Name) end end
    for _,obj in ipairs(Index.phaseLabels) do
        R.phaseLabelReads=(R.phaseLabelReads or 0)+1
        if visible(obj) then
            local phase=Logic.phase(obj.Text)
            if phase then bits[phase]=true;bits.source="HUD: "..obj.Name end
        end
    end
    if not bits.red and not bits.green and bits.rlgl and not bits.ended then
        local phase=calibratedPhase()
        if phase then bits[phase]=true;bits.source="Calibrated doll pose" end
    end
    return Logic.context(bits)
end

-- The live reports supply attacker identity on the CHARACTER. Baseline every
-- enable/respawn, then react only to a changed timestamp and matched identity.
local hitState={}
local function retaliation(now)
    local char=LocalPlayer.Character
    if not char then R.attacker=nil;hitState={};return end
    local stamp=attr(char,"LastHitTime")
    local from=attr(char,"LastHitFrom")
    if hitState.character~=char or hitState.epoch~=R.epoch then
        hitState={character=char,epoch=R.epoch,stamp=stamp,from=from};R.attacker=nil;return
    end
    if stamp~=nil and stamp~=hitState.stamp then
        hitState.stamp=stamp
        hitState.pendingUntil=now+.025 -- allow identity/time attributes to replicate separately
    end
    if hitState.pendingUntil then
        if from~=nil and (from~=hitState.from or now>=hitState.pendingUntil) then
            local found
            for _,p in ipairs(R.roster) do
                if p~=LocalPlayer and (from==p.Name or (p.UserId~=nil and tostring(from)==tostring(p.UserId))) then found=p;break end
            end
            if found then
                R.attacker={player=found,character=found.Character,untilTime=now+Config.RetaliationSeconds}
                R.nextAcquire=0;record("attack",found.Name)
            end
            hitState.from=from;hitState.pendingUntil=nil
        end
    end
    if R.attacker and (now>=R.attacker.untilTime or R.attacker.player.Character~=R.attacker.character) then R.attacker=nil end
end

local function glowing(character)
    for _,h in ipairs(Index.highlights) do
        if h.Parent and h.Enabled then
            local adorn=h.Adornee or h:FindFirstAncestorOfClass("Model")
            if adorn and (adorn==character or adorn:IsDescendantOf(character)) then
                if (h.FillTransparency<.95 and Logic.red(h.FillColor)) or (h.OutlineTransparency<.95 and Logic.red(h.OutlineColor)) then return true end
            end
        end
    end
    return false
end
local glowCache={}
local function refreshGlowCache()
    glowCache={}
    for _,h in ipairs(Index.highlights) do
        if h.Parent and h.Enabled and ((h.FillTransparency<.95 and Logic.red(h.FillColor))
            or (h.OutlineTransparency<.95 and Logic.red(h.OutlineColor))) then
            local adorn=h.Adornee or h:FindFirstAncestorOfClass("Model")
            local model=adorn
            for _=1,8 do
                if not model or model==Workspace then break end
                if model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") then glowCache[model]=true;break end
                model=model.Parent
            end
        end
    end
end
local function gunName(name)
    local n=Logic.norm(name)
    if n=="g3sg1" or n:find("sniper",1,true) then return "Sniper" end
    if n=="coltpython6" or n=="coltpython" or n=="python6" then return "Gun" end
    for _,s in ipairs({"rifle","pistol","revolver","shotgun","fnfal","ak47","mp5","m4a1","gun"}) do
        if n:find(s,1,true) then return "Gun" end
    end
    return nil
end
local function weapon()
    local char=LocalPlayer.Character
    if not char then return nil end
    local tool,kind
    local fallbackTool=char:FindFirstChildOfClass("Tool")
    for _,candidate in ipairs(char:GetChildren()) do
        if candidate:IsA("Tool") then
            local candidateKind=gunName(candidate.Name) or gunName(first(candidate,{"WeaponType","GunType"}))
            local ammo=value(candidate,"Ammo")
            if not candidateKind and (type(ammo)=="number" or value(candidate,"IsGun")==true or value(candidate,"Gun")==true) then candidateKind="Gun" end
            if candidateKind then tool,kind=candidate,candidateKind;break end
        end
    end
    local name=tool and tool.Name
    if not kind then
        for _,obj in ipairs({char,LocalPlayer}) do
            local named=first(obj,{"EquippedWeapon","CurrentWeapon","Weapon"})
            if type(named)=="string" and gunName(named) then kind=gunName(named);name=named;break end
        end
    end
    if Config.WeaponMode~="Auto" then
        kind=Config.WeaponMode;tool=tool or fallbackTool;name=name or (kind.." (custom weapon)")
    end
    if not kind then return nil end
    local interval=kind=="Sniper" and Config.SniperInterval or Config.WeaponInterval
    if tool then
        local seconds=first(tool,{"FireInterval","FireDelay","ShotDelay"})
        local rpm=value(tool,"RPM")
        if type(seconds)=="number" and seconds>=.05 and seconds<=10 then interval=seconds
        elseif type(rpm)=="number" and rpm>=6 and rpm<=1200 then interval=60/rpm end
        if tool.Enabled==false or value(tool,"Reloading")==true or value(tool,"Ammo")==0 then return nil end
    end
    return {tool=tool,kind=kind,name=name or kind,interval=interval}
end
local function controlsAllowed()
    R.pauseReason=nil
    local function pause(reason) R.pauseReason=reason;return false end
    if not R.enabled or R.destroying then return pause("OFF") end
    if not R.focused then return pause("Roblox is unfocused") end
    if UIS:GetFocusedTextBox() then return pause("typing") end
    if GuiService.MenuIsOpen then return pause("Roblox menu open") end
    local active=Env.isrbxactive or isrbxactive
    if type(active)=="function" then local ok,v=pcall(active);if ok and not v then return pause("Roblox window inactive") end end
    local cam=Workspace.CurrentCamera
    local h=living(LocalPlayer.Character,LocalPlayer)
    if not cam or not h then return pause("character unavailable") end
    if cam.CameraType==Enum.CameraType.Scriptable then return pause("cutscene camera") end
    local subject=cam.CameraSubject
    if subject and subject~=h and subject~=LocalPlayer.Character and not subject:IsDescendantOf(LocalPlayer.Character) then return pause("spectator camera") end
    local qte=rawget(Env,"__InkAutoQTE")
    if qte and (qte.pending or qte.held or (qte.phase and qte.phase~="idle")) then return pause("QTE is using input") end
    if ui and ui.screen.Enabled then
        local mouse=UIS:GetMouseLocation()
        local panel=ui.screen:FindFirstChild("Panel")
        if panel then
            local p,s=panel.AbsolutePosition,panel.AbsoluteSize
            if mouse.X>=p.X and mouse.X<=p.X+s.X and mouse.Y>=p.Y and mouse.Y<=p.Y+s.Y then return pause("cursor over panel; G hides it") end
        end
    end
    return true
end
local rays=RaycastParams.new();rays.FilterType=Enum.RaycastFilterType.Exclude;rays.IgnoreWater=true
local function sight(target)
    local cam=Workspace.CurrentCamera
    rays.FilterDescendantsInstances={LocalPlayer.Character,cam}
    local result=Workspace:Raycast(cam.CFrame.Position,target.part.Position-cam.CFrame.Position,rays)
    if result and not result.Instance:IsDescendantOf(target.character) then return false end
    local w=weapon();local handle=w and w.tool and w.tool:FindFirstChild("Handle")
    if handle and handle:IsA("BasePart") then
        result=Workspace:Raycast(handle.Position,target.part.Position-handle.Position,rays)
        if result and not result.Instance:IsDescendantOf(target.character) then return false end
    end
    return true
end
local function measure(character,subject,ownRoot,ownRole,refreshGlow)
    if character==LocalPlayer.Character then return nil end
    local humanoid,root=living(character,subject)
    if not humanoid then return nil end
    local targetRole=role(subject,character)
    if not subject and targetRole~="guard" then return nil end
    local hasGlow=refreshGlow and glowing(character) or (not refreshGlow and glowCache[character])
    local mode=Logic.eligible(R.context,ownRole,targetRole,friendly(subject,ownRole,targetRole),hasGlow,R.violated[character],R.attacker and R.attacker.character==character and os.clock()<R.attacker.untilTime)
    if not mode then return nil end
    local part=character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso") or character:FindFirstChild("Head") or root
    if not part:IsA("BasePart") then return nil end
    local distance=(root.Position-ownRoot.Position).Magnitude
    if distance>Config.MaxDistance then return nil end
    local cam=Workspace.CurrentCamera
    local point,onScreen=cam:WorldToViewportPoint(part.Position)
    local center=cam.ViewportSize*.5
    local error=Vector2.new(point.X,point.Y)-center
    local angleError
    if Config.TurnToTarget and ((mode=="RLGL" and Config.RLGLFullField) or (R.attacker and R.attacker.character==character and Config.RetaliationFullField)) then
        local d=part.Position-cam.CFrame.Position
        local look,up=cam.CFrame.LookVector,cam.CFrame.UpVector
        local right=Vector3.new(look.Y*up.Z-look.Z*up.Y,look.Z*up.X-look.X*up.Z,look.X*up.Y-look.Y*up.X).Unit
        local x=d.X*right.X+d.Y*right.Y+d.Z*right.Z
        local y=d.X*up.X+d.Y*up.Y+d.Z*up.Z
        local z=d.X*look.X+d.Y*look.Y+d.Z*look.Z
        angleError=Vector2.new(math.atan2(x,z),math.atan2(-y,math.sqrt(x*x+z*z)))
    elseif not onScreen or point.Z<=0 or error.Magnitude>Config.FOV then return nil end
    return {character=character,subject=subject,humanoid=humanoid,root=root,part=part,
        error=error,angleError=angleError,onScreen=onScreen,depth=point.Z,distance=distance,mode=mode}
end
local function updateRoster(now)
    if now<R.nextRoster then return end
    R.nextRoster=now+.2;R.roster=Players:GetPlayers()
    local existing={}
    for i,p in ipairs(R.roster) do if i<=128 and p.Character then existing[p.Character]=true end end
    for char in pairs(R.motion) do if not existing[char] then R.motion[char]=nil;R.violated[char]=nil end end
end
local function movement(now)
    local red=R.context.rlgl==true and R.context.light=="red"
    if red~=R.wasRed then
        R.wasRed=red;R.phaseSerial+=1;R.motion={};R.violated={};R.redSince=now
    end
    if not red then return end
    if now<(R.nextMovement or 0) then return end
    R.nextMovement=now+Config.MovementSample
    for i,p in ipairs(R.roster) do
        if i>128 then break end
        if p~=LocalPlayer then
            local _,root=living(p.Character,p)
            if root then
                local sample,moved=Logic.motion(R.motion[p.Character],root.Position,root.CFrame.LookVector,now,R.phaseSerial)
                R.motion[p.Character]=sample
                if moved and now-R.redSince>=Config.RedGrace then R.violated[p.Character]=true end
            end
        end
    end
end
local function choose(now,ownRoot,ownRole)
    local current=R.target and measure(R.target.character,R.target.subject,ownRoot,ownRole)
    if now<R.nextAcquire and current and sight(current) then return current end
    R.nextAcquire=now+Config.AcquireInterval
    local candidates,seen={},{}
    for i,p in ipairs(R.roster) do
        if i>128 then break end
        if p.Character then seen[p.Character]=true end
        local c=measure(p.Character,p,ownRoot,ownRole);if c then table.insert(candidates,c) end
    end
    if Config.IncludeNPCGuards and R.context.rebel then
        for _,h in ipairs(Index.npcs) do
            if h.Parent and not seen[h.Parent] then
                seen[h.Parent]=true;local c=measure(h.Parent,nil,ownRoot,ownRole)
                if c then table.insert(candidates,c) end
            end
        end
    end
    table.sort(candidates,function(a,b)
        local aa=R.attacker and a.character==R.attacker.character or false
        local ba=R.attacker and b.character==R.attacker.character or false
        if aa~=ba then return aa end
        if not Config.TurnToTarget then return a.error.Magnitude<b.error.Magnitude end
        if math.abs(a.distance-b.distance)<.1 then return a.error.Magnitude<b.error.Magnitude end
        return a.distance<b.distance
    end)
    -- Bound ray work. Check a rotating block so covered close targets cannot
    -- indefinitely starve a visible target farther down the shortlist.
    local start=R.searchOffset or 1
    if start>#candidates then start=1 end
    for i=start,math.min(start+5,#candidates) do
        if sight(candidates[i]) then R.searchOffset=1;return candidates[i] end
    end
    R.searchOffset=start+6
    return current and sight(current) and current or nil
end

-- Learn degrees per input pixel from the camera's observed response. The game
-- may change sensitivity when scoped, so a fixed guessed gain can oscillate.
-- This only READS camera orientation; movement remains simulated mouse input.
local function learnMouse(now)
    local sample=R.mouseSample;R.mouseSample=nil
    local camera=Workspace.CurrentCamera
    if not sample or not camera or camera~=sample.camera or now-sample.at>.12
        or math.abs(camera.FieldOfView-sample.fov)>.5 then return end
    local look=camera.CFrame.LookVector;local prior=sample.look
    local yaw=math.atan2(look.X,-look.Z)-math.atan2(prior.X,-prior.Z)
    yaw=math.atan2(math.sin(yaw),math.cos(yaw))
    local pitch=math.asin(math.clamp(prior.Y,-1,1))-math.asin(math.clamp(look.Y,-1,1))
    R.mouseGain=R.mouseGain or {}
    local function update(axis,actual,command)
        if math.abs(command)<1 or math.abs(actual)<.02 or math.abs(actual)>60 then return end
        if actual*command<=0 then return end
        local observed=math.abs(actual/command)
        if observed<.005 or observed>1.2 then return end
        local current=R.mouseGain[axis]
        R.mouseGain[axis]=current and (current*.4+observed*.6) or observed
    end
    update("X",math.deg(yaw),sample.delta.X)
    update("Y",math.deg(pitch),sample.delta.Y*(Config.InvertY and -1 or 1))
end
local function mouseDelta(target,dt,focal,response)
    local delta=target.angleError and Logic.angularDelta(target.angleError,dt,response)
        or Logic.delta(target.error,dt,focal,response)
    if R.mouseGain then
        delta=Vector2.new(delta.X*Config.MouseDegreesPerPixel/(R.mouseGain.X or Config.MouseDegreesPerPixel),
            delta.Y*Config.MouseDegreesPerPixel/(R.mouseGain.Y or Config.MouseDegreesPerPixel))
        local cap=Config.MaxMousePixelsPerSecond*math.clamp(dt,0,1/20)
        if delta.Magnitude>cap then delta=delta*(cap/delta.Magnitude) end
    end
    return delta
end


-- All simulated input is serialized through one deferred worker. OFF/Z only
-- invalidate intent; matching button-up events are drained outside callbacks.
local function resolveBackend()
    if R.backend or R.resolvePending or R.error~="" then return end
    R.resolvePending=true
    task.defer(function()
        local selected
        if Config.Backend=="Auto" or Config.Backend=="VirtualInput" then
            local ok,vi=pcall(function() return UIS:CreateVirtualInput() end)
            if ok and vi then
                local usable=pcall(function() vi:SendMouseDelta(Vector2.new(0,0)) end)
                if usable then selected={name="VirtualInput",
                    move=function(delta) vi:SendMouseDelta(delta) end,
                    position=function(point) vi:SendMousePosition(point) end,
                    key=function(code,down) vi:SendKey(down,code,false) end,
                    button=function(which,down,position)
                        vi:SendMouseButton(position,which==1 and Enum.UserInputType.MouseButton1 or Enum.UserInputType.MouseButton2,down,0)
                    end} end
            end
        end
        if not selected and (Config.Backend=="Auto" or Config.Backend=="ExecutorMouse") then
            local move=Env.mousemoverel or mousemoverel
            local down1,up1=Env.mouse1press or mouse1press,Env.mouse1release or mouse1release
            local down2,up2=Env.mouse2press or mouse2press,Env.mouse2release or mouse2release
            if type(move)=="function" and type(down1)=="function" and type(up1)=="function"
                and type(down2)=="function" and type(up2)=="function" then
                local keyDown,keyUp=Env.keypress or keypress,Env.keyrelease or keyrelease
                selected={name="ExecutorMouse",move=function(delta) move(delta.X,delta.Y) end,
                    position=function(point)
                        local current=UIS:GetMouseLocation();move(point.X-current.X,point.Y-current.Y)
                    end,
                    key=type(keyDown)=="function" and type(keyUp)=="function" and function(code,down,vk)
                        if down then keyDown(vk) else keyUp(vk) end
                    end or nil,
                    button=function(which,down)
                        local fn=which==1 and (down and down1 or up1) or (down and down2 or up2);fn()
                    end}
            end
        end
        R.resolvePending=false
        if selected then R.backend=selected;R.backendName=selected.name
        else R.error="Mouse simulation unavailable. Select an executor with VirtualInput or mouse functions.";R.setEnabled(false) end
    end)
end
local function freshTarget(target,force)
    if not controlsAllowed() or not target then return nil end
    R.context=context(force)
    local _,ownRoot=living(LocalPlayer.Character,LocalPlayer)
    if not ownRoot then return nil end
    local m=measure(target.character,target.subject,ownRoot,role(LocalPlayer,LocalPlayer.Character),true)
    return m and sight(m) and m or nil
end
local function aligned(target)
    if not target.onScreen or target.depth<=0 then return false end
    local cam=Workspace.CurrentCamera
    local focal=cam.ViewportSize.Y*.5/math.tan(math.rad(cam.FieldOfView*.5))
    local tolerance=math.clamp(target.part.Size.X*.32*focal/target.depth,.6,6)
    return target.error.Magnitude<=tolerance
end
local function inputTick(now,delta,fire,selectedWeapon)
    if R.inputBusy or not R.backend then return end
    local held=next(R.held)~=nil or R.keyHeld~=nil
    if not delta and not fire and not held then return end
    local epoch,target=R.epoch,R.target
    R.inputBusy=true;R.inputStarted=now
    task.defer(function()
        local ok,err=pcall(function()
            if R.keyHeld and (epoch~=R.epoch or not controlsAllowed() or os.clock()>=R.keyHeld.releaseAt) then
                local heldKey=R.keyHeld
                R.backend.key(heldKey.code,false,heldKey.vk);R.keyHeld=nil
            end
            local valid=epoch==R.epoch and controlsAllowed() and freshTarget(target) or nil
            local cam=Workspace.CurrentCamera
            local position=UIS:GetMouseLocation()
            local function button(which,down)
                if down then R.held[which]=true end -- reserve release before crossing native boundary
                R.backend.button(which,down,position)
                if not down then R.held[which]=nil end
            end
            if R.held[1] and (not valid or os.clock()>=R.releaseAt) then button(1,false) end
            if R.held[2] and not valid then button(2,false) end
            if not valid or not cam then return end
            -- While unlocked, put the pointer at the same viewport center used
            -- for alignment before capturing it with RMB or pulling the trigger.
            -- Relative movement of a free pointer must not count as camera aim.
            if Config.TurnToTarget and not R.held[2] and UIS.MouseBehavior~=Enum.MouseBehavior.LockCenter then
                local center=cam.ViewportSize*.5
                if (position-center).Magnitude>2 then
                    R.backend.position(center);return
                end
            end
            local needsLook=Config.TurnToTarget and not aligned(valid) and UIS.MouseBehavior~=Enum.MouseBehavior.LockCenter
            if (Config.AutoScope or needsLook) and not R.held[2] then
                button(2,true);R.scopeAt=os.clock()
                if Config.AutoScope then return end
            end
            if delta and Config.TurnToTarget then
                if delta.Magnitude>=1 then R.mouseSample={camera=cam,look=cam.CFrame.LookVector,
                    fov=cam.FieldOfView,delta=delta,at=os.clock()} end
                R.backend.move(delta)
            end
            -- Refresh phase, role, target health, visibility and weapon AFTER
            -- movement and immediately before every trigger pull.
            local current=fire and freshTarget(target,true)
            local w=current and weapon()
            if w and selectedWeapon and w.tool==selectedWeapon.tool and w.name==selectedWeapon.name
                and aligned(current) and not R.held[1]
                and (not Config.AutoScope or os.clock()-R.scopeAt>=Config.ScopeSettle)
                and os.clock()-R.lastShot>=w.interval then
                R.shotObservation={tool=w.tool,stamp=w.tool and attr(w.tool,"GunShotTick"),at=os.clock()}
                button(1,true);R.releaseAt=os.clock()+Config.ClickHold
                R.lastShot=os.clock();R.attempts+=1
                record("trigger",current.mode..": "..current.character.Name)
            end
        end)
        R.inputBusy=false
        if not ok then
            R.error="Input error: "..tostring(err);R.setEnabled(false)
            -- Release is retried, never replaced with a second input backend
            -- while a button may still be held by the first one.
            R.releaseErrors=(R.releaseErrors or 0)+1
            if R.releaseErrors>=3 then R.status="Input release failed; release mouse buttons manually" end
        else R.releaseErrors=0 end
    end)
end

local numberKeys={Enum.KeyCode.One,Enum.KeyCode.Two,Enum.KeyCode.Three,Enum.KeyCode.Four,Enum.KeyCode.Five,
    Enum.KeyCode.Six,Enum.KeyCode.Seven,Enum.KeyCode.Eight,Enum.KeyCode.Nine,Enum.KeyCode.Zero}
local function autoEquip(now)
    if not Config.AutoEquip or not R.backend or not R.backend.key or R.inputBusy or R.keyHeld
        or now<(R.nextEquip or 0) or not controlsAllowed() then return end
    local char=LocalPlayer.Character
    if not char then return end
    -- A disabled or reloading equipped gun is still equipped. Do not toggle it off.
    for _,tool in ipairs(char:GetChildren()) do
        if tool:IsA("Tool") and (gunName(tool.Name) or attr(tool,"Gun")==true or attr(tool,"IsGun")==true) then return end
    end
    local pg=LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local hotbar=pg and pg:FindFirstChild("Hotbar")
    hotbar=hotbar and hotbar:FindFirstChild("Backpack")
    hotbar=hotbar and hotbar:FindFirstChild("Hotbar")
    local backpack=LocalPlayer:FindFirstChildOfClass("Backpack")
    if not hotbar or not backpack then return end
    local selection
    for _,slot in ipairs(hotbar:GetChildren()) do
        local number=tonumber(slot.Name)
        local label=slot:FindFirstChild("ToolName")
        if number and number>=0 and number<=9 and label and label:IsA("TextLabel") then
            local tool=backpack:FindFirstChild(label.Text)
            local kind=tool and tool:IsA("Tool") and (gunName(tool.Name) or (attr(tool,"Gun")==true and "Gun"))
            if kind and visible(label) then
                local candidate={tool=tool,number=number}
                selection=selection or candidate
                if R.context.rlgl and kind=="Sniper" then selection=candidate;break end
            end
        end
    end
    if not selection then return end
    if R.equipTool~=selection.tool then R.equipTool=selection.tool;R.equipTries=0 end
    if (R.equipTries or 0)>=3 then R.status="Equip "..selection.tool.Name.." manually; hotbar key had no effect";return end
    local epoch=R.epoch
    R.nextEquip=now+1;R.equipTries=(R.equipTries or 0)+1
    R.inputBusy=true;R.inputStarted=now
    task.defer(function()
        local ok,err=pcall(function()
            if epoch~=R.epoch or not controlsAllowed() or weapon() or selection.tool.Parent~=backpack then return end
            local n=selection.number
            R.keyHeld={code=numberKeys[n==0 and 10 or n],vk=0x30+n,releaseAt=os.clock()+.035}
            R.backend.key(R.keyHeld.code,true,R.keyHeld.vk)
            record("equip","Hotbar "..n..": "..selection.tool.Name)
        end)
        R.inputBusy=false
        if not ok then R.error="Equip input: "..tostring(err);R.setEnabled(false) end
    end)
end


-- Compact standalone panel. Hiding it does not toggle automation.
local function makeUI()
    local pg=LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pg then return end
    disconnect(R.uiConnections)
    local screen=Instance.new("ScreenGui")
    screen.Name="InkGuardAim_UI";screen.ResetOnSpawn=false;screen.IgnoreGuiInset=true
    screen.DisplayOrder=10001;screen.Enabled=not R.hidden
    local frame=Instance.new("Frame");frame.Name="Panel";frame.Size=UDim2.new(0,430,0,342)
    frame.Position=UDim2.new(0,16,0,120);frame.BackgroundColor3=Color3.fromRGB(19,22,30)
    frame.BorderSizePixel=0;frame.Parent=screen
    local function label(text,y,height)
        local l=Instance.new("TextLabel");l.Position=UDim2.new(0,12,0,y);l.Size=UDim2.new(1,-24,0,height)
        l.BackgroundTransparency=1;l.TextColor3=Color3.fromRGB(225,232,245)
        l.Font=Enum.Font.Code;l.TextSize=12;l.TextWrapped=true
        l.TextXAlignment=Enum.TextXAlignment.Left;l.Text=text;l.Parent=frame;return l
    end
    local function button(text,x,y,width,fn)
        local b=Instance.new("TextButton");b.Position=UDim2.new(0,x,0,y);b.Size=UDim2.new(0,width,0,28)
        b.BackgroundColor3=Color3.fromRGB(43,52,72);b.TextColor3=Color3.fromRGB(245,248,255)
        b.BorderSizePixel=0;b.Font=Enum.Font.Code;b.TextSize=12;b.Text=text;b.Parent=frame
        connect(b.Activated,fn,R.uiConnections);return b
    end
    label("INK / AUTO SHOOT 1.1.0",8,24)
    local toggle=button("Auto Shoot [Z]: OFF",12,40,348,function() R.setEnabled(not R.enabled) end)
    local status=label("OFF",74,38)
    local state=label("Light: unknown",114,36)
    local fov=button("",12,158,112,function() Config.FOV=Config.FOV>=400 and 120 or Config.FOV+40 end)
    local smooth=button("",132,158,112,function() Config.TurnToTarget=not Config.TurnToTarget;R.epoch+=1;R.target=nil end)
    local scope=button("",252,158,108,function() Config.AutoScope=not Config.AutoScope end)
    local gun=button("Weapon: Auto",12,196,172,function()
        Config.WeaponMode=Config.WeaponMode=="Auto" and "Sniper" or (Config.WeaponMode=="Sniper" and "Gun" or "Auto")
    end)
    button("Save report",192,196,168,function() R.reportRequested=true end)
    button("Unload",252,234,108,R.destroy)
    local count=label("Shots attempted: 0",234,28);count.Size=UDim2.new(0,232,0,28)
    button("Mark GREEN",12,270,112,function() R.markPhase("green") end)
    button("Mark RED",132,270,112,function() R.markPhase("red") end)
    local equip=button("Auto-equip: ON",252,270,164,function() Config.AutoEquip=not Config.AutoEquip end)
    label("G: hide/show | Z: Auto Shoot ON/OFF",310,22)
    screen.Parent=pg
    ui={screen=screen,toggle=toggle,status=status,state=state,fov=fov,smooth=smooth,scope=scope,gun=gun,count=count,equip=equip}
end
local function uiTick(now)
    if now<R.nextUI then return end
    R.nextUI=now+.15
    if not ui or not ui.screen.Parent then makeUI() end
    if not ui then return end
    ui.toggle.Text=R.enabled and "Auto Shoot [Z]: ON" or "Auto Shoot [Z]: OFF"
    ui.toggle.BackgroundColor3=R.enabled and Color3.fromRGB(27,100,76) or Color3.fromRGB(43,52,72)
    ui.status.Text=R.error~="" and R.error or (((R.noticeUntil or 0)>now and R.notice) or R.status)
    ui.equip.Text=Config.AutoEquip and "Auto-equip: ON" or "Auto-equip: OFF"
    ui.state.Text=("Role: %s | Light: %s | %s\n%s"):format(role(LocalPlayer,LocalPlayer.Character) or "unknown",R.context.light,R.backendName,R.context.source or "Waiting")
    ui.fov.Text="FOV: "..Config.FOV.."px";ui.smooth.Text=Config.TurnToTarget and "Turn + fire" or "Crosshair only"
    ui.scope.Text=Config.AutoScope and "Scope: ON" or "Scope: OFF"
    local w=weapon()
    ui.gun.Text=Config.WeaponMode=="Auto" and (w and ("Auto: "..w.name) or "Auto: equip gun") or ("Weapon: "..Config.WeaponMode)
    ui.count.Text="Clicks: "..R.attempts.." | Gun events: "..(R.gunEvents or 0)
end
function R.getStats()
    return {version="1.1.0",enabled=R.enabled,status=R.status,error=R.error,context=R.context,
        role=role(LocalPlayer,LocalPlayer.Character),backend=R.backendName,shotsAttempted=R.attempts,
        target=R.target and R.target.character.Name,limited=Index.truncated,
        pauseReason=R.pauseReason,mouseGain=R.mouseGain,attacker=R.attacker and R.attacker.player.Name,
        gunEvents=R.gunEvents or 0,phaseLabels=#Index.phaseLabels,discoveryVisits=Index.visits,
        maxTickMs=R.maxTickMs or 0,meanTickMs=R.meanTickMs or 0,
        contextRefreshes=R.contextRefreshes or 0,phaseLabelReads=R.phaseLabelReads or 0,
        stateSources=#Index.sources,values=#Index.values,labels=#Index.labels,highlights=#Index.highlights,scanCounts=Index.scanCounts}
end
local function report()
    R.reportRequested=false
    local function attributes(obj)
        if not obj then return nil end
        local data={}
        for name,v in pairs(obj:GetAttributes()) do
            -- Keep runtime evidence; omit serialized inventory/account payloads.
            if name:sub(1,1)~="_" or name=="_GuardCrawlShotCount" then
                local kind=type(v)
                if kind=="boolean" or kind=="number" then data[name]=v
                else data[name]=tostring(v):sub(1,384) end
            end
        end
        return data
    end
    R.context=context(true)
    local w=weapon()
    local data={stats=R.getStats(),config=Config,events=R.events or {},guiRoots={},worldRoots={},dollHeads={},attributes={workspace=attributes(Workspace),replicatedStorage=attributes(ReplicatedStorage),
        player=attributes(LocalPlayer),character=attributes(LocalPlayer.Character),weapon=w and attributes(w.tool)},
        sources={},values={},players={},lightLabels={},visibleLabels={},roundObjects={},tools={},weapon=w and w.name}
    for _,obj in ipairs(Index.sources) do if obj.Parent then table.insert(data.sources,{path=obj:GetFullName(),attributes=attributes(obj)}) end end
    for _,obj in ipairs(Index.values) do if obj.Parent then table.insert(data.values,{path=obj:GetFullName(),value=obj.Value}) end end
    for i,p in ipairs(R.roster) do
        if i>64 then break end
        table.insert(data.players,{name=p.Name,role=role(p,p.Character),team=p.Team and p.Team.Name,
            attributes=attributes(p),character=attributes(p.Character),redGlow=p.Character and glowing(p.Character)})
    end
    for _,label in ipairs(Index.labels) do
        if Logic.phase(label.Text) then table.insert(data.lightLabels,{path=label:GetFullName(),text=label.Text,visible=visible(label)}) end
        if #data.visibleLabels<160 and visible(label) and label.Text~="" then
            table.insert(data.visibleLabels,{path=label:GetFullName(),text=label.Text:sub(1,192)})
        end
    end
    for _,obj in ipairs(Index.probes) do
        if obj.Parent then
            local entry={path=obj:GetFullName(),class=obj.ClassName,attributes=attributes(obj)}
            if obj:IsA("StringValue") or obj:IsA("BoolValue") or obj:IsA("NumberValue") then entry.value=obj.Value end
            if obj:IsA("Sound") then entry.playing=obj.IsPlaying;entry.soundId=obj.SoundId end
            table.insert(data.roundObjects,entry)
        end
    end
    local holders={LocalPlayer.Character,LocalPlayer:FindFirstChildOfClass("Backpack")}
    for _,holder in pairs(holders) do
        for _,tool in ipairs(holder:GetChildren()) do
            if tool:IsA("Tool") then table.insert(data.tools,{name=tool.Name,attributes=attributes(tool),enabled=tool.Enabled,equipped=holder==LocalPlayer.Character}) end
        end
    end
    for _,child in ipairs(Workspace:GetChildren()) do
        if #data.worldRoots<100 then table.insert(data.worldRoots,{name=child.Name,class=child.ClassName}) end
    end
    if Index.pg then for _,child in ipairs(Index.pg:GetChildren()) do
        table.insert(data.guiRoots,{name=child.Name,class=child.ClassName,skipped=skip(child) and true or false})
    end end
    for _,head in ipairs(Index.heads) do if head.Parent then
        local look=head.CFrame.LookVector
        table.insert(data.dollHeads,{path=head:GetFullName(),look={look.X,look.Y,look.Z}})
    end end
    R.lastReport=data
    local writer=Env.writefile or writefile
    if type(writer)=="function" then task.defer(function()
        R.reportSerial+=1
        local stamp=DateTime and DateTime.now().UnixTimestampMillis or math.floor(os.clock()*1000)
        local name="InkGame_AutoShoot_v110_"..stamp.."_"..R.reportSerial..".json"
        local ok,err=pcall(function() writer(name,HttpService:JSONEncode(data)) end)
        print(ok and ("[Ink Auto Shoot] Saved "..name) or ("[Ink Auto Shoot] Report: "..tostring(err)))
    end) end
end
local function tick(dt)
    local now=os.clock()
    if not R.alive then return end
    if R.inputBusy and now-R.inputStarted>1 then
        R.enabled=false;R.epoch+=1;R.error="Input backend stalled; no more input will be queued"
    end
    if R.destroying then
        inputTick(now)
        if not R.inputBusy and not R.resolvePending and not next(R.held) and not R.keyHeld then
            R.alive=false;disconnect(R.connections);disconnect(R.uiConnections)
            if ui then ui.screen:Destroy() end
            clearIndex();R.motion={};R.violated={};R.target=nil
            if rawget(Env,KEY)==R then Env[KEY]=nil end
        end
        return
    end
    if R.suppressPriorAim then
        -- Both files use Z. Retire the older aim intent after each toggle,
        -- including OFF, so its handler cannot accidentally re-enable aiming.
        local oldAim=rawget(Env,"__InkAutoQTE")
        if oldAim and type(oldAim.setAimEnabled)=="function" then
            oldAim.setAimEnabled(false)
        end
        R.suppressPriorAim=false
    end
    if R.enabled then
        if previous and previous.alive then R.status="Waiting for previous Guard Aim to release input";inputTick(now);uiTick(now);return end
        learnMouse(now);indexTick(now);updateRoster(now);retaliation(now)
        R.context=context();movement(now)
        if now>=(R.nextGlow or 0) then R.nextGlow=now+.04;refreshGlowCache() end
        if R.shotObservation then
            local obs=R.shotObservation
            if obs.tool and obs.tool.Parent and type(attr(obs.tool,"GunShotTick"))=="number" and attr(obs.tool,"GunShotTick")~=obs.stamp then
                R.gunEvents=(R.gunEvents or 0)+1;record("weapon","GunShotTick changed");R.shotObservation=nil
            elseif now-obs.at>1 then R.shotObservation=nil end
        end
        resolveBackend()
        local _,ownRoot=living(LocalPlayer.Character,LocalPlayer)
        local w=weapon()
        if not controlsAllowed() then R.target=nil;R.status="Paused: "..(R.pauseReason or "input unavailable")
        elseif not w then R.target=nil;R.status="Equip a gun; Auto-equip checks your numbered hotbar";autoEquip(now)
        else
            local ownRole=role(LocalPlayer,LocalPlayer.Character)
            R.target=choose(now,ownRoot,ownRole)
            if R.target then
                local camera=Workspace.CurrentCamera
                local focal=camera.ViewportSize.Y*.5/math.tan(math.rad(camera.FieldOfView*.5))
                local response=R.target.mode=="RLGL" and Config.RLGLResponse or Config.SmoothResponse
                local delta=mouseDelta(R.target,dt,focal,response)
                R.status=R.target.mode..": "..R.target.character.Name
                inputTick(now,Config.TurnToTarget and delta or nil,aligned(R.target),w)
            elseif R.context.rlgl and R.context.light~="red" then
                R.status=R.context.light=="unknown" and "RLGL phase missing: mark GREEN and RED doll poses once" or "RLGL: waiting for RED LIGHT"
            elseif not ownRole then R.status="Role unknown; waiting for a valid red-glow enemy"
            elseif ownRole=="guard" and R.context.rlgl==nil then R.status="Guard: no recognized round/light signal"
            else R.status="No visible enemy inside FOV" end
        end
    else
        R.target=nil
        if R.wasRed then R.wasRed=false;R.motion={};R.violated={};R.phaseSerial+=1 end
    end
    if not R.target then inputTick(now) end
    if R.reportRequested then report() end
    uiTick(now)
end
connect(UIS.InputBegan,function(input,processed)
    if not R.alive or R.destroying or UIS:GetFocusedTextBox() or GuiService.MenuIsOpen or not R.focused then return end
    local key=input.KeyCode
    if key~=Enum.KeyCode.G and key~=Enum.KeyCode.Z then return end
    local now=os.clock();if now-(R.lastKeys[key] or -math.huge)<.18 then return end
    R.lastKeys[key]=now
    if key==Enum.KeyCode.Z then R.setEnabled(not R.enabled)
    else R.hidden=not R.hidden;if ui then ui.screen.Enabled=not R.hidden end end
end)
connect(UIS.WindowFocused,function() R.focused=true end)
connect(UIS.WindowFocusReleased,function() R.focused=false;R.epoch+=1 end)
connect(RunService.RenderStepped,function(dt)
    local started=os.clock()
    local ok,err=pcall(tick,dt)
    local ms=(os.clock()-started)*1000
    R.maxTickMs=math.max(R.maxTickMs or 0,ms);R.meanTickMs=(R.meanTickMs or ms)*.98+ms*.02
    if not ok then R.error=tostring(err);R.setEnabled(false);inputTick(os.clock()) end
end)
makeUI()
print("[Ink Auto Shoot] Loaded OFF. Z: Auto Shoot. G: panel. Retaliation + Rebel + red glow; RLGL fires on confirmed red only.")
