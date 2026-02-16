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

local function createHopUI()
    -- Create ScreenGui
    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "WeatherHopUI"
    ScreenGui.ResetOnSpawn = false
    ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ScreenGui.Parent = PlayerGui
    
    -- Create Frame
    local Frame = Instance.new("Frame")
    Frame.Size = UDim2.new(0, 300, 0, 150)
    Frame.Position = UDim2.new(0.5, -150, 0.5, -75)
    Frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    Frame.BorderSizePixel = 0
    Frame.Parent = ScreenGui
    
    -- Add UICorner
    local UICorner = Instance.new("UICorner")
    UICorner.CornerRadius = UDim.new(0, 8)
    UICorner.Parent = Frame
    
    -- Create Title
    local Title = Instance.new("TextLabel")
    Title.Size = UDim2.new(1, 0, 0, 40)
    Title.BackgroundTransparency = 1
    Title.Text = "Weather Mismatch"
    Title.TextColor3 = Color3.fromRGB(255, 255, 255)
    Title.TextSize = 18
    Title.Font = Enum.Font.GothamBold
    Title.Parent = Frame
    
    -- Create Message
    local Message = Instance.new("TextLabel")
    Message.Size = UDim2.new(1, -20, 0, 40)
    Message.Position = UDim2.new(0, 10, 0, 40)
    Message.BackgroundTransparency = 1
    Message.Text = "Current weather is not " .. _G.flaxeweather_GEAR .. "\nServer hop to find it?"
    Message.TextColor3 = Color3.fromRGB(200, 200, 200)
    Message.TextSize = 14
    Message.Font = Enum.Font.Gotham
    Message.TextWrapped = true
    Message.Parent = Frame
    
    -- Create Yes Button
    local YesButton = Instance.new("TextButton")
    YesButton.Size = UDim2.new(0, 120, 0, 35)
    YesButton.Position = UDim2.new(0.5, -130, 1, -45)
    YesButton.BackgroundColor3 = Color3.fromRGB(0, 170, 0)
    YesButton.Text = "Yes"
    YesButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    YesButton.TextSize = 16
    YesButton.Font = Enum.Font.GothamBold
    YesButton.BorderSizePixel = 0
    YesButton.Parent = Frame
    
    local YesCorner = Instance.new("UICorner")
    YesCorner.CornerRadius = UDim.new(0, 6)
    YesCorner.Parent = YesButton
    
    -- Create No Button
    local NoButton = Instance.new("TextButton")
    NoButton.Size = UDim2.new(0, 120, 0, 35)
    NoButton.Position = UDim2.new(0.5, 10, 1, -45)
    NoButton.BackgroundColor3 = Color3.fromRGB(170, 0, 0)
    NoButton.Text = "No"
    NoButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    NoButton.TextSize = 16
    NoButton.Font = Enum.Font.GothamBold
    NoButton.BorderSizePixel = 0
    NoButton.Parent = Frame
    
    local NoCorner = Instance.new("UICorner")
    NoCorner.CornerRadius = UDim.new(0, 6)
    NoCorner.Parent = NoButton
    
    return ScreenGui, YesButton, NoButton
end

local function serverHop()
    if body and body.data then
        for i, v in next, body.data do
            if type(v) == "table" and tonumber(v.playing) and tonumber(v.maxPlayers) and v.playing < (v.maxPlayers) and v.id ~= game.JobId then
                table.insert(servers, 1, v.id)
            end
        end
    end
    
    if #servers > 0 then
        queue(this_thing)
        TeleportService:TeleportToPlaceInstance(game.PlaceId, servers[math.random(1, #servers)], LocalPlayer)
    else
        print("Couldn't find a server.")
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
            -- Create UI and wait for user input
            local gui, yesBtn, noBtn = createHopUI()
            
            local choice = nil
            yesBtn.MouseButton1Click:Connect(function()
                choice = true
                gui:Destroy()
            end)
            
            noBtn.MouseButton1Click:Connect(function()
                choice = false
                gui:Destroy()
            end)
            
            -- Wait for user choice
            while choice == nil do
                task.wait(0.1)
            end
            
            if choice then
                task.wait(1) -- Brief delay before hopping
                serverHop()
            else
                print("User chose not to server hop")
            end
        end
    end
end
