-- GPS Tracker Client for OpenComputers 1.7.10
-- Tracks and broadcasts player location
-- Can query locations of other entities
-- Requires linked card to connect to relay

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local term = require("term")
local computer = require("computer")
local gpu = component.gpu
local unicode = require("unicode")

-- Check for required components
if not component.isAvailable("tunnel") then
    print("═══════════════════════════════════════════════════════")
    print("ERROR: LINKED CARD REQUIRED!")
    print("═══════════════════════════════════════════════════════")
    return
end

local tunnel = component.tunnel

-- Check for Navigation Upgrade or Debug Card for position detection
local hasNav = component.isAvailable("navigation")
local hasDebug = component.isAvailable("debug")
local nav = hasNav and component.navigation or nil
local debug = hasDebug and component.debug or nil

-- State
local entityId = tunnel.address  -- Use tunnel address as unique ID
local entityName = nil
local myPosition = {x = 0, y = 0, z = 0, dimension = "overworld"}
local relayConnected = false
local autoUpdate = false
local updateInterval = 5  -- seconds

-- UI Config
local w, h = gpu.getResolution()
gpu.setResolution(80, 25)
w, h = 80, 25

-- Color scheme
local colors = {
    bg = 0x0F0F0F,
    header = 0x1E3A8A,
    accent = 0x3B82F6,
    success = 0x10B981,
    error = 0xEF4444,
    warning = 0xF59E0B,
    text = 0xFFFFFF,
    textDim = 0x9CA3AF,
    border = 0x374151,
    inputBg = 0x1F2937
}

-- Draw functions
local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
end

local function drawBox(x, y, width, height, color, title)
    gpu.setBackground(color or colors.bg)
    gpu.fill(x, y, width, height, " ")
    
    if title then
        gpu.setBackground(colors.header)
        gpu.fill(x, y, width, 1, " ")
        gpu.setForeground(colors.text)
        local titleX = x + math.floor((width - unicode.len(title)) / 2)
        gpu.set(titleX, y, title)
        gpu.setBackground(color or colors.bg)
    end
end

local function drawHeader(title, subtitle)
    gpu.setBackground(colors.header)
    gpu.fill(1, 1, w, 3, " ")
    
    gpu.setForeground(colors.text)
    local titleX = math.floor((w - unicode.len(title)) / 2)
    gpu.set(titleX, 2, title)
    
    if subtitle then
        gpu.setForeground(colors.textDim)
        local subX = math.floor((w - unicode.len(subtitle)) / 2)
        gpu.set(subX, 3, subtitle)
    end
    
    gpu.setBackground(colors.bg)
end

local function drawFooter(text)
    gpu.setBackground(colors.border)
    gpu.fill(1, h, w, 1, " ")
    gpu.setForeground(colors.textDim)
    gpu.set(2, h, text)
    gpu.setBackground(colors.bg)
end

local function showStatus(msg, msgType)
    msgType = msgType or "info"
    local color = colors.text
    
    if msgType == "success" then color = colors.success
    elseif msgType == "error" then color = colors.error
    elseif msgType == "warning" then color = colors.warning
    end
    
    gpu.setBackground(colors.bg)
    gpu.fill(1, h - 1, w, 1, " ")
    gpu.setForeground(color)
    local msgX = math.floor((w - unicode.len(msg)) / 2)
    gpu.set(msgX, h - 1, msg)
    gpu.setForeground(colors.text)
end

local function input(prompt, y, hidden, maxLen)
    maxLen = maxLen or 30
    gpu.setForeground(colors.text)
    gpu.set(2, y, prompt)
    
    local x = 2 + unicode.len(prompt)
    gpu.setBackground(colors.inputBg)
    gpu.fill(x, y, maxLen + 2, 1, " ")
    
    x = x + 1
    gpu.set(x, y, "")
    
    local text = ""
    while true do
        local _, _, char, code = event.pull("key_down")
        
        if code == 28 then break
        elseif code == 14 and unicode.len(text) > 0 then
            text = unicode.sub(text, 1, -2)
            gpu.setBackground(colors.inputBg)
            gpu.fill(x, y, maxLen, 1, " ")
            if hidden then
                gpu.set(x, y, string.rep("•", unicode.len(text)))
            else
                gpu.set(x, y, text)
            end
        elseif char >= 32 and char < 127 and unicode.len(text) < maxLen then
            text = text .. string.char(char)
            if hidden then
                gpu.set(x, y, string.rep("•", unicode.len(text)))
            else
                gpu.set(x, y, text)
            end
        end
    end
    
    gpu.setBackground(colors.bg)
    return text
end

-- Send message and wait for response
local function sendAndWait(data, timeout)
    timeout = timeout or 5
    
    if not relayConnected then
        return {
            type = "response",
            success = false,
            message = "Not connected to relay"
        }
    end
    
    data.tunnelAddress = tunnel.address
    data.tunnelChannel = tunnel.getChannel()
    
    local message = serialization.serialize(data)
    tunnel.send(message)
    
    local deadline = computer.uptime() + timeout
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, _, port, distance, msg = table.unpack(eventData)
            
            local isTunnel = (port == 0 or distance == nil or distance == math.huge)
            
            if isTunnel then
                local success, response = pcall(serialization.unserialize, msg)
                if success and response and response.type == "response" then
                    return response
                end
            end
        end
    end
    
    return nil
end

-- Get current position
local function getCurrentPosition()
    if nav then
        -- Use Navigation Upgrade
        local pos = nav.getPosition()
        if pos then
            myPosition.x = math.floor(pos[1])
            myPosition.y = math.floor(pos[2])
            myPosition.z = math.floor(pos[3])
            return true
        end
    elseif debug then
        -- Use Debug Card
        local players = debug.getPlayers()
        if players and #players > 0 then
            -- Assume first player is owner
            local player = debug.getPlayer(players[1])
            if player then
                myPosition.x = math.floor(player.x)
                myPosition.y = math.floor(player.y)
                myPosition.z = math.floor(player.z)
                myPosition.dimension = player.dimension or "overworld"
                return true
            end
        end
    end
    
    return false
end

-- Update location on server
local function updateLocation()
    if not getCurrentPosition() then
        return false, "Cannot detect position"
    end
    
    local response = sendAndWait({
        command = "update_location",
        entityId = entityId,
        name = entityName or entityId:sub(1, 8),
        x = myPosition.x,
        y = myPosition.y,
        z = myPosition.z,
        dimension = myPosition.dimension,
        entityType = "player"
    })
    
    if response and response.success then
        return true
    else
        return false, response and response.message or "No response"
    end
end

-- Register with relay
local function registerWithRelay()
    clearScreen()
    drawHeader("◆ CONNECTING TO GPS RELAY ◆", "Establishing tunnel connection")
    
    drawBox(20, 8, 40, 12, colors.bg)
    
    gpu.setForeground(colors.accent)
    gpu.set(22, 10, "GPS Tracker Status:")
    
    gpu.setForeground(colors.text)
    gpu.set(22, 11, "Tunnel: " .. tunnel.address:sub(1, 20))
    gpu.set(22, 12, "Channel: " .. tunnel.getChannel():sub(1, 20))
    
    gpu.set(22, 15, "⟳ Registering with relay...")
    
    drawFooter("GPS Tracker • " .. tunnel.address:sub(1, 16))
    
    local registration = serialization.serialize({
        type = "client_register",
        tunnelAddress = tunnel.address,
        tunnelChannel = tunnel.getChannel()
    })
    
    pcall(tunnel.send, registration)
    
    gpu.set(22, 16, "Waiting for relay ACK...")
    
    local deadline = computer.uptime() + 5
    
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, _, port, distance, msg = table.unpack(eventData)
            local isTunnel = (port == 0 or distance == nil or distance == math.huge)
            
            if isTunnel then
                local success, response = pcall(serialization.unserialize, msg)
                if success and response and response.type == "relay_ack" then
                    relayConnected = true
                    
                    clearScreen()
                    drawHeader("◆ CONNECTION ESTABLISHED ◆")
                    
                    drawBox(20, 10, 40, 6, colors.bg)
                    gpu.setForeground(colors.success)
                    gpu.set(22, 11, "✓ Connected to GPS relay")
                    gpu.setForeground(colors.text)
                    gpu.set(22, 12, "  " .. response.relay_name)
                    
                    if response.server_connected then
                        gpu.setForeground(colors.success)
                        gpu.set(22, 14, "✓ GPS Server online")
                    else
                        gpu.setForeground(colors.warning)
                        gpu.set(22, 14, "⚠ GPS Server searching...")
                    end
                    
                    showStatus("Press any key to continue...", "success")
                    event.pull("key_down")
                    return true
                end
            end
        end
    end
    
    gpu.setForeground(colors.error)
    gpu.set(22, 15, "✗ Connection failed")
    showStatus("Press any key to retry...", "error")
    event.pull("key_down")
    return false
end

-- Setup screen
local function setupScreen()
    clearScreen()
    drawHeader("◆ GPS TRACKER SETUP ◆", "Configure your tracking identity")
    
    drawBox(15, 7, 50, 10, colors.bg)
    
    gpu.setForeground(colors.accent)
    gpu.set(17, 8, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    gpu.setForeground(colors.textDim)
    gpu.set(17, 10, "Choose a display name for tracking")
    
    gpu.setForeground(colors.text)
    local name = input("Display Name: ", 12, false, 30)
    
    if name and name ~= "" then
        entityName = name
        showStatus("✓ Name set to: " .. name, "success")
    else
        entityName = entityId:sub(1, 8)
        showStatus("Using default name: " .. entityName, "warning")
    end
    
    os.sleep(1)
    
    -- Check position detection
    gpu.setForeground(colors.accent)
    gpu.set(17, 15, "Position Detection:")
    
    if hasNav then
        gpu.setForeground(colors.success)
        gpu.set(17, 16, "✓ Navigation Upgrade detected")
    elseif hasDebug then
        gpu.setForeground(colors.success)
        gpu.set(17, 16, "✓ Debug Card detected")
    else
        gpu.setForeground(colors.error)
        gpu.set(17, 16, "✗ No position detection hardware!")
        gpu.setForeground(colors.textDim)
        gpu.set(17, 17, "  Install Navigation Upgrade or Debug Card")
        showStatus("Press any key to continue anyway...", "warning")
        event.pull("key_down")
    end
    
    os.sleep(1)
end

-- Main menu
local function mainMenu()
    clearScreen()
    drawHeader("◆ GPS TRACKER ◆", entityName or "Unnamed")
    
    -- Current position display
    drawBox(15, 6, 50, 6, colors.bg)
    gpu.setForeground(colors.textDim)
    gpu.set(17, 7, "CURRENT POSITION")
    
    if getCurrentPosition() then
        gpu.setForeground(colors.success)
        gpu.set(17, 9, string.format("X: %.1f  Y: %.1f  Z: %.1f", myPosition.x, myPosition.y, myPosition.z))
        gpu.setForeground(colors.textDim)
        gpu.set(17, 10, "Dimension: " .. myPosition.dimension)
    else
        gpu.setForeground(colors.error)
        gpu.set(17, 9, "✗ Cannot detect position")
        gpu.setForeground(colors.textDim)
        gpu.set(17, 10, "Navigation hardware required")
    end
    
    -- Auto-update status
    if autoUpdate then
        gpu.setForeground(colors.success)
        gpu.set(55, 7, "● AUTO")
    end
    
    -- Menu options
    local menuY = 14
    gpu.setForeground(colors.text)
    gpu.set(25, menuY, "1  Update Location")
    gpu.set(25, menuY + 1, "2  Find Nearby Entities")
    gpu.set(25, menuY + 2, "3  Locate Entity")
    gpu.set(25, menuY + 3, "4  List All Entities")
    gpu.set(25, menuY + 4, "5  Toggle Auto-Update")
    gpu.set(25, menuY + 5, "6  Exit")
    
    drawFooter("Entity ID: " .. entityId:sub(1, 16) .. " • Connected")
    
    local _, _, char = event.pull("key_down")
    
    if char == string.byte('1') then
        -- Manual update
        showStatus("⟳ Updating location...", "info")
        local ok, msg = updateLocation()
        if ok then
            showStatus("✓ Location updated", "success")
        else
            showStatus("✗ " .. (msg or "Update failed"), "error")
        end
        os.sleep(2)
        
    elseif char == string.byte('2') then
        -- Find nearby
        if not getCurrentPosition() then
            showStatus("✗ Cannot detect position", "error")
            os.sleep(2)
            return
        end
        
        clearScreen()
        drawHeader("◆ NEARBY ENTITIES ◆", "Searching area...")
        
        drawBox(10, 6, 60, 3, colors.bg)
        gpu.setForeground(colors.text)
        local rangeStr = input("Search Radius (blocks): ", 8, false, 10)
        local range = tonumber(rangeStr) or 100
        
        showStatus("⟳ Searching within " .. range .. " blocks...", "info")
        
        local response = sendAndWait({
            command = "find_nearby",
            x = myPosition.x,
            y = myPosition.y,
            z = myPosition.z,
            dimension = myPosition.dimension,
            range = range
        }, 10)
        
        if response and response.success then
            clearScreen()
            drawHeader("◆ NEARBY ENTITIES ◆", "Found " .. response.count .. " entities")
            
            gpu.setForeground(colors.textDim)
            gpu.set(2, 5, "Name")
            gpu.set(25, 5, "Position")
            gpu.set(50, 5, "Distance")
            gpu.set(65, 5, "Type")
            
            local y = 6
            for i = 1, math.min(17, #response.entities) do
                local entity = response.entities[i]
                gpu.setForeground(colors.text)
                local name = entity.name
                if #name > 20 then name = name:sub(1, 17) .. "..." end
                gpu.set(2, y, name)
                
                gpu.setForeground(colors.accent)
                gpu.set(25, y, string.format("%.0f,%.0f,%.0f", entity.x, entity.y, entity.z))
                
                gpu.setForeground(colors.success)
                gpu.set(50, y, string.format("%.1f m", entity.distance))
                
                gpu.setForeground(colors.textDim)
                gpu.set(65, y, entity.type:sub(1, 10))
                
                y = y + 1
            end
            
            drawFooter("Press any key to return...")
            event.pull("key_down")
        else
            showStatus("✗ Search failed", "error")
            os.sleep(2)
        end
        
    elseif char == string.byte('3') then
        -- Locate specific entity
        clearScreen()
        drawHeader("◆ LOCATE ENTITY ◆", "Find specific entity")
        
        drawBox(15, 8, 50, 8, colors.bg)
        
        gpu.setForeground(colors.text)
        local targetId = input("Entity ID: ", 10, false, 40)
        
        if targetId and targetId ~= "" then
            showStatus("⟳ Locating entity...", "info")
            
            local response = sendAndWait({
                command = "get_location",
                entityId = targetId
            })
            
            if response and response.success then
                clearScreen()
                drawHeader("◆ ENTITY FOUND ◆", response.name)
                
                drawBox(15, 7, 50, 10, colors.bg)
                
                gpu.setForeground(colors.accent)
                gpu.set(17, 8, "Name: " .. response.name)
                gpu.set(17, 9, "Type: " .. response.type)
                
                gpu.setForeground(colors.success)
                gpu.set(17, 11, string.format("Position: %.1f, %.1f, %.1f", response.x, response.y, response.z))
                gpu.setForeground(colors.textDim)
                gpu.set(17, 12, "Dimension: " .. response.dimension)
                
                local age = response.age or 0
                local ageStr
                if age < 60 then
                    ageStr = age .. " seconds ago"
                elseif age < 3600 then
                    ageStr = math.floor(age / 60) .. " minutes ago"
                else
                    ageStr = math.floor(age / 3600) .. " hours ago"
                end
                
                gpu.setForeground(colors.textDim)
                gpu.set(17, 14, "Last Updated: " .. ageStr)
                
                -- Calculate distance if we have position
                if getCurrentPosition() and response.dimension == myPosition.dimension then
                    local dx = response.x - myPosition.x
                    local dy = response.y - myPosition.y
                    local dz = response.z - myPosition.z
                    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                    
                    gpu.setForeground(colors.accent)
                    gpu.set(17, 15, string.format("Distance: %.1f blocks", dist))
                end
                
                drawFooter("Press any key to return...")
                event.pull("key_down")
            else
                showStatus("✗ Entity not found", "error")
                os.sleep(2)
            end
        end
        
    elseif char == string.byte('4') then
        -- List all
        showStatus("⟳ Loading all entities...", "info")
        
        local response = sendAndWait({
            command = "list_all"
        }, 10)
        
        if response and response.success then
            clearScreen()
            drawHeader("◆ ALL TRACKED ENTITIES ◆", "Total: " .. response.total)
            
            gpu.setForeground(colors.textDim)
            gpu.set(2, 5, "Name")
            gpu.set(25, 5, "Position")
            gpu.set(50, 5, "Type")
            gpu.set(65, 5, "Age")
            
            local y = 6
            for i = 1, math.min(17, #response.entities) do
                local entity = response.entities[i]
                local age = entity.age or 0
                local isStale = age > 300
                
                gpu.setForeground(isStale and colors.textDim or colors.text)
                local name = entity.name
                if #name > 20 then name = name:sub(1, 17) .. "..." end
                gpu.set(2, y, name)
                
                gpu.setForeground(colors.accent)
                gpu.set(25, y, string.format("%.0f,%.0f,%.0f", entity.x, entity.y, entity.z))
                
                gpu.setForeground(colors.textDim)
                gpu.set(50, y, entity.type:sub(1, 10))
                
                gpu.setForeground(isStale and colors.error or colors.success)
                local ageStr
                if age < 60 then
                    ageStr = age .. "s"
                elseif age < 3600 then
                    ageStr = math.floor(age / 60) .. "m"
                else
                    ageStr = math.floor(age / 3600) .. "h"
                end
                gpu.set(65, y, ageStr)
                
                y = y + 1
            end
            
            drawFooter("Press any key to return...")
            event.pull("key_down")
        else
            showStatus("✗ Failed to load entities", "error")
            os.sleep(2)
        end
        
    elseif char == string.byte('5') then
        -- Toggle auto-update
        autoUpdate = not autoUpdate
        if autoUpdate then
            showStatus("✓ Auto-update enabled", "success")
        else
            showStatus("Auto-update disabled", "warning")
        end
        os.sleep(1)
        
    elseif char == string.byte('6') then
        return "exit"
    end
end

-- Auto-update timer
local function autoUpdateLoop()
    while true do
        os.sleep(updateInterval)
        if autoUpdate and relayConnected then
            updateLocation()
        end
    end
end

-- Main loop
local function main()
    clearScreen()
    
    -- Setup
    setupScreen()
    
    -- Register with relay
    while not relayConnected do
        if not registerWithRelay() then
            clearScreen()
            gpu.setForeground(colors.text)
            gpu.set(2, 10, "Retry connection? (y/n)")
            local _, _, char = event.pull("key_down")
            if char ~= string.byte('y') and char ~= string.byte('Y') then
                return
            end
        end
    end
    
    -- Start auto-update timer
    event.timer(1, autoUpdateLoop)
    
    -- Initial location update
    updateLocation()
    
    -- Main loop
    while true do
        local action = mainMenu()
        if action == "exit" then
            break
        end
    end
    
    clearScreen()
    gpu.setForeground(colors.success)
    local msg = "GPS Tracker closed"
    local msgX = math.floor((w - unicode.len(msg)) / 2)
    gpu.set(msgX, 12, msg)
end

local success, err = pcall(main)
if not success then
    clearScreen()
    gpu.setForeground(colors.error)
    print("Error: " .. tostring(err))
end

-- Cleanup
if relayConnected then
    local dereg = serialization.serialize({
        type = "client_deregister",
        tunnelAddress = tunnel.address,
        tunnelChannel = tunnel.getChannel()
    })
    pcall(tunnel.send, dereg)
end
