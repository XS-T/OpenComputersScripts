-- Digital Currency Client (Beautiful UI) for OpenComputers 1.7.10
-- Connects to relay via TUNNEL (linked card) ONLY
-- Modern, clean interface
-- ADMIN-ONLY REGISTRATION: Users cannot self-register

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local term = require("term")
local computer = require("computer")
local gpu = component.gpu
local unicode = require("unicode")

-- Check for tunnel
if not component.isAvailable("tunnel") then
    print("═══════════════════════════════════════════════════════")
    print("ERROR: LINKED CARD REQUIRED!")
    print("═══════════════════════════════════════════════════════")
    print("")
    print("This client requires a linked card to connect to a relay.")
    print("")
    print("SETUP:")
    print("1. Get a linked card pair (craft 2 linked cards + ender pearl)")
    print("2. Install one card in this computer (client)")
    print("3. Install the paired card in a relay computer")
    print("4. The relay will forward to the server wirelessly")
    print("")
    return
end

local tunnel = component.tunnel

-- State
local username = nil
local password = nil
local balance = 0
local loggedIn = false
local relayConnected = false
local clientId = tunnel.address

-- UI Config
local w, h = gpu.getResolution()
gpu.setResolution(80, 25)
w, h = 80, 25

-- Color scheme
local colors = {
    bg = 0x0F0F0F,
    header = 0x1E3A8A,
    accent = 0x3B82F6,
    success = 0x10B981,
    error = 0xEF4444,
    warning = 0xF59E0B,
    text = 0xFFFFFF,
    textDim = 0x9CA3AF,
    border = 0x374151,
    inputBg = 0x1F2937,
    balance = 0x10B981
}

-- Draw functions
local function drawBox(x, y, width, height, color, title)
    gpu.setBackground(color or colors.bg)
    gpu.fill(x, y, width, height, " ")
    
    if title then
        gpu.setBackground(colors.header)
        gpu.fill(x, y, width, 1, " ")
        gpu.setForeground(colors.text)
        local titleX = x + math.floor((width - unicode.len(title)) / 2)
        gpu.set(titleX, y, title)
        gpu.setBackground(color or colors.bg)
    end
end

local function drawLine(x, y, width, char)
    char = char or "─"
    gpu.set(x, y, string.rep(char, width))
end

local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
end

local function drawHeader(title, subtitle)
    -- Top bar
    gpu.setBackground(colors.header)
    gpu.fill(1, 1, w, 3, " ")
    
    -- Title
    gpu.setForeground(colors.text)
    local titleX = math.floor((w - unicode.len(title)) / 2)
    gpu.set(titleX, 2, title)
    
    if subtitle then
        gpu.setForeground(colors.textDim)
        local subX = math.floor((w - unicode.len(subtitle)) / 2)
        gpu.set(subX, 3, subtitle)
    end
    
    gpu.setBackground(colors.bg)
end

local function drawFooter(text)
    gpu.setBackground(colors.border)
    gpu.fill(1, h, w, 1, " ")
    gpu.setForeground(colors.textDim)
    gpu.set(2, h, text)
    gpu.setBackground(colors.bg)
end

local function showStatus(msg, msgType)
    msgType = msgType or "info"
    local color = colors.text
    
    if msgType == "success" then color = colors.success
    elseif msgType == "error" then color = colors.error
    elseif msgType == "warning" then color = colors.warning
    end
    
    gpu.setBackground(colors.bg)
    gpu.fill(1, h - 1, w, 1, " ")
    gpu.setForeground(color)
    local msgX = math.floor((w - unicode.len(msg)) / 2)
    gpu.set(msgX, h - 1, msg)
    gpu.setForeground(colors.text)
end

local function input(prompt, y, hidden, maxLen)
    maxLen = maxLen or 30
    gpu.setForeground(colors.text)
    gpu.set(2, y, prompt)
    
    local x = 2 + unicode.len(prompt)
    
    -- Draw input box
    gpu.setBackground(colors.inputBg)
    gpu.fill(x, y, maxLen + 2, 1, " ")
    
    x = x + 1
    gpu.set(x, y, "")
    
    local text = ""
    while true do
        local _, _, char, code = event.pull("key_down")
        
        if code == 28 then -- Enter
            break
        elseif code == 14 and unicode.len(text) > 0 then -- Backspace
            text = unicode.sub(text, 1, -2)
            gpu.setBackground(colors.inputBg)
            gpu.fill(x, y, maxLen, 1, " ")
            if hidden then
                gpu.set(x, y, string.rep("•", unicode.len(text)))
            else
                gpu.set(x, y, text)
            end
        elseif char >= 32 and char < 127 and unicode.len(text) < maxLen then
            text = text .. string.char(char)
            if hidden then
                gpu.set(x, y, string.rep("•", unicode.len(text)))
            else
                gpu.set(x, y, text)
            end
        end
    end
    
    gpu.setBackground(colors.bg)
    return text
end

local function drawButton(x, y, text, selected)
    local bg = selected and colors.accent or colors.border
    local fg = selected and colors.text or colors.textDim
    
    gpu.setBackground(bg)
    gpu.setForeground(fg)
    gpu.set(x, y, " " .. text .. " ")
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
end

-- Send message and wait for response
local function sendAndWait(data, timeout)
    timeout = timeout or 5
    
    if not relayConnected then
        return {
            type = "response",
            success = false,
            message = "Not connected to relay"
        }
    end
    
    -- Add tunnel info to every message
    data.tunnelAddress = tunnel.address
    data.tunnelChannel = tunnel.getChannel()
    
    local message = serialization.serialize(data)
    tunnel.send(message)
    
    local deadline = computer.uptime() + timeout
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, _, port, distance, msg = table.unpack(eventData)
            
            local isTunnel = (port == 0 or distance == nil or distance == math.huge)
            
            if isTunnel then
                local success, response = pcall(serialization.unserialize, msg)
                if success and response and response.type == "response" then
                    return response
                end
            end
        end
    end
    
    return nil
end

-- Register with relay
local function registerWithRelay()
    clearScreen()
    drawHeader("◆ CONNECTING TO RELAY ◆", "Establishing secure tunnel connection")
    
    drawBox(20, 8, 40, 12, colors.bg)
    
    gpu.setForeground(colors.accent)
    gpu.set(22, 10, "Tunnel Component Check:")
    
    -- Show tunnel info
    gpu.setForeground(colors.text)
    gpu.set(22, 11, "Address: " .. tunnel.address:sub(1, 20))
    gpu.set(22, 12, "Channel: " .. tunnel.getChannel():sub(1, 20))
    gpu.setForeground(colors.textDim)
    gpu.set(22, 13, "Client ID: " .. clientId:sub(1, 20))
    
    gpu.setForeground(colors.text)
    gpu.set(22, 15, "⟳ Sending registration...")
    
    drawFooter("Tunnel: " .. tunnel.address:sub(1, 16))
    
    local registration = serialization.serialize({
        type = "client_register",
        tunnelAddress = tunnel.address,
        tunnelChannel = tunnel.getChannel()
    })
    
    gpu.set(22, 16, "Message size: " .. #registration .. " bytes")
    
    local sendOk, sendErr = pcall(tunnel.send, registration)
    if not sendOk then
        gpu.setForeground(colors.error)
        gpu.set(22, 17, "✗ Send error: " .. tostring(sendErr))
        showStatus("Press any key to retry...", "error")
        event.pull("key_down")
        return false
    end
    
    gpu.setForeground(colors.success)
    gpu.set(22, 17, "✓ Sent via tunnel")
    
    gpu.setForeground(colors.text)
    gpu.set(22, 18, "Waiting for relay ACK...")
    
    local deadline = computer.uptime() + 5
    local eventCount = 0
    
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            eventCount = eventCount + 1
            local eventType, _, sender, port, distance, msg = table.unpack(eventData)
            
            -- Debug on screen
            gpu.fill(22, 19, 35, 1, " ")
            gpu.setForeground(colors.textDim)
            gpu.set(22, 19, "Event #" .. eventCount .. ": port=" .. tostring(port))
            
            -- Tunnel messages have port=0
            local isTunnel = (port == 0 or distance == nil or distance == math.huge)
            
            if isTunnel then
                gpu.setForeground(colors.success)
                gpu.set(22, 20, "✓ Tunnel message detected")
                
                local success, response = pcall(serialization.unserialize, msg)
                if success and response then
                    gpu.set(22, 21, "Type: " .. tostring(response.type))
                    
                    if response.type == "relay_ack" then
                        relayConnected = true
                        
                        clearScreen()
                        drawHeader("◆ CONNECTION ESTABLISHED ◆")
                        
                        drawBox(20, 10, 40, 6, colors.bg)
                        gpu.setForeground(colors.success)
                        gpu.set(22, 11, "✓ Connected to relay")
                        gpu.setForeground(colors.text)
                        gpu.set(22, 12, "  " .. response.relay_name)
                        
                        if response.server_connected then
                            gpu.setForeground(colors.success)
                            gpu.set(22, 14, "✓ Server online")
                        else
                            gpu.setForeground(colors.warning)
                            gpu.set(22, 14, "⚠ Server searching...")
                        end
                        
                        showStatus("Press any key to continue...", "success")
                        event.pull("key_down")
                        return true
                    else
                        gpu.setForeground(colors.warning)
                        gpu.set(22, 21, "Wrong type: " .. tostring(response.type))
                    end
                else
                    gpu.setForeground(colors.error)
                    gpu.set(22, 21, "Parse error")
                end
            else
                gpu.setForeground(colors.textDim)
                gpu.set(22, 20, "Wireless (ignored)")
            end
        end
    end
    
    gpu.setForeground(colors.error)
    gpu.fill(22, 15, 35, 10, " ")
    gpu.set(22, 15, "✗ Connection failed")
    gpu.setForeground(colors.text)
    gpu.set(22, 17, "Events received: " .. eventCount)
    gpu.set(22, 19, "Check:")
    gpu.setForeground(colors.textDim)
    gpu.set(22, 20, "• Relay is running")
    gpu.set(22, 21, "• Paired linked card")
    gpu.set(22, 22, "• Same channel ID")
    
    showStatus("Press any key to retry...", "error")
    event.pull("key_down")
    return false
end

-- Welcome screen
local function welcomeScreen()
    clearScreen()
    drawHeader("◆ DIGITAL CURRENCY SYSTEM ◆", "Secure P2P Banking")
    
    -- Info box
    drawBox(15, 7, 50, 5, colors.bg)
    gpu.setForeground(colors.accent)
    gpu.set(17, 8, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    gpu.setForeground(colors.textDim)
    gpu.set(17, 9, "  Secured by linked card technology")
    gpu.set(17, 10, "  End-to-end tunnel encryption")
    gpu.setForeground(colors.accent)
    gpu.set(17, 11, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    -- Menu
    gpu.setForeground(colors.text)
    gpu.set(32, 15, "1  Login to Account")
    gpu.set(32, 17, "2  Exit")
    
    -- Registration notice
    gpu.setForeground(colors.textDim)
    gpu.set(17, 20, "Note: Account registration is managed by")
    gpu.set(17, 21, "      administrators at the server level.")
    
    drawFooter("Linked Card: " .. tunnel.getChannel():sub(1, 16) .. " • Secure Connection")
    
    local _, _, char = event.pull("key_down")
    
    if char == string.byte('1') then
        return "login"
    elseif char == string.byte('2') then
        return "exit"
    end
    
    return nil
end

-- Login screen
local function loginScreen()
    clearScreen()
    drawHeader("◆ LOGIN ◆", "Access your account")
    
    drawBox(20, 8, 40, 10, colors.bg)
    
    gpu.setForeground(colors.text)
    local user = input("Username: ", 10, false, 20)
    local pass = input("Password: ", 12, true, 20)
    
    showStatus("⟳ Authenticating...", "info")
    
    local response = sendAndWait({
        command = "login",
        username = user,
        password = pass
    })
    
    if response and response.success then
        username = user
        password = pass
        balance = response.balance or 0
        loggedIn = true
        showStatus("✓ Login successful!", "success")
        os.sleep(1)
        return true
    elseif response then
        showStatus("✗ " .. (response.message or "Login failed"), "error")
        os.sleep(2)
    else
        showStatus("✗ No response from server", "error")
        os.sleep(2)
    end
    
    return false
end

-- Main menu
local function mainMenu()
    clearScreen()
    drawHeader("◆ ACCOUNT DASHBOARD ◆", username)
    
    -- Balance display
    drawBox(15, 6, 50, 5, colors.bg)
    gpu.setForeground(colors.textDim)
    gpu.set(17, 7, "BALANCE")
    gpu.setForeground(colors.balance)
    local balStr = string.format("%.2f CR", balance)
    local balX = math.floor(40 - unicode.len(balStr) / 2)
    gpu.set(balX, 9, balStr)
    
    -- Menu options
    local menuY = 13
    gpu.setForeground(colors.text)
    gpu.set(25, menuY, "1  Check Balance")
    gpu.set(25, menuY + 2, "2  Transfer Funds")
    gpu.set(25, menuY + 4, "3  View Accounts")
    gpu.set(25, menuY + 6, "4  Logout")
    
    drawFooter("Account: " .. username .. " • Connected")
    
    local _, _, char = event.pull("key_down")
    
    if char == string.byte('1') then
        -- Check balance
        showStatus("⟳ Refreshing balance...", "info")
        local response = sendAndWait({
            command = "balance",
            username = username,
            password = password
        })
        
        if response and response.success then
            balance = response.balance
            showStatus("✓ Balance: " .. string.format("%.2f", balance) .. " CR", "success")
        else
            showStatus("✗ " .. (response and response.message or "Failed"), "error")
        end
        os.sleep(2)
        
    elseif char == string.byte('2') then
        -- Transfer
        clearScreen()
        drawHeader("◆ TRANSFER FUNDS ◆", "Send credits to another account")
        
        drawBox(20, 8, 40, 11, colors.bg)
        
        gpu.setForeground(colors.textDim)
        gpu.set(22, 9, "Available: " .. string.format("%.2f CR", balance))
        
        gpu.setForeground(colors.text)
        local recipient = input("To:     ", 11, false, 20)
        
        if recipient == "" or recipient == username then
            showStatus("✗ Invalid recipient", "error")
            os.sleep(2)
            return
        end
        
        local amountStr = input("Amount: ", 13, false, 10)
        local amount = tonumber(amountStr)
        
        if not amount or amount <= 0 then
            showStatus("✗ Invalid amount", "error")
            os.sleep(2)
            return
        end
        
        if amount > balance then
            showStatus("✗ Insufficient funds", "error")
            os.sleep(2)
            return
        end
        
        gpu.setForeground(colors.warning)
        gpu.set(22, 16, "Confirm transfer?")
        gpu.set(22, 17, string.format("%.2f CR → %s", amount, recipient))
        drawButton(30, 19, "CONFIRM [Y]", true)
        drawButton(44, 19, "CANCEL [N]", false)
        
        local _, _, confirmChar = event.pull("key_down")
        
        if confirmChar == string.byte('y') or confirmChar == string.byte('Y') or confirmChar == 28 then
            showStatus("⟳ Processing transfer...", "info")
            
            local response = sendAndWait({
                command = "transfer",
                username = username,
                password = password,
                recipient = recipient,
                amount = amount
            }, 10)
            
            if not response then
                showStatus("✗ No response from server (timeout)", "error")
                os.sleep(3)
            elseif response.success then
                balance = response.balance
                showStatus("✓ Transfer successful! New balance: " .. string.format("%.2f", balance) .. " CR", "success")
                os.sleep(3)
            else
                showStatus("✗ " .. (response.message or "Transfer failed"), "error")
                os.sleep(3)
            end
        else
            showStatus("Transfer cancelled", "warning")
            os.sleep(1)
        end
        
    elseif char == string.byte('3') then
        -- List accounts
        showStatus("⟳ Loading accounts...", "info")
        
        local response = sendAndWait({
            command = "list_accounts"
        })
        
        if response and response.success then
            clearScreen()
            drawHeader("◆ ACCOUNT DIRECTORY ◆", "Total: " .. response.total .. " accounts")
            
            gpu.setForeground(colors.textDim)
            gpu.set(10, 6, "USERNAME")
            gpu.set(50, 6, "STATUS")
            
            drawLine(10, 7, 60, "─")
            
            local y = 8
            for i = 1, math.min(15, #response.accounts) do
                local acc = response.accounts[i]
                gpu.setForeground(colors.text)
                gpu.set(10, y, acc.name)
                
                if acc.online then
                    gpu.setForeground(colors.success)
                    gpu.set(50, y, "● ONLINE")
                else
                    gpu.setForeground(colors.textDim)
                    gpu.set(50, y, "○ offline")
                end
                y = y + 1
            end
            
            drawFooter("Press any key to return...")
            event.pull("key_down")
        else
            showStatus("✗ Failed to load accounts", "error")
            os.sleep(2)
        end
        
    elseif char == string.byte('4') then
        -- Logout
        showStatus("⟳ Logging out...", "info")
        
        sendAndWait({
            command = "logout",
            username = username,
            password = password
        })
        
        local disconnect = serialization.serialize({
            type = "client_deregister",
            tunnelAddress = tunnel.address,
            tunnelChannel = tunnel.getChannel()
        })
        tunnel.send(disconnect)
        
        loggedIn = false
        username = nil
        password = nil
        balance = 0
        
        showStatus("✓ Logged out successfully", "success")
        os.sleep(1)
    end
end

-- Main loop
local function main()
    clearScreen()
    
    -- Register with relay first
    while not relayConnected do
        if not registerWithRelay() then
            clearScreen()
            gpu.setForeground(colors.text)
            gpu.set(2, 10, "Retry connection? (y/n)")
            local _, _, char = event.pull("key_down")
            if char ~= string.byte('y') and char ~= string.byte('Y') then
                return
            end
        end
    end
    
    -- Main loop
    while true do
        if not loggedIn then
            local action = welcomeScreen()
            
            if action == "login" then
                loginScreen()
            elseif action == "exit" then
                break
            end
        else
            mainMenu()
        end
    end
    
    clearScreen()
    gpu.setForeground(colors.success)
    local msg = "Thank you for using Digital Currency!"
    local msgX = math.floor((w - unicode.len(msg)) / 2)
    gpu.set(msgX, 12, msg)
end

local success, err = pcall(main)
if not success then
    clearScreen()
    gpu.setForeground(colors.error)
    print("Error: " .. tostring(err))
end

-- Final cleanup
if loggedIn and username then
    pcall(sendAndWait, {
        command = "logout",
        username = username,
        password = password
    }, 2)
end

if relayConnected then
    local dereg = serialization.serialize({
        type = "client_deregister",
        tunnelAddress = tunnel.address,
        tunnelChannel = tunnel.getChannel()
    })
    pcall(tunnel.send, dereg)
end
