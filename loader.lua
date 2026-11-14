-- Loader for kyle12314124/ewanko :: aimbot.lua
-- Paste into the executor, execute, done.

local OWNER, REPO, FILE = "kyle12314124", "ewanko", "aimbot.lua"
local BRANCHES = { "main", "master" }
local CACHE_BUST = "?v=" .. tostring(os.time())

local source, lastError

for _, branch in ipairs(BRANCHES) do
    local url = string.format(
        "https://raw.githubusercontent.com/%s/%s/%s/%s%s",
        OWNER, REPO, branch, FILE, CACHE_BUST
    )

    local ok, body = pcall(game.HttpGet, game, url)

    if ok and type(body) == "string" and #body > 0
        and not string.find(body, "404: Not Found", 1, true) then
        source = body
        break
    end

    lastError = body
end

if not source then
    warn("[aimbot] source unreachable: " .. tostring(lastError))
    return
end

local chunk, compileError = loadstring(source)

if not chunk then
    warn("[aimbot] compile failed: " .. tostring(compileError))
    return
end

chunk()
