-- Turret Controller for OpenComputers 1.7.10
-- Manages local turrets in one world/dimension
-- Connects to relay via LINKED CARD for cross-dimensional communication
-- Syncs with central server for trusted player list

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require("computer")
local term = require("term")
local filesystem = require("filesystem")

-- Configuration
local CONFIG_DIR = "/home/turret-controller/"
local CONFIG_FILE = CONFIG_DIR .. "config.cfg"

-- Load configuration
local function loadConfig()
    if not filesystem.exists(CONFIG_FILE) then
        return nil
    end
    
    local file = io.open(CONFIG_FILE, "r")
    if file then
        local content = file:read("*a")
        file:close()
        
        local ok, config = pcall(serialization.unserialize, content)
        if ok and config then
            return config
        end
    end
    
    return nil
end

-- Try to load config
local config = loadConfig()

if not config then
    print("═══════════════════════════════════════════════════════")
    print("NO CONFIGURATION FOUND!")
    print("═══════════════════════════════════════════════════════")
    print("")
    print("This appears to be the first time running the controller.")
    print("")
    print("Please run the setup wizard first:")
    print("  > setup-wizard")
    print("")
    print("The wizard will:")
    print("  • Check hardware requirements")
    print("  • Configure controller name and dimension")
    print("  • Save settings for future use")
    print("")
    print("After setup, run this program again.")
    print("")
    return
end

-- Use configuration values
local CONTROLLER_NAME = config.controllerName or "Turret Controller"
local WORLD_NAME = config.worldName or "Unknown"

print("Loaded configuration:")
print("  Controller: " .. CONTROLLER_NAME)
print("  World: " .. WORLD_NAME)
print("")

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
local trustedPlayers = {}  -- Global trusted players
local localTrustedPlayers = {}  -- Controller-specific trusted players
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
    print("Trusted (Global): " .. #trustedPlayers)
    print("Trusted (Local): " .. #localTrustedPlayers)
    print("Trusted (Total): " .. (#trustedPlayers + #localTrustedPlayers))
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
        
        -- Wait for sync response
        local deadline = computer.uptime() + 10
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
                            -- Keep waiting for sync
                        elseif response.type == "sync_trusted" then
                            -- Got sync from server!
                            relayConnected = true
                            
                            -- Process the sync immediately
                            if response.players then
                                trustedPlayers = {}
                                for _, player in ipairs(response.players) do
                                    table.insert(trustedPlayers, player)
                                    addTrustedPlayerAll(player)
                                end
                                addToLog("Synced " .. #trustedPlayers .. " global players", "SUCCESS")
                            end
                            
                            if response.controller_players then
                                localTrustedPlayers = {}
                                for _, player in ipairs(response.controller_players) do
                                    table.insert(localTrustedPlayers, player)
                                    addTrustedPlayerAll(player)
                                end
                                addToLog("Synced " .. #localTrustedPlayers .. " local players", "SUCCESS")
                            end
                            
                            stats.syncCount = stats.syncCount + 1
                            addToLog("Registration complete!", "SUCCESS")
                            updateDisplay()
                            return true
                        end
                    end
                end
            end
        end
        
        if relayConnected then
            -- Got relay ack but no sync yet - that's okay
            addToLog("Connected, waiting for sync...", "RELAY")
            return true
        else
            addToLog("No response from relay", "ERROR")
            return false
        end
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
                turret_count = #turretProxies,
                request_sync = true  -- Request sync with every heartbeat
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
    if data.type == "sync_trusted" then
        addToLog("Received sync from server", "SYNC")
        
        -- Clear all turrets first to start fresh
        for _, turret in ipairs(turretProxies) do
            pcall(function()
                local currentPlayers = turret.getTrustedPlayers()
                for _, player in ipairs(currentPlayers) do
                    pcall(turret.removeTrustedPlayer, player)
                end
            end)
        end
        
        -- Sync global list
        if data.players then
            trustedPlayers = {}
            for _, player in ipairs(data.players) do
                table.insert(trustedPlayers, player)
            end
            addToLog("Synced " .. #trustedPlayers .. " global players", "SUCCESS")
        end
        
        -- Sync local list
        if data.controller_players then
            localTrustedPlayers = {}
            for _, player in ipairs(data.controller_players) do
                table.insert(localTrustedPlayers, player)
            end
            addToLog("Synced " .. #localTrustedPlayers .. " local players", "SUCCESS")
        end
        
        -- Now add all players to all turrets
        for _, player in ipairs(trustedPlayers) do
            addTrustedPlayerAll(player)
        end
        
        for _, player in ipairs(localTrustedPlayers) do
            addTrustedPlayerAll(player)
        end
        
        stats.syncCount = stats.syncCount + 1
        updateDisplay()
        return
    end
    
    -- Handle add player command
    if data.type == "add_player" and data.player then
        local player = data.player
        local scope = data.scope or "global"
        
        if scope == "global" then
            addToLog("Add player (GLOBAL): " .. player, "SYNC")
            
            if not contains(trustedPlayers, player) then
                table.insert(trustedPlayers, player)
                addTrustedPlayerAll(player)
                stats.commandsProcessed = stats.commandsProcessed + 1
                addToLog("✓ Added (global): " .. player, "SUCCESS")
            end
            
        elseif scope == "specific" then
            -- Check if this command is for us
            if data.target_controller == controllerId then
                addToLog("Add player (LOCAL): " .. player, "SYNC")
                
                if not contains(localTrustedPlayers, player) then
                    table.insert(localTrustedPlayers, player)
                    addTrustedPlayerAll(player)
                    stats.commandsProcessed = stats.commandsProcessed + 1
                    addToLog("✓ Added (local): " .. player, "SUCCESS")
                end
            end
        end
        
        updateDisplay()
        return
    end
    
    -- Handle remove player command
    if data.type == "remove_player" and data.player then
        local player = data.player
        local scope = data.scope or "global"
        
        if scope == "global" then
            addToLog("Remove player (GLOBAL): " .. player, "SYNC")
            
            if contains(trustedPlayers, player) then
                removeFromList(trustedPlayers, player)
                
                -- Only remove from turrets if not in local list
                if not contains(localTrustedPlayers, player) then
                    removeTrustedPlayerAll(player)
                end
                
                stats.commandsProcessed = stats.commandsProcessed + 1
                addToLog("✓ Removed (global): " .. player, "SUCCESS")
            end
            
        elseif scope == "specific" then
            -- Check if this command is for us
            if data.target_controller == controllerId then
                addToLog("Remove player (LOCAL): " .. player, "SYNC")
                
                if contains(localTrustedPlayers, player) then
                    removeFromList(localTrustedPlayers, player)
                    
                    -- Only remove from turrets if not in global list
                    if not contains(trustedPlayers, player) then
                        removeTrustedPlayerAll(player)
                    end
                    
                    stats.commandsProcessed = stats.commandsProcessed + 1
                    addToLog("✓ Removed (local): " .. player, "SUCCESS")
                end
            end
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
                        -- Sync global players
                        if data.players then
                            trustedPlayers = data.players
                            for _, player in ipairs(trustedPlayers) do
                                addTrustedPlayerAll(player)
                            end
                            print("✓ Synced " .. #trustedPlayers .. " global players")
                        end
                        
                        -- Sync local players
                        if data.controller_players then
                            localTrustedPlayers = data.controller_players
                            for _, player in ipairs(localTrustedPlayers) do
                                addTrustedPlayerAll(player)
                            end
                            print("✓ Synced " .. #localTrustedPlayers .. " local players")
                        end
                        
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
    
    -- Start heartbeat (syncs every 30 seconds automatically)
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
