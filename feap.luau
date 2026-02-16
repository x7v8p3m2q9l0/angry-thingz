if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- ===== CONFIG =====
_G.flaxeweather_GEAR = "Valentines"

-- ===== SERVICES =====
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

-- ===== QUEUE COMPAT =====
local function queue(code)
    if queue_on_teleport then
        queue_on_teleport(code)
    elseif syn and syn.queue_on_teleport then
        syn.queue_on_teleport(code)
    elseif fluxus and fluxus.queue_on_teleport then
        fluxus.queue_on_teleport(code)
    else
        warn("Teleport queue not supported.")
    end
end

-- ===== LOADER TO RUN AFTER HOP =====
local this_thing = [[
    pcall(function()
        loadstring(game:HttpGet("https://raw.githubusercontent.com/x7v8p3m2q9l0/angry-thingz/refs/heads/main/feap.luau"))()
    end)
]]

-- ===== WEATHER LIST CHECK =====
local function getWeatherList()
    local list = {}
    local weatherFolder = ReplicatedStorage:FindFirstChild("Weather")

    if not weatherFolder then
        return list
    end

    for _, v in ipairs(weatherFolder:GetChildren()) do
        table.insert(list, v.Name)
    end

    table.sort(list)
    return list
end

-- ===== CURRENT WEATHER =====
local function getCurrentWeather(timeout)
    timeout = timeout or 15
    local start = tick()

    repeat
        local PlayerGui = LocalPlayer:FindFirstChild("PlayerGui")
        if PlayerGui then
            local label = PlayerGui:FindFirstChild("HUD", true)
            if label then
                local ok, result = pcall(function()
                    return PlayerGui.HUD.MainHolder.TopHolder.WeatherDisplay.TextLabel.Text
                end)

                if ok and result and result ~= "" then
                    return result
                end
            end
        end
        task.wait(0.5)
    until tick() - start > timeout

    return nil
end

-- ===== SERVER FETCH =====
local function getServers()
    local servers = {}

    local req = game:HttpGet(
        "https://games.roblox.com/v1/games/" ..
        game.PlaceId ..
        "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"
    )

    local body = HttpService:JSONDecode(req)

    if body and body.data then
        for _, v in ipairs(body.data) do
            if v.playing < v.maxPlayers and v.id ~= game.JobId then
                table.insert(servers, v.id)
            end
        end
    end

    return servers
end

-- ===== TELEPORT FAIL HANDLER =====
TeleportService.TeleportInitFailed:Connect(function(_, result)
    warn("Teleport failed:", result)
end)

-- ===== MAIN LOGIC =====
if not _G.flaxeweather_GEAR then
    warn("No weather selected.")
    return
end

if not table.find(getWeatherList(), _G.flaxeweather_GEAR) then
    warn("Weather not valid.")
    return
end

local currentWeather = getCurrentWeather()

if currentWeather == _G.flaxeweather_GEAR then
    print("Found target weather:", currentWeather)
    return
end

print("Weather mismatch:", currentWeather, " hopping")

local servers = getServers()

if #servers == 0 then
    warn("No servers available.")
    return
end

-- Shuffle servers
for i = #servers, 2, -1 do
    local j = math.random(i)
    servers[i], servers[j] = servers[j], servers[i]
end

queue(this_thing)

for _, serverId in ipairs(servers) do
    local success = pcall(function()
        TeleportService:TeleportToPlaceInstance(
            game.PlaceId,
            serverId,
            LocalPlayer
        )
    end)

    if success then
        break
    end

    task.wait(0.25)
end
