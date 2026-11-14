-- ewanko aimbot v9 — crash bisect build: safe boot, staged diagnostics,
-- telemetry heartbeat, camera/mouse nudge tests
-- Luau / executor context. One file, no external UI library.

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local Workspace        = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
if not localPlayer then
    repeat task.wait(0.1) until Players.LocalPlayer
    localPlayer = Players.LocalPlayer
end

local VERSION = "v10"

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

    -- aim method: mouse mode drives the game's own camera instead of writing CFrames
    AimMethod         = "Camera",   -- Auto | Camera | Mouse
    MouseGain         = 1.0,
    AutoFallback      = false,      -- off by default: input injection is the crash vector
    MouseRate         = 20,         -- max mousemoverel calls per second
    MouseClamp        = 15,         -- max pixels moved per call

    -- stability
    RenderPriority    = 200,        -- stock camera slot; raise only after a clean nudge test
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
    ESPMaxDistance    = 500,
    ESPBoxes          = true,
    ESPNames          = true,
    ESPColor          = { 255, 77, 141 },

    -- menu
    MenuKeyName       = "RightShift",
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
    esp          = {},
    refreshers   = {},
    dragging     = false,
    dragStart    = nil,
    dragOrigin   = nil,
    mouseMode    = false,
    prevAngle    = nil,
    stuckFrames  = 0,
    nextMouse    = 0,
    uiClosed     = false,
    uiRebuilds   = 0,
    stage        = "boot",
    debug        = { candidates = 0, blocked = 0, found = false },
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
local function claimCamera(camera)
    if state.savedCamera == nil then
        state.savedCamera = camera.CameraType
    end
    if camera.CameraType ~= Enum.CameraType.Scriptable then
        camera.CameraType = Enum.CameraType.Scriptable
    end
end

local function releaseCamera()
    if state.savedCamera == nil then return end

    local camera = currentCamera()
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

local function isValidTarget(player)
    if not isEnemy(player) then return false end

    local character = player.Character
    if not character then return false end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return false end

    return true
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
    debug.found      = false

    rayParams.RespectCanCollide = CONFIG.CollidableOnly

    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player) then
            local character = player.Character
            local part = aimPartFor(character)

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

                            if offset < bestScore then
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

    if not isFinite(fraction) then return end

    camera.CFrame = current:Lerp(desired, fraction)
end

local function angleToTarget(camera, world)
    local delta = world - camera.CFrame.Position
    if delta.Magnitude < 0.001 then return 0 end
    local dot = math.clamp(camera.LookVector:Dot(delta.Unit), -1, 1)
    return math.deg(math.acos(dot))
end

-- Drives the game's own camera by moving the mouse, for games that rebuild
-- Camera.CFrame themselves every frame and overwrite anything written to it.
-- Rate limited and pixel clamped: a hook that floods the client at frame rate
-- is what kills executors, so the call rate is a ceiling, not a target.
local function clampPixels(value, limit)
    if value > limit then return limit end
    if value < -limit then return -limit end
    return value
end

local function applyMouseAim(camera, targetPart, dt)
    if not hasMouseMove then return false end

    local now = os.clock()
    if now < state.nextMouse then return true end

    local step = 1 / math.max(CONFIG.MouseRate, 1)
    state.nextMouse = now + step

    local screen = camera:WorldToViewportPoint(targetPart.Position)
    if screen.Z <= 0 then return false end
    if not (isFinite(screen.X) and isFinite(screen.Y)) then return false end

    local centre = screenCentre(camera)
    local tau    = 0.008 + (CONFIG.Smoothness / 100) ^ 2 * 0.9
    local alpha  = 1 - math.exp(-step / tau)

    local errorX = screen.X - centre.X
    local errorY = screen.Y - centre.Y

    local dx = clampPixels(math.floor(errorX * CONFIG.MouseGain * alpha + 0.5), CONFIG.MouseClamp)
    local dy = clampPixels(math.floor(errorY * CONFIG.MouseGain * alpha + 0.5), CONFIG.MouseClamp)

    -- never let rounding stall the approach on a large remaining error
    if dx == 0 and math.abs(errorX) > 2 then dx = errorX > 0 and 1 or -1 end
    if dy == 0 and math.abs(errorY) > 2 then dy = errorY > 0 and 1 or -1 end

    if dx == 0 and dy == 0 then return true end

    local ok = pcall(mousemoverel, dx, dy)
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
end

local function updateESP(camera)
    if not CONFIG.ESP or typeof(Drawing) ~= "table" then
        for _, entry in pairs(state.esp) do hideESP(entry) end
        return
    end

    local origin = camera.CFrame.Position
    local colour = rgb(CONFIG.ESPColor)

    for _, player in ipairs(Players:GetPlayers()) do
        local entry = state.esp[player]

        local show = false
        if player ~= localPlayer then
            local character = player.Character
            local head  = character and character:FindFirstChild("Head")
            local root  = character and character:FindFirstChild("HumanoidRootPart")
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local enemy = (not CONFIG.ESPTeamCheck)
                or player.Team == nil
                or localPlayer.Team == nil
                or player.Team ~= localPlayer.Team

            if head and root and humanoid and humanoid.Health > 0 and enemy then
                local distance = (root.Position - origin).Magnitude

                if distance <= CONFIG.ESPMaxDistance then
                    local top, topOk    = camera:WorldToViewportPoint(head.Position + Vector3.new(0, 0.6, 0))
                    local bottom, botOk = camera:WorldToViewportPoint(root.Position - Vector3.new(0, 2.6, 0))

                    if topOk and botOk and top.Z > 0 and bottom.Z > 0 then
                        if not entry then
                            entry = newESPEntry()
                            state.esp[player] = entry
                        end

                        if entry then
                            local height = math.abs(bottom.Y - top.Y)
                            local width  = height * 0.6

                            entry.box.Position = Vector2.new(top.X - width * 0.5, top.Y)
                            entry.box.Size     = Vector2.new(width, height)
                            entry.box.Color    = colour
                            entry.box.Visible  = CONFIG.ESPBoxes

                            entry.name.Text     = player.Name
                            entry.name.Position = Vector2.new(top.X, top.Y - 16)
                            entry.name.Color    = colour
                            entry.name.Visible  = CONFIG.ESPNames

                            show = CONFIG.ESPBoxes or CONFIG.ESPNames
                        end
                    end
                end
            end
        end

        if not show then hideESP(entry) end
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

    labels.camera.Text = "camera: " .. tostring(camera.CameraType)
    labels.aiming.Text = "aiming: " .. tostring(state.aiming)
        .. "  target: " .. tostring(debug.found)
    labels.candidates.Text = "in FOV: " .. tostring(debug.candidates)
        .. "  wall-blocked: " .. tostring(debug.blocked)
    labels.resolution.Text = ("viewport: %d x %d"):format(
        math.floor(camera.ViewportSize.X), math.floor(camera.ViewportSize.Y))
    labels.priority.Text = "render priority: " .. tostring(CONFIG.RenderPriority)
    labels.method.Text = "method: " .. (state.mouseMode and "mouse" or "camera")
        .. "  (" .. CONFIG.AimMethod .. ")"
        .. "  stuck: " .. tostring(state.stuckFrames)
        .. (hasMouseMove and "" or "  [no mousemoverel]")
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
        releaseCamera()
        return
    end

    local useMouse = CONFIG.AimMethod == "Mouse"
        or (CONFIG.AimMethod == "Auto" and state.mouseMode)

    if not useMouse then
        claimCamera(camera)

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
        applyAim(camera, part, dt)
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

local ACCENT = Color3.fromRGB(255, 77, 141)
local BG     = Color3.fromRGB(13, 13, 17)
local PANEL  = Color3.fromRGB(21, 21, 27)
local TEXT   = Color3.fromRGB(235, 235, 242)
local MUTED  = Color3.fromRGB(120, 120, 132)

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

local function stroke(inst, colour, thickness)
    create("UIStroke", {
        Color = colour or Color3.fromRGB(40, 40, 50),
        Thickness = thickness or 1,
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
        Position = position or UDim2.new(0, 0, 0, 0),
        Size = UDim2.new(1, 0, 1, 0),
    }, parent)
end

-- ======================================================================
-- controls
-- ======================================================================

local function addToggle(parent, text, key, onChange)
    local row = create("Frame", {
        Size = UDim2.new(1, -8, 0, 26),
        BackgroundTransparency = 1,
    }, parent)

    label(row, text, 13, TEXT).Size = UDim2.new(1, -46, 1, 0)

    local pill = create("Frame", {
        Size = UDim2.new(0, 34, 0, 18),
        Position = UDim2.new(1, -34, 0.5, -9),
        BackgroundColor3 = CONFIG[key] and ACCENT or Color3.fromRGB(45, 45, 55),
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
    }, row)

    local function apply()
        pill.BackgroundColor3 = CONFIG[key] and ACCENT or Color3.fromRGB(45, 45, 55)
        dot.Position = CONFIG[key] and UDim2.new(0, 18, 0, 2) or UDim2.new(0, 2, 0, 2)
    end

    hit.MouseButton1Click:Connect(function()
        CONFIG[key] = not CONFIG[key]
        apply()
        if onChange then onChange(CONFIG[key]) end
    end)

    table.insert(state.refreshers, apply)
    apply()
    return row
end

local function addSlider(parent, text, key, min, max, step, suffix)
    local row = create("Frame", {
        Size = UDim2.new(1, -8, 0, 40),
        BackgroundTransparency = 1,
    }, parent)

    local title = label(row, text, 13, TEXT)
    title.Size = UDim2.new(1, -60, 0, 16)

    local valueLabel = create("TextLabel", {
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = "",
        TextColor3 = MUTED,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right,
        Position = UDim2.new(0, 0, 0, 0),
        Size = UDim2.new(1, 0, 0, 16),
    }, row)

    local track = create("Frame", {
        Size = UDim2.new(1, 0, 0, 6),
        Position = UDim2.new(0, 0, 0, 26),
        BackgroundColor3 = Color3.fromRGB(40, 40, 50),
        BorderSizePixel = 0,
    }, row)
    corner(track, 3)

    local fill = create("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = ACCENT,
        BorderSizePixel = 0,
    }, track)
    corner(fill, 3)

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
        local alpha = (CONFIG[key] - min) / (max - min)
        fill.Size = UDim2.new(math.clamp(alpha, 0, 1), 0, 1, 0)
        describe()
    end

    local function setFromX(x)
        local alpha = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        local value = min + alpha * (max - min)
        if step and step > 0 then
            value = math.floor(value / step + 0.5) * step
        end
        CONFIG[key] = math.clamp(value, min, max)
        apply()
    end

    track.InputBegan:Connect(function(input)
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

    table.insert(state.refreshers, apply)
    apply()
    return row
end

local function addCycle(parent, text, key, options)
    local row = create("Frame", {
        Size = UDim2.new(1, -8, 0, 26),
        BackgroundTransparency = 1,
    }, parent)

    label(row, text, 13, TEXT).Size = UDim2.new(1, -110, 1, 0)

    local button = create("TextButton", {
        Size = UDim2.new(0, 100, 0, 20),
        Position = UDim2.new(1, -100, 0.5, -10),
        BackgroundColor3 = Color3.fromRGB(32, 32, 40),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        Text = tostring(CONFIG[key]),
        TextColor3 = TEXT,
        TextSize = 12,
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

    table.insert(state.refreshers, apply)
    apply()
    return row
end

local function addKeybind(parent, text, key)
    local row = create("Frame", {
        Size = UDim2.new(1, -8, 0, 26),
        BackgroundTransparency = 1,
    }, parent)

    label(row, text, 13, TEXT).Size = UDim2.new(1, -110, 1, 0)

    local button = create("TextButton", {
        Size = UDim2.new(0, 100, 0, 20),
        Position = UDim2.new(1, -100, 0.5, -10),
        BackgroundColor3 = Color3.fromRGB(32, 32, 40),
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

    table.insert(state.refreshers, apply)
    apply()
    return row
end

local function addButton(parent, text, onClick)
    local button = create("TextButton", {
        Size = UDim2.new(1, -8, 0, 26),
        BackgroundColor3 = Color3.fromRGB(32, 32, 40),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        Text = text,
        TextColor3 = TEXT,
        TextSize = 12,
        AutoButtonColor = false,
    }, parent)
    corner(button, 4)

    button.MouseButton1Click:Connect(onClick)
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
    print("in FOV:", state.debug.candidates, "wall-blocked:", state.debug.blocked)
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

    local window = create("Frame", {
        Name = "Window",
        Size = UDim2.new(0, 480, 0, 340),
        Position = UDim2.new(0.5, -240, 0.5, -170),
        BackgroundColor3 = BG,
        BorderSizePixel = 0,
        ClipsDescendants = true,
    }, gui)
    corner(window, 8)
    stroke(window, Color3.fromRGB(38, 38, 48))

    local titleBar = create("Frame", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundColor3 = PANEL,
        BorderSizePixel = 0,
    }, window)

    create("TextLabel", {
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = "ewanko  " .. VERSION,
        TextColor3 = TEXT,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.new(0, 12, 0, 0),
        Size = UDim2.new(1, -60, 1, 0),
    }, titleBar)

    local close = create("TextButton", {
        Size = UDim2.new(0, 26, 0, 20),
        Position = UDim2.new(1, -32, 0.5, -10),
        BackgroundColor3 = Color3.fromRGB(40, 40, 50),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Text = "x",
        TextColor3 = TEXT,
        TextSize = 12,
        AutoButtonColor = false,
    }, titleBar)
    corner(close, 4)

    close.MouseButton1Click:Connect(function()
        gui.Enabled = not gui.Enabled
        state.uiClosed = not gui.Enabled
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
            window.Position = UDim2.new(
                state.dragOrigin.X.Scale,
                state.dragOrigin.X.Offset + delta.X,
                state.dragOrigin.Y.Scale,
                state.dragOrigin.Y.Offset + delta.Y
            )
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            state.dragging = false
        end
    end)

    local tabs = create("Frame", {
        Size = UDim2.new(0, 112, 1, -30),
        Position = UDim2.new(0, 0, 0, 30),
        BackgroundColor3 = PANEL,
        BorderSizePixel = 0,
    }, window)

    local content = create("Frame", {
        Size = UDim2.new(1, -122, 1, -40),
        Position = UDim2.new(0, 112, 0, 34),
        BackgroundTransparency = 1,
    }, window)

    local pages = {}
    local buttons = {}

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
            Size = UDim2.new(1, -12, 0, 26),
            Position = UDim2.new(0, 6, 0, 6 + (order - 1) * 30),
            BackgroundColor3 = Color3.fromRGB(28, 28, 36),
            BorderSizePixel = 0,
            Font = Enum.Font.GothamMedium,
            Text = name,
            TextColor3 = MUTED,
            TextSize = 12,
            AutoButtonColor = false,
        }, tabs)
        corner(button, 4)

        button.MouseButton1Click:Connect(function()
            for pageName, page in pairs(pages) do
                page.Visible = (pageName == name)
            end
            for tabName, tabButton in pairs(buttons) do
                tabButton.BackgroundColor3 = (tabName == name)
                    and ACCENT
                    or Color3.fromRGB(28, 28, 36)
                tabButton.TextColor3 = (tabName == name) and Color3.new(1, 1, 1) or MUTED
            end
        end)

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

    addToggle(aimPage, "Enabled", "AimEnabled", function(value)
        if not value then
            state.aiming = false
            state.target = nil
        end
    end)
    addCycle(aimPage, "Aim mode", "AimMode", { "Hold", "Toggle" })
    addKeybind(aimPage, "Bind", "KeyName")
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
    addToggle(aimPage, "Team check", "TeamCheck")
    addToggle(aimPage, "Wall check", "WallCheck")

    addToggle(visualPage, "FOV circle", "FOVCircle")
    addSlider(visualPage, "Circle thickness", "CircleThickness", 1, 4, 1, "px")
    addToggle(visualPage, "ESP", "ESP")
    addToggle(visualPage, "ESP boxes", "ESPBoxes")
    addToggle(visualPage, "ESP names", "ESPNames")
    addToggle(visualPage, "ESP team check", "ESPTeamCheck")
    addSlider(visualPage, "ESP distance", "ESPMaxDistance", 50, 1500, 25, " studs")

    -- FIX tab: the switches that make it work in games that fight the camera
    addCycle(compatibilityPage, "Aim method", "AimMethod", { "Auto", "Camera", "Mouse" })
    addSlider(compatibilityPage, "Mouse gain", "MouseGain", 0.1, 3, 0.1)
    addSlider(compatibilityPage, "Mouse rate", "MouseRate", 10, 120, 5, " Hz")
    addSlider(compatibilityPage, "Mouse clamp", "MouseClamp", 5, 100, 5, " px")
    addToggle(compatibilityPage, "Auto fallback to mouse", "AutoFallback")
    addToggle(compatibilityPage, "Safe mode", "SafeMode")
    addSlider(compatibilityPage, "Render priority", "RenderPriority", 200, 2000, 50)
    addToggle(compatibilityPage, "Raycast collidable only", "CollidableOnly")
    addKeybind(compatibilityPage, "Panic key", "PanicKey")
    addButton(compatibilityPage, "Test: camera write", nudgeCamera)
    addButton(compatibilityPage, "Test: mouse move", nudgeMouse)
    addToggle(compatibilityPage, "UI watchdog", "UIWatchdog")
    addToggle(compatibilityPage, "Telemetry heartbeat", "Telemetry")
    addButton(compatibilityPage, "Print diagnostic report", printReport)

    state.debugLabels.camera = label(compatibilityPage, "camera: -", 11, MUTED)
    state.debugLabels.aiming = label(compatibilityPage, "aiming: -", 11, MUTED)
    state.debugLabels.candidates = label(compatibilityPage, "in FOV: -", 11, MUTED)
    state.debugLabels.resolution = label(compatibilityPage, "viewport: -", 11, MUTED)
    state.debugLabels.priority = label(compatibilityPage, "render priority: -", 11, MUTED)
    state.debugLabels.method = label(compatibilityPage, "method: -", 11, MUTED)
    state.debugLabels.error = label(compatibilityPage, "last error: -", 11, MUTED)

    for _, debugLabel in pairs(state.debugLabels) do
        debugLabel.Size = UDim2.new(1, -8, 0, 16)
    end

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

    addKeybind(configPage, "Menu key", "MenuKeyName")

    addButton(configPage, "Unload", function()
        if getgenv().EwankoUnload then getgenv().EwankoUnload() end
    end)

    label(configPage, "ewanko " .. VERSION .. " — " .. tostring(#Players:GetPlayers()) .. " players",
        11, MUTED).Size = UDim2.new(1, -8, 0, 18)

    pages.AIM.Visible = true
    buttons.AIM.BackgroundColor3 = ACCENT
    buttons.AIM.TextColor3 = Color3.new(1, 1, 1)

    return gui
end

-- ======================================================================
-- input
-- ======================================================================

local gui = buildWindow()

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
    local entry = state.esp[player]
    if entry then
        pcall(function()
            entry.box:Remove()
            entry.name:Remove()
        end)
        state.esp[player] = nil
    end
end)

-- ======================================================================
-- lifecycle
-- ======================================================================

if getgenv().EwankoUnload then
    pcall(getgenv().EwankoUnload)
end

RunService:BindToRenderStep("EwankoAimbot", CONFIG.RenderPriority, safeRender)

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
