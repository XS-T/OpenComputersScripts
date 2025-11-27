-- Digital Currency Relay (Multi-Client) for OpenComputers 1.7.10
-- Encryption + Multi-Tunnel + Threaded + File Debug Logging + Debug Toggle (press 'D')

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require("computer")
local term = require("term")
local thread = require("thread")
local filesystem = require("filesystem")

-- Requirement checks
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

-- ==========================
-- CONFIG
-- ==========================
local SERVER_NAME = "Empire Credit Union"
local PORT = 1000
local RELAY_NAME = "Multi-Client Relay (Encrypted)"

-- File logging config
local DEBUG = true                    -- default debug on
local LOG_FILE = "/home/relay_debug.log"
local ROTATED_LOG_FILE = "/home/relay_debug.log.1"
local MAX_LOG_BYTES = 100 * 1024      -- rotate when > ~100KB

-- Encryption key (must match server)
local ENCRYPTION_KEY = data.md5(SERVER_NAME .. "RelaySecure2024")

-- ==========================
-- ENCRYPT/DECRYPT HELPERS
-- ==========================
local function encryptMessage(plaintext)
    if not plaintext or plaintext == "" then return nil end
    local iv = data.random(16)
    local encrypted = data.encrypt(plaintext, ENCRYPTION_KEY, iv)
    return data.encode64(iv .. encrypted)
end

local function decryptMessage(ciphertext)
    if not ciphertext or ciphertext == "" then return nil end
    local ok, result = pcall(function()
        local combined = data.decode64(ciphertext)
        local iv = combined:sub(1, 16)
        local encrypted = combined:sub(17)
        return data.decrypt(encrypted, ENCRYPTION_KEY, iv)
    end)
    if ok then return result else return nil end
end

-- ==========================
-- TUNNELS (linked cards)
-- ==========================
local tunnels = {}
for addr in component.list("tunnel") do
    local ok, proxy = pcall(component.proxy, addr)
    if ok and proxy then
        table.insert(tunnels, proxy)
        print("Found linked card: " .. tostring(addr):sub(1,16))
    end
end

if #tunnels == 0 then
    print("ERROR: No Tunnel (Linked Card) found!")
    print("Install at least one linked card for client connectivity.")
    return
end
print("Total linked cards: " .. #tunnels)

-- ==========================
-- STATE
-- ==========================
local serverAddress = nil
local registeredClients = {}   -- clientId -> {tunnel = tunnelObj, clientTunnelAddress, relayTunnelAddress, lastSeen}
local stats = {
    messagesForwarded = 0,
    messagesToClient = 0,
    uptime = 0,
    activeThreads = 0,
    totalMessages = 0
}

-- ==========================
-- LOGGING
-- ==========================
local function rotateLogIfNeeded()
    -- rotate when file exists and is too large
    if filesystem.exists(LOG_FILE) then
        local ok, size = pcall(filesystem.size, LOG_FILE)
        if ok and size and size > MAX_LOG_BYTES then
            if filesystem.exists(ROTATED_LOG_FILE) then
                filesystem.remove(ROTATED_LOG_FILE)
            end
            -- rename (move) current to rotated
            filesystem.rename(LOG_FILE, ROTATED_LOG_FILE)
        end
    end
end

local function writeLogLine(line)
    -- Always write to file regardless of DEBUG? We'll write only when log exists, but include regardless so you keep full history.
    -- Use append mode, create directories if needed
    local ok, err = pcall(function()
        rotateLogIfNeeded()
        local f = io.open(LOG_FILE, "a")
        if not f then error("open failed") end
        f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. line .. "\n")
        f:close()
    end)
    if not ok then
        -- if writing fails, print to stderr once
        io.stderr:write("Log write failed: " .. tostring(err) .. "\n")
    end
end

local function addToLog(message, category)
    category = category or "INFO"
    local entry = "[" .. category .. "] " .. tostring(message)
    -- screen output only if DEBUG enabled (but we always write to file per your request)
    if DEBUG then
        -- keep terminal readable (don't clear here)
        print(os.date("%H:%M:%S") .. " " .. entry)
    end
    writeLogLine(entry)
end

-- ==========================
-- DISPLAY (simple periodic display update)
-- ==========================
local function updateDisplay()
    if not DEBUG then return end
    term.clear()
    print("═══════════════════════════════════════════════════════")
    print("Currency Relay - " .. RELAY_NAME)
    print("═══════════════════════════════════════════════════════")
    print("Mode: MULTI-TUNNEL ←→ WIRELESS (ENCRYPTED + THREADED + DEBUG)")
    print("Clients via: LINKED CARDS (" .. #tunnels .. " cards)")
    print("Server via:  WIRELESS + AES ENCRYPTION")
    print("")
    if serverAddress then
        print("Server: ✓ CONNECTED (Address: " .. serverAddress:sub(1,16) .. ")")
    else
        print("Server: ✗ SEARCHING...")
    end
    print("")
    print("Wireless Port: " .. PORT)
    print("Messages Forwarded: " .. stats.messagesForwarded)
    print("Messages to Clients: " .. stats.messagesToClient)
    print("Active Threads: " .. stats.activeThreads)
    print("Total Messages: " .. stats.totalMessages)
    local rc = 0
    for _ in pairs(registeredClients) do rc = rc + 1 end
    print("Registered Clients: " .. rc)
    print("═══════════════════════════════════════════════════════")
    print("Press 'D' to toggle debug logging to screen (file logging always on).")
end

-- ==========================
-- SERVER DISCOVERY
-- ==========================
local function findServer()
    if serverAddress then return true end
    addToLog("Searching for server (discovery ping)...", "SEARCH")
    local ping = serialization.serialize({ type = "relay_ping", relay_name = RELAY_NAME })
    local encryptedPing = encryptMessage(ping)
    modem.broadcast(PORT, encryptedPing)
    local deadline = computer.uptime() + 3
    while computer.uptime() < deadline do
        local ev = { event.pull(0.5, "modem_message") }
        if ev[1] then
            local _, _, sender, port, _, message = table.unpack(ev)
            if port == PORT then
                local dec = decryptMessage(message)
                if dec then
                    local ok, data = pcall(serialization.unserialize, dec)
                    if ok and data and data.type == "server_response" then
                        serverAddress = sender
                        addToLog("Server found at " .. sender, "SUCCESS")
                        return true
                    end
                else
                    addToLog("Server discovery: received encrypted message but decryption failed", "DEBUG")
                end
            end
        end
    end
    addToLog("Server discovery timed out", "ERROR")
    return false
end

-- ==========================
-- HEARTBEAT
-- ==========================
local function serverHeartbeat()
    while true do
        os.sleep(30)
        if serverAddress then
            local clientCount = 0 for _ in pairs(registeredClients) do clientCount = clientCount + 1 end
            local hb = serialization.serialize({ type = "relay_heartbeat", relay_name = RELAY_NAME, clients = clientCount })
            local enc = encryptMessage(hb)
            pcall(modem.send, serverAddress, PORT, enc)
            addToLog("Heartbeat sent to server (" .. clientCount .. " clients)", "SERVER")
        else
            findServer()
        end
    end
end

-- ==========================
-- UTIL: tunnel helpers
-- ==========================
local function findTunnelByChannel(channel)
    for i, t in ipairs(tunnels) do
        local ok, ch = pcall(t.getChannel, t)
        if ok and ch == channel then return t end
    end
    return nil
end

-- ==========================
-- MESSAGE HANDLER
-- ==========================
local function isTunnelMessage(sender, port, distance)
    -- Tunnel messages observed in this relay arrive with port == 0 or distance == nil
    if port ~= 0 and distance ~= nil and distance ~= math.huge then
        return false
    end
    return true
end

local function handleMessage(eventName, _, sender, port, distance, message)
    stats.totalMessages = stats.totalMessages + 1
    thread.create(function()
        stats.activeThreads = stats.activeThreads + 1
        addToLog("MSG: sender=" .. tostring(sender):sub(1,8) .. " port=" .. tostring(port) .. " dist=" .. tostring(distance), "DEBUG")

        local tunneled = isTunnelMessage(sender, port, distance)
        if tunneled then
            -- CLIENT → RELAY (plaintext via linked card)
            addToLog("← CLIENT via tunnel (raw): " .. tostring(message), "CLIENT")
            -- attempt unserialize
            local ok, data = pcall(serialization.unserialize, message)
            if not ok or not data then
                addToLog("Failed to parse client message: " .. tostring(message), "ERROR")
                stats.activeThreads = stats.activeThreads - 1
                return
            end
            addToLog("CLIENT PARSED: " .. (pcall(serialization.serialize, data) and serialization.serialize(data) or tostring(data)), "DEBUG")

            -- determine source tunnel
            local sourceTunnel = nil
            if data.tunnelChannel then
                sourceTunnel = findTunnelByChannel(data.tunnelChannel)
                if sourceTunnel then addToLog("Matched tunnel by channel: " .. tostring(data.tunnelChannel):sub(1,16), "SUCCESS") end
            end
            if not sourceTunnel and data.tunnelAddress then
                local reg = registeredClients[data.tunnelAddress]
                if reg then
                    sourceTunnel = reg.tunnel
                    addToLog("Using registered tunnel for client", "DEBUG")
                end
            end
            if not sourceTunnel and #tunnels == 1 then
                sourceTunnel = tunnels[1]
                addToLog("Using only available tunnel (fallback)", "DEBUG")
            end
            if not sourceTunnel then
                addToLog("ERROR: Could not determine source tunnel for client message", "ERROR")
                stats.activeThreads = stats.activeThreads - 1
                return
            end

            -- registration handling
            if data.type == "client_register" then
                local clientId = data.tunnelAddress or data.clientId or tostring(sender)
                registeredClients[clientId] = {
                    tunnel = sourceTunnel,
                    clientTunnelAddress = data.tunnelAddress,
                    relayTunnelAddress = sourceTunnel.address,
                    lastSeen = os.time()
                }
                addToLog("CLIENT REGISTERED: " .. clientId:sub(1,8), "SUCCESS")
                -- send ack
                local ack = { type = "relay_ack", relay_name = RELAY_NAME, server_connected = (serverAddress ~= nil) }
                local ackMsg = serialization.serialize(ack)
                local oksend, errsend = pcall(sourceTunnel.send, ackMsg)
                if oksend then addToLog("ACK to client sent", "SUCCESS") else addToLog("ACK send failed: " .. tostring(errsend), "ERROR") end
                stats.activeThreads = stats.activeThreads - 1
                updateDisplay()
                return
            end

            if data.type == "client_disconnect" or data.type == "client_deregister" then
                local cid = data.tunnelAddress or data.clientId or tostring(sender)
                registeredClients[cid] = nil
                addToLog("CLIENT DISCONNECTED: " .. tostring(cid):sub(1,8), "CLIENT")
                stats.activeThreads = stats.activeThreads - 1
                updateDisplay()
                return
            end

            -- forward to server (ensure server known)
            if not serverAddress then
                addToLog("No server known - starting discovery", "ERROR")
                if not findServer() then
                    addToLog("Server discovery failed; returning error to client", "ERROR")
                    local errMsg = serialization.serialize({ type = "response", success = false, message = "Relay cannot reach server" })
                    pcall(sourceTunnel.send, errMsg)
                    stats.activeThreads = stats.activeThreads - 1
                    return
                end
            end

            -- Forward (plaintext logged, encrypted for wireless)
            addToLog("→ SERVER (PLAINTEXT): " .. tostring(message), "SERVER")
            local encrypted = encryptMessage(message)
            addToLog("→ SERVER (ENCRYPTED): " .. tostring(encrypted), "DEBUG")

            local sendOk, sendErr = pcall(modem.send, serverAddress, PORT, encrypted)
            if sendOk then
                stats.messagesForwarded = stats.messagesForwarded + 1
                addToLog("Wireless send successful", "SUCCESS")
                -- record last sender tunnel to route response
                local lastKey = data.tunnelAddress or data.clientId or tostring(sourceTunnel.address)
                registeredClients["_last_sender"] = sourceTunnel
                registeredClients["_last_sender_key"] = lastKey
            else
                addToLog("Wireless send failed: " .. tostring(sendErr), "ERROR")
            end

        else
            -- SERVER → RELAY (encrypted over wireless)
            if port ~= PORT then
                stats.activeThreads = stats.activeThreads - 1
                return
            end

            addToLog("← SERVER (wireless, encrypted): " .. tostring(message), "SERVER")
            addToLog("SERVER → RELAY (ENCRYPTED): " .. tostring(message), "DEBUG")

            local dec = decryptMessage(message)
            addToLog("SERVER → RELAY (DECRYPTED): " .. tostring(dec), "DEBUG")

            if not dec then
                addToLog("Decryption of server message failed", "ERROR")
                stats.activeThreads = stats.activeThreads - 1
                return
            end

            -- If this is discovery reply, set serverAddress
            if sender and not serverAddress then
                local ok, pdata = pcall(serialization.unserialize, dec)
                if ok and pdata and pdata.type == "server_response" then
                    serverAddress = sender
                    addToLog("Server identified during reply: " .. tostring(sender), "SUCCESS")
                end
            end

            -- route to last sender tunnel
            local targetTunnel = registeredClients["_last_sender"]
            if targetTunnel then
                addToLog("→ CLIENT (PLAINTEXT): forwarding to last tunnel", "CLIENT")
                addToLog("RELAY → CLIENT (PLAINTEXT): " .. tostring(dec), "DEBUG")
                local oksend, errsend = pcall(targetTunnel.send, dec)
                if oksend then
                    stats.messagesToClient = stats.messagesToClient + 1
                    addToLog("Tunnel send to client successful", "SUCCESS")
                else
                    addToLog("Tunnel send failed: " .. tostring(errsend), "ERROR")
                end
            else
                addToLog("No target tunnel recorded for server response", "ERROR")
            end
        end

        updateDisplay()
        stats.activeThreads = stats.activeThreads - 1
    end):detach()
end

-- ==========================
-- KEY HANDLER (toggle debug)
-- ==========================
local function keyHandler(_, _, char, code, player)
    -- char may be numeric (unicode codepoint) or nil; it may also be string in some environments
    local ch = nil
    if type(char) == "number" then
        pcall(function() ch = string.char(char) end)
    elseif type(char) == "string" then
        ch = char
    end
    if ch and ch:lower() == "d" then
        DEBUG = not DEBUG
        addToLog("Debug toggled: " .. (DEBUG and "ON" or "OFF"), "DEBUG")
        updateDisplay()
    end
end

-- ==========================
-- MAIN
-- ==========================
local function main()
    print("Starting Multi-Client Currency Relay (Encrypted, DEBUG+FILE) ...")
    print("Relay: " .. RELAY_NAME)
    modem.open(PORT)
    modem.setStrength(400)
    addToLog("Relay started on wireless port " .. PORT, "SUCCESS")
    addToLog("Linked cards: " .. tostring(#tunnels), "INFO")
    updateDisplay()

    -- start heartbeat in background
    thread.create(serverHeartbeat):detach()

    -- listen for incoming modem messages
    event.listen("modem_message", handleMessage)
    -- listen for key presses to toggle debug
    event.listen("key_down", keyHandler)

    addToLog("Listeners registered: modem_message, key_down", "INFO")

    -- run forever
    while true do
        os.sleep(1)
        stats.uptime = stats.uptime + 1

        -- cleanup stale clients (not seen recently)
        local now = os.time()
        for clientId, client in pairs(registeredClients) do
            if clientId ~= "_last_sender" and client.lastSeen then
                if now - client.lastSeen > 300 then
                    registeredClients[clientId] = nil
                    addToLog("Client timed out: " .. tostring(clientId):sub(1,8), "CLIENT")
                end
            end
        end
    end
end

local ok, err = pcall(main)
if not ok then
    addToLog("Relay crashed: " .. tostring(err), "ERROR")
    print("Relay crashed: " .. tostring(err))
end

-- cleanup handlers (in case of exit)
pcall(event.ignore, "modem_message", handleMessage)
pcall(event.ignore, "key_down", keyHandler)
pcall(modem.close, PORT)
addToLog("Relay stopped", "INFO")
