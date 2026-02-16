if not game:IsLoaded() then
    game.Loaded:Wait()
end

_G.flaxeweather_GEAR = "Valentines"

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer

-- queue compatibility
local function queue(code)
    if queue_on_teleport then
        queue_on_teleport(code)
    elseif syn and syn.queue_on_teleport then
        syn.queue_on_teleport(code)
    end
end

local this_thing = [[
    loadstring(game:HttpGet("https://raw.githubusercontent.com/x7v8p3m2q9l0/angry-thingz/refs/heads/main/fecy.luau"))()
]]

-- get weather once
local function getWeather()
    local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
    local label = PlayerGui:WaitForChild("HUD")
        :WaitForChild("MainHolder")
        :WaitForChild("TopHolder")
        :WaitForChild("WeatherDisplay")
        :WaitForChild("TextLabel")

    return label.Text
end

task.wait(3)

local current = getWeather()
if current == _G.flaxeweather_GEAR then
    print("Found:", current)
    return
end

-- fetch servers (smaller list for stability)
local req = game:HttpGet(
    "https://games.roblox.com/v1/games/" ..
    game.PlaceId ..
    "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"
)

local body = HttpService:JSONDecode(req)
if not body or not body.data then
    warn("Failed to fetch servers")
    return
end

local servers = {}
for _, v in ipairs(body.data) do
    if v.playing < v.maxPlayers and v.id ~= game.JobId then
        table.insert(servers, v.id)
    end
end

if #servers == 0 then
    warn("No available servers")
    return
end

local index = 1

local function attemptTeleport()
    if index > #servers then
        warn("All servers attempted")
        return
    end

    queue(this_thing)
    TeleportService:TeleportToPlaceInstance(
        game.PlaceId,
        servers[index],
        LocalPlayer
    )
end

TeleportService.TeleportInitFailed:Connect(function(player, result)
    index += 1
    task.wait(0.5)
    attemptTeleport()
end)

attemptTeleport()
