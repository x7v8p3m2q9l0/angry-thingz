if not game:IsLoaded() then
    game.Loaded:Wait()
end
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

local this_thing=[[
	loadstring(game:HttpGet("https://raw.githubusercontent.com/x7v8p3m2q9l0/angry-thingz/refs/heads/main/feau.luau"))()
]]

--AuroraBorealis Blizzard CosmicShower Default Eruption Gravebound Rain Sandstorm Snowy Thunderstorm Underwater Valentines

if not _G.flaxeweather_GEAR then
	print("no weather selected")
else
	if table.find(_G.flaxeweather_GEAR, getWeatherList()) then
		if PlayerGui.HUD.MainHolder.TopHolder.WeatherDisplay.TextLabel.Text==_G.flaxeweather_GEAR then
			print("found")
			
		else
			if body and body.data then
				for i, v in next, body.data do
					if type(v) == "table" and tonumber(v.playing) and tonumber(v.maxPlayers) and v.playing < v.maxPlayers and v.id ~= JobId then
						table.insert(servers, 1, v.id)
					end
				end
			end

			if #servers > 0 then
				queue_on_teleport()
				TeleportService:TeleportToPlaceInstance(game.PlaceId, servers[math.random(1, #servers)], LocalPlayer)
			else
				return notify("Serverhop", "Couldn't find a server.")
			end
		end
	end
end

