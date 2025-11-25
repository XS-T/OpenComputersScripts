--[[
    BANKING API LIBRARY v3.0
    
    Reusable library for interacting with the banking server
    
    USAGE:
        local bankAPI = require("bank_api")
        
        -- Connect to relay
        if bankAPI.connect() then
            -- Login
            local success, balance = bankAPI.login("username", "password")
            
            -- Check balance
            local success, balance = bankAPI.getBalance("username", "password")
            
            -- Transfer
            local success, newBalance = bankAPI.transfer("username", "password", "recipient", amount)
            
            -- Logout
            bankAPI.logout("username")
        end
]]

local component = require("component")
local serialization = require("serialization")
local event = require("event")
local computer = require("computer")

local bankAPI = {}

-- Configuration
bankAPI.timeout = 5  -- Default timeout in seconds
bankAPI.connected = false
bankAPI.tunnel = nil
bankAPI.loggedInUsers = {}  -- Track logged in users: {username = password}

-- Check for tunnel component
local function checkTunnel()
    if not component.isAvailable("tunnel") then
        return false, "Linked card (tunnel component) not found"
    end
    
    bankAPI.tunnel = component.tunnel
    return true
end

-- Send request and wait for response
local function sendAndWait(data, timeout)
    timeout = timeout or bankAPI.timeout
    
    if not bankAPI.connected then
        return nil, "Not connected to relay"
    end
    
    -- Add tunnel info
    data.tunnelAddress = bankAPI.tunnel.address
    data.tunnelChannel = bankAPI.tunnel.getChannel()
    
    -- Send message
    local message = serialization.serialize(data)
    local sendOk, sendErr = pcall(bankAPI.tunnel.send, message)
    
    if not sendOk then
        return nil, "Failed to send: " .. tostring(sendErr)
    end
    
    -- Wait for response
    local deadline = computer.uptime() + timeout
    
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, sender, port, distance, msg = table.unpack(eventData)
            
            -- Tunnel messages have port=0
            if port == 0 or distance == nil or distance == math.huge then
                local success, response = pcall(serialization.unserialize, msg)
                if success and response and response.type == "response" then
                    return response
                end
            end
        end
    end
    
    return nil, "Timeout - no response from server"
end

--[[
    Connect to relay
    
    Returns: success (boolean), error (string)
    
    Must be called before any other API functions
]]
function bankAPI.connect()
    local ok, err = checkTunnel()
    if not ok then
        return false, err
    end
    
    -- Send registration
    local registration = serialization.serialize({
        type = "client_register",
        tunnelAddress = bankAPI.tunnel.address,
        tunnelChannel = bankAPI.tunnel.getChannel()
    })
    
    local sendOk, sendErr = pcall(bankAPI.tunnel.send, registration)
    if not sendOk then
        return false, "Failed to send registration: " .. tostring(sendErr)
    end
    
    -- Wait for ACK
    local deadline = computer.uptime() + bankAPI.timeout
    
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, _, port, distance, msg = table.unpack(eventData)
            
            if port == 0 or distance == nil then
                local success, response = pcall(serialization.unserialize, msg)
                if success and response and response.type == "relay_ack" then
                    bankAPI.connected = true
                    return true, "Connected to " .. (response.relay_name or "relay")
                end
            end
        end
    end
    
    return false, "No response from relay"
end

--[[
    Login to account
    
    Parameters:
        username (string)
        password (string)
    
    Returns: success (boolean), balance (number) or error (string)
]]
function bankAPI.login(username, password)
    local response, err = sendAndWait({
        command = "login",
        username = username,
        password = password
    })
    
    if not response then
        return false, err
    end
    
    if response.success then
        -- Track this user and password for auto-logout on disconnect
        bankAPI.loggedInUsers[username] = password
        return true, response.balance
    else
        return false, response.message or "Login failed"
    end
end

--[[
    Get account balance
    
    Parameters:
        username (string)
        password (string)
    
    Returns: success (boolean), balance (number) or error (string)
]]
function bankAPI.getBalance(username, password)
    local response, err = sendAndWait({
        command = "balance",
        username = username,
        password = password
    })
    
    if not response then
        return false, err
    end
    
    if response.success then
        return true, response.balance
    else
        return false, response.message or "Failed to get balance"
    end
end

--[[
    Transfer funds
    
    Parameters:
        username (string) - your username
        password (string) - your password
        recipient (string) - recipient's username
        amount (number) - amount to transfer
    
    Returns: success (boolean), newBalance (number) or error (string)
]]
function bankAPI.transfer(username, password, recipient, amount)
    local response, err = sendAndWait({
        command = "transfer",
        username = username,
        password = password,
        recipient = recipient,
        amount = amount
    })
    
    if not response then
        return false, err
    end
    
    if response.success then
        return true, response.balance
    else
        return false, response.message or "Transfer failed"
    end
end

--[[
    List all accounts (public info only)
    
    Returns: success (boolean), accounts (table) or error (string)
    
    accounts format: {{name = "user1", online = true}, ...}
]]
function bankAPI.listAccounts()
    local response, err = sendAndWait({
        command = "list_accounts"
    })
    
    if not response then
        return false, err
    end
    
    if response.success then
        return true, response.accounts, response.total
    else
        return false, response.message or "Failed to list accounts"
    end
end

--[[
    Logout from account
    
    Parameters:
        username (string)
        password (string) - required for authentication
    
    Returns: success (boolean), error (string)
]]
function bankAPI.logout(username, password)
    local response, err = sendAndWait({
        command = "logout",
        username = username,
        password = password
    })
    
    if not response then
        return false, err
    end
    
    -- Remove from tracked users
    bankAPI.loggedInUsers[username] = nil
    
    return response.success, response.message
end

--[[
    Disconnect from relay
    
    Call this when shutting down to cleanly disconnect
    Automatically logs out all logged-in users
]]
function bankAPI.disconnect()
    -- Logout all tracked users first
    for username, password in pairs(bankAPI.loggedInUsers) do
        pcall(function()
            sendAndWait({
                command = "logout",
                username = username,
                password = password
            }, 2)  -- Shorter timeout for cleanup
        end)
    end
    
    -- Clear tracked users
    bankAPI.loggedInUsers = {}
    
    -- Send deregistration
    if bankAPI.connected and bankAPI.tunnel then
        local dereg = serialization.serialize({
            type = "client_deregister",
            tunnelAddress = bankAPI.tunnel.address,
            tunnelChannel = bankAPI.tunnel.getChannel()
        })
        
        pcall(bankAPI.tunnel.send, dereg)
        bankAPI.connected = false
    end
end

--[[
    Helper: Check if account exists
    
    Parameters:
        username (string)
    
    Returns: exists (boolean), online (boolean or nil)
]]
function bankAPI.accountExists(username)
    local success, accounts = bankAPI.listAccounts()
    
    if not success then
        return false, nil
    end
    
    for _, acc in ipairs(accounts) do
        if acc.name == username then
            return true, acc.online
        end
    end
    
    return false, nil
end

--[[
    Helper: Validate amount
    
    Parameters:
        amount (any)
    
    Returns: valid (boolean), error (string or nil)
]]
function bankAPI.validateAmount(amount)
    if type(amount) ~= "number" then
        return false, "Amount must be a number"
    end
    
    if amount <= 0 then
        return false, "Amount must be positive"
    end
    
    if amount ~= amount then  -- NaN check
        return false, "Amount is not a valid number"
    end
    
    return true
end

--[[
    Helper: Format currency
    
    Parameters:
        amount (number)
        symbol (string, optional) - defaults to "$"
    
    Returns: formatted string
]]
function bankAPI.formatCurrency(amount, symbol)
    symbol = symbol or "$"
    return string.format("%s%.2f", symbol, amount)
end

return bankAPI
