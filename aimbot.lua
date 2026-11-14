-- ewanko aimbot v3 — UI framework + aimbot + ESP
-- Luau / executor context. One file, no external UI library.

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local HttpService      = game:GetService("HttpService")
local Workspace        = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
if not localPlayer then
    repeat task.wait(0.1) until Players.LocalPlayer
    localPlayer = Players.LocalPlayer
end

local VERSION = "v3"

local CONFIG = {
    -- aim
    AimEnabled        = true,
    KeyName           = "Q",
    FOV               = 140,
    Smooth            = 1,
    MaxDistance       = 600,
    AimPart           = "Head",
    TeamCheck         = true,
    WallCheck         = true,
    Prediction        = 0,
    SelectInterval    = 0.03,
    RespectScriptable = true,

    -- visuals
    FOVCircle         = true,
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
    MaxErrors         = 20,
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
    awaitingBind = nil,
    nextScan     = 0,
    errorCount   = 0,
    esp          = {},
    refreshers   = {},
    dragging     = false,
    dragStart    = nil,
    dragOrigin   = nil,
}

local function keyCodeFor(name)
    return Enum.KeyCode[name] or Enum.KeyCode.Unknown
end

local function rgb(triple)
    return Color3.fromRGB(triple[1], triple[2], triple[3])
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

local function screenCentre(camera)
    local viewport = camera.ViewportSize
    return Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
end

if typeof(Drawing) == "table" then
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

                        if offset <= CONFIG.FOV and offset < bestScore then
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
                                best, bestScore = world, offset
                            end
                        end
                    end
                end
            end
        end
    end

    return best
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

local function onRender()
    local camera = currentCamera()
    if not camera then return end

    if fovCircle then
        fovCircle.Position  = screenCentre(camera)
        fovCircle.Radius    = CONFIG.FOV
        fovCircle.Color     = rgb(CONFIG.CircleColor)
        fovCircle.Thickness = CONFIG.CircleThickness
        fovCircle.Visible   = CONFIG.FOVCircle and (state.aiming or CONFIG.AimEnabled == false)
    end

    updateESP(camera)

    if not state.aiming or not CONFIG.AimEnabled then return end

    if CONFIG.RespectScriptable and camera.CameraType == Enum.CameraType.Scriptable then
        return
    end

    local now = os.clock()
    if now < state.nextScan then
        return
    end
    state.nextScan = now + CONFIG.SelectInterval

    local target = selectTarget()
    if not target then return end

    local origin  = camera.CFrame.Position
    local desired = CFrame.lookAt(origin, target)
    local alpha   = math.clamp(CONFIG.Smooth, 0, 1)

    if alpha >= 1 then
        camera.CFrame = desired
    elseif alpha > 0 then
        camera.CFrame = camera.CFrame:Lerp(desired, alpha)
    end
end

local function safeRender()
    local ok, err = pcall(onRender)
    if ok then return end

    state.errorCount += 1
    if state.errorCount >= CONFIG.MaxErrors then
        warn(("[ewanko] self-unbind after %d render errors: %s")
            :format(state.errorCount, tostring(err)))
        if getgenv().EwankoUnload then getgenv().EwankoUnload() end
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

    label(row, text, 13, TEXT)
        .Size = UDim2.new(1, -46, 1, 0)

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
        TextSize = 12,
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
        apply()
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
    local ok = pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode(CONFIG))
    end)
    return ok
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
        Size = UDim2.new(0, 470, 0, 330),
        Position = UDim2.new(0.5, -235, 0.5, -165),
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

    local title = create("TextLabel", {
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
    end)

    -- drag
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

    -- tab column
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
    local configPage = makePage("CONFIG")

    makeTab("AIM", 1)
    makeTab("VISUAL", 2)
    makeTab("CONFIG", 3)

    -- AIM
    addToggle(aimPage, "Enabled", "AimEnabled")
    addKeybind(aimPage, "Hold key", "KeyName")
    addSlider(aimPage, "FOV", "FOV", 20, 400, 1, "px")
    addSlider(aimPage, "Smooth", "Smooth", 0.05, 1, 0.05)
    addSlider(aimPage, "Max distance", "MaxDistance", 50, 1500, 25, " studs")
    addSlider(aimPage, "Prediction", "Prediction", 0, 0.4, 0.01, " s")
    addCycle(aimPage, "Aim part", "AimPart", { "Head", "UpperTorso", "HumanoidRootPart" })
    addToggle(aimPage, "Team check", "TeamCheck")
    addToggle(aimPage, "Wall check", "WallCheck")

    -- VISUAL
    addToggle(visualPage, "FOV circle", "FOVCircle")
    addSlider(visualPage, "Circle thickness", "CircleThickness", 1, 4, 1, "px")
    addToggle(visualPage, "ESP", "ESP")
    addToggle(visualPage, "ESP boxes", "ESPBoxes")
    addToggle(visualPage, "ESP names", "ESPNames")
    addToggle(visualPage, "ESP team check", "ESPTeamCheck")
    addSlider(visualPage, "ESP distance", "ESPMaxDistance", 50, 1500, 25, " studs")

    -- CONFIG
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

    -- first tab active
    pages.AIM.Visible = true
    buttons.AIM.BackgroundColor3 = ACCENT
    buttons.AIM.TextColor3 = Color3.new(1, 1, 1)

    return gui
end

-- ======================================================================
-- input
-- ======================================================================

local gui = buildWindow()

UserInputService.InputBegan:Connect(function(input, processed)
    if state.awaitingBind and input.UserInputType == Enum.UserInputType.Keyboard then
        CONFIG[state.awaitingBind] = input.KeyCode.Name
        state.awaitingBind = nil
        refreshAll()
        return
    end

    if processed then return end

    if input.KeyCode == keyCodeFor(CONFIG.MenuKeyName) and input.UserInputType == Enum.UserInputType.Keyboard then
        gui.Enabled = not gui.Enabled
    end

    if input.KeyCode == keyCodeFor(CONFIG.KeyName) and CONFIG.AimEnabled then
        state.aiming = true
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode == keyCodeFor(CONFIG.KeyName) then
        state.aiming = false
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

RunService:BindToRenderStep("EwankoAimbot", Enum.RenderPriority.Camera.Value + 1, safeRender)

getgenv().EwankoUnload = function()
    RunService:UnbindFromRenderStep("EwankoAimbot")
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

print("[ewanko] " .. VERSION .. " bound — hold " .. CONFIG.KeyName
    .. " to aim, " .. CONFIG.MenuKeyName .. " for the menu.")
