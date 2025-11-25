-- Central Turret Management Server for OpenComputers 1.7.10
-- Manages multiple remote turret controllers across different dimensions
-- Controllers connect via RELAY (which uses linked cards for cross-dimensional support)
-- Clients also connect via same RELAY system

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local computer = require("computer")
local gpu = component.gpu
local term = require("term")

-- Configuration
local PORT = 19321
local SERVER_NAME = "Central Turret Control"
local DATA_DIR = "/home/turrets/"
local DATA_FILE = DATA_DIR .. "trusted.dat"

-- Network components
local modem = component.modem

if not modem or not modem.isWireless() then
    print("ERROR: Wireless Network Card required!")
    return
end

-- Data structures
local trustedPlayers = {}
local turretControllers = {} -- address -> {name, world, lastSeen, turretCount}
local relays = {} -- relay address -> {name, lastSeen, controllers, managers}
local stats = {
    totalControllers = 0,
    totalTurrets = 0,
    totalTrusted = 0,
    relayCount = 0,
    commandsProcessed = 0
}

-- Screen setup
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
    border = 0x374151
}

-- Activity log
local activityLog = {}

-- Initialize data directory
if not filesystem.exists(DATA_DIR) then
    filesystem.makeDirectory(DATA_DIR)
end

-- Utility functions
local function contains(list, item)
    for _, v in ipairs(list) do
        if v == item then return true end
    end
    return false
end

local function removeFromList(list, item)
    for i = #list, 1, -1 do
        if list[i] == item then
            table.remove(list, i)
        end
    end
end

-- Data persistence
local function saveTrustedPlayers()
    local file = io.open(DATA_FILE, "w")
    if file then
        file:write(serialization.serialize(trustedPlayers))
        file:close()
        return true
    end
    return false
end

local function loadTrustedPlayers()
    if not filesystem.exists(DATA_FILE) then
        return false
    end
    
    local file = io.open(DATA_FILE, "r")
    if file then
        local content = file:read("*a")
        file:close()
        
        local ok, data = pcall(serialization.unserialize, content)
        if ok and type(data) == "table" then
            trustedPlayers = data
            stats.totalTrusted = #trustedPlayers
            return true
        end
    end
    return false
end

-- Activity logging
local function log(message, category)
    category = category or "INFO"
    local entry = {
        time = os.date("%H:%M:%S"),
        category = category,
        message = message
    }
    
    table.insert(activityLog, 1, entry)
    if #activityLog > 50 then
        table.remove(activityLog)
    end
    
    stats.commandsProcessed = stats.commandsProcessed + 1
end

-- Controller management
local function registerController(address, controllerName, worldName, turretCount)
    if not turretControllers[address] then
        turretControllers[address] = {
            address = address,
            name = controllerName or "Unknown",
            world = worldName or "Unknown",
            turretCount = turretCount or 0,
            lastSeen = computer.uptime(),
            lastHeartbeat = computer.uptime()
        }
        stats.totalControllers = stats.totalControllers + 1
        log("Controller: " .. controllerName .. " (" .. worldName .. ")", "CONTROLLER")
    else
        turretControllers[address].lastSeen = computer.uptime()
        turretControllers[address].turretCount = turretCount or turretControllers[address].turretCount
    end
    
    -- Recalculate total turrets
    stats.totalTurrets = 0
    for _, ctrl in pairs(turretControllers) do
        stats.totalTurrets = stats.totalTurrets + ctrl.turretCount
    end
end

-- Relay management
local function registerRelay(address, relayName)
    if not relays[address] then
        relays[address] = {
            address = address,
            name = relayName,
            lastSeen = computer.uptime(),
            controllers = 0,
            managers = 0
        }
        stats.relayCount = stats.relayCount + 1
        log("Relay connected: " .. relayName, "RELAY")
    else
        relays[address].lastSeen = computer.uptime()
    end
end

-- Broadcast command to all controllers via relay
local function broadcastToControllers(command, relayAddress)
    local msg = serialization.serialize(command)
    
    if relayAddress then
        -- Send to specific relay
        modem.send(relayAddress, PORT, msg)
        return true
    else
        -- Broadcast to all relays (they'll forward to their controllers)
        modem.broadcast(PORT, msg)
        return true
    end
end

-- UI Drawing
local function drawServerUI()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
    
    -- Header
    gpu.setBackground(colors.header)
    gpu.fill(1, 1, w, 3, " ")
    local title = "=== " .. SERVER_NAME .. " ==="
    gpu.set(math.floor((w - #title) / 2), 2, title)
    gpu.setForeground(colors.textDim)
    local subtitle = "Cross-Dimensional Turret Management"
    gpu.set(math.floor((w - #subtitle) / 2), 3, subtitle)
    
    -- Stats panel
    gpu.setBackground(0x1E1E1E)
    gpu.setForeground(colors.success)
    gpu.fill(1, 4, w, 2, " ")
    gpu.set(2, 4, "Controllers: " .. stats.totalControllers)
    gpu.set(22, 4, "Total Turrets: " .. stats.totalTurrets)
    gpu.set(45, 4, "Trusted: " .. stats.totalTrusted)
    gpu.set(65, 4, "Port: " .. PORT)
    
    gpu.set(2, 5, "Relays: " .. stats.relayCount)
    gpu.setForeground(colors.warning)
    gpu.set(22, 5, "Commands: " .. stats.commandsProcessed)
    
    -- Show turret controllers by world
    gpu.setBackground(0x2D2D2D)
    gpu.setForeground(colors.warning)
    gpu.fill(1, 7, w, 1, " ")
    gpu.set(2, 7, "Turret Controllers (via Linked Cards):")
    
    gpu.setForeground(colors.text)
    gpu.set(2, 8, "World/Dimension")
    gpu.set(30, 8, "Controller")
    gpu.set(52, 8, "Turrets")
    gpu.set(62, 8, "HB")
    gpu.set(68, 8, "Status")
    
    local y = 9
    local controllerList = {}
    for _, ctrl in pairs(turretControllers) do
        table.insert(controllerList, ctrl)
    end
    table.sort(controllerList, function(a, b) return a.world < b.world end)
    
    for i = 1, math.min(5, #controllerList) do
        local ctrl = controllerList[i]
        local now = computer.uptime()
        local timeDiff = now - ctrl.lastHeartbeat
        local isActive = timeDiff < 90  -- 90 seconds (3 missed heartbeats)
        
        gpu.setForeground(isActive and colors.accent or 0x888888)
        local world = ctrl.world or "Unknown"
        if #world > 25 then world = world:sub(1, 22) .. "..." end
        gpu.set(2, y, world)
        
        gpu.setForeground(isActive and colors.text or 0x888888)
        local name = ctrl.name or "Unknown"
        if #name > 18 then name = name:sub(1, 15) .. "..." end
        gpu.set(30, y, name)
        
        gpu.setForeground(isActive and colors.success or 0x888888)
        gpu.set(52, y, tostring(ctrl.turretCount or 0))
        
        -- Show time since last heartbeat
        local hbTime = math.floor(timeDiff)
        gpu.setForeground(isActive and colors.textDim or 0x888888)
        gpu.set(62, y, hbTime .. "s")
        
        gpu.setForeground(isActive and colors.success or colors.error)
        gpu.set(68, y, isActive and "ONLINE" or "OFFLINE")
        y = y + 1
    end
    
    if #controllerList == 0 then
        gpu.setForeground(colors.textDim)
        gpu.set(2, y, "  (no controllers connected)")
    end
    
    -- Show relays
    y = math.max(y + 1, 15)
    gpu.setBackground(0x2D2D2D)
    gpu.setForeground(colors.warning)
    gpu.fill(1, y, w, 1, " ")
    gpu.set(2, y, "Connected Relays:")
    y = y + 1
    
    local relayList = {}
    for _, relay in pairs(relays) do
        table.insert(relayList, relay)
    end
    table.sort(relayList, function(a, b) return a.lastSeen > b.lastSeen end)
    
    for i = 1, math.min(3, #relayList) do
        local relay = relayList[i]
        local now = computer.uptime()
        local isActive = (now - relay.lastSeen) < 90
        
        gpu.setForeground(isActive and colors.success or 0x888888)
        local name = relay.name or "Unknown"
        if #name > 30 then name = name:sub(1, 27) .. "..." end
        gpu.set(4, y, "• " .. name)
        
        gpu.setForeground(isActive and colors.textDim or 0x888888)
        local info = "Ctrl:" .. (relay.controllers or 0) .. " Mgr:" .. (relay.managers or 0)
        gpu.set(40, y, info)
        
        gpu.setForeground(isActive and colors.success or colors.error)
        gpu.set(68, y, isActive and "ACTIVE" or "TIMEOUT")
        y = y + 1
    end
    
    -- Trusted players list
    y = math.max(y + 1, 19)
    gpu.setForeground(colors.warning)
    gpu.fill(1, y, w, 1, " ")
    gpu.set(2, y, "Trusted Players (Global - All Dimensions):")
    y = y + 1
    
    gpu.setBackground(0x2D2D2D)
    gpu.setForeground(colors.text)
    
    local maxPlayers = math.min(3, #trustedPlayers)
    for i = 1, maxPlayers do
        local player = trustedPlayers[i]
        gpu.set(4, y, "• " .. player)
        y = y + 1
    end
    
    if #trustedPlayers == 0 then
        gpu.setForeground(colors.textDim)
        gpu.set(4, y, "(no trusted players)")
        y = y + 1
    elseif #trustedPlayers > 3 then
        gpu.setForeground(colors.textDim)
        gpu.set(4, y, "... and " .. (#trustedPlayers - 3) .. " more")
        y = y + 1
    end
    
    -- Recent activity
    gpu.setBackground(0x1E1E1E)
    gpu.setForeground(colors.warning)
    gpu.fill(1, 23, w, 1, " ")
    gpu.set(2, 23, "Recent Activity:")
    
    gpu.setBackground(0x2D2D2D)
    y = 24
    for i = 1, math.min(1, #activityLog) do
        local entry = activityLog[i]
        local color = 0xAAAAAA
        if entry.category == "SUCCESS" then color = colors.success
        elseif entry.category == "ERROR" then color = colors.error
        elseif entry.category == "RELAY" then color = 0xFF00FF
        elseif entry.category == "CONTROLLER" then color = colors.accent
        elseif entry.category == "TURRET" then color = colors.warning
        end
        
        gpu.setForeground(color)
        local msg = "[" .. entry.time .. "] " .. entry.message
        gpu.set(2, y, msg:sub(1, 76))
        y = y + 1
    end
    
    -- Footer
    gpu.setBackground(colors.header)
    gpu.setForeground(colors.text)
    gpu.fill(1, 25, w, 1, " ")
    local footer = "Central Server • " .. stats.totalTurrets .. " turrets • " .. stats.totalControllers .. " dimensions"
    gpu.set(2, 25, footer)
end

-- Network message handler
local function handleMessage(eventType, _, sender, port, distance, message)
    if port ~= PORT then return end
    
    local success, data = pcall(serialization.unserialize, message)
    if not success or not data then
        log("Bad message from " .. sender:sub(1, 8), "ERROR")
        return
    end
    
    -- Handle relay ping
    if data.type == "relay_ping" then
        registerRelay(sender, data.relay_name or "Unknown")
        
        local response = {
            type = "server_response",
            serverName = SERVER_NAME
        }
        modem.send(sender, PORT, serialization.serialize(response))
        drawServerUI()
        return
    end
    
    -- Handle relay heartbeat
    if data.type == "relay_heartbeat" then
        registerRelay(sender, data.relay_name or "Unknown")
        if relays[sender] then
            relays[sender].controllers = data.controllers or 0
            relays[sender].managers = data.managers or 0
        end
        drawServerUI()
        return
    end
    
    -- Handle turret controller registration (from relay)
    if data.type == "controller_register" then
        local controllerId = data.tunnelAddress or sender
        registerController(controllerId, data.controllerName or data.controller_name, data.worldName or data.world_name, data.turret_count)
        
        -- Send current trusted player list back via relay
        local response = {
            type = "sync_trusted",
            players = trustedPlayers
        }
        modem.send(sender, PORT, serialization.serialize(response))
        
        log("Synced " .. #trustedPlayers .. " to " .. (data.controllerName or data.controller_name or "controller"), "CONTROLLER")
        drawServerUI()
        return
    end
    
    -- Handle turret controller heartbeat (from relay)
    if data.type == "controller_heartbeat" then
        local controllerId = data.tunnelAddress or sender
        local ctrl = turretControllers[controllerId]
        
        if ctrl then
            ctrl.lastHeartbeat = computer.uptime()
            ctrl.lastSeen = computer.uptime()
            ctrl.turretCount = data.turret_count or ctrl.turretCount
            ctrl.name = data.controllerName or data.controller_name or ctrl.name
            ctrl.world = data.worldName or data.world_name or ctrl.world
        else
            -- First heartbeat, register controller
            registerController(controllerId, data.controllerName or data.controller_name, data.worldName or data.world_name, data.turret_count)
        end
        
        -- Recalculate total turrets
        stats.totalTurrets = 0
        for _, c in pairs(turretControllers) do
            stats.totalTurrets = stats.totalTurrets + c.turretCount
        end
        
        drawServerUI()
        return
    end
    
    -- Handle manager sync request
    if data.type == "request_sync" then
        local response = {
            type = "sync_trusted",
            players = trustedPlayers
        }
        modem.send(sender, PORT, serialization.serialize(response))
        log("Re-synced to manager", "INFO")
        drawServerUI()
        return
    end
    
    -- All other messages are commands from client managers (via relay)
    local response = { status = "fail" }
    
    -- Command: Add trusted player
    if data.command == "addTrustedPlayer" and type(data.player) == "string" then
        local player = data.player
        log("Add player: " .. player, "TURRET")
        
        if not contains(trustedPlayers, player) then
            table.insert(trustedPlayers, player)
            stats.totalTrusted = #trustedPlayers
            saveTrustedPlayers()
            
            -- Broadcast to all controllers via relay
            local broadcast = {
                type = "add_player",
                player = player
            }
            broadcastToControllers(broadcast, sender)  -- Send back to relay
            
            response.status = "success"
            log("✓ Added globally: " .. player, "SUCCESS")
        else
            response.status = "success"
            response.message = "Player already trusted"
        end
        
    -- Command: Remove trusted player
    elseif data.command == "removeTrustedPlayer" and type(data.player) == "string" then
        local player = data.player
        log("Remove player: " .. player, "TURRET")
        
        if contains(trustedPlayers, player) then
            removeFromList(trustedPlayers, player)
            stats.totalTrusted = #trustedPlayers
            saveTrustedPlayers()
            
            -- Broadcast to all controllers via relay
            local broadcast = {
                type = "remove_player",
                player = player
            }
            broadcastToControllers(broadcast, sender)  -- Send back to relay
            
            response.status = "success"
            log("✓ Removed globally: " .. player, "SUCCESS")
        else
            response.status = "success"
            response.message = "Player not in list"
        end
        
    -- Command: Get trusted players
    elseif data.command == "getTrustedPlayers" then
        response.status = "success"
        response.players = trustedPlayers
        log("Sent player list to manager", "INFO")
        
    -- Command: Get controllers (for manager UI)
    elseif data.command == "getControllers" then
        response.status = "success"
        response.controllers = {}
        
        for _, ctrl in pairs(turretControllers) do
            local now = computer.uptime()
            local isActive = (now - ctrl.lastHeartbeat) < 90
            
            if isActive then  -- Only send active controllers
                table.insert(response.controllers, {
                    name = ctrl.name,
                    world = ctrl.world,
                    turrets = ctrl.turretCount
                })
            end
        end
        
        log("Sent controller list to manager", "INFO")
        
    else
        response.reason = "Unknown command: " .. tostring(data.command)
        log("Unknown command from " .. sender:sub(1, 8), "ERROR")
    end
    
    modem.send(sender, PORT, serialization.serialize(response))
    drawServerUI()
end

-- Main server loop
local function main()
    print("Starting " .. SERVER_NAME .. "...")
    print("Mode: Central Management Server")
    print("Data directory: " .. DATA_DIR)
    print("")
    
    -- Load trusted players
    if loadTrustedPlayers() then
        print("Loaded " .. #trustedPlayers .. " trusted players")
    else
        print("No saved data, starting fresh")
    end
    
    modem.open(PORT)
    modem.setStrength(400)
    print("Listening on port " .. PORT)
    print("Wireless range: 400 blocks")
    print("")
    print("Architecture:")
    print("  Relay ←wireless→ This Server")
    print("  Controllers ←linked cards→ Relay")
    print("  Managers ←linked cards→ Relay")
    print("")
    print("Waiting for connections...")
    
    event.listen("modem_message", handleMessage)
    
    drawServerUI()
    
    log("Central server started", "SYSTEM")
    print("Server running!")
    
    -- Maintenance timer
    event.timer(60, function()
        -- Cleanup old controllers (3 minutes without heartbeat)
        local now = computer.uptime()
        for address, ctrl in pairs(turretControllers) do
            if now - ctrl.lastHeartbeat > 180 then
                turretControllers[address] = nil
                stats.totalControllers = math.max(0, stats.totalControllers - 1)
                log("Controller timeout: " .. ctrl.name, "ERROR")
            end
        end
        
        -- Cleanup old relays
        for address, relay in pairs(relays) do
            if now - relay.lastSeen > 120 then
                relays[address] = nil
                stats.relayCount = math.max(0, stats.relayCount - 1)
            end
        end
        
        -- Recalculate total turrets
        stats.totalTurrets = 0
        for _, ctrl in pairs(turretControllers) do
            stats.totalTurrets = stats.totalTurrets + ctrl.turretCount
        end
        
        drawServerUI()
    end, math.huge)
    
    while true do
        os.sleep(1)
    end
end

local success, err = pcall(main)
if not success then
    print("Error: " .. tostring(err))
end

modem.close(PORT)
print("Server stopped")
