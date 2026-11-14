-- ewanko aimbot v16 — players, NPCs, mobs and bots share one target list,
-- knock/down check, role detection (murderer / sheriff) and dropped-gun ESP,
-- camera write at RenderPriority.Last, per-frame mouse fallback, streamer mode
-- Luau / executor context. One file, no external UI library.

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local Workspace        = game:GetService("Workspace")
local TweenService     = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
if not localPlayer then
    repeat task.wait(0.1) until Players.LocalPlayer
    localPlayer = Players.LocalPlayer
end

local VERSION = "v16"

-- per-instance liveness: a second execution must not kill the first one's loops
local alive = true

local hasMouseMove = type(mousemoverel) == "function"

local CONFIG = {
    -- aim
    AimEnabled        = false,      -- safe boot: nothing runs until you arm it
    AimMode           = "Hold",     -- Hold | Toggle
    KeyName           = "Q",        -- keyboard name or MouseButton1/2/3
    FOV               = 140,
    Smoothness        = 45,         -- 0 = instant snap, 100 = very floaty
    Curve             = "Human",    -- Linear | Ease | Human
    RampIn            = 0.14,       -- seconds to reach full aim speed
    MaxTurnSpeed      = 900,        -- degrees per second ceiling
    Deadzone          = 0.6,        -- degrees; no micro-correction inside
    Humanize          = 0.35,       -- 0..1 wobble amount (Human curve only)
    MaxDistance       = 600,
    AimPart           = "Head",
    TeamCheck         = true,
    WallCheck         = true,
    Prediction        = 0,
    SelectInterval    = 0.03,

    -- targets
    KnockCheck        = true,       -- skip players/NPCs in a downed or ragdoll state
    NPCs              = true,       -- scan Workspace for non-player actors
    Mobs              = true,       -- also accept Humanoid-less models: mobs, bots, dummies
    NPCRate           = 0.4,        -- seconds between actor rescans
    NPCDepth          = 2,          -- how deep the Workspace walk goes

    -- aim method: mouse mode drives the game's own camera instead of writing CFrames
    AimMethod         = "Camera",   -- Auto | Camera | Mouse | Subject
    MouseGain         = 1.0,
    AutoFallback      = false,      -- off by default: input injection is the crash vector
    MouseRate         = 60,         -- mousemoverel calls per second (60 = every frame)
    MouseClamp        = 45,         -- max pixels moved per call

    -- stability
    RenderPriority    = 1999,       -- Enum.RenderPriority.Last: nothing writes the camera after this
    SafeMode          = true,       -- no humanize, no Drawing churn, throttled mouse
    PanicKey          = "End",      -- always unloads, works even if the UI is gone
    UIWatchdog        = false,      -- re-parent loop; off while bisecting, it masks the cause
    Telemetry         = true,       -- heartbeat print, last line before a crash is the culprit

    -- compatibility
    CollidableOnly    = true,       -- raycast ignores non-collidable decoration

    -- visuals
    FOVCircle         = false,
    CircleThickness   = 1,
    CircleColor       = { 255, 255, 255 },

    ESP               = false,
    ESPTeamCheck      = true,
    ESPKnockCheck     = false,      -- false = knocked bodies stay on screen
    ESPMaxDistance    = 500,
    ESPBoxes          = true,
    ESPNames          = true,
    ESPColor          = { 255, 77, 141 },
    ESPColorNPC       = { 255, 190, 60 },

    -- roles (MM2 and other role games)
    RoleCheck         = true,       -- read murderer / sheriff from tools and attributes
    RoleRate          = 0.5,        -- seconds between role rescans
    TargetRoles       = "All",      -- All | Murderer | Sheriff | Innocent
    ESPShowRoles      = true,       -- [M] / [S] prefix in the ESP name
    ESPColorMurderer  = { 255, 45, 45 },
    ESPColorSheriff   = { 80, 160, 255 },

    -- dropped items
    GunESP            = true,       -- ESP the sheriff's gun once it is on the floor
    GunRate           = 0.3,        -- seconds between dropped-gun rescans
    ESPColorGun       = { 255, 230, 60 },

    -- menu
    MenuKeyName       = "RightShift",

    -- streamer mode: one press kills every visual this script draws
    StealthKey        = "F2",
    AutoHideOnBlur    = true,       -- hide the moment the window loses focus
    StealthOnStart    = false,      -- boot hidden, reveal with StealthKey
}

local DEFAULTS = {}
for key, value in pairs(CONFIG) do
    if type(value) == "table" then
        local copy = {}
        for index, inner in ipairs(value) do copy[index] = inner end
        DEFAULTS[key] = copy
    else
        DEFAULTS[key] = value
    end
end

local state = {
    aiming       = false,
    aimStarted   = 0,
    target       = nil,
    awaitingBind = nil,
    bindArmed    = false,
    nextScan     = 0,
    errorCount   = 0,
    lastError    = "",
    savedCamera  = nil,
    savedSubject = nil,
    subjectSaved = false,
    lastWrite    = nil,
    writeKept    = false,
    esp          = {},
    refreshers   = {},
    dragging     = false,
    dragStart    = nil,
    dragOrigin   = nil,
    mouseMode    = false,
    prevAngle    = nil,
    stuckFrames  = 0,
    mouseAccum   = 0,
    npcCache     = {},
    npcNext      = 0,
    gunCache     = {},
    gunNext      = 0,
    gunESP       = {},
    uiClosed     = false,
    uiRebuilds   = 0,
    stealth      = false,
    statusLabel  = nil,
    lastDt       = 1 / 60,
    stage        = "boot",
    debug        = { candidates = 0, blocked = 0, knocked = 0, npcs = 0, mobs = 0,
                     murderer = 0, sheriff = 0, guns = 0, found = false },
    debugLabels  = {},
    lastDebug    = 0,
}

local MOUSE_BINDS = {
    MouseButton1 = true,
    MouseButton2 = true,
    MouseButton3 = true,
}

local function rgb(triple)
    return Color3.fromRGB(triple[1], triple[2], triple[3])
end

-- NaN or infinity in a CFrame is a hard client crash, not a Luau error.
local function isFinite(value)
    return value == value and value ~= math.huge and value ~= -math.huge
end

local function isFiniteVector(vector)
    return isFinite(vector.X) and isFinite(vector.Y) and isFinite(vector.Z)
end

local function inputMatches(input, bindName)
    if MOUSE_BINDS[bindName] then
        return input.UserInputType == Enum.UserInputType[bindName]
    end
    return input.UserInputType == Enum.UserInputType.Keyboard
        and input.KeyCode == Enum.KeyCode[bindName]
end

local function bindFromInput(input)
    if input.UserInputType == Enum.UserInputType.Keyboard then
        return input.KeyCode.Name
    end
    if MOUSE_BINDS[input.UserInputType.Name] then
        return input.UserInputType.Name
    end
    return nil
end

-- ======================================================================
-- aim
-- ======================================================================

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local fovCircle

local function currentCamera()
    return Workspace.CurrentCamera
end

-- Claiming the camera is the whole trick: a game camera script stops driving a
-- Scriptable camera, so the write survives in a match with no input injection.
-- "Subject" mode is the other non-injection route: the game's own camera follows
-- CameraSubject, so handing it the enemy humanoid aims it for us.
local function claimCamera(camera, part)
    if state.savedCamera == nil then
        state.savedCamera = camera.CameraType
    end

    if CONFIG.AimMethod == "Subject" then
        local character = part and part.Parent
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            if not state.subjectSaved then
                state.subjectSaved = true
                state.savedSubject  = camera.CameraSubject
            end
            if camera.CameraSubject ~= humanoid then
                camera.CameraSubject = humanoid
            end
        end
        if camera.CameraType ~= Enum.CameraType.Custom then
            camera.CameraType = Enum.CameraType.Custom
        end
        return
    end

    if camera.CameraType ~= Enum.CameraType.Scriptable then
        camera.CameraType = Enum.CameraType.Scriptable
    end
end

local function releaseCamera()
    local camera = currentCamera()

    if state.subjectSaved then
        state.subjectSaved = false
        if camera then
            pcall(function() camera.CameraSubject = state.savedSubject end)
        end
        state.savedSubject = nil
    end

    if state.savedCamera == nil then return end
    if camera then
        pcall(function() camera.CameraType = state.savedCamera end)
    end
    state.savedCamera = nil
end

local function screenCentre(camera)
    local viewport = camera.ViewportSize
    return Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
end

-- Drawing objects are created on demand: creating them at load is one of the
-- things that kills a client before you ever press the aim key.
local function ensureCircle()
    if fovCircle or typeof(Drawing) ~= "table" then return fovCircle end

    local ok, circle = pcall(function()
        local c = Drawing.new("Circle")
        c.Filled       = false
        c.NumSides     = 64
        c.Visible      = false
        c.Transparency = 0.75
        c.Color        = rgb(CONFIG.CircleColor)
        c.Thickness    = CONFIG.CircleThickness
        return c
    end)

    if ok then fovCircle = circle end
    return fovCircle
end

local function aimPartFor(character)
    return character:FindFirstChild(CONFIG.AimPart)
        or character:FindFirstChild("Head")
        or character:FindFirstChild("HumanoidRootPart")
end

local function isEnemy(player)
    if player == localPlayer then return false end
    if not CONFIG.TeamCheck then return true end
    if player.Team == nil or localPlayer.Team == nil then return true end
    return player.Team ~= localPlayer.Team
end

-- ======================================================================
-- targets
-- ======================================================================

-- Names games give the downed state: an attribute on the character, or a
-- BoolValue child. Both are cheap to read, unlike a recursive name search.
local KNOCK_NAMES = {
    Knocked = true, Knock = true, Downed = true, Down = true,
    Ragdoll = true, IsRagdoll = true, Ragdolled = true,
    Incapacitated = true, KO = true, KOd = true, Stunned = true,
    Grabbed = true, DBNO = true, IsDead = true, Dead = true,
}

local knockCache   = {}
local knockPruneAt = 0

local function knockFlagsSet(character)
    for name in pairs(KNOCK_NAMES) do
        if character:GetAttribute(name) == true then return true end
    end

    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("BoolValue") and child.Value and KNOCK_NAMES[child.Name] then
            return true
        end
    end

    return false
end

-- Downed detection, cached for 150 ms: this runs from both the aim loop and the
-- ESP loop, and the attribute/child scan is the expensive half of it.
local function isKnocked(humanoid, character)
    local now    = os.clock()
    local cached = knockCache[character]
    if cached and now - cached.at < 0.15 then
        return cached.knocked
    end

    local knocked = false

    if humanoid.Health <= 0
        or humanoid.PlatformStand
        or humanoid.Sit then
        knocked = true
    else
        local ok, humanoidState = pcall(function() return humanoid:GetState() end)
        if ok and (humanoidState == Enum.HumanoidStateType.Dead
            or humanoidState == Enum.HumanoidStateType.Physics
            or humanoidState == Enum.HumanoidStateType.FallingDown
            or humanoidState == Enum.HumanoidStateType.Ragdoll) then
            knocked = true
        elseif knockFlagsSet(character) then
            knocked = true
        end
    end

    knockCache[character] = { at = now, knocked = knocked }

    if now >= knockPruneAt then
        knockPruneAt = now + 10
        local pruned = {}
        for key, entry in pairs(knockCache) do
            if key.Parent and now - entry.at < 5 then pruned[key] = entry end
        end
        knockCache = pruned
    end

    return knocked
end

-- ======================================================================
-- roles and dropped items
-- ======================================================================

-- MM2 hands the murderer a Knife and the sheriff a Gun as Tools in the Backpack,
-- moved into the character once equipped. Other role games publish the same
-- information as a player or character attribute, so both are read.
local MURDERER_TOOLS = {
    Knife = true, MurdererKnife = true, KnifeTool = true, Dagger = true,
}
local SHERIFF_TOOLS = {
    Gun = true, Revolver = true, Pistol = true, SheriffGun = true,
}
local GUN_NAMES = {
    Gun = true, Revolver = true, Pistol = true, DroppedGun = true,
}
local ROLE_ATTRIBUTES = { "Role", "role", "Team", "TeamName", "GameRole", "Assignment" }

local roleCache   = {}
local rolePruneAt = 0

local function roleFromText(text)
    if type(text) ~= "string" then return nil end
    local lower = text:lower()
    if lower:find("murder") then return "Murderer" end
    if lower:find("sheriff") or lower:find("sherrif") then return "Sheriff" end
    if lower:find("innocent") then return "Innocent" end
    return nil
end

local function roleFromContainer(container)
    if not container then return nil end

    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("Tool") then
            if MURDERER_TOOLS[child.Name] then return "Murderer" end
            if SHERIFF_TOOLS[child.Name] then return "Sheriff" end
        end
    end

    return nil
end

-- Returns "Murderer" | "Sheriff" | "Innocent", or nil when the game exposes
-- nothing: an unknown role must not be reported as innocent, or every player in
-- an unrelated game would wear the label.
local function detectRole(player)
    local character = player.Character

    for _, source in ipairs({ player, character }) do
        if source then
            for _, attribute in ipairs(ROLE_ATTRIBUTES) do
                local role = roleFromText(source:GetAttribute(attribute))
                if role then return role end
            end
        end
    end

    local role = roleFromContainer(character)
        or roleFromContainer(player:FindFirstChildOfClass("Backpack"))
    if role then return role end

    if character then
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            local fromName = roleFromText(humanoid.DisplayName)
            if fromName then return fromName end
        end
    end

    return nil
end

-- Cached per player: role detection walks the Backpack and reads attributes,
-- which is not a per-frame operation but is cheap at RoleRate.
local function roleOf(player)
    if not CONFIG.RoleCheck then return nil end

    local now    = os.clock()
    local cached = roleCache[player]
    if cached and now - cached.at < math.max(CONFIG.RoleRate, 0.1) then
        return cached.role
    end

    local role = detectRole(player)
    roleCache[player] = { at = now, role = role }

    if now >= rolePruneAt then
        rolePruneAt = now + 10
        for key, entry in pairs(roleCache) do
            if key.Parent == nil or now - entry.at > 5 then roleCache[key] = nil end
        end
    end

    return role
end

-- A gun inside a player's character is being carried; only the one on the floor
-- is worth an ESP box. Walking the ancestor chain catches the tool whether it is
-- parented to the character, to a folder, or to a wrapper model.
local function carriedByPlayer(inst)
    local parent = inst.Parent

    while parent and parent ~= Workspace do
        if parent:IsA("Model") and Players:GetPlayerFromCharacter(parent) then
            return true
        end
        parent = parent.Parent
    end

    return false
end

local function gunPosition(gun)
    if gun:IsA("Tool") then
        local handle = gun:FindFirstChild("Handle")
        return handle and handle.Position or nil
    end

    if gun:IsA("BasePart") then return gun.Position end

    if gun:IsA("Model") then
        if gun.PrimaryPart then return gun.PrimaryPart.Position end
        local ok, pivot = pcall(function() return gun:GetPivot().Position end)
        if ok then return pivot end
    end

    return nil
end

local function collectDroppedGuns()
    local found = {}

    local function walk(container, depth)
        if depth > CONFIG.NPCDepth + 1 then return end

        for _, child in ipairs(container:GetChildren()) do
            if (child:IsA("Tool") or child:IsA("Model") or child:IsA("BasePart"))
                and GUN_NAMES[child.Name] then
                if not carriedByPlayer(child) then
                    table.insert(found, child)
                end
            elseif child:IsA("Model") or child:IsA("Folder") then
                walk(child, depth + 1)
            end
        end
    end

    pcall(function() walk(Workspace, 0) end)
    return found
end

local function currentGuns()
    local now = os.clock()
    if now >= state.gunNext then
        state.gunNext  = now + math.max(CONFIG.GunRate, 0.1)
        state.gunCache = collectDroppedGuns()
    end
    return state.gunCache
end

-- ======================================================================
-- actors (NPCs, mobs, bots)
-- ======================================================================

-- A target is anything that stands up and can be hit. Three shapes cover the
-- field: a Model with a Humanoid (players, NPCs), a Humanoid-less rig (dummy,
-- bot, animated mob), and a part-based mob with an exposed health value.
local MOB_KEYWORDS = {
    "mob", "bot", "npc", "enemy", "zombie", "guard", "soldier", "monster",
    "creature", "dummy", "hostile", "unit", "troop", "raider", "bandit",
    "slime", "skeleton", "demon", "goblin", "brute", "thug", "boss", "minion",
}

local HEALTH_ATTRIBUTES = { "Health", "health", "HP", "Hp", "hp", "CurrentHealth", "currentHealth" }
local HEALTH_CHILDREN   = { "Health", "HP", "HealthValue", "HealthBar" }

local HEAD_NAMES = { "Head", "head", "Chest", "Core", "UpperTorso", "Torso" }
local ROOT_NAMES = { "HumanoidRootPart", "Torso", "UpperTorso", "RootPart", "Root" }

local function firstPart(model, names)
    for _, name in ipairs(names) do
        local inst = model:FindFirstChild(name)
        if inst and inst:IsA("BasePart") then return inst end
    end
    return nil
end

-- Aim point for a model that has no Humanoid: a named body part if the rig has
-- one, otherwise the primary part, otherwise the first part found. The descendant
-- walk is capped so a 400-part mob does not cost a full traversal.
local function actorPart(model)
    local part = firstPart(model, HEAD_NAMES) or firstPart(model, ROOT_NAMES)
    if part then return part end
    if model.PrimaryPart then return model.PrimaryPart end

    local scanned = 0
    for _, descendant in ipairs(model:GetDescendants()) do
        scanned += 1
        if descendant:IsA("BasePart") then return descendant end
        if scanned >= 60 then break end
    end

    return nil
end

local function actorHealth(model)
    for _, name in ipairs(HEALTH_ATTRIBUTES) do
        local value = model:GetAttribute(name)
        if type(value) == "number" then return value end
    end

    for _, name in ipairs(HEALTH_CHILDREN) do
        local child = model:FindFirstChild(name)
        if child and (child:IsA("IntValue") or child:IsA("NumberValue")) then
            return child.Value
        end
    end

    return nil
end

local function nameLooksLikeActor(name)
    local lower = name:lower()
    for _, keyword in ipairs(MOB_KEYWORDS) do
        if lower:find(keyword, 1, true) then return true end
    end
    return false
end

-- Acceptance for a Humanoid-less model: a name that reads like a mob, an exposed
-- health value, or the Head-plus-root shape of an animated rig. That last one is
-- what catches dummies and bots that carry no Humanoid at all.
local function actorAccepted(model)
    if nameLooksLikeActor(model.Name) then return true end
    if actorHealth(model) then return true end
    if firstPart(model, { "Head" }) and firstPart(model, ROOT_NAMES) then return true end
    return false
end

-- Actor scan: depth-limited walk of Workspace for anything no player owns.
-- Throttled, because GetChildren over a whole place is not a per-frame operation.
local function collectActors()
    local found = {}

    local function walk(container, depth)
        if depth > CONFIG.NPCDepth then return end

        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Model") then
                if not Players:GetPlayerFromCharacter(child) then
                    local humanoid = child:FindFirstChildOfClass("Humanoid")

                    if humanoid then
                        found[#found + 1] = {
                            model    = child,
                            humanoid = humanoid,
                            kind     = "npc",
                        }
                        walk(child, depth + 1)
                    elseif CONFIG.Mobs and actorAccepted(child) then
                        local part = actorPart(child)
                        if part then
                            found[#found + 1] = {
                                model    = child,
                                humanoid = nil,
                                part     = part,
                                kind     = "mob",
                            }
                        end
                        walk(child, depth + 1)
                    else
                        walk(child, depth + 1)
                    end
                end
            elseif child:IsA("Folder") then
                walk(child, depth + 1)
            end
        end
    end

    pcall(function() walk(Workspace, 0) end)
    return found
end

-- One list feeds both the aim and the ESP, so a name that shows on screen is a
-- name the aim can select. `enemy` is team state, not a filter: ESP decides
-- whether it cares, aim always does.
local function collectTargets()
    local now = os.clock()
    if CONFIG.NPCs and now >= state.npcNext then
        state.npcNext  = now + math.max(CONFIG.NPCRate, 0.1)
        state.npcCache = collectActors()
    end

    local targets = {}

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= localPlayer then
            local character = player.Character
            local humanoid  = character and character:FindFirstChildOfClass("Humanoid")

            if character and humanoid then
                targets[#targets + 1] = {
                    character = character,
                    humanoid  = humanoid,
                    part      = nil,          -- resolved per scan: AimPart can change
                    name      = player.Name,
                    player    = player,
                    isNPC     = false,
                    role      = roleOf(player),
                    enemy     = isEnemy(player),
                    kind      = "player",
                }
            end
        end
    end

    if CONFIG.NPCs then
        for _, actor in ipairs(state.npcCache) do
            local character = actor.model

            if character.Parent and (actor.kind ~= "mob" or CONFIG.Mobs) then
                local humanoid = actor.humanoid
                local part

                if humanoid and humanoid.Parent then
                    part = nil                -- same: AimPart decides
                else
                    humanoid = nil            -- the rig lost its Humanoid, retarget the parts
                    part = actorPart(character)
                end

                if humanoid or part then
                    targets[#targets + 1] = {
                        character = character,
                        humanoid  = humanoid,
                        part      = part,
                        name      = character.Name,
                        player    = nil,
                        isNPC     = true,
                        role      = nil,
                        enemy     = true,
                        kind      = humanoid and "npc" or "mob",
                    }
                end
            end
        end
    end

    return targets
end

local function selectTarget()
    local camera = currentCamera()
    if not camera then return nil end

    local origin    = camera.CFrame.Position
    local centre    = screenCentre(camera)
    local best      = nil
    local bestScore = math.huge

    local debug = state.debug
    debug.candidates = 0
    debug.blocked    = 0
    debug.knocked    = 0
    debug.npcs       = 0
    debug.mobs       = 0
    debug.found      = false

    rayParams.RespectCanCollide = CONFIG.CollidableOnly

    local wanted = CONFIG.TargetRoles

    for _, target in ipairs(collectTargets()) do
        if target.isNPC then
            debug.npcs += 1
            if target.kind == "mob" then debug.mobs += 1 end
        end

        local character = target.character
        local humanoid  = target.humanoid

        -- a Humanoid carries its own health; a mob rig exposes it as an
        -- attribute or value, and a rig with neither is assumed alive
        local health = humanoid and humanoid.Health or (actorHealth(character) or 1)

        -- the role filter applies to players only: an NPC has no role to match
        local roleOk = target.isNPC
            or wanted == "All"
            or (wanted == "Murderer" and target.role == "Murderer")
            or (wanted == "Sheriff" and target.role == "Sheriff")
            or (wanted == "Innocent" and target.role ~= "Murderer"
                and target.role ~= "Sheriff")

        if roleOk and target.enemy and health > 0 then
            local part = target.part or aimPartFor(character)

            if part then
                local world = part.Position
                if CONFIG.Prediction > 0 then
                    world += part.AssemblyLinearVelocity * CONFIG.Prediction
                end

                local distance = (world - origin).Magnitude
                if distance <= CONFIG.MaxDistance and distance > 1 then
                    local screen = camera:WorldToViewportPoint(world)

                    if screen.Z > 0 then
                        local offset = (Vector2.new(screen.X, screen.Y) - centre).Magnitude

                        if offset <= CONFIG.FOV then
                            debug.candidates += 1

                            if CONFIG.KnockCheck and humanoid and isKnocked(humanoid, character) then
                                debug.knocked += 1
                            elseif offset < bestScore then
                                local clear = true

                                if CONFIG.WallCheck then
                                    local filter = { character, camera }
                                    if localPlayer.Character then
                                        table.insert(filter, localPlayer.Character)
                                    end
                                    rayParams.FilterDescendantsInstances = filter
                                    clear = Workspace:Raycast(origin, world - origin, rayParams) == nil
                                end

                                if clear then
                                    best, bestScore = part, offset
                                else
                                    debug.blocked += 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    debug.found = best ~= nil
    return best
end

local function predictedWorld(targetPart)
    local world = targetPart.Position
    if not isFiniteVector(world) then return nil end

    if CONFIG.Prediction > 0 then
        local velocity = targetPart.AssemblyLinearVelocity
        if not isFiniteVector(velocity) then return world end
        if velocity.Magnitude > 1000 then velocity = velocity.Unit * 1000 end
        world += velocity * CONFIG.Prediction
        if not isFiniteVector(world) then return nil end
    end

    return world
end

local function applyAim(camera, targetPart, dt)
    local origin  = camera.CFrame.Position
    local world   = predictedWorld(targetPart)
    if not world then return end

    local desired = CFrame.lookAt(origin, world)

    -- human wobble: low-frequency angular noise on the target itself
    if CONFIG.Curve == "Human" and CONFIG.Humanize > 0 and not CONFIG.SafeMode then
        local t = os.clock()
        local jitter = CONFIG.Humanize * 0.02
        desired = desired * CFrame.Angles(
            math.noise(t * 3.1, 11.7) * jitter,
            math.noise(t * 3.1, 0.5) * jitter,
            0
        )
    end

    local current = camera.CFrame
    local dot     = math.clamp(current.LookVector:Dot(desired.LookVector), -1, 1)
    local angle   = math.deg(math.acos(dot))

    if angle <= CONFIG.Deadzone then return end

    -- time-constant smoothing: 0 snaps, 100 takes ~0.9s to settle
    local tau   = 0.008 + (CONFIG.Smoothness / 100) ^ 2 * 0.9
    local alpha = 1 - math.exp(-dt / tau)

    if CONFIG.Curve ~= "Linear" then
        local elapsed = os.clock() - (state.aimStarted or os.clock())
        local ramp    = math.clamp(elapsed / math.max(CONFIG.RampIn, 0.001), 0, 1)
        alpha = alpha * (0.25 + 0.75 * ramp)
    end

    -- hard angular velocity ceiling, the part that reads as human
    local allowed  = math.min(angle * alpha, CONFIG.MaxTurnSpeed * dt)
    local fraction = math.clamp(allowed / angle, 0, 1)

    if not isFinite(fraction) then return nil end

    local written = current:Lerp(desired, fraction)
    camera.CFrame = written
    return written
end

local function angleToTarget(camera, world)
    local delta = world - camera.CFrame.Position
    if delta.Magnitude < 0.001 then return 0 end
    local dot = math.clamp(camera.LookVector:Dot(delta.Unit), -1, 1)
    return math.deg(math.acos(dot))
end

-- Drives the game's own camera by moving the mouse, for games that rebuild
-- Camera.CFrame themselves every frame and overwrite anything written to it.
-- The controller works in screen pixels: the distance from the target to the
-- crosshair is the rotation still owed, so one call per frame is the correct
-- rate. The old 20 Hz cap is what made this feel chunky.
local function applyMouseAim(camera, targetPart, dt)
    if not hasMouseMove then return false end

    dt = dt or 1 / 60

    -- rate gate: 60 means every frame, 30 means every other frame
    state.mouseAccum += dt
    local interval = 1 / math.max(CONFIG.MouseRate, 1)
    if state.mouseAccum < interval then return true end
    local step = state.mouseAccum
    state.mouseAccum = 0

    local screen = camera:WorldToViewportPoint(targetPart.Position)
    if screen.Z <= 0 then return false end
    if not (isFinite(screen.X) and isFinite(screen.Y)) then return false end

    local centre = screenCentre(camera)
    local errorX = screen.X - centre.X
    local errorY = screen.Y - centre.Y

    -- sub-pixel error is below what a mouse can express
    if math.abs(errorX) < 1 and math.abs(errorY) < 1 then return true end

    -- Smoothness 0 snaps, 100 glides. tau stays small because the loop already
    -- runs at frame rate and the pixel cap bounds the travel per call.
    local tau   = 0.004 + (CONFIG.Smoothness / 100) ^ 2 * 0.35
    local alpha = 1 - math.exp(-step / tau)

    local dx = errorX * CONFIG.MouseGain * alpha
    local dy = errorY * CONFIG.MouseGain * alpha

    local cap = math.max(CONFIG.MouseClamp, 1)
    if dx >  cap then dx =  cap elseif dx < -cap then dx = -cap end
    if dy >  cap then dy =  cap elseif dy < -cap then dy = -cap end

    -- round on the magnitude, then reapply the sign: math.floor(x + 0.5) on a
    -- negative number rounds half-steps toward zero and biases the approach
    local ix = math.floor(math.abs(dx) + 0.5)
    if dx < 0 then ix = -ix end
    local iy = math.floor(math.abs(dy) + 0.5)
    if dy < 0 then iy = -iy end

    -- rounding must never stall the approach on a large remaining error
    if ix == 0 and math.abs(errorX) > 2 then ix = errorX > 0 and 1 or -1 end
    if iy == 0 and math.abs(errorY) > 2 then iy = errorY > 0 and 1 or -1 end
    if ix == 0 and iy == 0 then return true end

    local ok = pcall(mousemoverel, ix, iy)
    if not ok then
        state.mouseMode = false
        return false
    end

    return true
end

-- ======================================================================
-- esp
-- ======================================================================

local function newESPEntry()
    if typeof(Drawing) ~= "table" then return nil end

    local ok, entry = pcall(function()
        local box = Drawing.new("Square")
        box.Filled    = false
        box.Thickness = 1
        box.Visible   = false

        local name = Drawing.new("Text")
        name.Center  = true
        name.Outline = true
        name.Size    = 14
        name.Visible = false

        return { box = box, name = name }
    end)

    if ok then return entry end
    return nil
end

local function hideESP(entry)
    if not entry then return end
    entry.box.Visible  = false
    entry.name.Visible = false
end

local function clearESP()
    for _, entry in pairs(state.esp) do
        pcall(function()
            entry.box:Remove()
            entry.name:Remove()
        end)
    end
    state.esp = {}

    for _, entry in pairs(state.gunESP) do
        pcall(function()
            entry.box:Remove()
            entry.name:Remove()
        end)
    end
    state.gunESP = {}
end

local function updateESP(camera)
    if not CONFIG.ESP or typeof(Drawing) ~= "table" then
        for _, entry in pairs(state.esp) do hideESP(entry) end
        for _, entry in pairs(state.gunESP) do hideESP(entry) end
        return
    end

    local origin         = camera.CFrame.Position
    local playerColour   = rgb(CONFIG.ESPColor)
    local npcColour      = rgb(CONFIG.ESPColorNPC)
    local murdererColour = rgb(CONFIG.ESPColorMurderer)
    local sheriffColour  = rgb(CONFIG.ESPColorSheriff)
    local seen           = {}

    for _, target in ipairs(collectTargets()) do
        local character = target.character
        local humanoid  = target.humanoid
        local show      = false

        local allowed = target.isNPC or (not CONFIG.ESPTeamCheck) or target.enemy
        local health  = humanoid and humanoid.Health or (actorHealth(character) or 1)
        local knocked = humanoid and CONFIG.ESPKnockCheck
            and isKnocked(humanoid, character)

        local topWorld, bottomWorld, distance

        if humanoid then
            local head = character:FindFirstChild("Head")
            local root = character:FindFirstChild("HumanoidRootPart")

            if head and root then
                topWorld    = head.Position + Vector3.new(0, 0.6, 0)
                bottomWorld = root.Position - Vector3.new(0, 2.6, 0)
                distance    = (root.Position - origin).Magnitude
            end
        else
            -- a mob rig has no Head/HumanoidRootPart contract: the box is built
            -- from the aim part's own height, so a one-part slime boxes correctly
            local part = target.part

            if part then
                local half = part.Size.Y * 0.5
                topWorld    = part.Position + Vector3.new(0, half, 0)
                bottomWorld = part.Position - Vector3.new(0, half, 0)
                distance    = (part.Position - origin).Magnitude
            end
        end

        if topWorld and bottomWorld and allowed and health > 0 and not knocked then
            if distance <= CONFIG.ESPMaxDistance then
                local top, topOk    = camera:WorldToViewportPoint(topWorld)
                local bottom, botOk = camera:WorldToViewportPoint(bottomWorld)

                if topOk and botOk and top.Z > 0 and bottom.Z > 0 then
                    local entry = state.esp[character]
                    if not entry then
                        entry = newESPEntry()
                        state.esp[character] = entry
                    end

                    if entry then
                        local height = math.abs(bottom.Y - top.Y)
                        local width  = height * 0.6

                        local colour = playerColour
                        local prefix = ""

                        if target.isNPC then
                            colour = npcColour
                        elseif target.role == "Murderer" then
                            colour = murdererColour
                            prefix = "[M] "
                        elseif target.role == "Sheriff" then
                            colour = sheriffColour
                            prefix = "[S] "
                        end

                        entry.box.Position = Vector2.new(top.X - width * 0.5, top.Y)
                        entry.box.Size     = Vector2.new(width, height)
                        entry.box.Color    = colour
                        entry.box.Visible  = CONFIG.ESPBoxes

                        entry.name.Text     = (CONFIG.ESPShowRoles and prefix or "") .. target.name
                        entry.name.Position = Vector2.new(top.X, top.Y - 16)
                        entry.name.Color    = colour
                        entry.name.Visible  = CONFIG.ESPNames

                        seen[character] = true
                        show = CONFIG.ESPBoxes or CONFIG.ESPNames
                    end
                end
            end
        end

        if not show then hideESP(state.esp[character]) end
    end

    -- entries key off the character model now, not the player, so NPCs get the
    -- same treatment and nothing leaks when a body leaves the world
    for character, entry in pairs(state.esp) do
        if not seen[character] then
            hideESP(entry)
            if not character.Parent then
                pcall(function()
                    entry.box:Remove()
                    entry.name:Remove()
                end)
                state.esp[character] = nil
            end
        end
    end

    -- dropped gun: the sheriff's Tool lands in Workspace on death. Boxed and
    -- labelled with its distance so the walk to it is a straight line.
    local gunsSeen = {}

    if CONFIG.GunESP then
        local gunColour = rgb(CONFIG.ESPColorGun)

        for _, gun in ipairs(currentGuns()) do
            local position = gunPosition(gun)

            if position then
                local distance = (position - origin).Magnitude

                if distance <= CONFIG.ESPMaxDistance then
                    local screen, onScreen = camera:WorldToViewportPoint(position)

                    if onScreen and screen.Z > 0 then
                        local entry = state.gunESP[gun]
                        if not entry then
                            entry = newESPEntry()
                            state.gunESP[gun] = entry
                        end

                        if entry then
                            -- constant screen size: 1200 / distance keeps the
                            -- box readable at 20 studs and at 200
                            local size = math.clamp(1200 / math.max(distance, 1), 8, 70)

                            entry.box.Position = Vector2.new(
                                screen.X - size * 0.5, screen.Y - size * 0.5)
                            entry.box.Size     = Vector2.new(size, size)
                            entry.box.Color    = gunColour
                            entry.box.Visible  = CONFIG.ESPBoxes

                            entry.name.Text     = ("GUN  %dm"):format(math.floor(distance))
                            entry.name.Position = Vector2.new(
                                screen.X, screen.Y - size * 0.5 - 16)
                            entry.name.Color    = gunColour
                            entry.name.Visible  = CONFIG.ESPNames

                            gunsSeen[gun] = true
                        end
                    end
                end
            end
        end
    end

    for gun, entry in pairs(state.gunESP) do
        if not gunsSeen[gun] then
            hideESP(entry)
            if not gun.Parent then
                pcall(function()
                    entry.box:Remove()
                    entry.name:Remove()
                end)
                state.gunESP[gun] = nil
            end
        end
    end
end

-- ======================================================================
-- render
-- ======================================================================

local function updateDebug(camera)
    local labels = state.debugLabels
    if not labels.camera then return end

    local now = os.clock()
    if now - state.lastDebug < 0.15 then return end
    state.lastDebug = now

    local debug = state.debug

    -- role census: cached lookups, so this is a cheap pass at 6.6 Hz
    local murderer, sheriff = 0, 0
    for _, player in ipairs(Players:GetPlayers()) do
        local role = roleOf(player)
        if role == "Murderer" then
            murderer += 1
        elseif role == "Sheriff" then
            sheriff += 1
        end
    end

    debug.murderer = murderer
    debug.sheriff  = sheriff
    debug.guns     = #currentGuns()

    labels.camera.Text = "camera: " .. tostring(camera.CameraType)
    labels.aiming.Text = "aiming: " .. tostring(state.aiming)
        .. "  target: " .. tostring(debug.found)
    labels.candidates.Text = "in FOV: " .. tostring(debug.candidates)
        .. "  wall-blocked: " .. tostring(debug.blocked)
        .. "  knocked: " .. tostring(debug.knocked)
        .. "  npcs: " .. tostring(debug.npcs)
        .. "  mobs: " .. tostring(debug.mobs)
    labels.resolution.Text = ("viewport: %d x %d"):format(
        math.floor(camera.ViewportSize.X), math.floor(camera.ViewportSize.Y))
    labels.priority.Text = "render priority: " .. tostring(CONFIG.RenderPriority)
    labels.method.Text = "method: " .. (state.mouseMode and "mouse" or "camera")
        .. "  (" .. CONFIG.AimMethod .. ")"
        .. "  stuck: " .. tostring(state.stuckFrames)
        .. "  write: " .. (state.writeKept and "kept" or "lost")
        .. (hasMouseMove and "" or "  [no mousemoverel]")
    labels.roles.Text = "murderer: " .. tostring(debug.murderer)
        .. "  sheriff: " .. tostring(debug.sheriff)
        .. "  dropped guns: " .. tostring(debug.guns)
        .. "  aiming at: " .. CONFIG.TargetRoles
    labels.error.Text = "errors: " .. tostring(state.errorCount)
        .. "  last: " .. (state.lastError == "" and "none" or state.lastError)
end

local function onRender(dt)
    local camera = currentCamera()
    if not camera then return end

    dt = math.min(dt or 1 / 60, 0.1)

    state.stage = "debug"
    updateDebug(camera)

    if CONFIG.FOVCircle then
        state.stage = "fovcircle"
        local circle = ensureCircle()
        if circle then
            circle.Position  = screenCentre(camera)
            circle.Radius    = CONFIG.FOV
            circle.Color     = rgb(CONFIG.CircleColor)
            circle.Thickness = CONFIG.CircleThickness
            circle.Visible   = state.aiming
        end
    elseif fovCircle then
        fovCircle.Visible = false
    end

    state.stage = "esp"
    updateESP(camera)

    if not state.aiming or not CONFIG.AimEnabled then
        state.target = nil
        state.prevAngle = nil
        state.stuckFrames = 0
        state.lastWrite = nil
        releaseCamera()
        return
    end

    -- explicit method wins over the auto-detected one
    if CONFIG.AimMethod == "Camera" and state.mouseMode then
        state.mouseMode = false
        state.stuckFrames = 0
        state.prevAngle = nil
    elseif CONFIG.AimMethod == "Mouse" and not state.mouseMode then
        state.mouseMode = true
    end

    local now = os.clock()
    if now >= state.nextScan then
        state.nextScan = now + CONFIG.SelectInterval
        state.stage = "select"
        state.target = selectTarget()
    end

    local part = state.target
    if not part or not part.Parent then
        state.target = nil
        state.lastWrite = nil
        releaseCamera()
        return
    end

    local useMouse = CONFIG.AimMethod == "Mouse"
        or (CONFIG.AimMethod == "Auto" and state.mouseMode)

    if CONFIG.AimMethod == "Subject" then
        claimCamera(camera, part)
        state.stage = "subject"
        return
    end

    if not useMouse then
        -- did last frame's write survive, or did the game overwrite it?
        if state.lastWrite then
            local nowCFrame = camera.CFrame
            state.writeKept = nowCFrame.LookVector:Dot(state.lastWrite.LookVector) > 0.999
                and (nowCFrame.Position - state.lastWrite.Position).Magnitude < 0.05
        end

        claimCamera(camera, part)

        -- if the angle to target never shrinks, the write lands and is discarded
        local before = angleToTarget(camera, part.Position)

        if state.prevAngle and before > 2 and before > state.prevAngle - 0.02 then
            state.stuckFrames += 1
        else
            state.stuckFrames = 0
        end
        state.prevAngle = before

        if CONFIG.AimMethod == "Auto" and CONFIG.AutoFallback
            and hasMouseMove and state.stuckFrames > 15 then
            state.mouseMode = true
            state.stuckFrames = 0
            print("[ewanko] camera writes are being overridden — mouse fallback active")
            applyMouseAim(camera, part, dt)
            return
        end

        state.stage = "camera"
        state.lastWrite = applyAim(camera, part, dt) or state.lastWrite
        return
    end

    state.stage = "mouse"
    applyMouseAim(camera, part, dt)
end

local function safeRender(dt)
    local ok, err = pcall(onRender, dt)
    if ok then
        if state.errorCount > 0 then
            state.errorCount = 0
            state.lastError = ""
        end
        return
    end

    state.errorCount  += 1
    state.lastError = tostring(err)

    -- a recurring error must not take the menu down with it: that is what
    -- "the cheat crashed and the UI vanished" actually looked like
    if state.errorCount == 20 then
        warn("[ewanko] render error, aim disabled: " .. tostring(err))
    end

    if state.errorCount >= 20 then
        state.aiming = false
        state.target = nil
        state.stuckFrames = 0
    end
end

-- ======================================================================
-- ui helpers
-- ======================================================================

local ACCENT      = Color3.fromRGB(255, 77, 141)
local ACCENT_SOFT = Color3.fromRGB(255, 145, 182)
local BG          = Color3.fromRGB(11, 11, 15)
local PANEL       = Color3.fromRGB(17, 17, 23)
local PANEL_HI    = Color3.fromRGB(28, 28, 36)
local PANEL_LO    = Color3.fromRGB(21, 21, 28)
local TEXT        = Color3.fromRGB(240, 240, 248)
local MUTED       = Color3.fromRGB(116, 116, 130)
local LINE        = Color3.fromRGB(35, 35, 45)

local FAST = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function create(className, properties, parent)
    local inst = Instance.new(className)
    for key, value in pairs(properties) do
        inst[key] = value
    end
    if parent then inst.Parent = parent end
    return inst
end

local function corner(inst, radius)
    create("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, inst)
    return inst
end

local function stroke(inst, colour, thickness, transparency)
    create("UIStroke", {
        Color = colour or LINE,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
    }, inst)
    return inst
end

local function gradient(inst, from, to, rotation)
    create("UIGradient", {
        Color = ColorSequence.new(from, to),
        Rotation = rotation or 0,
    }, inst)
    return inst
end

local function label(parent, text, size, colour, position)
    return create("TextLabel", {
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = text,
        TextColor3 = colour or TEXT,
        TextSize = size or 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Position = position or UDim2.new(0, 0, 0, 0),
        Size = UDim2.new(1, 0, 1, 0),
    }, parent)
end

-- Section header: uppercase caption plus a hairline rule that fades into the
-- page background, so the list reads as groups instead of one long column.
local function section(parent, title)
    local frame = create("Frame", {
        Size = UDim2.new(1, -8, 0, 26),
        BackgroundTransparency = 1,
    }, parent)

    local tick = create("Frame", {
        Size = UDim2.new(0, 2, 0, 10),
        Position = UDim2.new(0, 0, 0, 8),
        BackgroundColor3 = ACCENT,
        BorderSizePixel = 0,
    }, frame)
    corner(tick, 1)

    local caption = label(frame, string.upper(title), 10, MUTED, UDim2.new(0, 8, 0, 7))
    caption.Size = UDim2.new(0, 138, 0, 12)
    caption.Font = Enum.Font.GothamBold

    local rule = create("Frame", {
        Size = UDim2.new(1, -150, 0, 1),
        Position = UDim2.new(0, 150, 0, 12),
        BackgroundColor3 = LINE,
        BorderSizePixel = 0,
    }, frame)
    gradient(rule, LINE, BG, 0)

    return frame
end

local function divider(parent)
    local rule = create("Frame", {
        Size = UDim2.new(1, -8, 0, 1),
        BackgroundColor3 = LINE,
        BorderSizePixel = 0,
    }, parent)
    gradient(rule, LINE, BG, 0)
    return rule
end

local function tween(inst, goal, info)
    TweenService:Create(inst, info or FAST, goal):Play()
end

-- ======================================================================
-- controls
-- ======================================================================

local function addToggle(parent, text, key, onChange)
    local row = create("Frame", {
        Size = UDim2.new(1, -8, 0, 28),
        BackgroundColor3 = PANEL_LO,
        BorderSizePixel = 0,
    }, parent)
    corner(row, 6)

    local title = label(row, text, 13, TEXT, UDim2.new(0, 10, 0, 0))
    title.Size = UDim2.new(1, -56, 1, 0)

    local pill = create("Frame", {
        Size = UDim2.new(0, 34, 0, 18),
        Position = UDim2.new(1, -44, 0.5, -9),
        BackgroundColor3 = CONFIG[key] and ACCENT or PANEL_HI,
        BorderSizePixel = 0,
    }, row)
    corner(pill, 9)

    local dot = create("Frame", {
        Size = UDim2.new(0, 14, 0, 14),
        Position = CONFIG[key] and UDim2.new(0, 18, 0, 2) or UDim2.new(0, 2, 0, 2),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BorderSizePixel = 0,
    }, pill)
    corner(dot, 7)

    local hit = create("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    }, row)

    local function apply()
        tween(pill, { BackgroundColor3 = CONFIG[key] and ACCENT or PANEL_HI })
        tween(dot, {
            Position = CONFIG[key] and UDim2.new(0, 18, 0, 2) or UDim2.new(0, 2, 0, 2),
        })
    end

    hit.MouseButton1Click:Connect(function()
        CONFIG[key] = not CONFIG[key]
        apply()
        if onChange then onChange(CONFIG[key]) end
    end)

    hit.MouseEnter:Connect(function()
        tween(row, { BackgroundColor3 = PANEL_HI })
    end)
    hit.MouseLeave:Connect(function()
        tween(row, { BackgroundColor3 = PANEL_LO })
    end)

    table.insert(state.refreshers, apply)
    apply()
    return row
end

local function addSlider(parent, text, key, min, max, step, suffix)
    local row = create("Frame", {
        Size = UDim2.new(1, -8, 0, 46),
        BackgroundColor3 = PANEL_LO,
        BorderSizePixel = 0,
    }, parent)
    corner(row, 6)

    label(row, text, 13, TEXT, UDim2.new(0, 10, 0, 5)).Size = UDim2.new(1, -108, 0, 16)

    -- the value chip has to hold "3000 deg/s" and "1500 studs" whole
    local chip = create("Frame", {
        Size = UDim2.new(0, 82, 0, 18),
        Position = UDim2.new(1, -92, 0, 4),
        BackgroundColor3 = PANEL_HI,
        BorderSizePixel = 0,
    }, row)
    corner(chip, 4)

    local valueLabel = create("TextLabel", {
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = "",
        TextColor3 = ACCENT_SOFT,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Center,
        Size = UDim2.new(1, 0, 1, 0),
    }, chip)

    local track = create("Frame", {
        Size = UDim2.new(1, -20, 0, 5),
        Position = UDim2.new(0, 10, 0, 33),
        BackgroundColor3 = Color3.fromRGB(38, 38, 48),
        BorderSizePixel = 0,
    }, row)
    corner(track, 3)

    local fill = create("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = ACCENT,
        BorderSizePixel = 0,
    }, track)
    corner(fill, 3)
    gradient(fill, ACCENT, ACCENT_SOFT, 0)

    local knob = create("Frame", {
        Size = UDim2.new(0, 10, 0, 10),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BorderSizePixel = 0,
        ZIndex = 3,
    }, track)
    corner(knob, 5)

    -- the visible track is 5 px; the grab area is 20, or the slider is unusable
    local hit = create("TextButton", {
        Size = UDim2.new(1, -10, 0, 22),
        Position = UDim2.new(0, 5, 0, 24),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 4,
    }, row)

    local dragging = false

    local function describe()
        local shown = CONFIG[key]
        if step and step >= 1 then shown = math.floor(shown + 0.5) end
        if suffix then
            valueLabel.Text = tostring(shown) .. suffix
        elseif step and step < 1 then
            valueLabel.Text = string.format("%.2f", shown)
        else
            valueLabel.Text = tostring(shown)
        end
    end

    local function apply()
        local alpha = math.clamp((CONFIG[key] - min) / (max - min), 0, 1)
        fill.Size     = UDim2.new(alpha, 0, 1, 0)
        knob.Position = UDim2.new(alpha, 0, 0.5, 0)
        describe()
    end

    local function setFromX(x)
        local alpha = math.clamp((x - hit.AbsolutePosition.X) / hit.AbsoluteSize.X, 0, 1)
        local value = min + alpha * (max - min)
        if step and step > 0 then
            value = math.floor(value / step + 0.5) * step
        end
        CONFIG[key] = math.clamp(value, min, max)
        apply()
    end

    hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            setFromX(input.Position.X)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            setFromX(input.Position.X)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)

    hit.MouseEnter:Connect(function()
        tween(row, { BackgroundColor3 = PANEL_HI })
    end)
    hit.MouseLeave:Connect(function()
        tween(row, { BackgroundColor3 = PANEL_LO })
    end)

    table.insert(state.refreshers, apply)
    apply()
    return row
end

local function addCycle(parent, text, key, options)
    local row = create("Frame", {
        Size = UDim2.new(1, -8, 0, 28),
        BackgroundColor3 = PANEL_LO,
        BorderSizePixel = 0,
    }, parent)
    corner(row, 6)

    label(row, text, 13, TEXT, UDim2.new(0, 10, 0, 0)).Size = UDim2.new(1, -134, 1, 0)

    local button = create("TextButton", {
        Size = UDim2.new(0, 112, 0, 20),
        Position = UDim2.new(1, -122, 0.5, -10),
        BackgroundColor3 = PANEL_HI,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        Text = tostring(CONFIG[key]),
        TextColor3 = ACCENT_SOFT,
        TextSize = 11,
        AutoButtonColor = false,
    }, row)
    corner(button, 4)

    local function apply()
        button.Text = tostring(CONFIG[key])
    end

    button.MouseButton1Click:Connect(function()
        local index = 1
        for i, option in ipairs(options) do
            if option == CONFIG[key] then index = i end
        end
        index = index % #options + 1
        CONFIG[key] = options[index]
        apply()
    end)

    button.MouseEnter:Connect(function()
        tween(row, { BackgroundColor3 = PANEL_HI })
    end)
    button.MouseLeave:Connect(function()
        tween(row, { BackgroundColor3 = PANEL_LO })
    end)

    table.insert(state.refreshers, apply)
    apply()
    return row
end

local function addKeybind(parent, text, key)
    local row = create("Frame", {
        Size = UDim2.new(1, -8, 0, 28),
        BackgroundColor3 = PANEL_LO,
        BorderSizePixel = 0,
    }, parent)
    corner(row, 6)

    label(row, text, 13, TEXT, UDim2.new(0, 10, 0, 0)).Size = UDim2.new(1, -134, 1, 0)

    local button = create("TextButton", {
        Size = UDim2.new(0, 112, 0, 20),
        Position = UDim2.new(1, -122, 0.5, -10),
        BackgroundColor3 = PANEL_HI,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        Text = tostring(CONFIG[key]),
        TextColor3 = TEXT,
        TextSize = 11,
        AutoButtonColor = false,
    }, row)
    corner(button, 4)

    local function apply()
        if state.awaitingBind == key then
            button.Text = "press..."
            button.TextColor3 = ACCENT
        else
            button.Text = tostring(CONFIG[key])
            button.TextColor3 = TEXT
        end
    end

    button.MouseButton1Click:Connect(function()
        state.awaitingBind = key
        state.bindArmed = false
        apply()
        task.delay(0.2, function()
            if state.awaitingBind == key then
                state.bindArmed = true
            end
        end)
    end)

    button.MouseEnter:Connect(function()
        tween(row, { BackgroundColor3 = PANEL_HI })
    end)
    button.MouseLeave:Connect(function()
        tween(row, { BackgroundColor3 = PANEL_LO })
    end)

    table.insert(state.refreshers, apply)
    apply()
    return row
end

local function addButton(parent, text, onClick)
    local button = create("TextButton", {
        Size = UDim2.new(1, -8, 0, 28),
        BackgroundColor3 = PANEL_LO,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        Text = text,
        TextColor3 = TEXT,
        TextSize = 12,
        AutoButtonColor = false,
    }, parent)
    corner(button, 6)

    button.MouseButton1Click:Connect(onClick)

    button.MouseEnter:Connect(function()
        tween(button, { BackgroundColor3 = PANEL_HI, TextColor3 = ACCENT_SOFT })
    end)
    button.MouseLeave:Connect(function()
        tween(button, { BackgroundColor3 = PANEL_LO, TextColor3 = TEXT })
    end)

    return button
end

local function refreshAll()
    for _, apply in ipairs(state.refreshers) do
        pcall(apply)
    end
end

-- ======================================================================
-- config io
-- ======================================================================

local CONFIG_FILE = "ewanko_aimbot.json"

local function saveConfig()
    if not writefile then return false end
    return pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode(CONFIG))
    end)
end

local function loadConfig()
    if not (isfile and readfile) then return false end
    if not isfile(CONFIG_FILE) then return false end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(CONFIG_FILE))
    end)

    if not ok or type(data) ~= "table" then return false end

    for key, value in pairs(data) do
        if CONFIG[key] ~= nil and type(value) == type(CONFIG[key]) then
            CONFIG[key] = value
        end
    end

    refreshAll()
    return true
end

local function printReport()
    local camera = currentCamera()
    print("=== ewanko report ===")
    print("version:", VERSION)
    print("place:", game.PlaceId, game.JobId)
    print("camera:", camera and camera.CameraType or "nil")
    print("viewport:", camera and tostring(camera.ViewportSize) or "nil")
    print("aiming:", state.aiming, "target:", state.debug.found)
    print("in FOV:", state.debug.candidates, "wall-blocked:", state.debug.blocked,
        "knocked:", state.debug.knocked, "npcs:", state.debug.npcs,
        "mobs:", state.debug.mobs)
    print("murderer:", state.debug.murderer, "sheriff:", state.debug.sheriff,
        "dropped guns:", state.debug.guns, "target role:", CONFIG.TargetRoles)
    print("players:", #Players:GetPlayers())
    print("last error:", state.lastError)
    print("errors:", state.errorCount, "safe mode:", CONFIG.SafeMode)
    print("method:", state.mouseMode and "mouse" or "camera",
        "stuck:", state.stuckFrames, "mousemoverel:", hasMouseMove)
    print("stage:", state.stage)
    for key, value in pairs(CONFIG) do
        if type(value) ~= "table" then
            print(string.format("  %-18s %s", key, tostring(value)))
        end
    end
    print("=== end report ===")
end

-- Two clicks that separate the two possible crash sources. If the camera nudge
-- kills the client, the game owns the camera. If the mouse nudge kills it, the
-- executor's input hook is the problem. If neither does, it is the loop rate.
local function nudgeCamera()
    local camera = currentCamera()
    if not camera then
        print("[ewanko] nudge: no camera")
        return
    end

    local ok, err = pcall(function()
        camera.CFrame = camera.CFrame * CFrame.Angles(0, math.rad(3), 0)
    end)

    print(ok and "[ewanko] nudge: camera write accepted"
        or ("[ewanko] nudge: camera write FAILED — " .. tostring(err)))
end

local function nudgeMouse()
    if not hasMouseMove then
        print("[ewanko] nudge: executor has no mousemoverel")
        return
    end

    local ok, err = pcall(mousemoverel, 40, 0)

    print(ok and "[ewanko] nudge: 40px mouse move accepted"
        or ("[ewanko] nudge: mousemoverel FAILED — " .. tostring(err)))
end

-- ======================================================================
-- window
-- ======================================================================

local function buildWindow()
    local parent = game:GetService("CoreGui")
    if gethui then
        local ok, hidden = pcall(gethui)
        if ok and hidden then parent = hidden end
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "EwankoUI"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local attached = pcall(function() gui.Parent = parent end)
    if not attached then
        gui.Parent = localPlayer:WaitForChild("PlayerGui")
    end

    local WINDOW_W, WINDOW_H = 484, 376

    -- a soft drop shadow behind the window: a second frame, since the window
    -- itself clips descendants and would eat any shadow parented to it
    local shadow = create("Frame", {
        Name = "Shadow",
        Size = UDim2.new(0, WINDOW_W, 0, WINDOW_H),
        Position = UDim2.new(0.5, -WINDOW_W / 2 + 5, 0.5, -WINDOW_H / 2 + 7),
        BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 0.45,
        BorderSizePixel = 0,
        ZIndex = 1,
    }, gui)
    corner(shadow, 12)

    local window = create("Frame", {
        Name = "Window",
        Size = UDim2.new(0, WINDOW_W, 0, WINDOW_H),
        Position = UDim2.new(0.5, -WINDOW_W / 2, 0.5, -WINDOW_H / 2),
        BackgroundColor3 = BG,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        ZIndex = 2,
    }, gui)
    corner(window, 8)
    stroke(window, Color3.fromRGB(44, 44, 58))

    local titleBar = create("Frame", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = PANEL_HI,
        BorderSizePixel = 0,
        ZIndex = 3,
    }, window)
    gradient(titleBar, PANEL_HI, PANEL, 90)

    -- accent rule under the title bar: the one saturated line in the chrome
    local titleRule = create("Frame", {
        Size = UDim2.new(1, 0, 0, 2),
        Position = UDim2.new(0, 0, 0, 36),
        BackgroundColor3 = ACCENT,
        BorderSizePixel = 0,
        ZIndex = 3,
    }, window)
    gradient(titleRule, ACCENT, Color3.fromRGB(120, 40, 70), 0)

    local brand = label(titleBar, "ewanko", 15, TEXT, UDim2.new(0, 14, 0, 0))
    brand.Size = UDim2.new(0, 66, 1, 0)
    brand.Font = Enum.Font.GothamBold

    local versionChip = create("Frame", {
        Size = UDim2.new(0, 32, 0, 16),
        Position = UDim2.new(0, 76, 0.5, -8),
        BackgroundColor3 = Color3.fromRGB(40, 40, 52),
        BorderSizePixel = 0,
        ZIndex = 4,
    }, titleBar)
    corner(versionChip, 4)
    create("TextLabel", {
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = VERSION,
        TextColor3 = ACCENT_SOFT,
        TextSize = 10,
        Size = UDim2.new(1, 0, 1, 0),
    }, versionChip)

    -- live state pill: read the aim state off the chrome, not the FIX tab
    local statusPill = create("Frame", {
        Size = UDim2.new(0, 76, 0, 18),
        Position = UDim2.new(1, -192, 0.5, -9),
        BackgroundColor3 = Color3.fromRGB(24, 24, 32),
        BorderSizePixel = 0,
        ZIndex = 4,
    }, titleBar)
    corner(statusPill, 9)
    stroke(statusPill, LINE, 1, 0.35)

    local statusDot = create("Frame", {
        Size = UDim2.new(0, 6, 0, 6),
        Position = UDim2.new(0, 9, 0.5, -3),
        BackgroundColor3 = MUTED,
        BorderSizePixel = 0,
        ZIndex = 5,
    }, statusPill)
    corner(statusDot, 3)

    local statusText = create("TextLabel", {
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = "IDLE",
        TextColor3 = MUTED,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Center,
        Position = UDim2.new(0, 8, 0, 0),
        Size = UDim2.new(1, -14, 1, 0),
        ZIndex = 5,
    }, statusPill)

    state.statusLabel = { pill = statusPill, dot = statusDot, text = statusText }

    local close = create("TextButton", {
        Size = UDim2.new(0, 26, 0, 22),
        Position = UDim2.new(1, -34, 0.5, -11),
        BackgroundColor3 = Color3.fromRGB(44, 44, 56),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Text = "x",
        TextColor3 = TEXT,
        TextSize = 12,
        AutoButtonColor = false,
        ZIndex = 4,
    }, titleBar)
    corner(close, 5)

    -- streamer chip: one click hides the window, the ESP and the FOV circle
    local streamChip = create("TextButton", {
        Size = UDim2.new(0, 62, 0, 18),
        Position = UDim2.new(1, -104, 0.5, -9),
        BackgroundColor3 = Color3.fromRGB(40, 40, 52),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        Text = "STREAM",
        TextColor3 = MUTED,
        TextSize = 10,
        AutoButtonColor = false,
        ZIndex = 4,
    }, titleBar)
    corner(streamChip, 4)

    close.MouseButton1Click:Connect(function()
        gui.Enabled = not gui.Enabled
        state.uiClosed = not gui.Enabled
    end)

    close.MouseEnter:Connect(function()
        tween(close, { BackgroundColor3 = ACCENT })
    end)
    close.MouseLeave:Connect(function()
        tween(close, { BackgroundColor3 = Color3.fromRGB(44, 44, 56) })
    end)

    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            state.dragging = true
            state.dragStart = input.Position
            state.dragOrigin = window.Position
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if state.dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - state.dragStart
            local nextPosition = UDim2.new(
                state.dragOrigin.X.Scale,
                state.dragOrigin.X.Offset + delta.X,
                state.dragOrigin.Y.Scale,
                state.dragOrigin.Y.Offset + delta.Y
            )
            window.Position = nextPosition
            shadow.Position = UDim2.new(
                nextPosition.X.Scale,
                nextPosition.X.Offset + 5,
                nextPosition.Y.Scale,
                nextPosition.Y.Offset + 7
            )
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            state.dragging = false
        end
    end)

    local tabs = create("Frame", {
        Size = UDim2.new(0, 112, 1, -46),
        Position = UDim2.new(0, 0, 0, 38),
        BackgroundColor3 = PANEL,
        BorderSizePixel = 0,
    }, window)

    -- hairline rail: the strip and the page area were butting into each other
    create("Frame", {
        Size = UDim2.new(0, 1, 1, -38),
        Position = UDim2.new(0, 112, 0, 38),
        BackgroundColor3 = LINE,
        BorderSizePixel = 0,
    }, window)

    local content = create("Frame", {
        Size = UDim2.new(1, -122, 1, -50),
        Position = UDim2.new(0, 112, 0, 42),
        BackgroundTransparency = 1,
    }, window)

    local TAB_IDLE = Color3.fromRGB(24, 24, 31)

    local pages = {}
    local buttons = {}

    -- Instance fields cannot be extended with custom keys, so the activator
    -- for each tab lives in a plain Lua table keyed by tab name
    local tabActivate = {}

    local function makePage(name)
        local frame = create("ScrollingFrame", {
            Name = name,
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = 2,
            ScrollBarImageColor3 = ACCENT,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Visible = false,
        }, content)

        create("UIListLayout", {
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }, frame)

        create("UIPadding", {
            PaddingTop = UDim.new(0, 4),
            PaddingRight = UDim.new(0, 6),
        }, frame)

        pages[name] = frame
        return frame
    end

    local function makeTab(name, order)
        local button = create("TextButton", {
            Size = UDim2.new(1, -12, 0, 28),
            Position = UDim2.new(0, 6, 0, 8 + (order - 1) * 32),
            BackgroundColor3 = TAB_IDLE,
            BorderSizePixel = 0,
            Font = Enum.Font.GothamMedium,
            Text = name,
            TextColor3 = MUTED,
            TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
            AutoButtonColor = false,
        }, tabs)
        corner(button, 4)

        create("UIPadding", { PaddingLeft = UDim.new(0, 11) }, button)

        local bar = create("Frame", {
            Size = UDim2.new(0, 2, 0, 0),
            Position = UDim2.new(0, 0, 0.5, 0),
            BackgroundColor3 = ACCENT,
            BorderSizePixel = 0,
        }, button)
        corner(bar, 1)

        -- active state is tracked as an attribute, so a hover can never
        -- repaint the selected tab back to idle
        local function activate(active)
            button:SetAttribute("active", active)
            button.BackgroundColor3 = active and PANEL_HI or TAB_IDLE
            button.TextColor3 = active and TEXT or MUTED
            bar.Size = UDim2.new(0, 2, active and 0.62 or 0, 0)
        end

        button.MouseButton1Click:Connect(function()
            for pageName, page in pairs(pages) do
                page.Visible = (pageName == name)
            end
            for tabName, setActive in pairs(tabActivate) do
                setActive(tabName == name)
            end
        end)

        button.MouseEnter:Connect(function()
            if not button:GetAttribute("active") then
                tween(button, { BackgroundColor3 = PANEL_LO, TextColor3 = TEXT })
            end
        end)
        button.MouseLeave:Connect(function()
            if not button:GetAttribute("active") then
                tween(button, { BackgroundColor3 = TAB_IDLE, TextColor3 = MUTED })
            end
        end)

        tabActivate[name] = activate
        buttons[name] = button
        return button
    end

    local aimPage = makePage("AIM")
    local visualPage = makePage("VISUAL")
    local compatibilityPage = makePage("FIX")
    local configPage = makePage("CONFIG")

    makeTab("AIM", 1)
    makeTab("VISUAL", 2)
    makeTab("FIX", 3)
    makeTab("CONFIG", 4)

    section(aimPage, "core")
    addToggle(aimPage, "Enabled", "AimEnabled", function(value)
        if not value then
            state.aiming = false
            state.target = nil
        end
    end)
    addCycle(aimPage, "Aim mode", "AimMode", { "Hold", "Toggle" })
    addKeybind(aimPage, "Bind", "KeyName")

    section(aimPage, "behaviour")
    addSlider(aimPage, "FOV", "FOV", 20, 400, 1, "px")
    addSlider(aimPage, "Smoothness", "Smoothness", 0, 100, 1)
    addCycle(aimPage, "Curve", "Curve", { "Linear", "Ease", "Human" })
    addSlider(aimPage, "Ramp in", "RampIn", 0, 0.4, 0.01, " s")
    addSlider(aimPage, "Max turn speed", "MaxTurnSpeed", 90, 3000, 10, " deg/s")
    addSlider(aimPage, "Deadzone", "Deadzone", 0, 3, 0.1, " deg")
    addSlider(aimPage, "Humanize", "Humanize", 0, 1, 0.05)
    addSlider(aimPage, "Max distance", "MaxDistance", 50, 1500, 25, " studs")
    addSlider(aimPage, "Prediction", "Prediction", 0, 0.4, 0.01, " s")
    addCycle(aimPage, "Aim part", "AimPart", { "Head", "UpperTorso", "HumanoidRootPart" })

    section(aimPage, "filters")
    addToggle(aimPage, "Team check", "TeamCheck")
    addToggle(aimPage, "Wall check", "WallCheck")
    addToggle(aimPage, "Skip knocked/downed", "KnockCheck")
    addToggle(aimPage, "Aim at NPCs/mobs/bots", "NPCs", refreshAll)
    addToggle(aimPage, "Mobs (no Humanoid)", "Mobs")
    addToggle(aimPage, "Role check", "RoleCheck")
    addCycle(aimPage, "Target role", "TargetRoles", { "All", "Murderer", "Sheriff", "Innocent" })

    section(visualPage, "reticle")
    addToggle(visualPage, "FOV circle", "FOVCircle")
    addSlider(visualPage, "Circle thickness", "CircleThickness", 1, 4, 1, "px")

    section(visualPage, "esp")
    addToggle(visualPage, "ESP", "ESP")
    addToggle(visualPage, "ESP boxes", "ESPBoxes")
    addToggle(visualPage, "ESP names", "ESPNames")
    addToggle(visualPage, "ESP team check", "ESPTeamCheck")
    addToggle(visualPage, "ESP NPCs/mobs/bots", "NPCs", refreshAll)
    addToggle(visualPage, "ESP hide knocked", "ESPKnockCheck")
    addToggle(visualPage, "ESP roles [M]/[S]", "ESPShowRoles")
    addSlider(visualPage, "ESP distance", "ESPMaxDistance", 50, 1500, 25, " studs")

    section(visualPage, "items")
    addToggle(visualPage, "ESP dropped gun", "GunESP")

    -- FIX tab: the switches that make it work in games that fight the camera
    section(compatibilityPage, "aim method")
    addCycle(compatibilityPage, "Aim method", "AimMethod", { "Auto", "Camera", "Mouse", "Subject" })
    addSlider(compatibilityPage, "Mouse gain", "MouseGain", 0.1, 3, 0.1)
    addSlider(compatibilityPage, "Mouse rate", "MouseRate", 10, 120, 5, " Hz")
    addSlider(compatibilityPage, "Mouse clamp", "MouseClamp", 5, 100, 5, " px")
    addToggle(compatibilityPage, "Auto fallback to mouse", "AutoFallback")

    section(compatibilityPage, "stability")
    addToggle(compatibilityPage, "Safe mode", "SafeMode")
    addSlider(compatibilityPage, "Render priority", "RenderPriority", 199, 2000, 1)
    addToggle(compatibilityPage, "Raycast collidable only", "CollidableOnly")
    addSlider(compatibilityPage, "Actor rescan", "NPCRate", 0.1, 2, 0.1, " s")
    addSlider(compatibilityPage, "Actor scan depth", "NPCDepth", 1, 4, 1)
    addSlider(compatibilityPage, "Role rescan", "RoleRate", 0.1, 2, 0.1, " s")
    addSlider(compatibilityPage, "Gun rescan", "GunRate", 0.1, 2, 0.1, " s")
    addKeybind(compatibilityPage, "Panic key", "PanicKey")

    section(compatibilityPage, "self test")
    addButton(compatibilityPage, "Test: camera write", nudgeCamera)
    addButton(compatibilityPage, "Test: mouse move", nudgeMouse)
    addButton(compatibilityPage, "Print diagnostic report", printReport)
    addToggle(compatibilityPage, "UI watchdog", "UIWatchdog")
    addToggle(compatibilityPage, "Telemetry heartbeat", "Telemetry")

    -- telemetry: one recessed console block, monospace, so six live values read
    -- as a single instrument instead of a column of loose labels
    section(compatibilityPage, "telemetry")
    local console = create("Frame", {
        Size = UDim2.new(1, -8, 0, 152),
        BackgroundColor3 = PANEL_LO,
        BorderSizePixel = 0,
    }, compatibilityPage)
    corner(console, 6)
    stroke(console, LINE, 1, 0.35)

    create("UIListLayout", {
        Padding = UDim.new(0, 2),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, console)

    create("UIPadding", {
        PaddingTop = UDim.new(0, 9),
        PaddingLeft = UDim.new(0, 9),
        PaddingRight = UDim.new(0, 9),
    }, console)

    for _, name in ipairs({ "camera", "aiming", "candidates", "resolution",
        "priority", "method", "roles", "error" }) do
        local debugRow = label(console, name .. ": -", 11, MUTED)
        debugRow.Size = UDim2.new(1, 0, 0, 15)
        debugRow.Font = Enum.Font.Code
        state.debugLabels[name] = debugRow
    end

    section(configPage, "profiles")
    addButton(configPage, "Save config", function()
        local ok = saveConfig()
        print(ok and "[ewanko] config saved" or "[ewanko] no filesystem access")
    end)

    addButton(configPage, "Load config", function()
        local ok = loadConfig()
        print(ok and "[ewanko] config loaded" or "[ewanko] no saved config")
    end)

    addButton(configPage, "Reset to defaults", function()
        for key, value in pairs(DEFAULTS) do
            if type(value) == "table" then
                local copy = {}
                for index, inner in ipairs(value) do copy[index] = inner end
                CONFIG[key] = copy
            else
                CONFIG[key] = value
            end
        end
        refreshAll()
    end)

    section(configPage, "system")
    addKeybind(configPage, "Menu key", "MenuKeyName")

    addButton(configPage, "Unload", function()
        if getgenv().EwankoUnload then getgenv().EwankoUnload() end
    end)

    local footer = label(configPage,
        "ewanko " .. VERSION .. "  ·  " .. CONFIG.AimMethod .. "  ·  "
            .. tostring(#Players:GetPlayers()) .. " players",
        10, MUTED, UDim2.new(0, 0, 0, 4))
    footer.Size = UDim2.new(1, -8, 0, 16)
    footer.Font = Enum.Font.Code
    footer.TextXAlignment = Enum.TextXAlignment.Center

    pages.AIM.Visible = true
    tabActivate.AIM(true)

    return gui
end

-- ======================================================================
-- input
-- ======================================================================

local gui = buildWindow()

-- Chrome state, refreshed off the render path: no UI work inside the aim loop.
task.spawn(function()
    while alive do
        task.wait(0.12)

        local status = state.statusLabel
        if status and gui and gui.Parent and status.text.Parent then
            local armed = CONFIG.AimEnabled
            local live  = armed and state.aiming

            status.text.Text = live and "AIMING"
                or (armed and (state.mouseMode and "MOUSE" or "ARMED"))
                or "IDLE"

            local colour = live and ACCENT or (armed and ACCENT_SOFT or MUTED)
            status.text.TextColor3 = colour
            status.dot.BackgroundColor3 = colour
        end
    end
end)

-- The game can hide, re-parent, or nuke unknown GUIs during a match. The
-- watchdog re-asserts the window instead of letting it vanish for the session.
local function uiParent()
    if gethui then
        local ok, hidden = pcall(gethui)
        if ok and hidden then return hidden end
    end
    return game:GetService("CoreGui")
end

local function ensureUI()
    if not alive or not gui then return end

    local ok = pcall(function()
        if gui.Parent == nil then
            local attached = pcall(function() gui.Parent = uiParent() end)
            if not attached or gui.Parent == nil then
                local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
                if playerGui then gui.Parent = playerGui end
            end
        end

        if not state.uiClosed and not gui.Enabled then
            gui.Enabled = true
        end
    end)

    if ok and gui.Parent ~= nil then return end

    if state.uiRebuilds >= 3 then return end
    state.uiRebuilds += 1
    gui = buildWindow()
    state.uiClosed = false
end

if CONFIG.UIWatchdog then
    task.spawn(function()
        while alive do
            task.wait(0.75)
            pcall(ensureUI)
        end
    end)
end

-- Heartbeat: whatever is printed last before the client dies names the stage.
task.spawn(function()
    while alive do
        task.wait(2)
        if CONFIG.Telemetry then
            print(("[ewanko] beat stage=%s mouse=%s aim=%s err=%d")
                :format(tostring(state.stage), tostring(state.mouseMode),
                    tostring(state.aiming), state.errorCount))
        end
    end
end)


local function aimPressed()
    if not CONFIG.AimEnabled then return end

    if CONFIG.AimMode == "Toggle" then
        state.aiming = not state.aiming
    else
        state.aiming = true
    end

    if state.aiming then
        state.aimStarted = os.clock()
    else
        releaseCamera()
    end
end

local function aimReleased()
    if CONFIG.AimMode == "Hold" then
        state.aiming = false
        releaseCamera()
    end
end

UserInputService.InputBegan:Connect(function(input, processed)
    if not alive then return end

    -- panic key is checked first and always: it must work even if the UI is gone
    if inputMatches(input, CONFIG.PanicKey) then
        if getgenv().EwankoUnload then getgenv().EwankoUnload() end
        return
    end

    if state.awaitingBind and state.bindArmed then
        local bind = bindFromInput(input)
        if bind then
            CONFIG[state.awaitingBind] = bind
            state.awaitingBind = nil
            state.bindArmed = false
            refreshAll()
            return
        end
    end

    if inputMatches(input, CONFIG.MenuKeyName) then
        gui.Enabled = not gui.Enabled
        state.uiClosed = not gui.Enabled
        return
    end

    if inputMatches(input, CONFIG.KeyName) then
        aimPressed()
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if inputMatches(input, CONFIG.KeyName) then
        aimReleased()
    end
end)

Players.PlayerRemoving:Connect(function(player)
    roleCache[player] = nil

    local character = player.Character
    local entry = character and state.esp[character]
    if entry then
        pcall(function()
            entry.box:Remove()
            entry.name:Remove()
        end)
        state.esp[character] = nil
    end
end)

-- ======================================================================
-- lifecycle
-- ======================================================================

if getgenv().EwankoUnload then
    pcall(getgenv().EwankoUnload)
end

RunService:BindToRenderStep("EwankoAimbot", CONFIG.RenderPriority, safeRender)

-- Second pass for games that drive their camera from RenderStepped: if the
-- frame's write was overwritten after the bind step, put it back. One CFrame
-- comparison per frame, no input injection.
RunService.RenderStepped:Connect(function()
    if not alive then return end
    if CONFIG.AimMethod ~= "Camera" then return end
    if not state.aiming or not state.lastWrite then return end

    local camera = currentCamera()
    if not camera then return end

    local current = camera.CFrame
    if current.LookVector:Dot(state.lastWrite.LookVector) > 0.999
        and (current.Position - state.lastWrite.Position).Magnitude < 0.05 then
        return
    end

    pcall(function() camera.CFrame = state.lastWrite end)
end)

getgenv().EwankoUnload = function()
    alive = false
    pcall(function() RunService:UnbindFromRenderStep("EwankoAimbot") end)
    releaseCamera()
    clearESP()
    if fovCircle then
        pcall(function() fovCircle:Remove() end)
        fovCircle = nil
    end
    pcall(function() gui:Destroy() end)
end

if isfile and isfile(CONFIG_FILE) then
    loadConfig()
end

print("[ewanko] " .. VERSION .. " bound — " .. CONFIG.AimMode .. " " .. CONFIG.KeyName
    .. " to aim, " .. CONFIG.MenuKeyName .. " for the menu, " .. CONFIG.PanicKey
    .. " to panic, aim method " .. CONFIG.AimMethod .. ".")
