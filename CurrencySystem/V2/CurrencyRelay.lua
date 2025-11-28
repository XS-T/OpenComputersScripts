-- Dual-Server Relay for OpenComputers 1.7.10
-- Routes to Currency Server (PORT 1000) AND Loan Server (PORT 1001)
-- Multi-client support via linked cards + Username-based routing
-- VERSION 1.0.0

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require("computer")
local term = require("term")

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
    print("Found linked card: " .. address:sub(1, 16))
end

if #tunnels == 0 then
    print("ERROR: No Tunnel (Linked Card) found!")
    return
end

print("Total linked cards: " .. #tunnels)

-- Configuration
local CURRENCY_PORT = 1000
local LOAN_PORT = 1001
local RELAY_NAME = "Dual-Server Relay"
local SERVER_NAME = "Empire Credit Union"
local ENCRYPTION_KEY = data.md5(SERVER_NAME .. "RelaySecure2024")

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
local stats = {
    messagesForwarded = 0,
    messagesToClient = 0,
    totalMessages = 0
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

-- Find servers
local function findServers()
    print("Searching for servers...")
    
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
                        print("✓ Currency Server found: " .. sender:sub(1, 8))
                    elseif port == LOAN_PORT and not loanServerAddress then
                        loanServerAddress = sender
                        print("✓ Loan Server found: " .. sender:sub(1, 8))
                    end
                end
            end
        end
    end
    
    if not currencyServerAddress then print("✗ Currency Server not found") end
    if not loanServerAddress then print("✗ Loan Server not found") end
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
            
            local ack = {
                type = "relay_ack",
                relay_name = RELAY_NAME,
                server_connected = (currencyServerAddress ~= nil and loanServerAddress ~= nil)
            }
            sourceTunnel.send(serialization.serialize(ack))
            return
        end
        
        if data.type == "client_deregister" then
            registeredClients[data.tunnelAddress or sender] = nil
            return
        end
        
        -- Route to appropriate server
        local targetPort, targetServer
        if isLoanCommand(data.command) then
            targetPort = LOAN_PORT
            targetServer = loanServerAddress
        else
            targetPort = CURRENCY_PORT
            targetServer = currencyServerAddress
        end
        
        if not targetServer then return end
        
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
            end
        else
            -- Server discovery
            local success, data = pcall(serialization.unserialize, decrypted)
            if success and data and data.type == "server_response" then
                if port == CURRENCY_PORT and not currencyServerAddress then
                    currencyServerAddress = sender
                    print("✓ Currency Server connected: " .. sender:sub(1, 8))
                elseif port == LOAN_PORT and not loanServerAddress then
                    loanServerAddress = sender
                    print("✓ Loan Server connected: " .. sender:sub(1, 8))
                end
            end
        end
    end
end

-- Main
local function main()
    term.clear()
    print("═══════════════════════════════════════════════════════")
    print("Dual-Server Relay - " .. RELAY_NAME)
    print("═══════════════════════════════════════════════════════")
    print("")
    print("Linked Cards: " .. #tunnels)
    for i, tunnel in ipairs(tunnels) do
        print("  [" .. i .. "] " .. tunnel.getChannel():sub(1, 24))
    end
    print("")
    
    modem.open(CURRENCY_PORT)
    modem.open(LOAN_PORT)
    modem.setStrength(400)
    
    print("Ports opened:")
    print("  Currency: " .. CURRENCY_PORT)
    print("  Loans:    " .. LOAN_PORT)
    print("")
    
    findServers()
    
    print("")
    print("Relay running!")
    print("═══════════════════════════════════════════════════════")
    print("")
    
    event.listen("modem_message", handleMessage)
    
    -- Periodic server ping
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
            end
        end
    end, math.huge)
    
    while true do
        os.sleep(1)
        print("\rForwarded: " .. stats.messagesForwarded .. " | To Clients: " .. stats.messagesToClient .. " | Total: " .. stats.totalMessages .. "   ", false)
    end
end

local success, err = pcall(main)
if not success then
    print("Error: " .. tostring(err))
end

modem.close(CURRENCY_PORT)
modem.close(LOAN_PORT)
print("Relay stopped")
