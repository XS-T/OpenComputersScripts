-- Digital Currency Relay (Multi-Client) for OpenComputers 1.7.10
-- SUPPORTS MULTIPLE LINKED CARDS with ENCRYPTION + THREADED
-- Receives from clients via TUNNEL (linked cards)
-- Forwards to server via WIRELESS (ENCRYPTED)

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require("computer")
local term = require("term")
local thread = require("thread")

-- Check for required components
if not component.isAvailable("modem") then
    print("ERROR: Wireless Network Card required!")
    return
end

if not component.isAvailable("data") then
    print("ERROR: Data Card (Tier 2+) required for encryption!")
    return
end

local modem = component.modem
local data = component.data

-- Encryption key (must match server)
local ENCRYPTION_KEY_BASE = "e2x36U7W0ZmUVjWH"
--local ENCRYPTION_KEY = ENCRYPTION_KEY_BASE .. string.rep("\0", 32 - #ENCRYPTION_KEY_BASE)

-- Encryption functions
local function encryptMessage(message)
    -- Generate random 16-byte IV (128 bits)
    local iv = ""
    for i = 1, 16 do
        iv = iv .. string.char(math.random(0, 255))
    end
    -- Encrypt using AES-256
    local encrypted = data.encrypt(message, ENCRYPTION_KEY, iv)
    -- Prepend IV to encrypted data
    return iv .. encrypted
end

local function decryptMessage(encryptedData)
    if not encryptedData or #encryptedData < 16 then
        return nil
    end
    -- Extract IV (first 16 bytes)
    local iv = encryptedData:sub(1, 16)
    -- Extract encrypted content (rest)
    local encrypted = encryptedData:sub(17)
    -- Decrypt
    local success, decrypted = pcall(data.decrypt, encrypted, ENCRYPTION_KEY, iv)
    if success then
        return decrypted
    end
    return nil
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
    print("This relay needs at least one linked card to communicate with clients.")
    print("Install linked cards for each client you want to support.")
    return
end

print("Total linked cards: " .. #tunnels)

-- Configuration
local PORT = 1000
local RELAY_NAME = "Multi-Client Relay (Encrypted)"

-- State
local serverAddress = nil
local registeredClients = {} -- clientId -> {tunnel = tunnelObj, lastSeen = time}
local stats = {
    messagesForwarded = 0,
    messagesToClient = 0,
    uptime = 0,
    activeThreads = 0,
    totalMessages = 0
}

-- Screen setup
term.clear()

-- Logging
local log = {}

-- Display (defined first so addToLog can use it)
local function updateDisplay()
    term.clear()
    print("═══════════════════════════════════════════════════════")
    print("Currency Relay - " .. RELAY_NAME)
    print("═══════════════════════════════════════════════════════")
    print("")
    print("Mode: MULTI-TUNNEL ←→ WIRELESS (ENCRYPTED + THREADED)")
    print("  Clients connect via: LINKED CARDS (" .. #tunnels .. " cards)")
    print("  Server connect via:  WIRELESS + AES ENCRYPTION")
    print("")
    
    if serverAddress then
        print("Server: ✓ CONNECTED (Encrypted)")
        print("  Address: " .. serverAddress:sub(1, 16))
    else
        print("Server: ✗ SEARCHING...")
    end
    
    print("")
    
    -- Show all tunnel channels
    print("Linked Cards:")
    for i, tunnel in ipairs(tunnels) do
        print("  [" .. i .. "] " .. tunnel.getChannel():sub(1, 24))
    end
    
    print("")
    print("Wireless Port: " .. PORT)
    print("Messages Forwarded: " .. stats.messagesForwarded)
    print("Messages to Clients: " .. stats.messagesToClient)
    print("Active Threads: " .. stats.activeThreads)
    print("Total Messages: " .. stats.totalMessages)
    print("Registered Clients: " .. (function() local c=0; for _ in pairs(registeredClients) do c=c+1 end return c end)())
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
        elseif entry.category == "CLIENT" then
            io.write("\27[36m") -- Cyan
        elseif entry.category == "SERVER" then
            io.write("\27[33m") -- Yellow
        elseif entry.category == "DEBUG" then
            io.write("\27[35m") -- Magenta
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
    
    addToLog("Searching for server...", "SEARCH")
    
    local ping = serialization.serialize({
        type = "relay_ping",
        relay_name = RELAY_NAME
    })
    
    -- Encrypt the ping
    local encryptedPing = encryptMessage(ping)
    
    modem.broadcast(PORT, encryptedPing)
    
    -- Wait for response
    local deadline = computer.uptime() + 3
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, sender, port, _, message = table.unpack(eventData)
            if port == PORT then
                -- Try to decrypt
                local decrypted = decryptMessage(message)
                if decrypted then
                    local success, data = pcall(serialization.unserialize, decrypted)
                    if success and data and data.type == "server_response" then
                        serverAddress = sender
                        addToLog("Server found: " .. sender:sub(1, 8), "SUCCESS")
                        return true
                    end
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
            local clientCount = 0
            for _ in pairs(registeredClients) do
                clientCount = clientCount + 1
            end
            
            local heartbeat = serialization.serialize({
                type = "relay_heartbeat",
                relay_name = RELAY_NAME,
                clients = clientCount
            })
            
            -- Encrypt heartbeat
            local encryptedHeartbeat = encryptMessage(heartbeat)
            
            modem.send(serverAddress, PORT, encryptedHeartbeat)
            addToLog("Heartbeat sent (" .. clientCount .. " clients)", "SERVER")
        else
            findServer()
        end
    end
end

-- Find which tunnel a message came from
local function getTunnelBySender(sender)
    -- When message comes via tunnel, sender is the tunnel's own address
    for _, tunnel in ipairs(tunnels) do
        if tunnel.address == sender then
            return tunnel
        end
    end
    return nil
end

-- Get tunnel by checking if it's in our list
local function isTunnelMessage(sender, port, distance)
    -- Tunnel messages have port == 0 OR distance == nil
    if port ~= 0 and distance ~= nil and distance ~= math.huge then
        return false, nil
    end
    
    -- For tunnel messages, sender is the COMPUTER address, not tunnel address
    -- So we can't match by sender. Instead, we need to check ALL tunnels
    -- and see if any received a message (we'll determine this from the message content)
    
    -- Port 0 or nil distance means it's definitely a tunnel message
    -- We'll figure out WHICH tunnel from the registration data
    return true, nil  -- Return true but tunnel unknown until we parse message
end

-- Unified message handler - handles both tunnel and wireless
local function handleMessage(eventType, _, sender, port, distance, message)
    -- Increment total message counter
    stats.totalMessages = stats.totalMessages + 1
    
    -- Spawn thread to handle this message concurrently
    thread.create(function()
        stats.activeThreads = stats.activeThreads + 1
        
        -- DEBUG: Log all incoming messages
        addToLog("MSG: sender=" .. sender:sub(1,8) .. " port=" .. tostring(port) .. " dist=" .. tostring(distance), "DEBUG")
        
        -- Check if sender matches any of our tunnels
        local matchedTunnel = false
        for i, tunnel in ipairs(tunnels) do
            if tunnel.address == sender then
                addToLog("  Matched tunnel #" .. i, "DEBUG")
                matchedTunnel = true
                break
            end
        end
        
        if not matchedTunnel and (port == 0 or distance == nil) then
            addToLog("  Looks like tunnel but NO MATCH!", "DEBUG")
            addToLog("  Known tunnels:", "DEBUG")
            for i, tunnel in ipairs(tunnels) do
                addToLog("    [" .. i .. "] " .. tunnel.address:sub(1,16), "DEBUG")
            end
        end
        
        -- Check if this is a tunnel message and which tunnel
    local isTunnel, sourceTunnel = isTunnelMessage(sender, port, distance)
    
    if isTunnel then
        -- ==========================================
        -- FROM CLIENT (via tunnel) - NOT ENCRYPTED
        -- ==========================================
        addToLog("← CLIENT via tunnel (port=" .. tostring(port) .. ")", "CLIENT")
        
        -- Parse message first to get client's tunnel address
        local success, data = pcall(serialization.unserialize, message)
        
        if not success or not data then
            addToLog("ERROR: Failed to parse message", "ERROR")
            return
        end
        
        -- Find which tunnel to use based on client's tunnel address
        local sourceTunnel = nil
        
        if data.tunnelAddress then
            -- Client sent their tunnel address - find our paired tunnel
            local clientTunnelAddr = data.tunnelAddress
            addToLog("  Client tunnel: " .. clientTunnelAddr:sub(1, 8), "DEBUG")
            
            -- Try to match by channel (paired tunnels have same channel)
            if data.tunnelChannel then
                for i, tunnel in ipairs(tunnels) do
                    if tunnel.getChannel() == data.tunnelChannel then
                        sourceTunnel = tunnel
                        addToLog("  Matched tunnel #" .. i .. " by channel", "SUCCESS")
                        break
                    end
                end
            end
        end
        
        -- If still no match, try to find from registered clients
        if not sourceTunnel and data.tunnelAddress then
            local client = registeredClients[data.tunnelAddress]
            if client then
                sourceTunnel = client.tunnel
                addToLog("  Using registered tunnel", "DEBUG")
            end
        end
        
        -- Last resort: use first tunnel (for single-tunnel setups)
        if not sourceTunnel and #tunnels == 1 then
            sourceTunnel = tunnels[1]
            addToLog("  Using only available tunnel", "DEBUG")
        end
        
        if not sourceTunnel then
            addToLog("ERROR: Cannot determine source tunnel!", "ERROR")
            addToLog("  Client tunnel: " .. tostring(data.tunnelAddress), "ERROR")
            addToLog("  Available tunnels: " .. #tunnels, "ERROR")
            return
        end
        
        -- Data is already parsed above
        
        if data then
            -- Handle client registration
            if data.type == "client_register" then
                local clientTunnelAddr = data.tunnelAddress or data.clientId or sender
                
                addToLog("Client tunnel: " .. clientTunnelAddr:sub(1, 8), "CLIENT")
                
                -- Use client's tunnel address as their ID
                local clientId = clientTunnelAddr
                
                registeredClients[clientId] = {
                    tunnel = sourceTunnel,           -- The relay tunnel that received this
                    clientTunnelAddress = clientTunnelAddr,  -- Client's tunnel address
                    relayTunnelAddress = sourceTunnel.address, -- Relay's tunnel address
                    lastSeen = os.time()
                }
                
                addToLog("CLIENT REGISTERED: " .. clientId:sub(1, 8), "SUCCESS")
                addToLog("  Client tunnel: " .. clientTunnelAddr:sub(1,16), "SUCCESS")
                addToLog("  Relay tunnel: " .. sourceTunnel.address:sub(1,16), "SUCCESS")
                addToLog("  Channel: " .. sourceTunnel.getChannel():sub(1,16), "SUCCESS")
                
                -- Send acknowledgment back to client via same tunnel
                local ack = {
                    type = "relay_ack",
                    relay_name = RELAY_NAME,
                    server_connected = serverAddress ~= nil
                }
                
                local ackMsg = serialization.serialize(ack)
                local sendOk, sendErr = pcall(sourceTunnel.send, ackMsg)
                
                if sendOk then
                    addToLog("  ACK sent via tunnel", "SUCCESS")
                else
                    addToLog("  ACK FAILED: " .. tostring(sendErr), "ERROR")
                end
                
                updateDisplay()
                return
            end
            
            -- Handle client deregistration
            if data.type == "client_deregister" or data.type == "client_disconnect" then
                local clientId = data.tunnelAddress or data.clientId or sender
                registeredClients[clientId] = nil
                
                addToLog("CLIENT DISCONNECTED: " .. clientId:sub(1, 8), "CLIENT")
                updateDisplay()
                return
            end
        end
        
        -- Regular message forwarding to server
        if not serverAddress then
            addToLog("NO SERVER - attempting discovery", "ERROR")
            if not findServer() then
                addToLog("SERVER DISCOVERY FAILED", "ERROR")
                -- Send error back to client via same tunnel
                if sourceTunnel then
                    local errorMsg = serialization.serialize({
                        type = "response",
                        success = false,
                        message = "Relay cannot reach server"
                    })
                    pcall(sourceTunnel.send, errorMsg)
                end
                return
            else
                addToLog("SERVER FOUND: " .. serverAddress, "SUCCESS")
            end
        end
        
        -- Forward to server via wireless WITH ENCRYPTION
        addToLog("→ SERVER: Forwarding (encrypted, " .. #message .. " bytes)", "SERVER")
        
        -- Encrypt before sending
        local encryptedMessage = encryptMessage(message)
        
        local sendOk, sendErr = pcall(modem.send, serverAddress, PORT, encryptedMessage)
        if sendOk then
            stats.messagesForwarded = stats.messagesForwarded + 1
            addToLog("  Wireless send: SUCCESS (encrypted)", "SUCCESS")
            
            -- Store which tunnel sent this so we can reply to them
            -- We'll use the sender address as a temporary key
            registeredClients["_last_sender"] = sourceTunnel
        else
            addToLog("  Wireless send FAILED: " .. tostring(sendErr), "ERROR")
        end
        
    else
        -- ==========================================
        -- FROM SERVER (via wireless) - ENCRYPTED
        -- ==========================================
        if port ~= PORT then
            return
        end
        
        addToLog("← SERVER (Wireless, encrypted)", "SERVER")
        
        -- Decrypt the message first
        local decryptedMessage = decryptMessage(message)
        
        if not decryptedMessage then
            addToLog("  Decryption FAILED", "ERROR")
            return
        end
        
        addToLog("  Decrypted successfully", "SUCCESS")
        
        if sender == serverAddress then
            -- Message from server - forward to client via tunnel
            -- Use the last tunnel that sent us a message
            local targetTunnel = registeredClients["_last_sender"]
            
            if targetTunnel then
                addToLog("→ CLIENT: Forwarding via tunnel", "CLIENT")
                
                -- Send DECRYPTED message to client (tunnel is secure)
                local sendOk, sendErr = pcall(targetTunnel.send, decryptedMessage)
                if sendOk then
                    stats.messagesToClient = stats.messagesToClient + 1
                    addToLog("  Tunnel send: SUCCESS", "SUCCESS")
                else
                    addToLog("  Tunnel send FAILED: " .. tostring(sendErr), "ERROR")
                end
            else
                addToLog("No target tunnel for response!", "ERROR")
            end
        else
            addToLog("Unknown sender: " .. sender:sub(1, 16), "ERROR")
            -- Might be server response during discovery
            local success, data = pcall(serialization.unserialize, decryptedMessage)
            if success and data and data.type == "server_response" then
                serverAddress = sender
                addToLog("SERVER IDENTIFIED: " .. sender:sub(1, 8), "SUCCESS")
            end
        end
    end
    
    updateDisplay()
    stats.activeThreads = stats.activeThreads - 1
    end):detach()  -- Detach thread so it doesn't block relay
end

-- Main
local function main()
    print("Starting Multi-Client Currency Relay (Encrypted)...")
    print("Relay Name: " .. RELAY_NAME)
    print("")
    
    -- Open port
    modem.open(PORT)
    modem.setStrength(400)
    print("Wireless port " .. PORT .. " opened (range: 400)")
    print("Encryption: AES (Data Card)")
    
    print("")
    print("Linked Cards Installed:")
    for i, tunnel in ipairs(tunnels) do
        print("  [" .. i .. "] Channel: " .. tunnel.getChannel())
        print("      Address: " .. tunnel.address)
    end
    print("")
    print("Each client needs a PAIRED linked card!")
    print("Pair " .. #tunnels .. " linked cards and give them to clients.")
    print("")
    
    -- Find server
    print("Searching for server...")
    if findServer() then
        print("✓ Server found!")
    else
        print("✗ Server not found - will keep trying")
    end
    
    print("")
    print("Relay running! Press Ctrl+C to stop")
    print("Waiting for client messages via tunnels...")
    print("Server communication is ENCRYPTED")
    print("")
    
    -- Start heartbeat
    event.timer(1, serverHeartbeat)
    
    -- Listen for ALL modem messages (both tunnel and wireless)
    event.listen("modem_message", handleMessage)
    
    updateDisplay()
    
    addToLog("Multi-Client relay started (" .. #tunnels .. " cards, encrypted)", "SUCCESS")
    
    -- Keep running
    while true do
        os.sleep(1)
        stats.uptime = stats.uptime + 1
        
        -- Cleanup stale clients (haven't sent anything in 5 minutes)
        local now = os.time()
        for clientId, client in pairs(registeredClients) do
            if clientId ~= "_last_sender" and client.lastSeen then
                if now - client.lastSeen > 300 then
                    registeredClients[clientId] = nil
                    addToLog("Client timeout: " .. clientId:sub(1, 8), "CLIENT")
                end
            end
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
