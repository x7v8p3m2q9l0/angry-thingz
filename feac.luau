if not game:IsLoaded() then
    game.Loaded:Wait()
end

_G.flaxeweather_HOP_ATTEMPTS = _G.flaxeweather_HOP_ATTEMPTS or 0
_G.flaxeweather_MAX_ATTEMPTS = 5

local ReplicatedStorage=game.ReplicatedStorage
local LocalPlayer=game.Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui
local HttpService=game:GetService("HttpService")
local TeleportService=game:GetService("TeleportService")
local servers = {}
local req = game:HttpGet("https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true")
local body = HttpService:JSONDecode(req)

local function getWeatherList()
    local tempList = {}
    if ReplicatedStorage then
        print("Weather: " .. #ReplicatedStorage.Weather:GetChildren() .. " children")
        for _, v in pairs(ReplicatedStorage.Weather:GetChildren()) do
            table.insert(tempList, v.Name)
        end
    else
        print("Plots folder not found in workspace")
    end
    table.sort(tempList)
    return tempList
end

local this_thing =
    "_G.flaxeweather_GEAR=\"" .. tostring(_G.flaxeweather_GEAR)..  "\"" .. "\n" ..
    "_G.flaxeweather_HOP_ATTEMPTS=" .. tostring(_G.flaxeweather_HOP_ATTEMPTS + 1) .. "\n" ..
    "_G.flaxeweather_MAX_ATTEMPTS=" .. tostring(_G.flaxeweather_MAX_ATTEMPTS) .. "\n" ..
    [[
if not game:IsLoaded() then
    game.Loaded:Wait()
end
task.wait(6)
loadstring(game:HttpGet("https://raw.githubusercontent.com/x7v8p3m2q9l0/angry-thingz/refs/heads/main/feac.luau"))()
]]

local function queue(code)
    if queue_on_teleport then
        queue_on_teleport(code)
    elseif syn and syn.queue_on_teleport then
        syn.queue_on_teleport(code)
    elseif fluxus and fluxus.queue_on_teleport then
        fluxus.queue_on_teleport(code)
    else
        warn("Teleport queue not supported in this executor")
    end
end

-- Check if maximum attempts reached
if _G.flaxeweather_HOP_ATTEMPTS >= _G.flaxeweather_MAX_ATTEMPTS then
    warn("Maximum server hop attempts reached (" .. _G.flaxeweather_MAX_ATTEMPTS .. "). Stopping.")
    return
end

if _G.flaxeweather_GEAR==nil then
    print("no weather selected")
else
    if table.find(getWeatherList(),_G.flaxeweather_GEAR) then
        if PlayerGui:WaitForChild('HUD'):WaitForChild('MainHolder'):WaitForChild('TopHolder'):WaitForChild('WeatherDisplay'):WaitForChild('TextLabel').Text==_G.flaxeweather_GEAR then
            print("Weather found! Stopping server hop.")
            _G.flaxeweather_HOP_ATTEMPTS = 0 -- Reset counter on success
        else
            print("Weather not found. Attempt " .. (_G.flaxeweather_HOP_ATTEMPTS + 1) .. " of " .. _G.flaxeweather_MAX_ATTEMPTS)
            
            if body and body.data then
                for i, v in next, body.data do
                    if type(v) == "table" and tonumber(v.playing) and tonumber(v.maxPlayers) and v.playing < (v.maxPlayers) and v.id ~= game.JobId then
                        table.insert(servers, 1, v.id)
                    end
                end
            end
            
            task.wait(2)
            
            if #servers > 0 then
                queue(this_thing)
                TeleportService:TeleportToPlaceInstance(game.PlaceId, servers[math.random(1, #servers)], LocalPlayer)
            else
                warn("Couldn't find a server.")
            end
        end
    end
end
