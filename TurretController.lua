-- Turret Controller for OpenComputers 1.7.10
-- Manages local turrets in one world/dimension
-- Connects to relay via LINKED CARD for cross-dimensional communication
-- Syncs with central server for trusted player list

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require("computer")
local term = require("term")

-- Configuration
local CONTROLLER_NAME = "Overworld Turrets"  -- CHANGE THIS for each world
local WORLD_NAME = "Overworld"                -- CHANGE THIS for each world

-- Check for tunnel (linked card)
if not component.isAvailable("tunnel") then
    print("═══════════════════════════════════════════════════════")
    print("ERROR: LINKED CARD REQUIRED!")
    print("═══════════════════════════════════════════════════════")
    print("")
    print("This controller requires a linked card to connect to relay.")
    print("")
    print("SETUP:")
    print("1. Get a linked card pair (craft 2 linked cards + ender pearl)")
    print("2. Install one card in this controller (in your dimension)")
    print("3. Install the paired card in a relay (in main dimension)")
    print("4. The relay will forward to the central server")
    print("")
    return
end

local tunnel = component.tunnel

-- Find all turret proxies
local turretProxies = {}
for address, ttype in component.list("tierFiveTurretBase") do
    local proxy = component.proxy(address)
    if proxy then
        proxy.address = address
        table.insert(turretProxies, proxy)
        print("Found turret: " .. address:sub(1, 16))
    end
end

if #turretProxies == 0 then
    print("WARNING: No tierFiveTurretBase turret components found!")
    print("Controller will run but cannot manage turrets.")
    print("Connect turrets via adapters or cables.")
end

-- State
local relayConnected = false
local trustedPlayers = {}
local controllerId = tunnel.address
local stats = {
    turretCount = #turretProxies,
    syncCount = 0,
    commandsProcessed = 0,
    heartbeatsSent = 0
}

-- Logging
local log = {}

local function addToLog(message, category)
    category = category or "INFO"
    local entry = {
        time = os.date("%H:%M:%S"),
        category = category,
        message = message
    }
    table.insert(log, 1, entry)
    if #log > 20 then
        table.remove(log)
    end
end

-- Display
local function updateDisplay()
    term.clear()
    print("═══════════════════════════════════════════════════════")
    print("Turret Controller - " .. CONTROLLER_NAME)
    print("═══════════════════════════════════════════════════════")
    print("")
    print("World: " .. WORLD_NAME)
    print("Turrets: " .. stats.turretCount)
    print("Trusted Players: " .. #trustedPlayers)
    print("")
    
    if relayConnected then
        print("Relay: ✓ CONNECTED via Linked Card")
        print("  Tunnel: " .. tunnel.getChannel():sub(1, 24))
    else
        print("Relay: ✗ NOT CONNECTED")
    end
    
    print("")
    print("Commands Processed: " .. stats.commandsProcessed)
    print("Sync Count: " .. stats.syncCount)
    print("Heartbeats Sent: " .. stats.heartbeatsSent)
    print("")
    print("═══════════════════════════════════════════════════════")
    print("ACTIVITY LOG:")
    print("═══════════════════════════════════════════════════════")
    
    for i = 1, math.min(10, #log) do
        local entry = log[i]
        if entry.category == "SUCCESS" then
            io.write("\27[32m") -- Green
        elseif entry.category == "ERROR" then
            io.write("\27[31m") -- Red
        elseif entry.category == "SYNC" then
            io.write("\27[36m") -- Cyan
        elseif entry.category == "RELAY" then
            io.write("\27[33m") -- Yellow
        end
        
        print("[" .. entry.time .. "] " .. entry.message)
        io.write("\27[0m") -- Reset
    end
end

-- Turret operations
local function addTrustedPlayerAll(player)
    local anySuccess = false
    for _, proxy in ipairs(turretProxies) do
        local success, err = pcall(proxy.addTrustedPlayer, player)
        if success then
            anySuccess = true
        end
    end
    return anySuccess
end

local function removeTrustedPlayerAll(player)
    local anySuccess = false
    for _, proxy in ipairs(turretProxies) do
        local success, err = pcall(proxy.removeTrustedPlayer, player)
        if success then
            anySuccess = true
        end
    end
    return anySuccess
end

-- Utility
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

-- Send message via tunnel
local function sendToRelay(data)
    data.tunnelAddress = tunnel.address
    data.tunnelChannel = tunnel.getChannel()
    data.controllerName = CONTROLLER_NAME
    data.worldName = WORLD_NAME
    
    local message = serialization.serialize(data)
    local success, err = pcall(tunnel.send, message)
    
    if not success then
        addToLog("Tunnel send error: " .. tostring(err), "ERROR")
        return false
    end
    
    return true
end

-- Register with relay
local function registerWithRelay()
    addToLog("Registering with relay...", "RELAY")
    
    local registration = {
        type = "controller_register",
        controller_name = CONTROLLER_NAME,
        world_name = WORLD_NAME,
        turret_count = #turretProxies
    }
    
    if sendToRelay(registration) then
        addToLog("Registration sent via tunnel", "RELAY")
        
        -- Wait for ACK
        local deadline = computer.uptime() + 5
        while computer.uptime() < deadline do
            local eventData = {event.pull(0.5, "modem_message")}
            if eventData[1] then
                local _, _, sender, port, distance, msg = table.unpack(eventData)
                
                -- Tunnel messages have port=0 or nil distance
                local isTunnel = (port == 0 or distance == nil or distance == math.huge)
                
                if isTunnel then
                    local success, response = pcall(serialization.unserialize, msg)
                    if success and response then
                        if response.type == "relay_ack" then
                            relayConnected = true
                            addToLog("Connected to relay: " .. response.relay_name, "SUCCESS")
                            updateDisplay()
                            return true
                        elseif response.type == "sync_trusted" then
                            -- Got sync immediately
                            relayConnected = true
                            addToLog("Connected and synced!", "SUCCESS")
                            return true
                        end
                    end
                end
            end
        end
        
        addToLog("No response from relay", "ERROR")
        return false
    end
    
    return false
end

-- Heartbeat
local function sendHeartbeat()
    while true do
        os.sleep(30)
        
        if relayConnected then
            local heartbeat = {
                type = "controller_heartbeat",
                controller_name = CONTROLLER_NAME,
                world_name = WORLD_NAME,
                turret_count = #turretProxies
            }
            
            if sendToRelay(heartbeat) then
                stats.heartbeatsSent = stats.heartbeatsSent + 1
                addToLog("Heartbeat #" .. stats.heartbeatsSent, "RELAY")
                updateDisplay()
            else
                addToLog("Heartbeat failed", "ERROR")
                relayConnected = false
                updateDisplay()
            end
        else
            -- Try to reconnect
            registerWithRelay()
        end
    end
end

-- Message handler
local function handleMessage(eventType, _, sender, port, distance, message)
    -- Only process tunnel messages
    local isTunnel = (port == 0 or distance == nil or distance == math.huge)
    if not isTunnel then
        return
    end
    
    local success, data = pcall(serialization.unserialize, message)
    if not success or not data then return end
    
    -- Handle sync from central server (via relay)
    if data.type == "sync_trusted" and data.players then
        addToLog("Received full sync from server", "SYNC")
        
        -- Clear old list
        trustedPlayers = {}
        
        -- Add all players from server
        for _, player in ipairs(data.players) do
            table.insert(trustedPlayers, player)
            addTrustedPlayerAll(player)
        end
        
        stats.syncCount = stats.syncCount + 1
        addToLog("Synced " .. #trustedPlayers .. " players to turrets", "SUCCESS")
        updateDisplay()
        return
    end
    
    -- Handle add player command
    if data.type == "add_player" and data.player then
        local player = data.player
        addToLog("Add player: " .. player, "SYNC")
        
        if not contains(trustedPlayers, player) then
            table.insert(trustedPlayers, player)
            addTrustedPlayerAll(player)
            stats.commandsProcessed = stats.commandsProcessed + 1
            addToLog("✓ Added: " .. player, "SUCCESS")
        else
            addToLog("Already trusted: " .. player, "INFO")
        end
        
        updateDisplay()
        return
    end
    
    -- Handle remove player command
    if data.type == "remove_player" and data.player then
        local player = data.player
        addToLog("Remove player: " .. player, "SYNC")
        
        if contains(trustedPlayers, player) then
            removeFromList(trustedPlayers, player)
            removeTrustedPlayerAll(player)
            stats.commandsProcessed = stats.commandsProcessed + 1
            addToLog("✓ Removed: " .. player, "SUCCESS")
        else
            addToLog("Not in list: " .. player, "INFO")
        end
        
        updateDisplay()
        return
    end
    
    -- Handle relay ACK
    if data.type == "relay_ack" then
        if not relayConnected then
            relayConnected = true
            addToLog("Relay ACK received", "SUCCESS")
            updateDisplay()
        end
        return
    end
end

-- Main
local function main()
    print("Starting Turret Controller...")
    print("Controller: " .. CONTROLLER_NAME)
    print("World: " .. WORLD_NAME)
    print("Turrets found: " .. #turretProxies)
    print("")
    print("Tunnel Info:")
    print("  Address: " .. tunnel.address)
    print("  Channel: " .. tunnel.getChannel())
    print("")
    
    -- Register with relay
    print("Connecting to relay via linked card...")
    if registerWithRelay() then
        print("✓ Connected to relay!")
        print("  Waiting for trusted player sync...")
        
        -- Wait for initial sync
        local deadline = computer.uptime() + 5
        while computer.uptime() < deadline do
            local eventData = {event.pull(0.5, "modem_message")}
            if eventData[1] then
                local _, _, sender, port, distance, msg = table.unpack(eventData)
                
                local isTunnel = (port == 0 or distance == nil or distance == math.huge)
                if isTunnel then
                    local success, data = pcall(serialization.unserialize, msg)
                    if success and data and data.type == "sync_trusted" then
                        trustedPlayers = data.players or {}
                        
                        -- Apply to all turrets
                        for _, player in ipairs(trustedPlayers) do
                            addTrustedPlayerAll(player)
                        end
                        
                        print("✓ Synced " .. #trustedPlayers .. " trusted players")
                        stats.syncCount = 1
                        addToLog("Initial sync complete", "SUCCESS")
                        break
                    end
                end
            end
        end
    else
        print("✗ Could not connect to relay")
        print("  Make sure:")
        print("  • Relay is running")
        print("  • Linked cards are paired")
        print("  • Relay has the paired card installed")
    end
    
    print("")
    print("Controller running! Press Ctrl+C to stop")
    
    -- Start heartbeat
    event.timer(1, sendHeartbeat)
    
    -- Listen for messages
    event.listen("modem_message", handleMessage)
    
    updateDisplay()
    
    addToLog("Controller started: " .. CONTROLLER_NAME, "SUCCESS")
    
    -- Keep running
    while true do
        os.sleep(1)
    end
end

local success, err = pcall(main)
if not success then
    print("Error: " .. tostring(err))
end

event.ignore("modem_message", handleMessage)
print("Controller stopped")
