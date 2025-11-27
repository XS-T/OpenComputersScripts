-- Digital Currency Relay (Multi-Client) for OpenComputers 1.7.10
-- SUPPORTS MULTIPLE LINKED CARDS with ENCRYPTION + THREADED + DEBUG + FILE LOG
-- Added: debug toggle, file logging, safe shutdown
-- Original functionality preserved

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require("computer")
local term = require("term")
local thread = require("thread")

-- Debug toggle
local DEBUG = true

-- Shutdown flag
local RUNNING = true

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

-- Encryption key
local SERVER_NAME = "Empire Credit Union"
local ENCRYPTION_KEY = data.md5(SERVER_NAME .. "RelaySecure2024")

-- Get ALL tunnel components (linked cards)
local tunnels = {}
for address in component.list("tunnel") do
    table.insert(tunnels, component.proxy(address))
    print("Found linked card: " .. address:sub(1, 16))
end

if #tunnels == 0 then
    print("ERROR: No Tunnel (Linked Card) found!")
    return
end

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

-- Forward declaration so addToLog can call updateDisplay
local updateDisplay
local handleMessage

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

-- Display function (unchanged functionality)
updateDisplay = function()
    term.clear()
    print("═══════════════════════════════════════════════════════")
    print("Currency Relay - " .. RELAY_NAME)
    print("═══════════════════════════════════════════════════════")
    print("")
    print("Mode: MULTI-TUNNEL ←→ WIRELESS (ENCRYPTED + THREADED + DEBUG)")
    print("Clients via LINKED CARDS: " .. #tunnels)
    print("Server via WIRELESS + AES")
    print("")
    if serverAddress then
        print("Server: ✓ CONNECTED")
        print("Address: " .. serverAddress:sub(1,16))
    else
        print("Server: ✗ SEARCHING...")
    end
    print("")
    print("Linked Cards:")
    for i, tunnel in ipairs(tunnels) do
        local ok, ch = pcall(tunnel.getChannel, tunnel)
        if ok then
            print(" ["..i.."] Channel: "..tostring(ch):sub(1,16))
        else
            print(" ["..i.."] Channel: unknown")
        end
    end
    print("")
    print("Wireless Port: " .. PORT)
    print("Messages Forwarded: " .. stats.messagesForwarded)
    print("Messages to Clients: " .. stats.messagesToClient)
    print("Active Threads: " .. stats.activeThreads)
    print("Total Messages: " .. stats.totalMessages)
    print("Registered Clients: " .. (function() local c=0; for _ in pairs(registeredClients) do c=c+1 end; return c end)())
    print("")
    print("═══════════════════════════════════════════════════════")
    print("ACTIVITY LOG:")
    print("═══════════════════════════════════════════════════════")
    for i = 1, math.min(10,#log) do
        local entry = log[i]
        if entry.category == "SUCCESS" then io.write("\27[32m")
        elseif entry.category == "ERROR" then io.write("\27[31m")
        elseif entry.category == "CLIENT" then io.write("\27[36m")
        elseif entry.category == "SERVER" then io.write("\27[33m")
        elseif entry.category == "DEBUG" then io.write("\27[35m") end
        print("["..entry.time.."] "..entry.message)
        io.write("\27[0m")
    end
end

-- Encryption key (must match server)
local SERVER_NAME = "Empire Credit Union"
local ENCRYPTION_KEY = data.md5(SERVER_NAME .. "RelaySecure2024")

-- Relay encryption functions
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

-- Server discovery
local function findServer()
    if serverAddress then return true end
    addToLog("Searching for server...", "DEBUG")
    local ping = serialization.serialize({type="relay_ping", relay_name=RELAY_NAME})
    local encryptedPing = encryptMessage(ping)
    modem.broadcast(PORT, encryptedPing)
    local deadline = computer.uptime() + 3
    while computer.uptime() < deadline do
        local e = {event.pull(0.5,"modem_message")}
        if e[1] then
            local _,_,sender,port,_,message = table.unpack(e)
            if port == PORT then
                local decrypted = decryptMessage(message)
                if decrypted then
                    local ok, data = pcall(serialization.unserialize,decrypted)
                    if ok and data and data.type=="server_response" then
                        serverAddress = sender
                        addToLog("Server found: "..sender:sub(1,8),"SUCCESS")
                        return true
                    end
                else
                    addToLog("Received server response but decryption failed","DEBUG")
                end
            end
        end
    end
    addToLog("Server not found","ERROR")
    return false
end

-- Server heartbeat
local function serverHeartbeat()
    while RUNNING do
        os.sleep(30)
        if serverAddress then
            local clientCount = 0
            for _ in pairs(registeredClients) do clientCount = clientCount + 1 end
            local heartbeat = serialization.serialize({
                type="relay_heartbeat",
                relay_name=RELAY_NAME,
                clients=clientCount
            })
            local encryptedHeartbeat = encryptMessage(heartbeat)
            modem.send(serverAddress, PORT, encryptedHeartbeat)
            addToLog("Heartbeat sent ("..clientCount.." clients)","SERVER")
        else
            findServer()
        end
    end
end

-- Stop relay
local function stopRelay()
    RUNNING = false
    event.ignore("modem_message", handleMessage)
    modem.close(PORT)
    addToLog("Relay stopped by stopRelay()","INFO")
end

-- Tunnel helpers
local function isTunnelMessage(sender,port,distance)
    if port ~= 0 and distance ~= nil and distance ~= math.huge then
        return false, nil
    end
    return true,nil
end

-- Message handler
handleMessage = function(eventType, _, sender, port, distance, message)
    stats.totalMessages = stats.totalMessages + 1
    thread.create(function()
        stats.activeThreads = stats.activeThreads + 1
        addToLog("MSG: sender="..tostring(sender):sub(1,8).." port="..tostring(port).." dist="..tostring(distance),"DEBUG")
        local isTunnel,_ = isTunnelMessage(sender,port,distance)

        if isTunnel then
            addToLog("← CLIENT via tunnel (port="..tostring(port)..")","CLIENT")
            addToLog("CLIENT RAW → "..tostring(message),"DEBUG")
            local ok,data = pcall(serialization.unserialize,message)
            if not ok or not data then
                addToLog("ERROR: Failed to parse client message: "..tostring(message),"ERROR")
                stats.activeThreads = stats.activeThreads - 1
                return
            end
            if data.type=="client_register" then
                local clientId = data.tunnelAddress or data.clientId or sender
                registeredClients[clientId] = {tunnel=tunnels[1], lastSeen=os.time()}
                addToLog("CLIENT REGISTERED: "..clientId:sub(1,8),"SUCCESS")
            end
            if data.type=="client_deregister" then
                local clientId = data.tunnelAddress or data.clientId or sender
                registeredClients[clientId] = nil
                addToLog("CLIENT DEREGISTERED: "..clientId:sub(1,8),"CLIENT")
            end
            -- Forward to server
            if serverAddress then
                local encryptedMessage = encryptMessage(message)
                local sendOk,sendErr = pcall(modem.send, serverAddress, PORT, encryptedMessage)
                if sendOk then
                    stats.messagesForwarded = stats.messagesForwarded + 1
                    addToLog("→ SERVER: Forwarded","SUCCESS")
                else
                    addToLog("→ SERVER: Failed "..tostring(sendErr),"ERROR")
                end
            else
                addToLog("NO SERVER - cannot forward","ERROR")
            end
        else
            if port ~= PORT then
                stats.activeThreads = stats.activeThreads - 1
                return
            end
            addToLog("← SERVER (Wireless, encrypted)","SERVER")
            local decryptedMessage = decryptMessage(message)
            if decryptedMessage then
                addToLog("SERVER → RELAY (DECRYPTED): "..tostring(decryptedMessage),"DEBUG")
                local targetTunnel = registeredClients["_last_sender"]
                if targetTunnel then
                    local sendOk,sendErr = pcall(targetTunnel.send,decryptedMessage)
                    if sendOk then
                        stats.messagesToClient = stats.messagesToClient + 1
                        addToLog("→ CLIENT: Forwarded","SUCCESS")
                    else
                        addToLog("→ CLIENT: Failed "..tostring(sendErr),"ERROR")
                    end
                end
            else
                addToLog("Server message decryption failed","ERROR")
            end
        end
        stats.activeThreads = stats.activeThreads - 1
    end):detach()
end

-- Main function
local function main()
    print("Starting Multi-Client Currency Relay (Encrypted, DEBUG PLAINTEXT)...")
    modem.open(PORT)
    modem.setStrength(400)
    thread.create(serverHeartbeat):detach()
    event.listen("modem_message", handleMessage)
    updateDisplay()
    addToLog("Relay started ("..#tunnels.." cards, debug="..tostring(DEBUG)..")","SUCCESS")

    while RUNNING do
        os.sleep(1)
        stats.uptime = stats.uptime + 1
        local now = os.time()
        for clientId, client in pairs(registeredClients) do
            if clientId ~= "_last_sender" and client.lastSeen and (now - client.lastSeen > 300) then
                registeredClients[clientId] = nil
                addToLog("Client timeout: "..clientId:sub(1,8),"CLIENT")
            end
        end
    end
end

-- Run main
local success, err = pcall(main)
if not success then
    print("Error: "..tostring(err))
end

stopRelay()
print("Relay stopped")
