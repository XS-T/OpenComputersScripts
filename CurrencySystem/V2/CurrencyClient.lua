-- Digital Currency Client (Dual-Server) for OpenComputers 1.7.10
-- Connects to Currency Server (banking) AND Loan Server (loans)
-- Via relay with username-based routing
-- VERSION 1.0.0

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local term = require("term")
local computer = require("computer")
local gpu = component.gpu

if not component.isAvailable("tunnel") then
    print("ERROR: LINKED CARD REQUIRED!")
    return
end

local tunnel = component.tunnel
local username, password, balance = nil, nil, 0
local loggedIn, relayConnected = false, false
local creditScore, creditRating = 650, "FAIR"
local isAdmin = false

local w, h = 80, 25
gpu.setResolution(w, h)

local colors = {
    bg = 0x0F0F0F, header = 0x1E3A8A, accent = 0x3B82F6, success = 0x10B981,
    error = 0xEF4444, warning = 0xF59E0B, text = 0xFFFFFF, textDim = 0x9CA3AF,
    border = 0x374151, inputBg = 0x1F2937, balance = 0x10B981
}

local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
end

local function centerText(y, text, fg)
    local x = math.floor((w - #text) / 2)
    gpu.setForeground(fg or colors.text)
    gpu.set(x, y, text)
end

local function showStatus(msg, msgType)
    msgType = msgType or "info"
    local color = msgType == "success" and colors.success or msgType == "error" and colors.error or msgType == "warning" and colors.warning or colors.text
    gpu.setBackground(colors.bg)
    gpu.fill(1, h - 1, w, 1, " ")
    gpu.setForeground(color)
    centerText(h - 1, msg)
    gpu.setForeground(colors.text)
end

local function input(prompt, y, hidden, maxLen)
    maxLen = maxLen or 30
    gpu.setForeground(colors.text)
    gpu.set(2, y, prompt)
    local x = 3 + #prompt
    gpu.setBackground(colors.inputBg)
    gpu.fill(x, y, maxLen + 2, 1, " ")
    gpu.set(x + 1, y, "")
    local text = ""
    while true do
        local _, _, char, code = event.pull("key_down")
        if code == 28 then break
        elseif code == 14 and #text > 0 then
            text = text:sub(1, -2)
            gpu.setBackground(colors.inputBg)
            gpu.fill(x + 1, y, maxLen, 1, " ")
            gpu.set(x + 1, y, hidden and string.rep("•", #text) or text)
        elseif char >= 32 and char < 127 and #text < maxLen then
            text = text .. string.char(char)
            gpu.set(x + 1, y, hidden and string.rep("•", #text) or text)
        end
    end
    gpu.setBackground(colors.bg)
    return text
end

local function sendAndWait(data, timeout)
    timeout = timeout or 5
    if not relayConnected then
        return {type = "response", success = false, message = "Not connected to relay"}
    end
    
    data.tunnelAddress = tunnel.address
    data.tunnelChannel = tunnel.getChannel()
    tunnel.send(serialization.serialize(data))
    
    local deadline = computer.uptime() + timeout
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, _, port = table.unpack(eventData)
            if port == 0 or port == nil then
                local msg = eventData[6]
                local success, response = pcall(serialization.unserialize, msg)
                if success and response and response.type == "response" then
                    return response
                end
            end
        end
    end
    return nil
end

local function registerWithRelay()
    clearScreen()
    centerText(10, "Connecting to relay...", colors.accent)
    centerText(12, "Tunnel: " .. tunnel.address:sub(1, 20), colors.textDim)
    
    local registration = serialization.serialize({
        type = "client_register",
        tunnelAddress = tunnel.address,
        tunnelChannel = tunnel.getChannel()
    })
    
    tunnel.send(registration)
    
    local deadline = computer.uptime() + 5
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local port = eventData[4]
            if port == 0 or port == nil then
                local msg = eventData[6]
                local success, response = pcall(serialization.unserialize, msg)
                if success and response and response.type == "relay_ack" then
                    relayConnected = true
                    showStatus("✓ Connected to relay", "success")
                    os.sleep(1)
                    return true
                end
            end
        end
    end
    
    showStatus("✗ Connection failed", "error")
    os.sleep(2)
    return false
end

local function loginScreen()
    clearScreen()
    centerText(2, "◆ LOGIN ◆", colors.header)
    centerText(3, "Access your account", colors.textDim)
    
    local user = input("Username: ", 10, false, 20)
    local pass = input("Password: ", 12, true, 20)
    
    showStatus("⟳ Authenticating...", "info")
    local response = sendAndWait({command = "login", username = user, password = pass})
    
    if not response then
        showStatus("✗ No response from server", "error")
        os.sleep(2)
        return false
    end
    
    if response.success then
        username, password = user, pass
        balance = response.balance or 0
        isAdmin = response.isAdmin or false
        loggedIn = true
        showStatus("✓ Login successful" .. (isAdmin and " (ADMIN)" or ""), "success")
        os.sleep(1)
        return true
    elseif response.locked then
        clearScreen()
        centerText(10, "⚠ ACCOUNT LOCKED ⚠", colors.error)
        centerText(12, "Reason: " .. (response.lockReason or "Contact administrator"), colors.text)
        centerText(14, "Press Enter to return", colors.textDim)
        io.read()
        return false
    else
        showStatus("✗ " .. (response.message or "Login failed"), "error")
        os.sleep(2)
    end
    return false
end

local function mainMenu()
    while loggedIn do
        clearScreen()
        centerText(2, "◆ ACCOUNT DASHBOARD ◆", colors.header)
        centerText(3, username, colors.textDim)
        
        gpu.setForeground(colors.textDim)
        centerText(7, "BALANCE")
        gpu.setForeground(colors.balance)
        centerText(9, string.format("%.2f CR", balance))
        
        gpu.setForeground(colors.text)
        centerText(13, "1  Check Balance")
        centerText(15, "2  Transfer Funds")
        centerText(17, "3  Loan Center")
        if isAdmin then
            gpu.setForeground(colors.warning)
            centerText(19, "4  Admin Panel  ⭐")
            gpu.setForeground(colors.text)
            centerText(21, "0  Logout")
        else
            centerText(19, "0  Logout")
        end
        
        showStatus("Account: " .. username .. (isAdmin and " • ADMIN" or ""), "info")
        
        local _, _, char = event.pull("key_down")
        
        if char == string.byte('1') then
            showStatus("⟳ Refreshing balance...", "info")
            local response = sendAndWait({command = "balance", username = username, password = password})
            if response and response.success then
                balance = response.balance
                showStatus("✓ Balance: " .. string.format("%.2f CR", balance), "success")
            else
                showStatus("✗ Failed to refresh", "error")
            end
            os.sleep(2)
            
        elseif char == string.byte('2') then
            clearScreen()
            centerText(2, "◆ TRANSFER FUNDS ◆", colors.header)
            centerText(3, "Available: " .. string.format("%.2f CR", balance), colors.textDim)
            
            local recipient = input("To:     ", 10, false, 20)
            if recipient ~= "" and recipient ~= username then
                local amountStr = input("Amount: ", 12, false, 10)
                local amount = tonumber(amountStr)
                if amount and amount > 0 and amount <= balance then
                    showStatus("Confirm: " .. string.format("%.2f CR", amount) .. " → " .. recipient .. " (Y/N)", "warning")
                    local _, _, confirmChar = event.pull("key_down")
                    if confirmChar == string.byte('y') or confirmChar == string.byte('Y') then
                        showStatus("⟳ Processing transfer...", "info")
                        local response = sendAndWait({command = "transfer", username = username, password = password, recipient = recipient, amount = amount}, 10)
                        if response and response.success then
                            balance = response.balance
                            showStatus("✓ Transfer successful! New balance: " .. string.format("%.2f CR", balance), "success")
                        else
                            showStatus("✗ " .. (response and response.message or "Transfer failed"), "error")
                        end
                        os.sleep(3)
                    end
                else
                    showStatus("✗ Invalid amount", "error")
                    os.sleep(2)
                end
            end
            
        elseif char == string.byte('3') then
            -- Loan menu
            while true do
                clearScreen()
                centerText(2, "◆ LOAN CENTER ◆", colors.header)
                centerText(3, "Credit Score: " .. creditScore .. " (" .. creditRating .. ")", colors.textDim)
                
                centerText(10, "1  View Credit Score")
                centerText(11, "2  Check Eligibility")
                centerText(12, "3  Apply for Loan")
                centerText(13, "4  View My Loans")
                centerText(14, "5  Make Payment")
                centerText(16, "0  Back to Main Menu")
                
                showStatus("Loan Center", "info")
                
                local _, _, loanChar = event.pull("key_down")
                
                if loanChar == string.byte('0') then
                    break
                elseif loanChar == string.byte('1') then
                    showStatus("⟳ Loading credit score...", "info")
                    local response = sendAndWait({command = "get_credit_score", username = username, password = password})
                    if response and response.success then
                        clearScreen()
                        centerText(2, "◆ CREDIT SCORE ◆", colors.header)
                        centerText(8, "Your Credit Score", colors.textDim)
                        centerText(10, tostring(response.score or 0), colors.success)
                        centerText(12, "Rating: " .. (response.rating or "UNKNOWN"), colors.text)
                        centerText(20, "Press Enter to continue", colors.textDim)
                        io.read()
                    else
                        showStatus("✗ Failed to load", "error")
                        os.sleep(2)
                    end
                elseif loanChar == string.byte('3') then
                    -- Apply for loan
                    showStatus("⟳ Checking eligibility...", "info")
                    local eligResponse = sendAndWait({command = "get_loan_eligibility", username = username, password = password})
                    if eligResponse and eligResponse.success and eligResponse.eligible then
                        clearScreen()
                        centerText(2, "◆ APPLY FOR LOAN ◆", colors.header)
                        centerText(3, "Max: " .. string.format("%.2f CR", eligResponse.maxLoan), colors.textDim)
                        
                        local amountStr = input("Amount:     ", 10, false, 15)
                        local amount = tonumber(amountStr)
                        if amount and amount >= 100 and amount <= eligResponse.maxLoan then
                            local termStr = input("Term (days):", 12, false, 5)
                            local term = tonumber(termStr)
                            if term and term >= 1 and term <= 30 then
                                showStatus("⟳ Submitting application...", "info")
                                local response = sendAndWait({command = "apply_loan", username = username, password = password, amount = amount, term = term})
                                if response and response.success then
                                    showStatus("✓ Application submitted! ID: " .. (response.pendingId or ""), "success")
                                else
                                    showStatus("✗ " .. (response and response.message or "Failed"), "error")
                                end
                                os.sleep(3)
                            end
                        end
                    else
                        showStatus("✗ Not eligible for loans", "error")
                        os.sleep(2)
                    end
                end
            end
            
        elseif char == string.byte('0') then
            showStatus("⟳ Logging out...", "info")
            sendAndWait({command = "logout", username = username, password = password})
            loggedIn = false
            username, password, balance = nil, nil, 0
            isAdmin = false
            showStatus("✓ Logged out", "success")
            os.sleep(1)
        end
    end
end

local function main()
    clearScreen()
    
    while not relayConnected do
        if not registerWithRelay() then
            clearScreen()
            centerText(12, "Retry connection? (Y/N)", colors.text)
            local _, _, char = event.pull("key_down")
            if char ~= string.byte('y') and char ~= string.byte('Y') then
                return
            end
        end
    end
    
    while true do
        if not loggedIn then
            clearScreen()
            centerText(2, "◆ DIGITAL CURRENCY SYSTEM ◆", colors.header)
            centerText(3, "Secure Banking + Loans", colors.textDim)
            centerText(12, "1  Login to Account")
            centerText(14, "2  Exit")
            showStatus("Welcome", "info")
            
            local _, _, char = event.pull("key_down")
            if char == string.byte('1') then
                loginScreen()
            elseif char == string.byte('2') then
                break
            end
        else
            mainMenu()
        end
    end
    
    clearScreen()
    centerText(12, "Thank you for using Digital Currency!", colors.success)
end

local success, err = pcall(main)
if not success then
    clearScreen()
    print("Error: " .. tostring(err))
end

if loggedIn and username then
    pcall(sendAndWait, {command = "logout", username = username, password = password}, 2)
end

if relayConnected then
    local dereg = serialization.serialize({
        type = "client_deregister",
        tunnelAddress = tunnel.address,
        tunnelChannel = tunnel.getChannel()
    })
    pcall(tunnel.send, dereg)
end
