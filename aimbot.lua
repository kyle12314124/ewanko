-- Roblox aimbot — camera lock, FOV gate, visibility check, bone select
-- Loaded by loader.lua from raw.githubusercontent.com

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")

local CONFIG = {
    Key           = Enum.KeyCode.Q,     -- hold to aim
    FOV           = 140,                -- pixels from screen centre
    Smooth        = 1,                  -- 1 = snap, 0.2 = heavy smoothing, 0 = off
    MaxDistance   = 600,                -- studs
    TeamCheck     = true,
    WallCheck     = true,
    AimPart       = "Head",             -- Head | UpperTorso | HumanoidRootPart
    Prediction    = 0,                  -- seconds of velocity lead
    ShowFOVCircle = true,
    CircleColor   = Color3.fromRGB(255, 255, 255),
}

local localPlayer = Players.LocalPlayer
if not localPlayer then
    repeat task.wait(0.1) until Players.LocalPlayer
    localPlayer = Players.LocalPlayer
end

local aiming = false
local fovCircle

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function currentCamera()
    return Workspace.CurrentCamera
end

local function screenCentre(camera)
    local viewport = camera.ViewportSize
    return Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
end

if CONFIG.ShowFOVCircle then
    local circleOk, circle = pcall(function()
        local c = Drawing.new("Circle")
        c.Thickness    = 1
        c.Transparency = 0.65
        c.NumSides     = 64
        c.Filled       = false
        c.Color        = CONFIG.CircleColor
        c.Visible      = false
        return c
    end)
    if circleOk then fovCircle = circle end
end

local function aimPartFor(character)
    return character:FindFirstChild(CONFIG.AimPart)
        or character:FindFirstChild("Head")
        or character:FindFirstChild("HumanoidRootPart")
end

local function isValidTarget(player)
    if player == localPlayer then return false end

    local character = player.Character
    if not character then return false end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return false end

    if CONFIG.TeamCheck
        and player.Team ~= nil
        and localPlayer.Team ~= nil
        and player.Team == localPlayer.Team then
        return false
    end

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

                                local hit = Workspace:Raycast(origin, world - origin, rayParams)
                                clear = (hit == nil)
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

local function onRender()
    local camera = currentCamera()
    if not camera then return end

    if fovCircle then
        fovCircle.Position = screenCentre(camera)
        fovCircle.Radius   = CONFIG.FOV
        fovCircle.Visible  = aiming
    end

    if not aiming then return end

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

if getgenv().AimbotUnload then
    pcall(getgenv().AimbotUnload)
end

RunService:BindToRenderStep("AimbotLock", Enum.RenderPriority.Camera.Value + 1, onRender)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == CONFIG.Key then
        aiming = true
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode == CONFIG.Key then
        aiming = false
    end
end)

getgenv().AimbotUnload = function()
    RunService:UnbindFromRenderStep("AimbotLock")
    if fovCircle then
        pcall(function() fovCircle:Remove() end)
    end
end

print("[aimbot] bound — hold Q to aim. unload: getgenv().AimbotUnload()")
