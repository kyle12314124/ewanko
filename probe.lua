-- ewanko probe — no UI, no render loop, no Drawing, no raycasts.
-- Three hotkeys, one action each, printed before they run.
-- Whatever prints last is the thing that killed the client.
--   F2 = one camera write        (tests: game owns the camera?)
--   F3 = one 40px mouse move     (tests: executor input hook?)
--   F4 = bind a single render step that writes the camera every frame

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")

local VERSION = "probe1"
local running = false

local function log(message)
    print("[probe] " .. message)
end

log(VERSION .. " loaded — F2 camera write, F3 mouse move, F4 render loop")

UserInputService.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

    if input.KeyCode == Enum.KeyCode.F2 then
        log("F2 pressed — writing camera CFrame once")
        local camera = Workspace.CurrentCamera
        if not camera then
            log("no camera, aborting")
            return
        end
        local ok, err = pcall(function()
            camera.CFrame = camera.CFrame * CFrame.Angles(0, math.rad(5), 0)
        end)
        log(ok and "camera write returned clean" or ("camera write threw: " .. tostring(err)))
    end

    if input.KeyCode == Enum.KeyCode.F3 then
        log("F3 pressed — calling mousemoverel(40, 0)")
        if type(mousemoverel) ~= "function" then
            log("mousemoverel missing in this executor")
            return
        end
        local ok, err = pcall(mousemoverel, 40, 0)
        log(ok and "mousemoverel returned clean" or ("mousemoverel threw: " .. tostring(err)))
    end

    if input.KeyCode == Enum.KeyCode.F4 then
        if running then
            pcall(function() RunService:UnbindFromRenderStep("EwankoProbe") end)
            running = false
            log("render loop stopped")
            return
        end

        running = true
        log("F4 pressed — binding render loop at priority 200, camera writes every frame")

        RunService:BindToRenderStep("EwankoProbe", Enum.RenderPriority.Camera.Value, function(dt)
            local camera = Workspace.CurrentCamera
            if not camera then return end
            pcall(function()
                camera.CFrame = camera.CFrame * CFrame.Angles(0, math.rad(0.5), 0)
            end)
        end)
    end
end)
