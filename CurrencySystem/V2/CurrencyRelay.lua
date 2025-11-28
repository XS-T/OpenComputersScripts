-- Dual-Server Relay for OpenComputers 1.7.10
-- Routes to Currency Server (PORT 1000) AND Loan Server (PORT 1001)
-- Multi-client support via linked cards + Username-based routing
-- VERSION 2.0.0 - CLEAN UI

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require("computer")
local term = require("term")
local gpu = component.gpu

if not component.isAvailable("modem") then
    print("ERROR: Wireless Network Card required!")
    return
end

if not component.isAvailable("data") then
    print("ERROR: Data Card required for encryption!")
    return
end

local modem = component.modem
local data = component.data

-- Get all tunnels
local tunnels = {}
for address in component.list("tunnel") do
    table.insert(tunnels, component.proxy(address))
end

if #tunnels == 0 then
    print("ERROR: No Tunnel (Linked Card) found!")
    return
end

-- Configuration
local CURRENCY_PORT = 1000
local LOAN_PORT = 1001
local RELAY_NAME = "Dual-Server Relay"
local SERVER_NAME = "Empire Credit Union"
local ENCRYPTION_KEY = data.md5(SERVER_NAME .. "RelaySecure2024")

-- Screen setup
local w, h = gpu.getResolution()
gpu.setResolution(80, 25)
w, h = 80, 25

local colors = {
    bg = 0x0F0F0F,
    header = 0x1E3A8A,
    success = 0x10B981,
    error = 0xEF4444,
    text = 0xFFFFFF,
    textDim = 0x9CA3AF
}

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
    return success and result or nil
end

-- State
local currencyServerAddress = nil
local loanServerAddress = nil
local registeredClients = {}
local activityLog = {}
local stats = {
    messagesForwarded = 0,
    messagesToClient = 0,
    totalMessages = 0,
    uptime = 0
}

-- Command routing table
local loanCommands = {
    get_credit_score = true,
    get_loan_eligibility = true,
    apply_loan = true,
    get_my_loans = true,
    make_loan_payment = true,
    get_pending_loans = true,
    approve_loan = true,
    deny_loan = true,
    admin_view_loans = true,
    admin_forgive_loan = true,
    admin_adjust_credit = true,
    admin_view_locked = true
}

local function isLoanCommand(command)
    return loanCommands[command] == true
end

-- Activity logging
local function log(message, category)
    category = category or "INFO"
    table.insert(activityLog, 1, {
        time = os.date("%H:%M:%S"),
        message = message,
        category = category
    })
    if #activityLog > 10 then
        table.remove(activityLog)
    end
end

-- UI Functions
local function drawUI()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
    
    -- Header
    gpu.setBackground(colors.header)
    gpu.fill(1, 1, w, 3, " ")
    local title = "=== DUAL-SERVER RELAY ==="
    gpu.set(math.floor((w - #title) / 2), 2, title)
    
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.textDim)
    
    -- Status section
    gpu.setForeground(colors.text)
    gpu.set(2, 5, "═══ SERVER STATUS ═══")
    
    gpu.setForeground(colors.textDim)
    gpu.set(2, 7, "Currency Server:")
    if currencyServerAddress then
        gpu.setForeground(colors.success)
        gpu.set(25, 7, "✓ CONNECTED")
        gpu.setForeground(colors.textDim)
        gpu.set(40, 7, currencyServerAddress:sub(1, 16))
    else
        gpu.setForeground(colors.error)
        gpu.set(25, 7, "✗ SEARCHING...")
    end
    
    gpu.setForeground(colors.textDim)
    gpu.set(2, 8, "Loan Server:")
    if loanServerAddress then
        gpu.setForeground(colors.success)
        gpu.set(25, 8, "✓ CONNECTED")
        gpu.setForeground(colors.textDim)
        gpu.set(40, 8, loanServerAddress:sub(1, 16))
    else
        gpu.setForeground(colors.error)
        gpu.set(25, 8, "✗ SEARCHING...")
    end
    
    -- Stats section
    gpu.setForeground(colors.text)
    gpu.set(2, 10, "═══ STATISTICS ═══")
    
    gpu.setForeground(colors.textDim)
    gpu.set(2, 12, "Messages to Server:")
    gpu.setForeground(colors.text)
    gpu.set(35, 12, tostring(stats.messagesForwarded))
    
    gpu.setForeground(colors.textDim)
    gpu.set(2, 13, "Messages to Client:")
    gpu.setForeground(colors.text)
    gpu.set(35, 13, tostring(stats.messagesToClient))
    
    gpu.setForeground(colors.textDim)
    gpu.set(2, 14, "Total Messages:")
    gpu.setForeground(colors.text)
    gpu.set(35, 14, tostring(stats.totalMessages))
    
    gpu.setForeground(colors.textDim)
    gpu.set(2, 15, "Active Clients:")
    gpu.setForeground(colors.text)
    local clientCount = 0
    for key in pairs(registeredClients) do
        if not key:match("^_") then
            clientCount = clientCount + 1
        end
    end
    gpu.set(35, 15, tostring(clientCount))
    
    gpu.setForeground(colors.textDim)
    gpu.set(2, 16, "Linked Cards:")
    gpu.setForeground(colors.text)
    gpu.set(35, 16, tostring(#tunnels))
    
    -- Activity log
    gpu.setForeground(colors.text)
    gpu.set(2, 18, "═══ ACTIVITY LOG ═══")
    
    local y = 19
    for i = 1, math.min(5, #activityLog) do
        local entry = activityLog[i]
        local color = colors.textDim
        if entry.category == "SUCCESS" then
            color = colors.success
        elseif entry.category == "ERROR" then
            color = colors.error
        elseif entry.category == "ROUTE" then
            color = 0x3B82F6
        end
        
        gpu.setForeground(color)
        local msg = "[" .. entry.time .. "] " .. entry.message
        gpu.set(2, y, msg:sub(1, 76))
        y = y + 1
    end
    
    -- Footer
    gpu.setBackground(colors.header)
    gpu.setForeground(colors.text)
    gpu.fill(1, h, w, 1, " ")
    gpu.set(2, h, "Relay Running • Press Ctrl+C to stop • Uptime: " .. math.floor(stats.uptime) .. "s")
end

-- Find servers
local function findServers()
    log("Searching for servers...", "INFO")
    
    local currencyPing = serialization.serialize({type = "relay_ping", relay_name = RELAY_NAME})
    local loanPing = serialization.serialize({type = "relay_ping", relay_name = RELAY_NAME})
    
    local encryptedCurrency = encryptMessage(currencyPing)
    local encryptedLoan = encryptMessage(loanPing)
    
    modem.broadcast(CURRENCY_PORT, encryptedCurrency)
    modem.broadcast(LOAN_PORT, encryptedLoan)
    
    local deadline = computer.uptime() + 3
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, sender, port, _, message = table.unpack(eventData)
            local decrypted = decryptMessage(message)
            if decrypted then
                local success, data = pcall(serialization.unserialize, decrypted)
                if success and data and data.type == "server_response" then
                    if port == CURRENCY_PORT and not currencyServerAddress then
                        currencyServerAddress = sender
                        log("Currency server found", "SUCCESS")
                    elseif port == LOAN_PORT and not loanServerAddress then
                        loanServerAddress = sender
                        log("Loan server found", "SUCCESS")
                    end
                end
            end
        end
    end
    
    if not currencyServerAddress then
        log("Currency server not found", "ERROR")
    end
    if not loanServerAddress then
        log("Loan server not found", "ERROR")
    end
    
    drawUI()
end

-- Message handler
local function handleMessage(eventType, _, sender, port, distance, message)
    stats.totalMessages = stats.totalMessages + 1
    
    -- Check if from tunnel
    local isTunnel = (port == 0 or distance == nil or distance == math.huge)
    
    if isTunnel then
        -- ═══════════════════════════════════════════════════════
        -- FROM CLIENT (via tunnel) - NOT ENCRYPTED
        -- ═══════════════════════════════════════════════════════
        local success, data = pcall(serialization.unserialize, message)
        if not success or not data then return end
        
        -- Find source tunnel
        local sourceTunnel = nil
        if data.tunnelAddress then
            for _, tunnel in ipairs(tunnels) do
                if tunnel.getChannel() == data.tunnelChannel then
                    sourceTunnel = tunnel
                    break
                end
            end
        end
        
        if not sourceTunnel and #tunnels == 1 then
            sourceTunnel = tunnels[1]
        end
        
        if not sourceTunnel then return end
        
        -- Handle registration
        if data.type == "client_register" then
            local clientId = data.tunnelAddress
            registeredClients[clientId] = {
                tunnel = sourceTunnel,
                lastSeen = os.time()
            }
            
            log("Client registered", "SUCCESS")
            
            local ack = {
                type = "relay_ack",
                relay_name = RELAY_NAME,
                server_connected = (currencyServerAddress ~= nil and loanServerAddress ~= nil)
            }
            sourceTunnel.send(serialization.serialize(ack))
            drawUI()
            return
        end
        
        if data.type == "client_deregister" then
            registeredClients[data.tunnelAddress or sender] = nil
            log("Client disconnected", "INFO")
            drawUI()
            return
        end
        
        -- Route to appropriate server
        local targetPort, targetServer, serverName
        if isLoanCommand(data.command) then
            targetPort = LOAN_PORT
            targetServer = loanServerAddress
            serverName = "Loan"
        else
            targetPort = CURRENCY_PORT
            targetServer = currencyServerAddress
            serverName = "Currency"
        end
        
        if not targetServer then
            log("No " .. serverName .. " server", "ERROR")
            drawUI()
            return
        end
        
        -- Store for response routing (username-based)
        if data.username then
            registeredClients["_pending_" .. data.username] = {
                tunnel = sourceTunnel,
                timestamp = os.time()
            }
        end
        registeredClients["_last_sender"] = sourceTunnel
        
        -- Forward to server (encrypted)
        local encrypted = encryptMessage(message)
        modem.send(targetServer, targetPort, encrypted)
        stats.messagesForwarded = stats.messagesForwarded + 1
        
        if data.command then
            log("→ " .. serverName .. ": " .. data.command, "ROUTE")
        end
        
    else
        -- ═══════════════════════════════════════════════════════
        -- FROM SERVER (via wireless) - ENCRYPTED
        -- ═══════════════════════════════════════════════════════
        if port ~= CURRENCY_PORT and port ~= LOAN_PORT then return end
        
        local decrypted = decryptMessage(message)
        if not decrypted then return end
        
        -- Update server addresses
        if sender == currencyServerAddress or sender == loanServerAddress then
            -- Parse response to find username
            local responseData = nil
            local parseOk, parsed = pcall(serialization.unserialize, decrypted)
            if parseOk and parsed then
                responseData = parsed
            end
            
            -- Route by username first
            local targetTunnel = nil
            if responseData and responseData.username then
                local pendingKey = "_pending_" .. responseData.username
                local pending = registeredClients[pendingKey]
                if pending and pending.tunnel then
                    targetTunnel = pending.tunnel
                    registeredClients[pendingKey] = nil
                end
            end
            
            -- Fallback to last sender
            if not targetTunnel then
                targetTunnel = registeredClients["_last_sender"]
            end
            
            if targetTunnel then
                targetTunnel.send(decrypted)
                stats.messagesToClient = stats.messagesToClient + 1
                log("← Client: Response sent", "ROUTE")
            end
        else
            -- Server discovery
            local success, data = pcall(serialization.unserialize, decrypted)
            if success and data and data.type == "server_response" then
                if port == CURRENCY_PORT and not currencyServerAddress then
                    currencyServerAddress = sender
                    log("Currency server connected", "SUCCESS")
                    drawUI()
                elseif port == LOAN_PORT and not loanServerAddress then
                    loanServerAddress = sender
                    log("Loan server connected", "SUCCESS")
                    drawUI()
                end
            end
        end
    end
end

-- Main
local function main()
    term.clear()
    print("═══════════════════════════════════════════════════════")
    print("Dual-Server Relay - Starting Up")
    print("═══════════════════════════════════════════════════════")
    print("")
    print("Initializing...")
    
    modem.open(CURRENCY_PORT)
    modem.open(LOAN_PORT)
    modem.setStrength(400)
    
    print("✓ Wireless ports opened (1000, 1001)")
    print("✓ Found " .. #tunnels .. " linked card(s)")
    print("")
    print("Searching for servers...")
    
    findServers()
    
    print("")
    print("Relay initialized!")
    os.sleep(1)
    
    drawUI()
    
    event.listen("modem_message", handleMessage)
    
    -- Periodic server ping and cleanup
    event.timer(30, function()
        if not currencyServerAddress or not loanServerAddress then
            findServers()
        end
        
        -- Cleanup stale pending
        local now = os.time()
        for key, client in pairs(registeredClients) do
            if key:match("^_pending_") and client.timestamp then
                if now - client.timestamp > 60 then
                    registeredClients[key] = nil
                end
            elseif not key:match("^_") and client.lastSeen then
                if now - client.lastSeen > 300 then
                    registeredClients[key] = nil
                    log("Client timeout", "INFO")
                end
            end
        end
        
        drawUI()
    end, math.huge)
    
    -- UI refresh timer
    event.timer(5, function()
        drawUI()
    end, math.huge)
    
    -- Uptime counter
    event.timer(1, function()
        stats.uptime = stats.uptime + 1
    end, math.huge)
    
    while true do
        os.sleep(1)
    end
end

local success, err = pcall(main)
if not success then
    term.clear()
    print("Error: " .. tostring(err))
end

event.ignore("modem_message", handleMessage)
modem.close(CURRENCY_PORT)
modem.close(LOAN_PORT)
term.clear()
print("Relay stopped")
