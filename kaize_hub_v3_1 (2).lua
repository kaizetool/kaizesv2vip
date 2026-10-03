-- KAIZE HUB 3.1 | Ride a Pet egg collector
-- Client-side KAIZE HUB update. No downloaded code or guessed remotes.
-- RightControl: show/hide. F6: stop all actions. Use X to unload completely.
-- First migration from the old script: rejoin once to remove its unmanaged loops.
-- Live-game compatibility is not guaranteed: server validation still applies.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
assert(LocalPlayer, "KAIZE HUB must run on the client")
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui", 10)
assert(PlayerGui, "KAIZE HUB: PlayerGui was not ready; try again")

local Config = {
    ScanInterval = 15, -- recovery scan; normal discovery uses instance events
    Tick = 0.12,
    MaxRows = 40,
    MaxManualQueue = 32,
    MaxAttempts = 2,
    RetryBase = 4,
    RetryMax = 30,
    HomeSettle = 0.3, -- brief delivery/replication window, then continue farming
    MaxESP = 80,
    MaxHighlights = 24,
    FlyMin = 50,
    FlyMax = 5000,
    ExtraAdminUserIds = {},
    AdminMinGroupRank = 200,
    -- Exact ancestor words; "Baseplate" and "Database" are not gardens.
    GardenWords = {garden = true, gardens = true, plot = true, plots = true,
        farm = true, farms = true, base = true, bases = true, ranch = true, ranches = true, home = true, homes = true},
}

local EggPriority = {
    ["Giant Egg"] = 1000, ["Dragon Egg"] = 990, ["Volcanic Egg"] = 985,
    ["Solaris Egg"] = 980, ["Cherub Egg"] = 970, ["Blackhole Egg"] = 960,
    ["Galaxy Egg"] = 950, ["Aurora Egg"] = 940, ["Soul Egg"] = 930,
    ["Sinister Egg"] = 920, ["Flaming Egg"] = 910, ["Dominus Egg"] = 900,
    ["Asteroid Egg"] = 890, ["Skull Egg"] = 880, ["Crystal Egg"] = 870,
    ["Diamond Egg"] = 860, ["Golden Egg"] = 850, ["Glass Egg"] = 840,
    ["Ice Egg"] = 830, ["Slime Egg"] = 820, ["Flower Egg"] = 810,
    ["Mushroom Egg"] = 800, ["Leaf Egg"] = 790, ["Stone Egg"] = 780,
    ["Easter Egg"] = 770, ["Cracked Egg"] = 760, ["Brown Egg"] = 750,
    ["White Egg"] = 740,
}

-- Pure scheduling rules are separated for regression tests.
-- CORE_BEGIN
local Rules = {}
function Rules.eggName(name)
    local lower = string.lower(name)
    return EggPriority[name] ~= nil or string.find(lower, "%f[%a]egg%f[%A]") ~= nil
end
function Rules.gardenName(name)
    local split = string.gsub(name, "(%l)(%u)", "%1 %2")
    for word in string.gmatch(string.lower(split), "%a+") do
        if Config.GardenWords[word] then return true end
    end
    return false
end
function Rules.less(a, b, mode)
    if mode == "Nearest" and a.distance ~= b.distance then return a.distance < b.distance end
    if a.priority ~= b.priority then return a.priority > b.priority end
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
end
function Rules.retryDelay(failures)
    return math.min(Config.RetryMax, Config.RetryBase * 2 ^ math.min(failures - 1, 8))
end
function Rules.autoAllowed(mode, selected, name)
    return mode == "All" or selected[name] == true
end
function Rules.flySpeed(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then return nil end
    return math.clamp(math.floor(number + 0.5), Config.FlyMin, Config.FlyMax)
end
function Rules.flightVelocity(look, right, forward, sideways, vertical, speed)
    local direction = look * forward + right * sideways + Vector3.new(0, vertical, 0)
    if direction.Magnitude > 1 then direction = direction.Unit end
    return direction * speed
end
function Rules.normalName(value)
    return string.lower(tostring(value)):gsub("[^%w]", "")
end
function Rules.baseGroup(name)
    local groups = {ranches = true, bases = true, plots = true, homes = true, gardens = true, farms = true}
    return groups[Rules.normalName(name)] == true
end
function Rules.baseName(name)
    if Rules.baseGroup(name) then return false end
    local split = string.gsub(name, "(%l)(%u)", "%1 %2")
    for word in string.gmatch(string.lower(split), "%a+") do
        if word == "ranch" or word == "base" or word == "plot" or word == "home" or word == "garden" then return true end
    end
    return false
end
-- CORE_END

local App = {
    alive = true, epoch = 0, connections = {}, candidates = {}, nextId = 0,
    queue = {}, queued = {}, active = nil, holding = nil,
    cooldown = setmetatable({}, {__mode = "k"}),
    auto = false, selected = {}, sort = "Priority", mode = "All",
    speed = "Balanced", autoReturn = true, stowEggTools = true,
    antiAFK = false, autoLeave = false, theme = "Galaxy", language = "en",
    uiScale = 1, baseProof = nil, baseCandidates = {}, baseLabels = {}, baseLastTry = -math.huge,
    baseStatus = "Base: checking assigned ranch", tab = "Collect",
    minimized = false, picked = 0, unverified = 0, failures = 0,
    started = os.clock(), status = "Ready", logs = {}, ui = {}, dirty = true,
    search = "", espEnabled = false, espSelectedOnly = false, espRows = {}, espCount = 0,
    flyEnabled = false, flySpeed = 100, flight = nil, flightKeys = {}, flightTouches = {},
    noclipEnabled = false, noclipCharacter = nil, collisionOriginal = {}, windowFocused = true,
}
local Profiles = {
    Fast = {settle = 0.05, grace = 0.55, gap = 0.05},
    Balanced = {settle = 0.12, grace = 1.0, gap = 0.12},
    Reliable = {settle = 0.25, grace = 1.8, gap = 0.25},
}
local FlyKeyActions = {
    [Enum.KeyCode.W] = "forward", [Enum.KeyCode.S] = "back",
    [Enum.KeyCode.A] = "left", [Enum.KeyCode.D] = "right",
    [Enum.KeyCode.Space] = "up", [Enum.KeyCode.E] = "up",
    [Enum.KeyCode.Q] = "down", [Enum.KeyCode.LeftControl] = "down",
}
local Compat = {firePrompt = type(fireproximityprompt) == "function" and fireproximityprompt or nil}
pcall(function() Compat.virtualUser = game:GetService("VirtualUser") end)

function App:connect(signal, callback)
    local connection = signal:Connect(function(...)
        if self.alive then callback(...) end
    end)
    table.insert(self.connections, connection)
    return connection
end
function App:log(message)
    self.status = message
    table.insert(self.logs, 1, string.format("%02d:%02d  %s",
        math.floor((os.clock() - self.started) / 60), math.floor(os.clock() - self.started) % 60, message))
    if #self.logs > 60 then table.remove(self.logs) end
    self.dirty = true
end
function App:character()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if root and humanoid and humanoid.Health > 0 then return char, root, humanoid end
    return nil
end
function App:valid(token, char)
    return self.alive and token == self.epoch and self:character() == char
end
function App:waitFor(seconds, token, char)
    local untilTime = os.clock() + seconds
    repeat
        if not self:valid(token, char) then return false end
        task.wait(math.min(0.05, math.max(0, untilTime - os.clock())))
    until os.clock() >= untilTime
    return self:valid(token, char)
end
function App:releaseInput()
    local holding = self.holding
    self.holding = nil
    if holding then
        pcall(function() holding.prompt:InputHoldEnd() end)
        if holding.originalHold ~= nil then
            pcall(function() holding.prompt.HoldDuration = holding.originalHold end)
        end
    end
end
function App:cancel(message)
    self.epoch = self.epoch + 1
    self.queue, self.queued = {}, {}
    self:releaseInput()
    if message then self:log(message) end
end
function App:stop(message)
    self.auto = false
    self:cancel(message or "Stopped")
    self:disableFly()
    self:setNoclip(false)
end
function App:unload()
    if not self.alive then return end
    self:stop()
    self.alive = false
    for _, connection in ipairs(self.connections) do connection:Disconnect() end
    self.connections = {}
    self:clearESP()
    if self.espGuiFolder then self.espGuiFolder:Destroy() end
    if self.espWorldFolder then self.espWorldFolder:Destroy() end
    if self.gui then self.gui:Destroy() end
end

-- Unload both the previous KAIZE session and older VIPKING versions.
for _, oldName in ipairs({"KAIZE_HUB_V3", "VIPKING_V2"}) do
    local previous = PlayerGui:FindFirstChild(oldName)
    if previous then
        local shutdown = previous:FindFirstChild("Shutdown")
        if shutdown and shutdown:IsA("BindableFunction") then pcall(function() shutdown:Invoke() end) end
        previous:Destroy()
    end
end

function App:isOwned(obj)
    local char = LocalPlayer.Character
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    return (char and obj:IsDescendantOf(char)) or (backpack and obj:IsDescendantOf(backpack)) or false
end
function App:inventory()
    -- Deduplicate by the top-level carried item, not every egg-named descendant.
    local items, seen = {}, {}
    local function scan(container)
        if not container then return end
        for _, item in ipairs(container:GetDescendants()) do
            if (item:IsA("Tool") or item:IsA("Model") or item:IsA("BasePart")) and Rules.eggName(item.Name) then
                local top = item
                while top.Parent and top.Parent ~= container do top = top.Parent end
                if top.Parent == container and not top:IsA("Accessory")
                    and top.Name ~= "HumanoidRootPart" and not seen[top] then
                    seen[top] = true
                    table.insert(items, {object = top, name = item.Name, priority = EggPriority[item.Name] or 1})
                end
            end
        end
    end
    scan(LocalPlayer.Character)
    scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
    table.sort(items, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.name < b.name
    end)
    return items
end
function App:confirmed(egg, name, before)
    if egg.Parent and self:isOwned(egg) then return true end
    for _, item in ipairs(self:inventory()) do
        if item.name == name and not before[item.object] then return true end
    end
    return false
end
function App:position(obj)
    if not obj or not obj.Parent then return nil end
    if obj:IsA("Attachment") then return obj.WorldPosition end
    if obj:IsA("BasePart") then return obj.Position end
    if obj:IsA("Model") and obj:FindFirstChildWhichIsA("BasePart", true) then return obj:GetPivot().Position end
    return nil
end
function App:eligible(obj)
    if not obj.Parent or not obj:IsDescendantOf(Workspace) then return false end
    if not (obj:IsA("Model") or obj:IsA("BasePart")) or not Rules.eggName(obj.Name) then return false end
    local node = obj
    while node and node ~= Workspace do
        if node:IsA("Tool") or node:IsA("Accessory") then return false end
        if node:IsA("Model") or node:IsA("Folder") then
            if Rules.gardenName(node.Name) then return false end
        end
        if node:IsA("Model") and (Players:GetPlayerFromCharacter(node) or node:FindFirstChildOfClass("Humanoid")) then
            return false
        end
        if node ~= obj and node:IsA("Model") and Rules.eggName(node.Name) then return false end
        node = node.Parent
    end
    return self:position(obj) ~= nil
end
function App:track(obj)
    if obj:IsA("TextLabel") then self.baseLabels[obj] = true end
    if (obj:IsA("Model") or obj:IsA("Folder")) and not Rules.baseGroup(obj.Name)
        and (Rules.baseName(obj.Name) or (obj.Parent and Rules.baseGroup(obj.Parent.Name))) then
        self.baseCandidates[obj] = true
    end
    if not self.candidates[obj] and (obj:IsA("Model") or obj:IsA("BasePart")) and Rules.eggName(obj.Name) then
        self.nextId = self.nextId + 1
        self.candidates[obj] = self.nextId
        self.dirty = true
    end
end
function App:scan()
    for obj in pairs(self.candidates) do
        if not obj:IsDescendantOf(Workspace) then self.candidates[obj] = nil end
    end
    for _, obj in ipairs(Workspace:GetDescendants()) do self:track(obj) end
    for _, obj in ipairs(PlayerGui:GetDescendants()) do
        if obj:IsA("TextLabel") and not obj:IsDescendantOf(self.gui) then self.baseLabels[obj] = true end
    end
    for obj in pairs(self.baseCandidates) do if not obj:IsDescendantOf(Workspace) then self.baseCandidates[obj] = nil end end
    for obj in pairs(self.baseLabels) do if not obj.Parent then self.baseLabels[obj] = nil end end
    self.dirty = true
end
function App:listEggs()
    local _, root = self:character()
    local list = {}
    for obj, id in pairs(self.candidates) do
        if self:eligible(obj) then
            table.insert(list, {object = obj, name = obj.Name, id = id, priority = EggPriority[obj.Name] or 1,
                distance = root and (self:position(obj) - root.Position).Magnitude or math.huge})
        end
    end
    table.sort(list, function(a, b) return Rules.less(a, b, self.sort) end)
    return list
end
function App:findPrompt(egg)
    -- Only prompts belonging to this egg. Never trigger a nearby unrelated prompt.
    local center = self:position(egg)
    if not center then return nil end
    local best, bestDistance
    for _, child in ipairs(egg:GetDescendants()) do
        if child:IsA("ProximityPrompt") and child.Enabled then
            local pos = self:position(child.Parent)
            local distance = pos and (pos - center).Magnitude
            if distance and (not bestDistance or distance < bestDistance) then best, bestDistance = child, distance end
        end
    end
    return best
end
function App:move(root, cf)
    if root.Anchored then return false end
    root.CFrame = cf
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    return true
end
-- Base resolution keeps live object references, never the player's CFrame.
local OwnerFields = {owner = true, ownerid = true, owneruserid = true, ownername = true,
    player = true, playerid = true, playeruserid = true, claimedby = true, plotowner = true, ranchowner = true}
local AssignmentFields = {base = true, baseid = true, basename = true, ranch = true, ranchid = true,
    ranchname = true, plot = true, plotid = true, plotname = true, home = true, assignedbase = true, assignedranch = true}
function App:matchesPlayer(value)
    if typeof(value) == "Instance" then return value == LocalPlayer end
    if type(value) == "number" then return value == LocalPlayer.UserId end
    if type(value) ~= "string" then return false end
    return value == tostring(LocalPlayer.UserId) or string.lower(value) == string.lower(LocalPlayer.Name)
end
function App:ownerState(obj)
    local matched, conflict = false, false
    local function consider(value)
        if value ~= nil and value ~= "" then
            if self:matchesPlayer(value) then matched = true else conflict = true end
        end
    end
    for key, value in pairs(obj:GetAttributes()) do if OwnerFields[Rules.normalName(key)] then consider(value) end end
    for _, child in ipairs(obj:GetChildren()) do
        if OwnerFields[Rules.normalName(child.Name)] and child:IsA("ValueBase") then consider(child.Value) end
    end
    return matched, conflict
end
function App:baseObjectAllowed(obj)
    if not obj or not obj:IsDescendantOf(Workspace) then return false end
    local node = obj
    while node and node ~= Workspace do
        if node:IsA("Tool") or node:IsA("Accessory") or Rules.eggName(node.Name) then return false end
        if node:IsA("Model") and (Players:GetPlayerFromCharacter(node) or node:FindFirstChildOfClass("Humanoid")) then return false end
        node = node.Parent
    end
    return true
end
function App:baseContainer(obj)
    if not self:baseObjectAllowed(obj) then return nil end
    local best, node = nil, obj
    while node and node ~= Workspace do
        if (node:IsA("Model") or node:IsA("Folder")) and not Rules.baseGroup(node.Name) then
            if node.Parent and Rules.baseGroup(node.Parent.Name) then return node end
            if Rules.baseName(node.Name) then best = node end
        end
        node = node.Parent
    end
    return best
end
function App:labelBase(label)
    if not label.Parent or not label.Visible then return nil end
    local text = Rules.normalName((label.Text:gsub("<[^>]+>", "")))
    if text ~= "yourranch" and text ~= "yourbase" and text ~= "yourhome" and text ~= "yourplot" then return nil end
    local node = label.Parent
    while node and node ~= Workspace and node ~= PlayerGui do
        if node:IsA("BillboardGui") or node:IsA("SurfaceGui") then
            if not node.Enabled then return nil end
            return self:baseContainer(node.Adornee or node.Parent)
        end
        node = node.Parent
    end
    return nil
end
function App:assignmentValue(proof)
    if proof.attribute then return proof.source:GetAttribute(proof.attribute) end
    return proof.source.Parent and proof.source.Value or nil
end
function App:assignmentMatches(root, value)
    if typeof(value) == "Instance" then return value == root or value:IsDescendantOf(root) end
    if type(value) ~= "number" and type(value) ~= "string" then return false end
    if tostring(value) == root.Name then return true end
    for _, key in ipairs({"BaseId", "RanchId", "PlotId", "Id", "ID"}) do
        local id = root:GetAttribute(key)
        if id ~= nil and tostring(id) == tostring(value) then return true end
    end
    return false
end
function App:baseProofValid(proof)
    if not proof or not self:baseObjectAllowed(proof.root) then return false end
    local own, conflict = self:ownerState(proof.root)
    if conflict then return false end
    if proof.kind == "owner" then return own end
    if proof.kind == "assigned" then return self:assignmentMatches(proof.root, self:assignmentValue(proof)) end
    if proof.kind == "label" then return self:labelBase(proof.source) == proof.root end
    if proof.kind == "name" then
        return proof.root.Parent and Rules.baseGroup(proof.root.Parent.Name)
            and (proof.root.Name == tostring(LocalPlayer.UserId) or string.lower(proof.root.Name) == string.lower(LocalPlayer.Name))
    end
    return false
end
function App:findAssignedBase()
    if self:baseProofValid(self.baseProof) then return self.baseProof.root end
    self.baseProof = nil
    if os.clock() - self.baseLastTry < 2 then return nil end
    self.baseLastTry = os.clock()
    local matches, bestRank = {}, 0
    local function offer(proof, rank)
        if not self:baseProofValid(proof) then return end
        if rank > bestRank then matches = {}; bestRank = rank end
        if rank == bestRank then matches[proof.root] = proof end
    end
    local function assignment(source, attribute, value)
        if typeof(value) == "Instance" and self:baseObjectAllowed(value) then
            local root = self:baseContainer(value) or value
            if not Rules.baseGroup(root.Name) and (root:IsA("Model") or root:IsA("Folder") or root:IsA("BasePart")) then
                offer({root = root, kind = "assigned", source = source, attribute = attribute}, 3)
            end
        else
            for root in pairs(self.baseCandidates) do
                if self:assignmentMatches(root, value) then offer({root = root, kind = "assigned", source = source, attribute = attribute}, 3) end
            end
        end
    end
    for key, value in pairs(LocalPlayer:GetAttributes()) do
        if AssignmentFields[Rules.normalName(key)] then assignment(LocalPlayer, key, value) end
    end
    for _, child in ipairs(LocalPlayer:GetChildren()) do
        if AssignmentFields[Rules.normalName(child.Name)] and child:IsA("ValueBase") then assignment(child, nil, child.Value) end
    end
    for root in pairs(self.baseCandidates) do
        offer({root = root, kind = "owner"}, 2)
        offer({root = root, kind = "name"}, 1)
    end
    for label in pairs(self.baseLabels) do
        local root = self:labelBase(label)
        if root then offer({root = root, kind = "label", source = label}, 1) end
    end
    local result
    for root, proof in pairs(matches) do
        if result and result.root ~= root then
            self.baseStatus = "Base: multiple assignments found; ownership is ambiguous"
            return nil
        end
        result = proof
    end
    self.baseProof = result
    if result then self.baseStatus = "Base: " .. result.root:GetFullName() .. " (" .. result.kind .. ")"; return result.root end
    self.baseStatus = "Base not detected: assigned ranch/ownership data is not available"
    return nil
end
function App:baseDestination()
    local base = self:findAssignedBase()
    if not base then return nil end
    local priorities = {returnpoint = 100, homespawn = 100, playerspawn = 100, spawnpoint = 95,
        spawn = 90, depositzone = 85, deliveryzone = 85, dropoff = 85, entrance = 70,
        floor = 50, baseplate = 50, ground = 50, platform = 45}
    local parts = base:GetDescendants()
    if base:IsA("BasePart") then table.insert(parts, base) end
    local candidates = {}
    for _, part in ipairs(parts) do
        if part:IsA("BasePart") and part.Anchored and self:baseObjectAllowed(part) then
            local rank = priorities[Rules.normalName(part.Name)] or 0
            if part == LocalPlayer.RespawnLocation then rank = 110 end
            if part.CanCollide and part.Size.X >= 4 and part.Size.Z >= 4 and part.Size.Y <= math.max(part.Size.X, part.Size.Z) / 2
                and part.CFrame.UpVector.Y > 0.7 then
                -- A live flat structural part inside the identified base, not its model pivot.
                if rank == 0 then rank = 10 end
                table.insert(candidates, {part = part, rank = rank})
            elseif rank >= 70 then
                -- Trigger/spawn markers may be non-colliding; ground must still belong to this base.
                table.insert(candidates, {part = part, rank = rank, needsGround = true})
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.part:GetFullName() < b.part:GetFullName()
    end)
    for _, item in ipairs(candidates) do
        if not item.needsGround then
            local part = item.part
            return CFrame.new(part.Position + Vector3.new(0, part.Size.Y / 2 + 3.5, 0))
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = {base}
        params.RespectCanCollide = true
        local hit = Workspace:Raycast(item.part.Position + Vector3.new(0, 8, 0), Vector3.new(0, -150, 0), params)
        if hit and hit.Normal.Y > 0.7 and self:baseObjectAllowed(hit.Instance)
            and (hit.Instance == base or hit.Instance:IsDescendantOf(base)) then
            return CFrame.new(hit.Position + Vector3.new(0, 3.5, 0))
        end
    end
    self.baseStatus = "Base found, but no usable spawn/floor is loaded: " .. base.Name
    return nil
end

function App:queueJob(job)
    if not self.alive then return end
    if job.kind ~= "pickup" and job.kind ~= "home" then return end
    self:disableFly()
    if #self.queue >= Config.MaxManualQueue then self:log("Queue is full"); return end
    if job.egg and (self.queued[job.egg] or (self.active and self.active.egg == job.egg)) then return end
    if job.egg then self.queued[job.egg] = true end
    table.insert(self.queue, job)
    self.dirty = true
end
function App:nextJob()
    while #self.queue > 0 do
        local job = table.remove(self.queue, 1)
        if job.egg then self.queued[job.egg] = nil end
        if not job.egg or self:eligible(job.egg) then return job end
    end
    if not self.auto then return nil end
    -- A carried/equipped egg must not block the next farm trip.
    for _, entry in ipairs(self:listEggs()) do
        local retry = self.cooldown[entry.object]
        if (not retry or retry.at <= os.clock()) and Rules.autoAllowed(self.mode, self.selected, entry.name) then
            return {kind = "pickup", egg = entry.object, automatic = true}
        end
    end
    self.status = self.mode == "Selected" and "Waiting for selected egg types" or "Waiting for available eggs"
    return nil
end

function App:attemptPickup(egg, token, char, root, before, name)
    local prompt = self:findPrompt(egg)
    if not prompt then return "failed", "No enabled prompt inside " .. name end
    local pos = self:position(prompt.Parent)
    if not pos then return "failed", "Prompt has no usable position" end
    if prompt.MaxActivationDistance < 0.5 then return "failed", "Prompt activation distance is too small" end
    local offset = math.min(2, prompt.MaxActivationDistance * 0.5)
    if not self:move(root, CFrame.new(pos + Vector3.new(0, offset, 0))) then return "failed", "Character is anchored" end
    local profile = Profiles[self.speed]
    if not self:waitFor(profile.settle, token, char) then return "cancelled" end
    if self:confirmed(egg, name, before) then return "confirmed" end
    if not self:eligible(egg) then return "unverified", "Egg moved or disappeared before pickup" end
    if not prompt.Parent or not prompt.Enabled then return "failed", "Prompt became unavailable" end
    if (root.Position - pos).Magnitude > prompt.MaxActivationDistance then return "failed", "Server moved character out of range" end

    local originalHold = prompt.HoldDuration
    self.holding = {prompt = prompt, originalHold = originalHold}
    -- One accelerated attempt, then the prompt's normal hold. Never spam prompts.
    if Compat.firePrompt and self.speed ~= "Reliable" then
        local ok = pcall(function()
            prompt.HoldDuration = 0
            Compat.firePrompt(prompt)
        end)
        pcall(function() prompt.HoldDuration = originalHold end)
        if ok then
            local deadline = os.clock() + profile.grace
            repeat
                if not self:valid(token, char) then return "cancelled" end
                if self:confirmed(egg, name, before) then return "confirmed" end
                task.wait(0.05)
            until os.clock() >= deadline
        end
    end
    if not self:valid(token, char) then return "cancelled" end
    if self:confirmed(egg, name, before) then return "confirmed" end
    if not self:eligible(egg) then return "unverified", "Egg left the map; ownership not confirmed" end
    if not prompt.Parent or not prompt.Enabled then return "failed", "Prompt disabled before normal hold" end
    if originalHold > 15 then return "failed", "Prompt hold exceeds the 15-second limit" end

    local held = pcall(function() prompt:InputHoldBegin() end)
    if not held then return "failed", "Prompt input is unavailable in this client" end
    local holdUntil = os.clock() + originalHold + 0.08
    repeat
        if not self:valid(token, char) then return "cancelled" end
        if self:confirmed(egg, name, before) then return "confirmed" end
        task.wait(0.05)
    until os.clock() >= holdUntil
    self:releaseInput()
    local deadline = os.clock() + profile.grace
    repeat
        if not self:valid(token, char) then return "cancelled" end
        if self:confirmed(egg, name, before) then return "confirmed" end
        task.wait(0.05)
    until os.clock() >= deadline
    if not self:eligible(egg) then return "unverified", "Egg left the map; ownership not confirmed" end
    return "failed", "No inventory confirmation for " .. name
end

function App:pickup(job, token, char, root)
    local egg, before = job.egg, {}
    if not self:eligible(egg) then return end
    local name = egg.Name
    for _, item in ipairs(self:inventory()) do before[item.object] = true end
    local result, reason
    for attempt = 1, Config.MaxAttempts do
        if not self:valid(token, char) then return end
        self.status = string.format("Picking up %s (%d/%d)", name, attempt, Config.MaxAttempts)
        result, reason = self:attemptPickup(egg, token, char, root, before, name)
        self:releaseInput()
        if result ~= "failed" then break end
        if not self:waitFor(Profiles[self.speed].gap, token, char) then return end
    end
    if not self:valid(token, char) or result == "cancelled" then return end
    if result == "confirmed" then
        self.picked = self.picked + 1
        self.cooldown[egg] = nil
        self:log("Confirmed pickup: " .. name)
    elseif result == "unverified" then
        self.unverified = self.unverified + 1
        self.cooldown[egg] = {at = os.clock() + Config.RetryMax, failures = 1}
        self:log(reason or "Pickup could not be verified")
    else
        self.failures = self.failures + 1
        local old = self.cooldown[egg]
        local failures = (old and old.failures or 0) + 1
        local delay = Rules.retryDelay(failures)
        self.cooldown[egg] = {at = os.clock() + delay, failures = failures}
        self:log((reason or "Pickup failed") .. string.format("; retry in %ds", delay))
    end
end

function App:returnSettle(token, char, humanoid)
    if not self:waitFor(Config.HomeSettle, token, char) then return end
    if self.stowEggTools then
        -- Only call UnequipTools when an egg Tool is equipped. No drop or trade input.
        for _, entry in ipairs(self:inventory()) do
            if entry.object:IsA("Tool") and entry.object:IsDescendantOf(char) then
                pcall(function() humanoid:UnequipTools() end)
                break
            end
        end
    end
    -- Non-Tool carried models are left alone; the scheduler still continues.
end

function App:clearFlightInput()
    self.flightKeys, self.flightTouches = {}, {}
    if self.flight and self.flight.velocity then
        pcall(function() self.flight.velocity.VectorVelocity = Vector3.zero end)
    end
end
function App:disableFly()
    local flight = self.flight
    self.flight = nil
    self.flyEnabled = false
    self:clearFlightInput()
    if self.ui.flightPad then self.ui.flightPad.Visible = false end
    if flight then
        for _, key in ipairs({"velocity", "orientation", "attachment"}) do
            if flight[key] then pcall(function() flight[key]:Destroy() end) end
        end
        pcall(function()
            flight.humanoid.AutoRotate = flight.autoRotate
            flight.humanoid.PlatformStand = flight.platformStand
            if not flight.platformStand and flight.humanoid.Health > 0 and LocalPlayer.Character == flight.character then
                flight.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
            end
        end)
        pcall(function()
            flight.root.AssemblyLinearVelocity = Vector3.zero
            flight.root.AssemblyAngularVelocity = Vector3.zero
        end)
    end
    self.dirty = true
end
function App:enableFly()
    if self.flyEnabled then return end
    local char, root, humanoid = self:character()
    if not root then self:log("Wait for your character to spawn"); return end
    if root.Anchored or humanoid.Sit then self:log("Stand up/dismount before enabling Fly"); return end
    self.auto = false
    self:cancel()
    self:clearFlightInput()
    local flight = {character = char, root = root, humanoid = humanoid,
        autoRotate = humanoid.AutoRotate, platformStand = humanoid.PlatformStand}
    self.flight = flight
    local ok, err = pcall(function()
        flight.attachment = self:node("Attachment", root, {Name = "KaizeFlightAttachment"})
        flight.velocity = self:node("LinearVelocity", root, {Name = "KaizeFlightVelocity",
            Attachment0 = flight.attachment, RelativeTo = Enum.ActuatorRelativeTo.World,
            VelocityConstraintMode = Enum.VelocityConstraintMode.Vector, ForceLimitsEnabled = false,
            VectorVelocity = Vector3.zero})
        flight.orientation = self:node("AlignOrientation", root, {Name = "KaizeFlightOrientation",
            Attachment0 = flight.attachment, Mode = Enum.OrientationAlignmentMode.OneAttachment,
            MaxTorque = 1000000000, MaxAngularVelocity = 100, Responsiveness = 25,
            CFrame = root.CFrame})
        humanoid.AutoRotate = false
        humanoid.PlatformStand = true
    end)
    if not ok then self:disableFly(); self:log("Fly unavailable: " .. tostring(err)); return end
    self.flyEnabled = true
    if self.ui.flightPad then self.ui.flightPad.Visible = true end
    self:log("Fly ON at " .. self.flySpeed .. " studs/s. Auto farm stopped.")
end
function App:setFlySpeed(value)
    local speed = Rules.flySpeed(value)
    if not speed then
        if self.ui.flySpeedBox then self.ui.flySpeedBox.Text = tostring(self.flySpeed) end
        self:log("Enter a number from 50 to 5000 for Fly speed")
        return false
    end
    self.flySpeed = speed
    if self.ui.flySpeedBox then self.ui.flySpeedBox.Text = tostring(speed) end
    self.dirty = true
    return true
end
function App:rememberCollision(part)
    if not part:IsA("BasePart") then return end
    if self.collisionOriginal[part] == nil then self.collisionOriginal[part] = part.CanCollide end
    part.CanCollide = false
end
function App:setNoclip(enabled)
    if not enabled then
        self.noclipEnabled = false
        if self.noclipAdded then self.noclipAdded:Disconnect(); self.noclipAdded = nil end
        for part, value in pairs(self.collisionOriginal) do pcall(function() part.CanCollide = value end) end
        self.collisionOriginal = {}
        self.noclipCharacter = nil
        self.dirty = true
        return
    end
    if self.noclipEnabled then return end
    local char = self:character()
    if not char then self:log("Wait for your character to spawn"); return end
    self.noclipCharacter = char
    self.noclipEnabled = true
    local ok, err = pcall(function()
        for _, part in ipairs(char:GetDescendants()) do self:rememberCollision(part) end
        self.noclipAdded = char.DescendantAdded:Connect(function(part)
            if self.alive and self.noclipEnabled and self.noclipCharacter == char then
                local tracked, trackError = pcall(function() self:rememberCollision(part) end)
                if not tracked then self:setNoclip(false); self:log("No Clip stopped: " .. tostring(trackError)) end
            end
        end)
    end)
    if not ok then self:setNoclip(false); self:log("No Clip unavailable: " .. tostring(err)); return end
    self:log("No Clip ON")
end
function App:updateMovement()
    local char, root = self:character()
    if self.noclipEnabled then
        if not char or char ~= self.noclipCharacter then self:setNoclip(false)
        else
            for part, original in pairs(self.collisionOriginal) do
                if part:IsDescendantOf(char) then part.CanCollide = false
                else
                    pcall(function() part.CanCollide = original end)
                    self.collisionOriginal[part] = nil
                end
            end
        end
    end
    local flight = self.flight
    if not self.flyEnabled or not flight then return end
    if char ~= flight.character or root ~= flight.root or root.Anchored
        or not flight.velocity.Parent or not flight.orientation.Parent or not flight.attachment.Parent then
        self:disableFly(); self:log("Fly stopped: character changed or cannot move"); return
    end
    local camera = Workspace.CurrentCamera
    if not camera or not self.windowFocused or UserInputService:GetFocusedTextBox() then
        self:clearFlightInput()
        flight.velocity.VectorVelocity = Vector3.zero
        return
    end
    local actions = {}
    for _, action in pairs(self.flightKeys) do actions[action] = true end
    for _, action in pairs(self.flightTouches) do actions[action] = true end
    local forward = (actions.forward and 1 or 0) - (actions.back and 1 or 0)
    local sideways = (actions.right and 1 or 0) - (actions.left and 1 or 0)
    local vertical = (actions.up and 1 or 0) - (actions.down and 1 or 0)
    flight.velocity.VectorVelocity = Rules.flightVelocity(camera.CFrame.LookVector, camera.CFrame.RightVector,
        forward, sideways, vertical, self.flySpeed)
    local look = camera.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    if flat.Magnitude > 0.01 then flight.orientation.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit) end
    flight.humanoid.AutoRotate = false
    flight.humanoid.PlatformStand = true
end

function App:runJob(job)
    local char, root, humanoid = self:character()
    if not root then self:log("Waiting for character"); return end
    if root.Anchored or humanoid.Sit then self:log("Stand up and wait until your character can move"); return end
    local token = self.epoch
    if job.kind == "home" or (job.kind == "pickup" and self.autoReturn) then
        local destination = self:baseDestination()
        if not destination then
            self.auto = false
            self:cancel(self.baseStatus .. "; collection stopped")
            return
        end
    end
    self.active = job
    local ok, err = xpcall(function()
        if job.kind == "pickup" then self:pickup(job, token, char, root)
        elseif job.kind == "home" then
            local destination = self:baseDestination()
            if destination then self:move(root, destination); self:log("Returned to assigned base")
            else self:log(self.baseStatus) end
        end
    end, function(message) return tostring(message) end)
    self:releaseInput() -- finally: always release input and restore prompt properties
    if self:valid(token, char) and job.kind == "pickup" and self.autoReturn then
        local returned, moved = pcall(function()
            local destination = self:baseDestination()
            if not destination then self.auto = false; self.queue = {}; self.queued = {}; return false end
            return self:move(root, destination)
        end)
        if returned and moved then
            local settled, settleError = pcall(function() self:returnSettle(token, char, humanoid) end)
            if not settled and self.alive then self:log("Home cleanup skipped: " .. tostring(settleError)) end
        elseif self.alive then self.auto = false; self.queue = {}; self.queued = {}; self:log(self.baseStatus .. "; return failed, collection stopped") end
    end
    self.active = nil
    self.dirty = true
    if not ok and self.alive then
        self:log("Action error: " .. tostring(err))
        if job.egg then self.cooldown[job.egg] = {at = os.clock() + Config.RetryMax, failures = 1} end
    end
end

-- UI: lightweight, touch-friendly, and scaled to the current viewport.
local Palettes = {
    Galaxy = {accent = Color3.fromRGB(141, 112, 255), bg = Color3.fromRGB(18, 20, 31)},
    Ocean = {accent = Color3.fromRGB(71, 177, 255), bg = Color3.fromRGB(15, 25, 36)},
    Emerald = {accent = Color3.fromRGB(74, 218, 163), bg = Color3.fromRGB(16, 29, 27)},
    Nebula = {accent = Color3.fromRGB(239, 119, 195), bg = Color3.fromRGB(29, 20, 33)},
    Crimson = {accent = Color3.fromRGB(255, 119, 131), bg = Color3.fromRGB(32, 20, 26)},
    Purple = {accent = Color3.fromRGB(194, 138, 255), bg = Color3.fromRGB(26, 20, 36)},
}
local Khmer = {
    Collect = "ប្រមូល", World = "ផែនទី", Settings = "ការកំណត់", Activity = "សកម្មភាព",
    Available = "ពងមាន", Confirmed = "បានយក", Queue = "ជួរ", Session = "រយៈពេល",
    ["START AUTO"] = "ចាប់ផ្តើមស្វ័យប្រវត្តិ", ["STOP AUTO"] = "បញ្ឈប់ស្វ័យប្រវត្តិ",
    ["Pick next"] = "យកពងបន្ទាប់", ["Go base"] = "ត្រឡប់ទៅមូលដ្ឋាន",
    ["Search eggs..."] = "ស្វែងរកពង...",
    ["No eggs match your search"] = "គ្មានពងត្រូវនឹងការស្វែងរក",
    ["No eligible eggs in the loaded map"] = "មិនមានពងនៅលើផែនទីដែលបានផ្ទុក",
    ["Return to base after pickup"] = "ត្រឡប់ក្រោយយកពង", ["Stow egg tools at home"] = "ទុកពងនៅក្នុងកាបូប",
    ["Anti-AFK"] = "ការពារនៅស្ងៀម", ["Auto leave for owner/admin"] = "ចេញពេលម្ចាស់ចូល",
    ["Refresh map"] = "ផ្ទុកផែនទីឡើងវិញ", ["Clear retry cooldowns"] = "សម្អាតពេលរង់ចាំ",
    ["Clear selected types"] = "សម្អាតប្រភេទដែលជ្រើស", ["Reset session stats"] = "កំណត់ស្ថិតិឡើងវិញ",
    ["Clear activity"] = "សម្អាតសកម្មភាព", ["Unload KAIZE HUB"] = "បិទ KAIZE HUB",
    PICK = "យក", ON = "បើក", OFF = "បិទ", Selected = "បានជ្រើស", All = "ទាំងអស់",
    Priority = "លំដាប់", Nearest = "ជិតបំផុត", ["Auto types"] = "ប្រភេទស្វ័យប្រវត្តិ",
    Speed = "ល្បឿន", Theme = "ពណ៌", ["UI scale"] = "ទំហំ", Language = "ភាសា",
    ["Egg ESP"] = "បង្ហាញពង ESP", ["ESP selected types only"] = "បង្ហាញតែប្រភេទដែលជ្រើស",
    Fly = "ហោះ", ["No Clip"] = "ឆ្លងជញ្ជាំង", ["Apply speed"] = "កំណត់ល្បឿន",
}
function App:tr(key) return self.language == "km" and Khmer[key] or key end
function App:colors()
    local palette = Palettes[self.theme]
    return {accent = palette.accent, bg = palette.bg, card = palette.bg:Lerp(Color3.new(1, 1, 1), 0.055),
        button = palette.bg:Lerp(Color3.new(1, 1, 1), 0.10), border = palette.bg:Lerp(Color3.new(1, 1, 1), 0.14),
        text = Color3.fromRGB(237, 240, 249), muted = Color3.fromRGB(155, 163, 185),
        danger = Color3.fromRGB(251, 112, 131), ink = Color3.fromRGB(17, 20, 30)}
end
function App:node(class, parent, props)
    local obj = Instance.new(class)
    for property, value in pairs(props or {}) do obj[property] = value end
    obj.Parent = parent
    return obj
end
function App:paint(obj, property, role)
    obj:SetAttribute("Color_" .. property, role)
    obj[property] = self:colors()[role]
end
function App:round(obj, radius)
    self:node("UICorner", obj, {CornerRadius = UDim.new(0, radius or 10)})
end
function App:label(parent, value, size, position, fontSize, role)
    local label = self:node("TextLabel", parent, {BackgroundTransparency = 1, Text = value,
        Size = size, Position = position or UDim2.new(), TextSize = fontSize or 13,
        Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd})
    self:paint(label, "TextColor3", role or "text")
    return label
end
function App:keyText(obj, key, property)
    property = property or "Text"
    obj:SetAttribute("Key_" .. property, key)
    obj[property] = self:tr(key)
end
function App:button(parent, title, size, position, callback, primary)
    local button = self:node("TextButton", parent, {Size = size, Position = position or UDim2.new(),
        Text = title, Font = Enum.Font.GothamMedium, TextSize = 13,
        BorderSizePixel = 0, AutoButtonColor = true, TextTruncate = Enum.TextTruncate.AtEnd})
    self:paint(button, "BackgroundColor3", primary and "accent" or "button")
    self:paint(button, "TextColor3", primary and "ink" or "text")
    self:round(button, 9)
    if callback then
        button.Activated:Connect(function()
            if not self.alive then return end
            local ok, err = pcall(callback)
            if not ok then self:log("Control error: " .. tostring(err)) end
            self.dirty = true
        end)
    end
    return button
end
function App:textBox(parent, placeholder, size, position)
    local box = self:node("TextBox", parent, {Size = size, Position = position, Text = "", ClearTextOnFocus = false,
        BorderSizePixel = 0, Font = Enum.Font.Gotham, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left})
    self:paint(box, "BackgroundColor3", "card")
    self:paint(box, "TextColor3", "text")
    self:paint(box, "PlaceholderColor3", "muted")
    self:keyText(box, placeholder, "PlaceholderText")
    self:node("UIPadding", box, {PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 8)})
    self:round(box)
    return box
end
function App:scroll(parent, size, position)
    local scroll = self:node("ScrollingFrame", parent, {Size = size, Position = position or UDim2.new(),
        BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y})
    self:paint(scroll, "ScrollBarImageColor3", "accent")
    self:node("UIListLayout", scroll, {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder})
    self:node("UIPadding", scroll, {PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8)})
    return scroll
end
function App:refreshStyle()
    local colors = self:colors()
    for _, obj in ipairs(self.gui:GetDescendants()) do
        for name, value in pairs(obj:GetAttributes()) do
            if string.sub(name, 1, 6) == "Color_" then obj[string.sub(name, 7)] = colors[value]
            elseif string.sub(name, 1, 4) == "Key_" then obj[string.sub(name, 5)] = self:tr(value) end
        end
    end
    self.dirty = true
end
function App:fit()
    if not self.ui.screen then return end
    local size = self.ui.screen.AbsoluteSize
    if self.ui.welcomeScale then
        self.ui.welcomeScale.Scale = math.max(0.25, math.min(1, (size.X - 24) / 380, (size.Y - 24) / 280))
    end
    if self.ui.flightPadScale then
        self.ui.flightPadScale.Scale = math.max(0.25, math.min(1, (size.X - 24) / 244, (size.Y - 24) / 144))
    end
    local scale = math.max(0.25, math.min(self.uiScale, (size.X - 20) / 448, (size.Y - 20) / 650))
    self.ui.scale.Scale = scale
    local w, h = 448 * scale, (self.minimized and 72 or 650) * scale
    local position = self.ui.main.Position
    self.ui.main.Position = UDim2.fromOffset(
        math.clamp(position.X.Offset, 0, math.max(0, size.X - w)),
        math.clamp(position.Y.Offset, 0, math.max(0, size.Y - h)))
end
function App:showTab(tab)
    self.tab = tab
    for name, page in pairs(self.ui.pages) do page.Visible = name == tab end
    for name, button in pairs(self.ui.tabs) do
        self:paint(button, "BackgroundColor3", name == tab and "accent" or "button")
        self:paint(button, "TextColor3", name == tab and "ink" or "text")
    end
    self.dirty = true
end
function App:toggleVisible()
    if self.ui.welcome and self.ui.welcome.Visible then self:openHub(); return end
    self.ui.main.Visible = not self.ui.main.Visible
    self.ui.launcher.Visible = not self.ui.main.Visible
end
function App:openHub()
    if self.ui.welcome then self.ui.welcome.Visible = false end
    self.ui.main.Visible = true
    self.ui.launcher.Visible = false
    self.dirty = true
end
function App:toggleAuto()
    if self.auto then self:stop("Auto collection stopped")
    else
        self:disableFly()
        self.auto = true
        self:log(self.mode == "Selected" and "Auto started for selected types" or "Auto started for all eligible eggs")
    end
end

function App:buildCollect(page)
    self.ui.stats = {}
    for i, key in ipairs({"Available", "Confirmed", "Queue", "Session"}) do
        local card = self:node("Frame", page, {Size = UDim2.new(0.25, -6, 0, 62),
            Position = UDim2.new((i - 1) * 0.25, 0, 0, 0), BorderSizePixel = 0})
        self:paint(card, "BackgroundColor3", "card"); self:round(card)
        local value = self:label(card, "0", UDim2.new(1, -16, 0, 27), UDim2.fromOffset(10, 7), 20)
        value.Font = Enum.Font.GothamBold
        local caption = self:label(card, "", UDim2.new(1, -16, 0, 16), UDim2.fromOffset(10, 37), 10, "muted")
        self:keyText(caption, key)
        self.ui.stats[key] = value
    end
    self.ui.farm = self:button(page, "", UDim2.new(1, 0, 0, 42), UDim2.fromOffset(0, 74), function() self:toggleAuto() end, true)
    local actions = {
        {"Pick next", function()
            local list = self:listEggs()
            for _, entry in ipairs(list) do
                if not self.queued[entry.object] and not (self.active and self.active.egg == entry.object) then
                    self:queueJob({kind = "pickup", egg = entry.object}); return
                end
            end
            self:log("No available egg to queue")
        end},
        {"Go base", function() self:stop("Returning to assigned base"); self.baseProof = nil; self.baseLastTry = -math.huge; self:queueJob({kind = "home"}) end},
    }
    for i, info in ipairs(actions) do
        local button = self:button(page, "", UDim2.new(0.5, -5, 0, 36), UDim2.new((i - 1) / 2, 0, 0, 124), info[2])
        self:keyText(button, info[1])
    end
    self.ui.search = self:textBox(page, "Search eggs...", UDim2.new(0.65, -6, 0, 36), UDim2.fromOffset(0, 172))
    self.ui.sort = self:button(page, "", UDim2.new(0.35, 0, 0, 36), UDim2.new(0.65, 0, 0, 172), function()
        self.sort = self.sort == "Priority" and "Nearest" or "Priority"
    end)
    self:connect(self.ui.search:GetPropertyChangedSignal("Text"), function()
        self.search = string.lower(self.ui.search.Text); self.dirty = true
    end)
    self.ui.eggScroll = self:scroll(page, UDim2.new(1, 0, 1, -244), UDim2.fromOffset(0, 220))
    self.ui.empty = self:label(self.ui.eggScroll, "", UDim2.new(1, 0, 0, 80), nil, 13, "muted")
    self.ui.empty.TextWrapped = true; self.ui.empty.TextTruncate = Enum.TextTruncate.None
    self.ui.rows = {}
    self.ui.listNote = self:label(page, "", UDim2.new(1, 0, 0, 18), UDim2.new(0, 0, 1, -18), 10, "muted")
end

function App:clearESP()
    for _, row in pairs(self.espRows) do
        row.board:Destroy()
        if row.highlight then row.highlight:Destroy() end
    end
    self.espRows = {}
    self.espCount = 0
end
function App:updateESP()
    if not self.espEnabled then
        if next(self.espRows) then self:clearESP() end
        return
    end
    if not self.espGuiFolder or not self.espGuiFolder.Parent then
        self.espGuiFolder = self:node("Folder", PlayerGui, {Name = "KAIZE_HUB_ESP_Labels"})
    end
    if not self.espWorldFolder or not self.espWorldFolder.Parent then
        self.espWorldFolder = self:node("Folder", Workspace, {Name = "KAIZE_HUB_ESP_Highlights"})
    end
    local list = self:listEggs()
    table.sort(list, function(a, b) return Rules.less(a, b, "Nearest") end)
    local visible, count = {}, 0
    local colors = self:colors()
    for _, entry in ipairs(list) do
        if count >= Config.MaxESP then break end
        if not self.espSelectedOnly or self.selected[entry.name] then
            local egg = entry.object
            local part = egg:IsA("BasePart") and egg or (egg.PrimaryPart or egg:FindFirstChildWhichIsA("BasePart", true))
            if part then
                count = count + 1
                visible[egg] = true
                local row = self.espRows[egg]
                if not row then
                    local board = self:node("BillboardGui", self.espGuiFolder, {Name = "EggESP", Adornee = part,
                        Size = UDim2.fromOffset(170, 42), StudsOffsetWorldSpace = Vector3.new(0, 4, 0),
                        AlwaysOnTop = true, LightInfluence = 0, MaxDistance = 100000, ResetOnSpawn = false})
                    local label = self:label(board, "", UDim2.fromScale(1, 1), nil, 12, "text")
                    label.TextXAlignment = Enum.TextXAlignment.Center
                    label.TextWrapped = true; label.TextTruncate = Enum.TextTruncate.None
                    label.TextStrokeTransparency = 0.25
                    label.TextStrokeColor3 = Color3.new(0, 0, 0)
                    row = {board = board, label = label}
                    self.espRows[egg] = row
                end
                row.board.Adornee = part
                local distance = entry.distance == math.huge and "--" or tostring(math.floor(entry.distance))
                row.label.Text = entry.name .. "\n" .. distance .. " studs"
                row.label.TextColor3 = self.selected[entry.name] and colors.accent or colors.text
                if count <= Config.MaxHighlights then
                    if not row.highlight then
                        row.highlight = self:node("Highlight", self.espWorldFolder, {Name = "EggOutline", Adornee = egg,
                            DepthMode = Enum.HighlightDepthMode.AlwaysOnTop, FillTransparency = 0.8, OutlineTransparency = 0})
                    end
                    row.highlight.FillColor = colors.accent; row.highlight.OutlineColor = colors.accent
                elseif row.highlight then row.highlight:Destroy(); row.highlight = nil end
            end
        end
    end
    for egg, row in pairs(self.espRows) do
        if not visible[egg] then
            row.board:Destroy()
            if row.highlight then row.highlight:Destroy() end
            self.espRows[egg] = nil
        end
    end
    self.espCount = count
end
function App:buildWorld(page)
    local scroll = self:scroll(page, UDim2.fromScale(1, 1))
    local function button(key, order, callback, primary)
        local obj = self:button(scroll, "", UDim2.new(1, 0, 0, 42), nil, callback, primary)
        obj.LayoutOrder = order
        self:keyText(obj, key)
        return obj
    end
    self.ui.espToggle = button("Egg ESP", 1, function()
        self.espEnabled = not self.espEnabled
        self:updateESP()
        self:log(self.espEnabled and "Egg ESP enabled" or "Egg ESP disabled")
    end, true)
    self.ui.espSelected = button("ESP selected types only", 2, function()
        self.espSelectedOnly = not self.espSelectedOnly; self:updateESP()
    end)
    self.ui.espInfo = self:label(scroll, "", UDim2.new(1, 0, 0, 48), nil, 12, "muted")
    self.ui.espInfo.LayoutOrder = 3; self.ui.espInfo.TextWrapped = true
    self.ui.espInfo.TextTruncate = Enum.TextTruncate.None
    self:buildMovementControls(scroll)
end
function App:renderWorld()
    self.ui.espToggle.Text = self:tr("Egg ESP") .. "  :  " .. self:tr(self.espEnabled and "ON" or "OFF")
    self.ui.espSelected.Text = self:tr("ESP selected types only") .. "  :  " .. self:tr(self.espSelectedOnly and "ON" or "OFF")
    self.ui.espInfo.Text = string.format("ESP labels: %d / %d max. Nearest %d get outlines. Loaded map eggs only.", self.espCount, Config.MaxESP, Config.MaxHighlights)
    self:renderMovementControls()
end

function App:buildMovementControls(scroll)
    self.ui.flyToggle = self:button(scroll, "Fly", UDim2.new(1, 0, 0, 42), nil, function()
        if self.flyEnabled then self:disableFly(); self:log("Fly OFF") else self:enableFly() end
    end, true)
    self.ui.flyToggle.LayoutOrder = 4
    local speedRow = self:node("Frame", scroll, {Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, LayoutOrder = 5})
    self.ui.flyMinus = self:button(speedRow, "-50", UDim2.fromOffset(48, 40), nil, function() self:setFlySpeed(self.flySpeed - 50) end)
    self.ui.flySpeedBox = self:textBox(speedRow, "50 - 5000", UDim2.new(1, -186, 0, 40), UDim2.fromOffset(56, 0))
    self.ui.flySpeedBox.Text = tostring(self.flySpeed)
    self.ui.flyPlus = self:button(speedRow, "+50", UDim2.fromOffset(48, 40), UDim2.new(1, -122, 0, 0), function() self:setFlySpeed(self.flySpeed + 50) end)
    self.ui.flyApply = self:button(speedRow, "Apply", UDim2.fromOffset(66, 40), UDim2.new(1, -66, 0, 0), function() self:setFlySpeed(self.ui.flySpeedBox.Text) end)
    self:connect(self.ui.flySpeedBox.FocusLost, function() self:setFlySpeed(self.ui.flySpeedBox.Text) end)
    local presets = self:node("Frame", scroll, {Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, LayoutOrder = 6})
    for i, speed in ipairs({50, 250, 1000, 5000}) do
        self:button(presets, tostring(speed), UDim2.new(0.25, -5, 0, 32), UDim2.new((i - 1) / 4, 0, 0, 0), function() self:setFlySpeed(speed) end)
    end
    self.ui.noclipToggle = self:button(scroll, "No Clip", UDim2.new(1, 0, 0, 42), nil, function()
        local wasEnabled = self.noclipEnabled
        self:setNoclip(not wasEnabled)
        if wasEnabled then self:log("No Clip OFF; collision restored") end
    end)
    self.ui.noclipToggle.LayoutOrder = 7
    self.ui.flyInfo = self:label(scroll, "", UDim2.new(1, 0, 0, 36), nil, 12, "muted")
    self.ui.flyInfo.LayoutOrder = 8; self.ui.flyInfo.TextWrapped = true
    self.ui.flyInfo.TextTruncate = Enum.TextTruncate.None
    local hint = self:label(scroll,
        "Fly: W A S D + camera. Space/E = up; Q/LeftCtrl = down. Touch buttons appear while flying.\nFly stops farming. Starting collection turns Fly off. F6/STOP turns off Fly and No Clip.",
        UDim2.new(1, 0, 0, 90), nil, 11, "muted")
    hint.LayoutOrder = 9; hint.TextWrapped = true; hint.TextTruncate = Enum.TextTruncate.None
end
function App:renderMovementControls()
    self.ui.flyToggle.Text = self:tr("Fly") .. "  :  " .. self:tr(self.flyEnabled and "ON" or "OFF")
    self.ui.noclipToggle.Text = self:tr("No Clip") .. "  :  " .. self:tr(self.noclipEnabled and "ON" or "OFF")
    self.ui.flyInfo.Text = "Fly speed: " .. self.flySpeed .. " studs/s  |  Range: 50 - 5000"
    if self.ui.flightInfo then self.ui.flightInfo.Text = "FLY  /  " .. self.flySpeed .. " studs/s" end
end
function App:buildFlightPad()
    local pad = self:node("Frame", self.ui.screen, {Name = "FlightControls", Size = UDim2.fromOffset(244, 144),
        Position = UDim2.new(1, -14, 1, -14), AnchorPoint = Vector2.new(1, 1), BorderSizePixel = 0, Visible = false})
    self.ui.flightPad = pad
    self:paint(pad, "BackgroundColor3", "bg"); self:round(pad, 12)
    self.ui.flightPadScale = self:node("UIScale", pad, {Scale = 1})
    self.ui.flightInfo = self:label(pad, "FLY", UDim2.new(1, -16, 0, 20), UDim2.fromOffset(8, 4), 11, "accent")
    self.ui.flyPadOff = self:button(pad, "OFF", UDim2.fromOffset(50, 44), UDim2.fromOffset(8, 30), function()
        self:disableFly(); self:log("Fly OFF")
    end)
    self.ui.flightButtons = {}
    for _, info in ipairs({{"forward", "W", 66, 30}, {"up", "UP", 182, 30},
        {"left", "A", 8, 82}, {"back", "S", 66, 82}, {"right", "D", 124, 82}, {"down", "DOWN", 182, 82}}) do
        local action = info[1]
        local button = self:button(pad, info[2], UDim2.fromOffset(50, 44), UDim2.fromOffset(info[3], info[4]), nil)
        button.TextSize = 11
        self.ui.flightButtons[action] = button
        self:connect(button.InputBegan, function(input)
            if self.flyEnabled and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1) then
                self.flightTouches[input] = action
            end
        end)
        self:connect(button.InputEnded, function(input) self.flightTouches[input] = nil end)
    end
end
function App:buildWelcome()
    local welcome = self:node("Frame", self.ui.screen, {Name = "Welcome", Size = UDim2.fromOffset(380, 280),
        Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0})
    self.ui.welcome = welcome
    self:paint(welcome, "BackgroundColor3", "bg"); self:round(welcome, 18)
    local border = self:node("UIStroke", welcome, {Thickness = 1})
    self:paint(border, "Color", "accent")
    self.ui.welcomeScale = self:node("UIScale", welcome, {Scale = 1})
    local store = self:label(welcome, "KAIZE STORE", UDim2.new(1, -32, 0, 20), UDim2.fromOffset(16, 22), 12, "accent")
    store.TextXAlignment = Enum.TextXAlignment.Center
    local title = self:label(welcome, "KAIZE HUB", UDim2.new(1, -32, 0, 40), UDim2.fromOffset(16, 51), 29)
    title.Font = Enum.Font.GothamBold; title.TextXAlignment = Enum.TextXAlignment.Center
    local greeting = self:label(welcome, "Welcome to my script — Kaize Store", UDim2.new(1, -48, 0, 50), UDim2.fromOffset(24, 99), 14, "muted")
    greeting.TextXAlignment = Enum.TextXAlignment.Center
    greeting.TextWrapped = true; greeting.TextTruncate = Enum.TextTruncate.None
    self.ui.welcomeGreeting = greeting
    self.ui.openHub = self:button(welcome, "OPEN KAIZE HUB", UDim2.new(1, -40, 0, 46), UDim2.fromOffset(20, 165), function() self:openHub() end, true)
    self.ui.closeWelcome = self:button(welcome, "Close script", UDim2.new(1, -40, 0, 32), UDim2.fromOffset(20, 224), function() self:unload() end)
    self.ui.main.Visible = false
    self.ui.launcher.Visible = false
end

function App:buildSettings(page)
    local scroll = self:scroll(page, UDim2.fromScale(1, 1))
    self.ui.settingButtons = {}
    local order = 0
    local function setting(title, callback, value)
        order = order + 1
        local button = self:button(scroll, title, UDim2.new(1, 0, 0, 42), nil, callback)
        button.LayoutOrder = order
        table.insert(self.ui.settingButtons, {button = button, title = title, value = value})
    end
    local function cycle(field, values)
        local index = table.find(values, self[field]) or 1
        self[field] = values[index % #values + 1]
    end
    setting("Auto types", function() cycle("mode", {"All", "Selected"}) end, function() return self:tr(self.mode) end)
    setting("Speed", function() cycle("speed", {"Balanced", "Fast", "Reliable"}) end, function() return self.speed end)
    for _, entry in ipairs({{"Return to base after pickup", "autoReturn"}, {"Stow egg tools at home", "stowEggTools"}, {"Anti-AFK", "antiAFK"}}) do
        local title, field = entry[1], entry[2]
        setting(title, function() self[field] = not self[field] end, function() return self:tr(self[field] and "ON" or "OFF") end)
    end
    setting("Auto leave for owner/admin", function()
        self.autoLeave = not self.autoLeave
        if self.autoLeave then for _, player in ipairs(Players:GetPlayers()) do self:checkAdmin(player) end end
    end, function() return self:tr(self.autoLeave and "ON" or "OFF") end)
    setting("Theme", function()
        cycle("theme", {"Galaxy", "Ocean", "Emerald", "Nebula", "Crimson", "Purple"}); self:refreshStyle()
    end, function() return self.theme end)
    setting("Language", function()
        self.language = self.language == "en" and "km" or "en"; self:refreshStyle()
    end, function() return self.language == "en" and "English" or "ខ្មែរ" end)
    setting("UI scale", function() cycle("uiScale", {0.8, 1, 1.15, 1.3}); self:fit() end, function() return tostring(self.uiScale) .. "x (auto-fit)" end)
    setting("Refresh map", function() self:scan(); self:log("Map index refreshed") end)
    setting("Clear retry cooldowns", function() self.cooldown = setmetatable({}, {__mode = "k"}); self:log("Retry cooldowns cleared") end)
    setting("Clear selected types", function() self.selected = {}; self:log("Selected types cleared") end)
    setting("Reset session stats", function() self.picked = 0; self.unverified = 0; self.failures = 0; self.started = os.clock() end)
    setting("Unload KAIZE HUB", function() self:unload() end)
    local note = self:label(scroll, "RightControl: show/hide  |  F6: stop\nSEL marks egg types for Selected mode.\nFast uses an optional prompt helper; Reliable uses the normal prompt hold. Settings last for this session.",
        UDim2.new(1, 0, 0, 90), nil, 11, "muted")
    note.LayoutOrder = order + 1; note.TextWrapped = true; note.TextTruncate = Enum.TextTruncate.None
end

function App:buildUI()
    self.gui = self:node("ScreenGui", PlayerGui, {Name = "KAIZE_HUB_V3", ResetOnSpawn = false,
        IgnoreGuiInset = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 50})
    local shutdown = self:node("BindableFunction", self.gui, {Name = "Shutdown"})
    shutdown.OnInvoke = function() self:unload() end
    self.ui.screen = self:node("Frame", self.gui, {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1})
    self.ui.main = self:node("Frame", self.ui.screen, {Name = "Window", Size = UDim2.fromOffset(448, 650),
        Position = UDim2.fromOffset(24, 24), BorderSizePixel = 0, ClipsDescendants = true})
    self:paint(self.ui.main, "BackgroundColor3", "bg"); self:round(self.ui.main, 16)
    local stroke = self:node("UIStroke", self.ui.main, {Thickness = 1})
    self:paint(stroke, "Color", "border")
    self.ui.scale = self:node("UIScale", self.ui.main, {Scale = 1})
    local header = self:node("Frame", self.ui.main, {Size = UDim2.new(1, 0, 0, 72), BackgroundTransparency = 1, Active = true})
    self:label(header, "KAIZE HUB", UDim2.fromOffset(196, 26), UDim2.fromOffset(18, 12), 22).Font = Enum.Font.GothamBold
    self:label(header, "KAIZE STORE  /  RIDE A PET  /  3.1", UDim2.fromOffset(200, 16), UDim2.fromOffset(19, 40), 10, "muted")
    local stop = self:button(header, "STOP", UDim2.fromOffset(54, 32), UDim2.new(1, -140, 0, 18), function() self:stop("Emergency stop") end)
    self:paint(stop, "TextColor3", "danger")
    self.ui.minimize = self:button(header, "-", UDim2.fromOffset(30, 32), UDim2.new(1, -78, 0, 18), function()
        self.minimized = not self.minimized
        self.ui.content.Visible = not self.minimized
        self.ui.main.Size = UDim2.fromOffset(448, self.minimized and 72 or 650)
        self.ui.minimize.Text = self.minimized and "+" or "-"
        self:fit()
    end)
    self:button(header, "X", UDim2.fromOffset(30, 32), UDim2.new(1, -40, 0, 18), function() self:unload() end)
    self.ui.launcher = self:button(self.ui.screen, "KAIZE", UDim2.fromOffset(76, 44), UDim2.new(0, 12, 0.5, -22), function() self:toggleVisible() end, true)
    self.ui.launcher.Visible = true
    self.ui.content = self:node("Frame", self.ui.main, {Size = UDim2.new(1, 0, 1, -72), Position = UDim2.fromOffset(0, 72), BackgroundTransparency = 1})
    self.ui.tabs, self.ui.pages = {}, {}
    for i, name in ipairs({"Collect", "World", "Settings", "Activity"}) do
        local button = self:button(self.ui.content, "", UDim2.new(0.25, -13, 0, 34), UDim2.new((i - 1) * 0.25, 14, 0, 4), function() self:showTab(name) end)
        self:keyText(button, name); self.ui.tabs[name] = button
        self.ui.pages[name] = self:node("Frame", self.ui.content, {Size = UDim2.new(1, -32, 1, -104), Position = UDim2.fromOffset(16, 52),
            BackgroundTransparency = 1, Visible = name == self.tab})
    end
    self:buildCollect(self.ui.pages.Collect)
    self:buildWorld(self.ui.pages.World)
    self:buildSettings(self.ui.pages.Settings)
    local activity = self.ui.pages.Activity
    self.ui.diagnostics = self:label(activity, "", UDim2.new(1, 0, 0, 76), nil, 11, "muted")
    self.ui.diagnostics.TextWrapped = true; self.ui.diagnostics.TextTruncate = Enum.TextTruncate.None
    local clear = self:button(activity, "", UDim2.new(1, 0, 0, 34), UDim2.fromOffset(0, 84), function() self.logs = {} end)
    self:keyText(clear, "Clear activity")
    local logScroll = self:scroll(activity, UDim2.new(1, 0, 1, -130), UDim2.fromOffset(0, 130))
    self.ui.logText = self:label(logScroll, "", UDim2.new(1, -4, 0, 0), nil, 12, "muted")
    self.ui.logText.AutomaticSize = Enum.AutomaticSize.Y
    self.ui.logText.TextWrapped = true; self.ui.logText.TextTruncate = Enum.TextTruncate.None
    self.ui.logText.TextYAlignment = Enum.TextYAlignment.Top
    self.ui.status = self:label(self.ui.content, "Ready", UDim2.new(1, -32, 0, 35), UDim2.new(0, 16, 1, -43), 11, "muted")
    self.ui.status.TextWrapped = true; self.ui.status.TextTruncate = Enum.TextTruncate.None
    self:connect(self.ui.screen:GetPropertyChangedSignal("AbsoluteSize"), function() self:fit() end)
    self:connect(self.gui.Destroying, function() self:unload() end)
    local drag
    self:connect(header.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            drag = {input = input, start = input.Position, position = self.ui.main.Position}
        end
    end)
    self:connect(UserInputService.InputChanged, function(input)
        if not drag then return end
        local mouse = drag.input.UserInputType == Enum.UserInputType.MouseButton1
        if (mouse and input.UserInputType == Enum.UserInputType.MouseMovement) or input == drag.input then
            local delta = input.Position - drag.start
            self.ui.main.Position = UDim2.fromOffset(drag.position.X.Offset + delta.X, drag.position.Y.Offset + delta.Y)
            self:fit()
        end
    end)
    self:connect(UserInputService.InputEnded, function(input)
        if drag and input == drag.input then drag = nil end
        self.flightKeys[input.KeyCode] = nil
        self.flightTouches[input] = nil
    end)
    self:connect(UserInputService.WindowFocusReleased, function()
        drag = nil; self.windowFocused = false; self:clearFlightInput()
    end)
    self:connect(UserInputService.WindowFocused, function() self.windowFocused = true end)
    self:connect(UserInputService.InputBegan, function(input, processed)
        if processed or UserInputService:GetFocusedTextBox() then return end
        if input.KeyCode == Enum.KeyCode.RightControl then self:toggleVisible()
        elseif input.KeyCode == Enum.KeyCode.F6 then self:stop("Emergency stop") end
        if self.flyEnabled and FlyKeyActions[input.KeyCode] then self.flightKeys[input.KeyCode] = FlyKeyActions[input.KeyCode] end
    end)
    self:buildFlightPad()
    self:buildWelcome()
    self:showTab(self.tab)
    self:fit()
end

function App:renderEggs(list)
    local shown, visible = 0, {}
    for _, entry in ipairs(list) do
        if string.find(string.lower(entry.name), self.search, 1, true) and shown < Config.MaxRows then
            shown = shown + 1
            local egg = entry.object
            visible[egg] = true
            local row = self.ui.rows[egg]
            if not row then
                local frame = self:node("Frame", self.ui.eggScroll, {Size = UDim2.new(1, 0, 0, 66), BorderSizePixel = 0})
                self:paint(frame, "BackgroundColor3", "card"); self:round(frame)
                row = {frame = frame}
                row.rank = self:label(frame, "", UDim2.fromOffset(32, 40), UDim2.fromOffset(10, 12), 13, "accent")
                row.name = self:label(frame, "", UDim2.new(1, -169, 0, 24), UDim2.fromOffset(45, 9), 13)
                row.info = self:label(frame, "", UDim2.new(1, -169, 0, 19), UDim2.fromOffset(45, 35), 10, "muted")
                row.pick = self:button(frame, "", UDim2.fromOffset(56, 36), UDim2.new(1, -114, 0, 15), function()
                    self:queueJob({kind = "pickup", egg = egg})
                end)
                row.select = self:button(frame, "SEL", UDim2.fromOffset(44, 36), UDim2.new(1, -50, 0, 15), function()
                    self.selected[egg.Name] = not self.selected[egg.Name]
                end)
                row.select.TextSize = 10
                self.ui.rows[egg] = row
            end
            row.frame.LayoutOrder = shown
            row.rank.Text = tostring(shown)
            row.name.Text = entry.name
            local retry = self.cooldown[egg]
            local state = self.active and self.active.egg == egg and "BUSY" or self.queued[egg] and "QUEUED" or "READY"
            if state == "READY" and retry and retry.at > os.clock() then state = "RETRY " .. math.ceil(retry.at - os.clock()) .. "s" end
            local distance = entry.distance == math.huge and "--" or tostring(math.floor(entry.distance))
            row.info.Text = distance .. " studs  /  " .. state
            row.pick.Text = self:tr("PICK")
            self:paint(row.select, "BackgroundColor3", self.selected[entry.name] and "accent" or "button")
            self:paint(row.select, "TextColor3", self.selected[entry.name] and "ink" or "muted")
        end
    end
    for egg, row in pairs(self.ui.rows) do
        if not visible[egg] then row.frame:Destroy(); self.ui.rows[egg] = nil end
    end
    self.ui.empty.Visible = shown == 0
    self.ui.empty.Text = self:tr(self.search == "" and "No eligible eggs in the loaded map" or "No eggs match your search")
    local selected = 0
    for _, value in pairs(self.selected) do if value then selected = selected + 1 end end
    self.ui.listNote.Text = string.format("Showing %d / %d  |  Selected types: %d  |  Auto: %s", shown, #list, selected, self.mode)
end
function App:render()
    if not self.alive then return end
    self.ui.status.Text = self.status
    if not self.ui.main.Visible or self.minimized then return end
    self.ui.farm.Text = self:tr(self.auto and "STOP AUTO" or "START AUTO")
    self:paint(self.ui.farm, "BackgroundColor3", self.auto and "danger" or "accent")
    self.ui.sort.Text = self:tr(self.sort)
    if self.tab == "Collect" then
        local list = self:listEggs()
        self.ui.stats.Available.Text = tostring(#list)
        self.ui.stats.Confirmed.Text = tostring(self.picked)
        self.ui.stats.Queue.Text = tostring(#self.queue + (self.active and 1 or 0))
        local elapsed = math.floor(os.clock() - self.started)
        self.ui.stats.Session.Text = string.format("%02d:%02d", math.floor(elapsed / 60), elapsed % 60)
        self:renderEggs(list)
    elseif self.tab == "World" then self:renderWorld()
    elseif self.tab == "Settings" then
        for _, entry in ipairs(self.ui.settingButtons) do
            entry.button.Text = self:tr(entry.title) .. (entry.value and ("  :  " .. entry.value()) or "")
        end
    elseif self.tab == "Activity" then
        self.ui.diagnostics.Text = string.format("Prompt helper: %s  |  Scan: %ds\nUnverified: %d  |  Failed jobs: %d\n%s",
            Compat.firePrompt and "available" or "normal hold only", Config.ScanInterval, self.unverified, self.failures, self.baseStatus)
        self.ui.logText.Text = table.concat(self.logs, "\n\n")
    end
end

function App:checkAdmin(player)
    if not self.autoLeave or player == LocalPlayer then return end
    task.spawn(function()
        local admin = table.find(Config.ExtraAdminUserIds, player.UserId) ~= nil
            or (game.CreatorType == Enum.CreatorType.User and game.CreatorId == player.UserId)
        if not admin and game.CreatorType == Enum.CreatorType.Group then
            local ok, rank = pcall(function() return player:GetRankInGroupAsync(game.CreatorId) end)
            admin = ok and rank >= Config.AdminMinGroupRank
        end
        if self.alive and self.autoLeave and admin and player.Parent == Players then
            self:stop("Auto leave: @" .. player.Name)
            LocalPlayer:Kick("KAIZE HUB: owner/admin detected (@" .. player.Name .. ")")
        end
    end)
end

App:buildUI()
App:connect(Workspace.DescendantAdded, function(obj) App:track(obj) end)
App:connect(PlayerGui.DescendantAdded, function(obj)
    if obj:IsA("TextLabel") and not obj:IsDescendantOf(App.gui) then App.baseLabels[obj] = true end
end)
App:connect(Workspace.DescendantRemoving, function(obj)
    if App.candidates[obj] then
        -- Defer: Roblox fires DescendantRemoving before Parent changes.
        task.defer(function()
            if App.alive and not obj:IsDescendantOf(Workspace) then App.candidates[obj] = nil; App.dirty = true end
        end)
    end
end)
App:connect(LocalPlayer.CharacterAdded, function()
    App:disableFly(); App:setNoclip(false)
    App:cancel("Respawn detected; waiting for your character")
    App.baseProof = nil; App.baseLastTry = -math.huge
end)
App:connect(LocalPlayer.CharacterRemoving, function()
    App:disableFly(); App:setNoclip(false)
    App:cancel("Character removed; actions cancelled")
end)
App:connect(RunService.PreSimulation, function()
    if not App.flyEnabled and not App.noclipEnabled then return end
    local ok, err = pcall(function() App:updateMovement() end)
    if not ok then
        App:disableFly(); App:setNoclip(false)
        App:log("Movement stopped: " .. tostring(err))
    end
end)
App:connect(Players.PlayerAdded, function(player) App.dirty = true; App:checkAdmin(player) end)
App:connect(Players.PlayerRemoving, function(player)
    App.dirty = true
end)
App:connect(LocalPlayer.Idled, function()
    if not App.antiAFK then return end
    local ok = pcall(function()
        assert(Compat.virtualUser, "VirtualUser unavailable")
        Compat.virtualUser:CaptureController()
        Compat.virtualUser:ClickButton2(Vector2.zero)
    end)
    if not ok then App.antiAFK = false; App:log("Anti-AFK is unavailable in this client") end
end)
App:scan()
App:log("Ready. Returns use your assigned base only; no positions are saved.")
App:render()

-- One movement worker owns pickup and return actions. Manual flight stops farming before taking control.
task.spawn(function()
    while App.alive do
        local ok, err = pcall(function()
            local char, root, humanoid = App:character()
            if root then
                if root.Anchored or humanoid.Sit then
                    if App.auto or #App.queue > 0 then App.status = "Paused: stand up and wait until your character can move" end
                else
                    local job = App:nextJob()
                    if job then App:runJob(job) end
                end
            elseif App.auto then App.status = "Waiting for character" end
        end)
        if not ok and App.alive then App:releaseInput(); App.active = nil; App:stop("Worker stopped: " .. tostring(err)) end
        task.wait(Config.Tick)
    end
end)

-- Bounded UI work: at most 5 updates/sec; whole-map recovery only every 15 sec.
task.spawn(function()
    local lastScan, lastRender, lastESP = os.clock(), 0, 0
    while App.alive do
        local now = os.clock()
        local ok, err = pcall(function()
            if now - lastScan >= Config.ScanInterval then App:scan(); lastScan = now end
            if App.dirty or now - lastRender >= 0.5 then
                App.dirty = false; lastRender = now; App:render()
            end
        end)
        if not ok and App.alive then
            warn("KAIZE HUB UI: " .. tostring(err))
            App:unload() -- do not keep a hidden collection worker running after UI failure
        end
        if App.alive and now - lastESP >= 0.5 then
            lastESP = now
            local espOK, espError = pcall(function() App:updateESP() end)
            if not espOK then
                App.espEnabled = false
                App:clearESP()
                App:log("ESP disabled after error: " .. tostring(espError))
            end
        end
        task.wait(0.2)
    end
end)
