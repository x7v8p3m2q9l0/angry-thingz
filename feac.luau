if not game:IsLoaded() then
    game.Loaded:Wait()
end
_G.flaxeweather_GEAR="Rain"
local ReplicatedStorage=game.ReplicatedStorage
local LocalPlayer=game.Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui
local HttpService=game:GetService("HttpService")
local TeleportService=game:GetService("TeleportService")
local servers = {}
local req = game:HttpGet("https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true")
local body = HttpService:JSONDecode(req)
local function getWeatherList()
    local tempList = {}  -- Use a local table to build the list
    if ReplicatedStorage then
        print("Weather: " .. #ReplicatedStorage.Weather:GetChildren() .. " children")  -- Debug: Check if folder exists and has children
        -- Loop through each Weather in the Plots folder
        for _, v in pairs(ReplicatedStorage.Weather:GetChildren()) do
            table.insert(tempList, v.Name)  -- Add the name to the table
        end
    else
        print("Plots folder not found in workspace")  -- Debug: If folder doesn't exist
    end
    table.sort(tempList)  -- Sort the list alphabetically
    return tempList
end

local this_thing =
    "_G.flaxeweather_GEAR=\"" .. tostring(_G.flaxeweather_GEAR)..  "\"" .. [[
if not game:IsLoaded() then
    game.Loaded:Wait()
end
task.wait(2)
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

--AuroraBorealis Blizzard CosmicShower Default Eruption Gravebound Rain Sandstorm Snowy Thunderstorm Underwater Valentines

if _G.flaxeweather_GEAR==nil then
	print("no weather selected")
else
	if table.find(getWeatherList(),_G.flaxeweather_GEAR) then
		if PlayerGui:WaitForChild('HUD'):WaitForChild('MainHolder'):WaitForChild('TopHolder'):WaitForChild('WeatherDisplay'):WaitForChild('TextLabel').Text==_G.flaxeweather_GEAR then
			print("found")
			
		else
			if body and body.data then
				for i, v in next, body.data do
					if type(v) == "table" and tonumber(v.playing) and tonumber(v.maxPlayers) and v.playing < (v.maxPlayers) and v.id ~= game.JobId then
						table.insert(servers, 1, v.id)
					end
				end
			end
			task.wait(5) -- avoid shits
			if #servers > 0 then
				queue(this_thing)
				TeleportService:TeleportToPlaceInstance(game.PlaceId, servers[math.random(1, #servers)], LocalPlayer)
			else
				return print("Couldn't find a server.")
			end
		end
	end
end
