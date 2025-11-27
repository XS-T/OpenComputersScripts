-- Digital Currency Relay (Multi-Client) for OpenComputers 1.7.10
-- Supports multiple linked cards, encryption, threaded handling, debug, and graceful shutdown

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require("computer")
local term = require("term")
local thread = require("thread")
local filesystem = require("filesystem")

-- CONFIGURATION
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

local SERVER_NAME = "Empire Credit Union"
local ENCRYPTION_KEY = data.md5(SERVER_NAME .. "RelaySecure2024")
local PORT = 1000
local RELAY_NAME = "Multi-Client Relay (Encrypted)"
local DEBUG = true
local running = true

-- Logging
local log = {}
local LOG_FILE = "/home/relay_debug.log"

local function writeLogToFile(entry)
    local ok, err = pcall(function()
        local f = io.open(LOG_FILE, "a")
        if f then
            f:write(string.format("[%s][%s] %s\n", entry.time, entry.category, entry.message))
            f:close()
        end
    end)
    if not ok then
        print("Failed to write log to file: " .. tostring(err))
    end
end

-- Encryption functions
local function encryptMessage(plaintext)
    if not plaintext or plaintext == "" then return nil end
    local iv = data.random(16)
    local encrypted = data.encrypt(plaintext, ENCRYPTION_KEY, iv)
    return data.encode64(iv .. encrypted)
end

local function decryptMessage(ciphertext)
    if not ciphertext or ciphertext == "" then return nil end
    local success, result = pcall(function()
        local combined = data.decode64(ciphertext)
        local iv = combined:sub(1, 16)
        local encrypted = combined:sub(17)
        return data.decrypt(encrypted, ENCRYPTION_KEY, iv)
    end)
    if success then return result else return nil end
end

-- Get all tunnels
local tunnels = {}
for address in component.list("tunnel") do
    table.insert(tunnels, component.proxy(address))
    print("Found linked card: " .. address:sub(1, 16))
end

if #tunnels == 0 then
    print("ERROR: No tunnel (linked card) found!")
    return
end
print("Total linked cards: " .. #tunnels)

-- State
local serverAddress = nil
local registeredClients = {}
local stats = {
    messagesForwarded = 0,
    messagesToClient = 0,
    uptime = 0,
    activeThreads = 0,
    totalMessages = 0
}

-- Display
local function updateDisplay()
    term.clear()
    print("═══════════════════════════════════════════════════════")
    print("Currency Relay - " .. RELAY_NAME)
    print("═══════════════════════════════════════════════════════")
    print("")
    print("Mode: MULTI-TUNNEL ←→ WIRELESS (ENCRYPTED + THREADED + DEBUG)")
    print("Clients via: LINKED CARDS (" .. #tunnels .. " cards)")
    print("Server via:  WIRELESS + AES ENCRYPTION")
    print("")
    
    if serverAddress then
        print("Server: ✓ CONNECTED (Encrypted)")
        print("Address: " .. serverAddress:sub(1,16))
    else
        print("Server: ✗ SEARCHING...")
    end
    
    print("")
    print("Linked Cards:")
    for i, tunnel in ipairs(tunnels) do
        local ok, ch = pcall(tunnel.getChannel, tunnel)
        print(" [" .. i .. "] Channel: " .. (ok and tostring(ch) or "(unknown)") .. " Address: " .. tunnel.address)
    end
    
    print("")
    print("Wireless Port: " .. PORT)
    print("Messages Forwarded: " .. stats.messagesForwarded)
    print("Messages to Clients: " .. stats.messagesToClient)
    print("Active Threads: " .. stats.activeThreads)
    print("Total Messages: " .. stats.totalMessages)
    print("Registered Clients: " .. (function() local c=0; for _ in pairs(registeredClients) do c=c+1 end return c end)())
    print("═══════════════════════════════════════════════════════")
    print("ACTIVITY LOG (last 10 entries):")
    for i=1, math.min(10,#log) do
        local e = log[i]
        print("[" .. e.time .. "][" .. e.category .. "] " .. e.message)
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
    if #log > 200 then
        for i = 201, #log do log[i] = nil end
    end
    writeLogToFile(entry)
    if DEBUG or category ~= "DEBUG" then
        updateDisplay()
    end
end

-- Server discovery
local function findServer()
    if serverAddress then return true end
    addToLog("Searching for server...", "INFO")
    local ping = serialization.serialize({ type="relay_ping", relay_name=RELAY_NAME })
    modem.broadcast(PORT, encryptMessage(ping))
    
    local deadline = computer.uptime() + 3
    while computer.uptime() < deadline do
        local evt = {event.pull(0.5, "modem_message")}
        if evt[1] then
            local _,_,sender,port,_,message = table.unpack(evt)
            if port == PORT then
                local decrypted = decryptMessage(message)
                if decrypted then
                    local ok,data = pcall(serialization.unserialize, decrypted)
                    if ok and data and data.type=="server_response" then
                        serverAddress = sender
                        addToLog("Server found: " .. sender:sub(1,8), "SUCCESS")
                        return true
                    end
                end
            end
        end
    end
    addToLog("Server not found", "ERROR")
    return false
end

-- Heartbeat thread
local function serverHeartbeat()
    while running do
        os.sleep(30)
        if serverAddress then
            local clientCount = 0
            for _ in pairs(registeredClients) do clientCount = clientCount + 1 end
            local hb = serialization.serialize({ type="relay_heartbeat", relay_name=RELAY_NAME, clients=clientCount })
            modem.send(serverAddress, PORT, encryptMessage(hb))
            addToLog("Heartbeat sent (" .. clientCount .. " clients)", "SERVER")
        else
            findServer()
        end
    end
end

-- Tunnel detection helper
local function isTunnelMessage(sender, port, distance)
    return port == 0 or distance == nil
end

-- Message handler
local function handleMessage(eventType, _, sender, port, distance, message)
    stats.totalMessages = stats.totalMessages + 1
    thread.create(function()
        stats.activeThreads = stats.activeThreads + 1
        addToLog("MSG: sender=" .. tostring(sender):sub(1,8), "DEBUG")
        
        local tunnelMsg = isTunnelMessage(sender, port, distance)
        if tunnelMsg then
            addToLog("← CLIENT via tunnel", "CLIENT")
            local ok,data = pcall(serialization.unserialize, message)
            if not ok or not data then
                addToLog("ERROR: Failed to parse client message", "ERROR")
                stats.activeThreads = stats.activeThreads - 1
                return
            end
            
            -- Registration
            if data.type == "client_register" then
                local clientId = data.tunnelAddress or data.clientId or sender
                registeredClients[clientId] = { tunnel=tunnels[1], clientTunnelAddress=clientId, lastSeen=os.time() }
                addToLog("CLIENT REGISTERED: " .. clientId:sub(1,8), "SUCCESS")
                
                local ack = serialization.serialize({ type="relay_ack", relay_name=RELAY_NAME, server_connected = serverAddress ~= nil })
                pcall(tunnels[1].send, ack)
                stats.activeThreads = stats.activeThreads - 1
                return
            end
            
            -- Forward message to server
            if serverAddress then
                local encryptedMessage = encryptMessage(message)
                local ok,err = pcall(modem.send, serverAddress, PORT, encryptedMessage)
                if ok then
                    stats.messagesForwarded = stats.messagesForwarded + 1
                    addToLog("Forwarded to server", "SERVER")
                else
                    addToLog("Failed forwarding to server: " .. tostring(err), "ERROR")
                end
            else
                findServer()
            end
        else
            -- FROM SERVER
            if port ~= PORT then stats.activeThreads = stats.activeThreads - 1 return end
            addToLog("← SERVER (Wireless)", "SERVER")
            local decrypted = decryptMessage(message)
            if not decrypted then addToLog("Decryption failed", "ERROR") stats.activeThreads = stats.activeThreads - 1 return end
            local lastTunnel = registeredClients["_last_sender"]
            if lastTunnel then pcall(lastTunnel.send, decrypted); stats.messagesToClient = stats.messagesToClient + 1 end
        end
        
        stats.activeThreads = stats.activeThreads - 1
    end):detach()
end

-- Key handler for debug toggle and shutdown
local function keyHandler(_, _, char, code)
    if not char then return end
    char = string.lower(type(char)=="number" and string.char(char) or char)
    if char == "d" then
        DEBUG = not DEBUG
        addToLog("Debug toggled: " .. (DEBUG and "ON" or "OFF"), "DEBUG")
    elseif char == "q" then
        addToLog("Shutdown requested via key press", "INFO")
        running = false
    end
end

-- MAIN
local function main()
    term.clear()
    modem.open(PORT)
    modem.setStrength(400)
    addToLog("Relay starting on port " .. PORT, "INFO")
    
    -- Start heartbeat thread
    thread.create(serverHeartbeat):detach()
    
    -- Listen for messages
    event.listen("modem_message", handleMessage)
    event.listen("key_down", keyHandler)
    
    updateDisplay()
    
    while running do
        os.sleep(1)
        stats.uptime = stats.uptime + 1
        
        -- cleanup stale clients
        local now = os.time()
        for clientId, client in pairs(registeredClients) do
            if clientId ~= "_last_sender" and client.lastSeen and now - client.lastSeen > 300 then
                registeredClients[clientId] = nil
                addToLog("Client timed out: " .. clientId:sub(1,8), "CLIENT")
            end
        end
    end
    
    -- Cleanup on shutdown
    event.ignore("modem_message", handleMessage)
    event.ignore("key_down", keyHandler)
    modem.close(PORT)
    addToLog("Relay stopped gracefully", "INFO")
    term.clear()
    print("Relay stopped gracefully")
end

local ok, err = pcall(main)
if not ok then print("Error: " .. tostring(err)) end
