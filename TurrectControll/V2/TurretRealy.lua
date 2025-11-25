-- Unified Turret Relay for OpenComputers 1.7.10
-- Handles BOTH turret controllers AND client managers via linked cards
-- Forwards all messages to central server via wireless
-- ENCRYPTED communication with server using Data Card

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require("computer")
local term = require("term")

-- Check for required components
if not component.isAvailable("modem") then
    print("ERROR: Wireless Network Card required!")
    return
end

-- Check for data card (for encryption)
if not component.isAvailable("data") then
    print("ERROR: Data card required for encryption!")
    print("Please install a Tier 2 or Tier 3 Data Card")
    return
end

local modem = component.modem
local data = component.data

-- Encryption key (must match server)
local SERVER_NAME = "Central Turret Control"
local ENCRYPTION_KEY = data.md5(SERVER_NAME .. "TurretSecure2024")

-- Encryption functions
local function encryptMessage(plaintext)
    if not plaintext or plaintext == "" then
        return nil
    end
    local iv = data.random(16)
    local encrypted = data.encrypt(plaintext, ENCRYPTION_KEY, iv)
    return data.encode64(iv .. encrypted)
end

local function decryptMessage(ciphertext)
    if not ciphertext or ciphertext == "" then
        return nil
    end
    
    local success, result = pcall(function()
        local combined = data.decode64(ciphertext)
        local iv = combined:sub(1, 16)
        local encrypted = combined:sub(17)
        return data.decrypt(encrypted, ENCRYPTION_KEY, iv)
    end)
    
    if success then
        return result
    else
        return nil
    end
end

-- Get ALL tunnel components (linked cards)
local tunnels = {}
for address in component.list("tunnel") do
    table.insert(tunnels, component.proxy(address))
    print("Found linked card: " .. address:sub(1, 16))
end

if #tunnels == 0 then
    print("ERROR: No Tunnel (Linked Card) found!")
    print("")
    print("This relay needs linked cards to communicate.")
    print("Install linked cards for:")
    print("  • Turret Controllers (one per dimension)")
    print("  • Client Managers (one per admin)")
    return
end

print("Total linked cards: " .. #tunnels)
print("Encryption: ENABLED")

-- Configuration
local PORT = 19321
local RELAY_NAME = "Unified Turret Relay"

-- State
local serverAddress = nil
local registeredClients = {} -- clientId -> {tunnel, type, lastSeen}
local stats = {
    messagesForwarded = 0,
    messagesToClients = 0,
    controllers = 0,
    managers = 0,
    uptime = 0
}

-- Screen setup
term.clear()

-- Logging
local log = {}

-- Display
local function updateDisplay()
    term.clear()
    print("═══════════════════════════════════════════════════════")
    print("Unified Turret Relay - " .. RELAY_NAME)
    print("═══════════════════════════════════════════════════════")
    print("")
    print("Mode: MULTI-TUNNEL ←→ WIRELESS (ENCRYPTED)")
    print("  Controllers connect via: LINKED CARDS")
    print("  Managers connect via:    LINKED CARDS")
    print("  Central server via:      WIRELESS (AES)")
    print("")
    
    if serverAddress then
        print("Central Server: ✓ CONNECTED (ENCRYPTED)")
        print("  Address: " .. serverAddress:sub(1, 16))
    else
        print("Central Server: ✗ SEARCHING...")
    end
    
    print("")
    
    -- Show all tunnel channels
    print("Linked Cards: " .. #tunnels .. " total")
    for i = 1, math.min(3, #tunnels) do
        local tunnel = tunnels[i]
        print("  [" .. i .. "] " .. tunnel.getChannel():sub(1, 24))
    end
    if #tunnels > 3 then
        print("  ... and " .. (#tunnels - 3) .. " more")
    end
    
    print("")
    print("═══════════════════════════════════════════════════════")
    print("CONNECTED CLIENTS:")
    print("═══════════════════════════════════════════════════════")
    
    -- Show controllers
    local controllerCount = 0
    local onlineControllers = 0
    for clientId, client in pairs(registeredClients) do
        if clientId ~= "_last_sender" and client.type == "controller" then
            controllerCount = controllerCount + 1
            local timeDiff = computer.uptime() - (client.lastSeen or 0)
            local isOnline = timeDiff < 90
            if isOnline then onlineControllers = onlineControllers + 1 end
        end
    end
    
    print("Controllers: " .. onlineControllers .. "/" .. controllerCount)
    for clientId, client in pairs(registeredClients) do
        if clientId ~= "_last_sender" and client.type == "controller" then
            local timeDiff = computer.uptime() - (client.lastSeen or 0)
            local isOnline = timeDiff < 90
            
            if isOnline then
                io.write("\27[32m") -- Green
                print("  ✓ " .. (client.name or "Unknown") .. " (" .. (client.world or "?") .. ") - " .. math.floor(timeDiff) .. "s")
            else
                io.write("\27[31m") -- Red
                print("  ✗ " .. (client.name or "Unknown") .. " (" .. (client.world or "?") .. ") - OFFLINE")
            end
            io.write("\27[0m") -- Reset
        end
    end
    
    if controllerCount == 0 then
        print("  (no controllers connected)")
    end
    
    print("")
    
    -- Show managers
    local managerCount = 0
    local onlineManagers = 0
    for clientId, client in pairs(registeredClients) do
        if clientId ~= "_last_sender" and client.type == "manager" then
            managerCount = managerCount + 1
            local timeDiff = computer.uptime() - (client.lastSeen or 0)
            local isOnline = timeDiff < 90
            if isOnline then onlineManagers = onlineManagers + 1 end
        end
    end
    
    print("Managers: " .. onlineManagers .. "/" .. managerCount)
    for clientId, client in pairs(registeredClients) do
        if clientId ~= "_last_sender" and client.type == "manager" then
            local timeDiff = computer.uptime() - (client.lastSeen or 0)
            local isOnline = timeDiff < 90
            
            if isOnline then
                io.write("\27[32m") -- Green
                print("  ✓ Manager " .. clientId:sub(1, 8) .. " - " .. math.floor(timeDiff) .. "s")
            else
                io.write("\27[31m") -- Red
                print("  ✗ Manager " .. clientId:sub(1, 8) .. " - OFFLINE")
            end
            io.write("\27[0m") -- Reset
        end
    end
    
    if managerCount == 0 then
        print("  (no managers connected)")
    end
    
    print("")
    print("═══════════════════════════════════════════════════════")
    print("STATISTICS:")
    print("═══════════════════════════════════════════════════════")
    print("Wireless Port: " .. PORT)
    print("→ Server: " .. stats.messagesForwarded .. " (encrypted)")
    print("→ Clients: " .. stats.messagesToClients)
    print("Uptime: " .. math.floor(stats.uptime / 60) .. "m " .. (stats.uptime % 60) .. "s")
    print("")
    print("═══════════════════════════════════════════════════════")
    print("ACTIVITY LOG:")
    print("═══════════════════════════════════════════════════════")
    
    for i = 1, math.min(8, #log) do
        local entry = log[i]
        if entry.category == "SUCCESS" then
            io.write("\27[32m") -- Green
        elseif entry.category == "ERROR" then
            io.write("\27[31m") -- Red
        elseif entry.category == "CONTROLLER" then
            io.write("\27[35m") -- Magenta
        elseif entry.category == "MANAGER" then
            io.write("\27[36m") -- Cyan
        elseif entry.category == "SERVER" then
            io.write("\27[33m") -- Yellow
        end
        
        print("[" .. entry.time .. "] " .. entry.message)
        io.write("\27[0m") -- Reset
    end
end

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
    updateDisplay()
end

-- Server discovery
local function findServer()
    if serverAddress then return true end
    
    addToLog("Searching for central server...", "SERVER")
    
    local ping = {
        type = "relay_ping",
        relay_name = RELAY_NAME
    }
    local pingMsg = serialization.serialize(ping)
    local encrypted = encryptMessage(pingMsg)
    
    modem.broadcast(PORT, encrypted or pingMsg)
    
    -- Wait for response
    local deadline = computer.uptime() + 3
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, sender, port, _, message = table.unpack(eventData)
            if port == PORT then
                -- Try to decrypt
                local decrypted = decryptMessage(message)
                local messageToUse = decrypted or message
                
                local success, data = pcall(serialization.unserialize, messageToUse)
                if success and data and data.type == "server_response" then
                    serverAddress = sender
                    addToLog("Server found: " .. sender:sub(1, 8), "SUCCESS")
                    return true
                end
            end
        end
    end
    
    addToLog("Server not found", "ERROR")
    return false
end

-- Server heartbeat
local function serverHeartbeat()
    while true do
        os.sleep(30)
        
        if serverAddress then
            local heartbeat = {
                type = "relay_heartbeat",
                relay_name = RELAY_NAME,
                controllers = stats.controllers,
                managers = stats.managers
            }
            local heartbeatMsg = serialization.serialize(heartbeat)
            local encrypted = encryptMessage(heartbeatMsg)
            
            modem.send(serverAddress, PORT, encrypted or heartbeatMsg)
            addToLog("Heartbeat (" .. stats.controllers .. " ctrl, " .. stats.managers .. " mgr)", "SERVER")
        else
            findServer()
        end
    end
end

-- Check if this is a tunnel message
local function isTunnelMessage(sender, port, distance)
    if port ~= 0 and distance ~= nil and distance ~= math.huge then
        return false
    end
    return true
end

-- Unified message handler
local function handleMessage(eventType, _, sender, port, distance, message)
    -- Check if sender matches any of our tunnels
    local matchedTunnel = false
    for i, tunnel in ipairs(tunnels) do
        if tunnel.address == sender then
            matchedTunnel = true
            break
        end
    end
    
    -- Check if this is a tunnel message
    local isTunnel = isTunnelMessage(sender, port, distance)
    
    if isTunnel then
        -- ==========================================
        -- FROM CLIENT (controller or manager via tunnel)
        -- ==========================================
        
        -- Parse message
        local success, data = pcall(serialization.unserialize, message)
        
        if not success or not data then
            addToLog("ERROR: Failed to parse message", "ERROR")
            return
        end
        
        -- Find which tunnel to use
        local sourceTunnel = nil
        
        if data.tunnelAddress then
            if data.tunnelChannel then
                for i, tunnel in ipairs(tunnels) do
                    if tunnel.getChannel() == data.tunnelChannel then
                        sourceTunnel = tunnel
                        break
                    end
                end
            end
        end
        
        if not sourceTunnel and data.tunnelAddress then
            local client = registeredClients[data.tunnelAddress]
            if client then
                sourceTunnel = client.tunnel
            end
        end
        
        if not sourceTunnel and #tunnels == 1 then
            sourceTunnel = tunnels[1]
        end
        
        if not sourceTunnel then
            addToLog("ERROR: Cannot determine source tunnel!", "ERROR")
            return
        end
        
        -- Handle controller registration
        if data.type == "controller_register" then
            local clientId = data.tunnelAddress
            
            registeredClients[clientId] = {
                tunnel = sourceTunnel,
                type = "controller",
                name = data.controller_name or "Unknown",
                world = data.world_name or "Unknown",
                lastSeen = computer.uptime()
            }
            
            stats.controllers = 0
            stats.managers = 0
            for _, client in pairs(registeredClients) do
                if client.type == "controller" then
                    stats.controllers = stats.controllers + 1
                elseif client.type == "manager" then
                    stats.managers = stats.managers + 1
                end
            end
            
            addToLog("CONTROLLER: " .. (data.controller_name or "Unknown"), "CONTROLLER")
            addToLog("  World: " .. (data.world_name or "?"), "CONTROLLER")
            
            -- Send ACK
            local ack = {
                type = "relay_ack",
                relay_name = RELAY_NAME,
                server_connected = serverAddress ~= nil
            }
            
            pcall(sourceTunnel.send, serialization.serialize(ack))
            
            updateDisplay()
            
            -- Forward registration to server
            if serverAddress then
                local encrypted = encryptMessage(message)
                modem.send(serverAddress, PORT, encrypted or message)
            end
            
            return
        end
        
        -- Update lastSeen for heartbeats and regular messages
        if data.tunnelAddress and registeredClients[data.tunnelAddress] then
            registeredClients[data.tunnelAddress].lastSeen = computer.uptime()
        end
        
        -- Handle manager registration
        if data.type == "manager_register" then
            local clientId = data.tunnelAddress
            
            registeredClients[clientId] = {
                tunnel = sourceTunnel,
                type = "manager",
                lastSeen = computer.uptime()
            }
            
            stats.controllers = 0
            stats.managers = 0
            for _, client in pairs(registeredClients) do
                if client.type == "controller" then
                    stats.controllers = stats.controllers + 1
                elseif client.type == "manager" then
                    stats.managers = stats.managers + 1
                end
            end
            
            addToLog("MANAGER connected", "MANAGER")
            
            -- Send ACK
            local ack = {
                type = "relay_ack",
                relay_name = RELAY_NAME,
                server_connected = serverAddress ~= nil
            }
            
            pcall(sourceTunnel.send, serialization.serialize(ack))
            
            updateDisplay()
            return
        end
        
        -- Handle deregistration
        if data.type == "client_deregister" or data.type == "controller_disconnect" or data.type == "manager_disconnect" then
            local clientId = data.tunnelAddress
            if registeredClients[clientId] then
                local clientType = registeredClients[clientId].type
                registeredClients[clientId] = nil
                
                if clientType == "controller" then
                    addToLog("Controller disconnected", "CONTROLLER")
                else
                    addToLog("Manager disconnected", "MANAGER")
                end
                
                stats.controllers = 0
                stats.managers = 0
                for _, client in pairs(registeredClients) do
                    if client.type == "controller" then
                        stats.controllers = stats.controllers + 1
                    elseif client.type == "manager" then
                        stats.managers = stats.managers + 1
                    end
                end
            end
            
            updateDisplay()
            return
        end
        
        -- Regular message forwarding to server
        if not serverAddress then
            addToLog("NO SERVER - attempting discovery", "ERROR")
            if not findServer() then
                addToLog("SERVER DISCOVERY FAILED", "ERROR")
                
                if sourceTunnel then
                    local errorMsg = serialization.serialize({
                        status = "fail",
                        reason = "Relay cannot reach central server"
                    })
                    pcall(sourceTunnel.send, errorMsg)
                end
                return
            end
        end
        
        -- Determine message type for logging
        local msgType = "message"
        if data.type == "controller_heartbeat" then
            msgType = "heartbeat"
        elseif data.command then
            msgType = "command: " .. data.command
        end
        
        addToLog("→ SERVER: " .. msgType, "SERVER")
        
        -- Encrypt before sending to server
        local encrypted = encryptMessage(message)
        local sendOk = pcall(modem.send, serverAddress, PORT, encrypted or message)
        if sendOk then
            stats.messagesForwarded = stats.messagesForwarded + 1
            
            -- Store which tunnel sent this
            registeredClients["_last_sender"] = sourceTunnel
        else
            addToLog("Wireless send FAILED", "ERROR")
        end
        
    else
        -- ==========================================
        -- FROM SERVER (via wireless)
        -- ==========================================
        if port ~= PORT then
            return
        end
        
        if sender == serverAddress then
            -- Try to decrypt message from server
            local decrypted = decryptMessage(message)
            local messageToUse = decrypted or message
            
            -- Parse to determine routing
            local success, data = pcall(serialization.unserialize, messageToUse)
            
            if success and data then
                -- If it has a target controller, route to specific tunnel
                if data.target_controller then
                    local targetClient = registeredClients[data.target_controller]
                    if targetClient and targetClient.tunnel then
                        addToLog("→ Specific controller", "SERVER")
                        pcall(targetClient.tunnel.send, messageToUse)
                        stats.messagesToClients = stats.messagesToClients + 1
                        return
                    end
                end
                
                -- Broadcast commands to all controllers (except sync_trusted)
                if data.type == "add_player" or data.type == "remove_player" then
                    addToLog("→ Broadcast to controllers", "SERVER")
                    
                    for clientId, client in pairs(registeredClients) do
                        if clientId ~= "_last_sender" and client.type == "controller" then
                            pcall(client.tunnel.send, messageToUse)
                            stats.messagesToClients = stats.messagesToClients + 1
                        end
                    end
                    return
                end
                
                -- sync_trusted is sent to specific controller (last sender)
                if data.type == "sync_trusted" then
                    local targetTunnel = registeredClients["_last_sender"]
                    
                    if targetTunnel then
                        addToLog("→ Sync to controller", "SERVER")
                        pcall(targetTunnel.send, messageToUse)
                        stats.messagesToClients = stats.messagesToClients + 1
                    else
                        addToLog("No target for sync!", "ERROR")
                    end
                    return
                end
            end
            
            -- Default: send to last sender
            local targetTunnel = registeredClients["_last_sender"]
            
            if targetTunnel then
                addToLog("→ Last sender", "SERVER")
                pcall(targetTunnel.send, messageToUse)
                stats.messagesToClients = stats.messagesToClients + 1
            else
                addToLog("No target for response!", "ERROR")
            end
        else
            -- Might be server response during discovery
            local decrypted = decryptMessage(message)
            local messageToUse = decrypted or message
            
            local success, data = pcall(serialization.unserialize, messageToUse)
            if success and data and data.type == "server_response" then
                serverAddress = sender
                addToLog("SERVER IDENTIFIED", "SUCCESS")
            end
        end
    end
    
    updateDisplay()
end

-- Main
local function main()
    print("Starting Unified Turret Relay...")
    print("Relay Name: " .. RELAY_NAME)
    print("")
    
    -- Open port
    modem.open(PORT)
    modem.setStrength(400)
    print("Wireless port " .. PORT .. " opened (range: 400)")
    
    print("")
    print("Linked Cards Installed:")
    for i, tunnel in ipairs(tunnels) do
        print("  [" .. i .. "] Channel: " .. tunnel.getChannel())
        print("      Address: " .. tunnel.address)
    end
    print("")
    print("Supports:")
    print("  • Turret Controllers (cross-dimensional)")
    print("  • Client Managers (admin access)")
    print("")
    
    -- Find server
    print("Searching for central server...")
    if findServer() then
        print("✓ Server found!")
    else
        print("✗ Server not found - will keep trying")
    end
    
    print("")
    print("Relay running! Press Ctrl+C to stop")
    
    -- Start heartbeat
    event.timer(1, serverHeartbeat)
    
    -- Listen for ALL modem messages
    event.listen("modem_message", handleMessage)
    
    updateDisplay()
    
    addToLog("Unified relay started (" .. #tunnels .. " cards)", "SUCCESS")
    
    -- Keep running
    while true do
        os.sleep(1)
        stats.uptime = stats.uptime + 1
        
        -- Update display every 5 seconds to show offline status
        if stats.uptime % 5 == 0 then
            updateDisplay()
        end
        
        -- Cleanup stale clients and mark as offline
        local now = computer.uptime()
        local anyOffline = false
        
        for clientId, client in pairs(registeredClients) do
            if clientId ~= "_last_sender" and client.lastSeen then
                local timeDiff = now - client.lastSeen
                
                -- Mark as offline after 90 seconds
                if timeDiff >= 90 and not client.markedOffline then
                    client.markedOffline = true
                    anyOffline = true
                    
                    if client.type == "controller" then
                        addToLog("Controller OFFLINE: " .. (client.name or "Unknown"), "ERROR")
                    else
                        addToLog("Manager OFFLINE: " .. clientId:sub(1, 8), "ERROR")
                    end
                end
                
                -- Remove completely after 5 minutes
                if timeDiff > 300 then
                    registeredClients[clientId] = nil
                    
                    if client.type == "controller" then
                        addToLog("Controller removed: " .. (client.name or "Unknown"), "ERROR")
                    else
                        addToLog("Manager removed: " .. clientId:sub(1, 8), "ERROR")
                    end
                    
                    -- Recalculate stats
                    stats.controllers = 0
                    stats.managers = 0
                    for _, c in pairs(registeredClients) do
                        if c.type == "controller" then
                            stats.controllers = stats.controllers + 1
                        elseif c.type == "manager" then
                            stats.managers = stats.managers + 1
                        end
                    end
                    
                    anyOffline = true
                end
            end
        end
        
        -- Update display if anything went offline
        if anyOffline then
            updateDisplay()
        end
    end
end

local success, err = pcall(main)
if not success then
    print("Error: " .. tostring(err))
end

event.ignore("modem_message", handleMessage)
modem.close(PORT)
print("Relay stopped")
