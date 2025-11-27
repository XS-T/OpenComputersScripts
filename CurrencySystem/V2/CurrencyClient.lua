-- Digital Currency Client with Loans for OpenComputers 1.7.10
-- Connects via TUNNEL (linked card)

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local term = require("term")
local computer = require("computer")
local gpu = component.gpu
local unicode = require("unicode")

if not component.isAvailable("tunnel") then
    print("ERROR: LINKED CARD REQUIRED!")
    print("This client requires a linked card to connect to a relay.")
    return
end

local tunnel = component.tunnel
local username = nil
local password = nil
local balance = 0
local loggedIn = false
local relayConnected = false
local clientId = tunnel.address
local creditScore = 650
local creditRating = "FAIR"

local w, h = gpu.getResolution()
gpu.setResolution(80, 25)
w, h = 80, 25

local colors = {
    bg = 0x0F0F0F, header = 0x1E3A8A, accent = 0x3B82F6, success = 0x10B981,
    error = 0xEF4444, warning = 0xF59E0B, text = 0xFFFFFF, textDim = 0x9CA3AF,
    border = 0x374151, inputBg = 0x1F2937, balance = 0x10B981,
    excellent = 0x10B981, good = 0x3B82F6, fair = 0xF59E0B, poor = 0xEF4444
}

local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
end

local function drawHeader(title, subtitle)
    gpu.setBackground(colors.header)
    gpu.fill(1, 1, w, 3, " ")
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
    elseif msgType == "warning" then color = colors.warning end
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
    gpu.setBackground(colors.inputBg)
    gpu.fill(x, y, maxLen + 2, 1, " ")
    x = x + 1
    gpu.set(x, y, "")
    local text = ""
    while true do
        local _, _, char, code = event.pull("key_down")
        if code == 28 then break
        elseif code == 14 and unicode.len(text) > 0 then
            text = unicode.sub(text, 1, -2)
            gpu.setBackground(colors.inputBg)
            gpu.fill(x, y, maxLen, 1, " ")
            if hidden then gpu.set(x, y, string.rep("•", unicode.len(text)))
            else gpu.set(x, y, text) end
        elseif char >= 32 and char < 127 and unicode.len(text) < maxLen then
            text = text .. string.char(char)
            if hidden then gpu.set(x, y, string.rep("•", unicode.len(text)))
            else gpu.set(x, y, text) end
        end
    end
    gpu.setBackground(colors.bg)
    return text
end

local function drawBox(x, y, width, height, color)
    gpu.setBackground(color or colors.bg)
    gpu.fill(x, y, width, height, " ")
end

local function centerText(y, text, fg)
    local x = math.floor((w - unicode.len(text)) / 2)
    gpu.setForeground(fg or colors.text)
    gpu.set(x, y, text)
end

local function sendAndWait(data, timeout)
    timeout = timeout or 5
    if not relayConnected then
        return {type = "response", success = false, message = "Not connected to relay"}
    end
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

local function registerWithRelay()
    clearScreen()
    drawHeader("◆ CONNECTING TO RELAY ◆", "Establishing secure tunnel connection")
    drawBox(20, 8, 40, 12, colors.bg)
    gpu.setForeground(colors.accent)
    gpu.set(22, 10, "Tunnel Component Check:")
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
            gpu.fill(22, 19, 35, 1, " ")
            gpu.setForeground(colors.textDim)
            gpu.set(22, 19, "Event #" .. eventCount .. ": port=" .. tostring(port))
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

local function welcomeScreen()
    clearScreen()
    drawHeader("◆ DIGITAL CURRENCY SYSTEM ◆", "Secure P2P Banking + Loans")
    drawBox(15, 7, 50, 5, colors.bg)
    gpu.setForeground(colors.accent)
    gpu.set(17, 8, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    gpu.setForeground(colors.textDim)
    gpu.set(17, 9, "  Secured by linked card technology")
    gpu.set(17, 10, "  Credit scoring & loan management")
    gpu.setForeground(colors.accent)
    gpu.set(17, 11, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    gpu.setForeground(colors.text)
    gpu.set(32, 15, "1  Login to Account")
    gpu.set(32, 17, "2  Exit")
    gpu.setForeground(colors.textDim)
    gpu.set(17, 20, "Note: Account registration is managed by")
    gpu.set(17, 21, "      administrators at the server level.")
    drawFooter("Linked Card: " .. tunnel.getChannel():sub(1, 16) .. " • Secure Connection")
    local _, _, char = event.pull("key_down")
    if char == string.byte('1') then return "login"
    elseif char == string.byte('2') then return "exit" end
    return nil
end

local function loginScreen()
    clearScreen()
    drawHeader("◆ LOGIN ◆", "Access your account")
    drawBox(20, 8, 40, 10, colors.bg)
    gpu.setForeground(colors.text)
    local user = input("Username: ", 10, false, 20)
    local pass = input("Password: ", 12, true, 20)
    showStatus("⟳ Authenticating...", "info")
    local response = sendAndWait({command = "login", username = user, password = pass})
    if response and response.success then
        username = user
        password = pass
        balance = response.balance or 0
        creditScore = response.creditScore or 650
        creditRating = response.creditRating or "FAIR"
        loggedIn = true
        showStatus("✓ Login successful!", "success")
        os.sleep(1)
        return true
    elseif response and response.locked then
        clearScreen()
        drawHeader("◆ ACCOUNT LOCKED ◆")
        drawBox(10, 8, 60, 12, colors.bg)
        gpu.setForeground(colors.error)
        centerText(9, "⚠ YOUR ACCOUNT IS LOCKED ⚠")
        gpu.setForeground(colors.text)
        centerText(11, "Reason: " .. (response.lockReason or "Contact administrator"))
        if response.lockedDate then
            local daysLocked = math.floor((os.time() - response.lockedDate) / 86400)
            centerText(12, "Days locked: " .. daysLocked)
        end
        gpu.setForeground(colors.textDim)
        centerText(14, "Please contact a server administrator")
        centerText(15, "to resolve this issue and unlock your account.")
        centerText(18, "Press Enter to return")
        drawFooter("Account Locked")
        io.read()
        username = nil
        password = nil
        return false
    elseif response then
        showStatus("✗ " .. (response.message or "Login failed"), "error")
        os.sleep(2)
    else
        showStatus("✗ No response from server", "error")
        os.sleep(2)
    end
    return false
end

local function getCreditScoreColor(score)
    if score >= 750 then return colors.excellent
    elseif score >= 700 then return colors.good
    elseif score >= 650 then return colors.fair
    else return colors.poor end
end

local function viewCreditScore()
    clearScreen()
    drawHeader("◆ CREDIT SCORE ◆", username)
    showStatus("⟳ Loading credit information...", "info")
    local response = sendAndWait({command = "get_credit_score", username = username, password = password})
    if response and response.success then
        clearScreen()
        drawHeader("◆ CREDIT SCORE ◆", username)
        drawBox(15, 6, 50, 15, colors.bg)
        gpu.setForeground(colors.textDim)
        centerText(7, "Your Credit Score")
        local scoreColor = getCreditScoreColor(response.score)
        gpu.setForeground(scoreColor)
        centerText(9, tostring(response.score))
        gpu.setForeground(colors.text)
        centerText(11, "Rating: " .. response.rating)
        gpu.setForeground(colors.textDim)
        centerText(13, "━━━━━━━━━━━━━━━━━━━━━━━━━━")
        gpu.setForeground(colors.text)
        centerText(14, "Credit History")
        if response.history and #response.history > 0 then
            local y = 15
            for i = 1, math.min(4, #response.history) do
                local event = response.history[i]
                local desc = event.description or "Unknown"
                if #desc > 45 then desc = desc:sub(1, 42) .. "..." end
                gpu.setForeground(colors.textDim)
                gpu.set(17, y, desc)
                y = y + 1
            end
        else
            gpu.setForeground(colors.textDim)
            centerText(16, "No credit history")
        end
    else
        showStatus("✗ Failed to load credit score", "error")
    end
    centerText(21, "Press Enter to continue")
    drawFooter("Credit Information")
    io.read()
end

local function checkLoanEligibility()
    clearScreen()
    drawHeader("◆ LOAN ELIGIBILITY ◆", username)
    showStatus("⟳ Checking eligibility...", "info")
    local response = sendAndWait({command = "get_loan_eligibility", username = username, password = password})
    if response and response.success then
        clearScreen()
        drawHeader("◆ LOAN ELIGIBILITY ◆", username)
        drawBox(10, 6, 60, 14, colors.bg)
        gpu.setForeground(colors.text)
        gpu.set(12, 7, "Credit Score: " .. response.creditScore .. " (" .. response.creditRating .. ")")
        gpu.set(12, 9, "Maximum Loan Amount: " .. string.format("%.2f CR", response.maxLoan))
        gpu.set(12, 10, "Interest Rate: " .. string.format("%.1f%%", response.interestRate * 100))
        gpu.set(12, 12, "Active Loans: " .. response.activeLoans)
        gpu.set(12, 13, "Total Owed: " .. string.format("%.2f CR", response.totalOwed))
        if response.eligible then
            gpu.setForeground(colors.success)
            centerText(16, "✓ You are eligible for loans")
        else
            gpu.setForeground(colors.error)
            centerText(16, "✗ Not currently eligible for loans")
        end
    else
        showStatus("✗ Failed to check eligibility", "error")
    end
    centerText(19, "Press Enter to continue")
    drawFooter("Loan Eligibility Check")
    io.read()
end

local function applyForLoan()
    clearScreen()
    drawHeader("◆ APPLY FOR LOAN ◆", username)
    showStatus("⟳ Checking eligibility...", "info")
    local eligResponse = sendAndWait({command = "get_loan_eligibility", username = username, password = password})
    if not eligResponse or not eligResponse.success then
        showStatus("✗ Failed to check eligibility", "error")
        os.sleep(2)
        return
    end
    if not eligResponse.eligible then
        clearScreen()
        drawHeader("◆ NOT ELIGIBLE ◆", username)
        drawBox(15, 8, 50, 8, colors.bg)
        gpu.setForeground(colors.error)
        centerText(10, "You are not currently eligible for loans")
        gpu.setForeground(colors.textDim)
        centerText(12, "Improve your credit score to qualify")
        centerText(14, "Press Enter to continue")
        drawFooter("Loan Application")
        io.read()
        return
    end
    clearScreen()
    drawHeader("◆ APPLY FOR LOAN ◆", username)
    drawBox(15, 6, 50, 13, colors.bg)
    gpu.setForeground(colors.text)
    gpu.set(17, 7, "Max Loan: " .. string.format("%.2f CR", eligResponse.maxLoan))
    gpu.set(17, 8, "Rate: " .. string.format("%.1f%%", eligResponse.interestRate * 100))
    local amountStr = input("Amount:     ", 10, false, 15)
    local amount = tonumber(amountStr)
    if not amount or amount <= 0 then
        showStatus("✗ Invalid amount", "error")
        os.sleep(2)
        return
    end
    if amount > eligResponse.maxLoan then
        showStatus("✗ Amount exceeds maximum", "error")
        os.sleep(2)
        return
    end
    local termStr = input("Term (days):", 12, false, 5)
    local term = tonumber(termStr)
    if not term or term < 1 or term > 30 then
        showStatus("✗ Invalid term (1-30 days)", "error")
        os.sleep(2)
        return
    end
    local interest = amount * eligResponse.interestRate
    local total = amount + interest
    gpu.setForeground(colors.textDim)
    gpu.set(17, 14, "Interest: " .. string.format("%.2f CR", interest))
    gpu.set(17, 15, "Total Owed: " .. string.format("%.2f CR", total))
    gpu.setForeground(colors.warning)
    centerText(17, "Confirm? (Y/N)")
    local _, _, char = event.pull("key_down")
    if char ~= string.byte('y') and char ~= string.byte('Y') then
        showStatus("✗ Cancelled", "warning")
        os.sleep(1)
        return
    end
    showStatus("⟳ Processing loan application...", "info")
    local response = sendAndWait({command = "apply_loan", username = username, password = password, amount = amount, term = term})
    if response and response.success then
        clearScreen()
        drawHeader("◆ LOAN APPLICATION SUBMITTED ◆", username)
        drawBox(15, 8, 50, 10, colors.bg)
        gpu.setForeground(colors.success)
        centerText(10, "✓ Application Submitted!")
        gpu.setForeground(colors.text)
        centerText(12, "Application ID: " .. response.pendingId)
        gpu.setForeground(colors.textDim)
        centerText(14, "Your loan is pending admin approval")
        centerText(15, "You will be notified when processed")
        centerText(17, "Press Enter to continue")
        drawFooter("Loan Application • Pending")
        io.read()
    else
        showStatus("✗ " .. (response and response.message or "Application failed"), "error")
        os.sleep(2)
    end
end

local function viewMyLoans()
    clearScreen()
    drawHeader("◆ MY LOANS ◆", username)
    showStatus("⟳ Loading loans...", "info")
    local response = sendAndWait({command = "get_my_loans", username = username, password = password})
    if response and response.success then
        clearScreen()
        drawHeader("◆ MY LOANS ◆", username)
        if #response.loans == 0 then
            drawBox(20, 10, 40, 5, colors.bg)
            gpu.setForeground(colors.textDim)
            centerText(12, "No active loans")
        else
            drawBox(5, 6, 70, 15, colors.bg)
            gpu.setForeground(colors.text)
            gpu.set(7, 7, "Loan ID")
            gpu.set(25, 7, "Principal")
            gpu.set(40, 7, "Remaining")
            gpu.set(55, 7, "Status")
            local y = 8
            for i = 1, math.min(10, #response.loans) do
                local loan = response.loans[i]
                gpu.setForeground(colors.textDim)
                gpu.set(7, y, loan.loanId)
                gpu.set(25, y, string.format("%.2f", loan.principal))
                gpu.set(40, y, string.format("%.2f", loan.remaining))
                local statusColor = colors.success
                if loan.status == "default" then statusColor = colors.error
                elseif loan.status == "paid" then statusColor = colors.good end
                gpu.setForeground(statusColor)
                gpu.set(55, y, loan.status)
                y = y + 1
            end
        end
    else
        showStatus("✗ Failed to load loans", "error")
    end
    centerText(22, "Press Enter to continue")
    drawFooter("My Loans")
    io.read()
end

local function makePayment()
    clearScreen()
    drawHeader("◆ MAKE PAYMENT ◆", username)
    showStatus("⟳ Loading loans...", "info")
    local loansResponse = sendAndWait({command = "get_my_loans", username = username, password = password})
    if not loansResponse or not loansResponse.success or #loansResponse.loans == 0 then
        clearScreen()
        drawHeader("◆ MAKE PAYMENT ◆", username)
        drawBox(20, 10, 40, 5, colors.bg)
        gpu.setForeground(colors.textDim)
        centerText(12, "No active loans to pay")
        centerText(14, "Press Enter to continue")
        drawFooter("Loan Payment")
        io.read()
        return
    end
    clearScreen()
    drawHeader("◆ MAKE PAYMENT ◆", username)
    drawBox(15, 6, 50, 14, colors.bg)
    gpu.setForeground(colors.text)
    gpu.set(17, 7, "Balance: " .. string.format("%.2f CR", balance))
    local loanId = input("Loan ID:    ", 9, false, 15)
    if not loanId or loanId == "" then return end
    local amountStr = input("Amount:     ", 11, false, 15)
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
    showStatus("⟳ Processing payment...", "info")
    local response = sendAndWait({command = "make_loan_payment", username = username, password = password, loanId = loanId, amount = amount})
    if response and response.success then
        balance = response.balance
        showStatus(string.format("✓ Paid %.2f CR, Remaining: %.2f CR", response.paid, response.remaining), "success")
        os.sleep(3)
    else
        showStatus("✗ " .. (response and response.message or "Payment failed"), "error")
        os.sleep(2)
    end
end

local function loanMenu()
    while loggedIn do
        clearScreen()
        drawHeader("◆ LOAN CENTER ◆", username)
        drawBox(20, 7, 40, 12, colors.bg)
        gpu.setForeground(colors.text)
        centerText(8, "Credit Score: " .. creditScore .. " (" .. creditRating .. ")")
        gpu.setForeground(colors.accent)
        centerText(10, "1  View Credit Score")
        centerText(11, "2  Check Eligibility")
        centerText(12, "3  Apply for Loan")
        centerText(13, "4  View My Loans")
        centerText(14, "5  Make Payment")
        centerText(16, "0  Back to Main Menu")
        drawFooter("Loan Center - Select option")
        local _, _, char = event.pull("key_down")
        if char == string.byte('1') then viewCreditScore()
        elseif char == string.byte('2') then checkLoanEligibility()
        elseif char == string.byte('3') then applyForLoan()
        elseif char == string.byte('4') then viewMyLoans()
        elseif char == string.byte('5') then makePayment()
        elseif char == string.byte('0') then break end
    end
end

-- Admin Functions
local function getPendingLoans()
    local response = sendAndWait({command = "get_pending_loans", username = username, password = password})
    if response and response.success then
        return response.pendingLoans or {}
    end
    return {}
end

local function approveLoan(pendingId)
    return sendAndWait({command = "approve_loan", username = username, password = password, pendingId = pendingId})
end

local function denyLoan(pendingId, reason)
    return sendAndWait({command = "deny_loan", username = username, password = password, pendingId = pendingId, reason = reason})
end

local function viewPendingLoansUI()
    clearScreen()
    drawHeader("◆ PENDING LOAN APPLICATIONS ◆", "Review and approve/deny")
    
    showStatus("⟳ Loading applications...", "info")
    local pending = getPendingLoans()
    
    if #pending == 0 then
        drawBox(20, 10, 40, 5, colors.bg)
        gpu.setForeground(colors.success)
        centerText(12, "✓ No pending applications")
        gpu.setForeground(colors.textDim)
        centerText(14, "Press any key to return")
        drawFooter("Admin Panel • No pending loans")
        event.pull("key_down")
        return
    end
    
    local currentIndex = 1
    
    while true do
        clearScreen()
        drawHeader("◆ PENDING LOAN APPLICATIONS ◆", string.format("Application %d of %d", currentIndex, #pending))
        
        local app = pending[currentIndex]
        
        drawBox(10, 6, 60, 16, colors.bg)
        
        gpu.setForeground(colors.accent)
        gpu.set(12, 7, "Application ID: " .. app.pendingId)
        
        gpu.setForeground(colors.text)
        gpu.set(12, 9, "User: " .. app.username)
        
        local ratingColor = colors.textDim
        if app.creditRating == "EXCELLENT" then ratingColor = colors.excellent
        elseif app.creditRating == "GOOD" then ratingColor = colors.good
        elseif app.creditRating == "FAIR" then ratingColor = colors.fair
        elseif app.creditRating == "POOR" or app.creditRating == "BAD" then ratingColor = colors.poor
        end
        
        gpu.setForeground(colors.textDim)
        gpu.set(12, 10, "Credit Score: ")
        gpu.setForeground(ratingColor)
        gpu.set(26, 10, app.creditScore .. " (" .. app.creditRating .. ")")
        
        gpu.setForeground(colors.textDim)
        gpu.set(12, 12, "Amount Requested:")
        gpu.setForeground(colors.text)
        gpu.set(35, 12, string.format("%.2f CR", app.amount))
        
        gpu.setForeground(colors.textDim)
        gpu.set(12, 13, "Loan Term:")
        gpu.setForeground(colors.text)
        gpu.set(35, 13, app.termDays .. " days")
        
        gpu.setForeground(colors.textDim)
        gpu.set(12, 14, "Interest Rate:")
        gpu.setForeground(colors.text)
        gpu.set(35, 14, string.format("%.1f%%", app.interestRate * 100))
        
        gpu.setForeground(colors.textDim)
        gpu.set(12, 15, "Interest Amount:")
        gpu.setForeground(colors.text)
        gpu.set(35, 15, string.format("%.2f CR", app.interest))
        
        gpu.setForeground(colors.textDim)
        gpu.set(12, 16, "Total to Repay:")
        gpu.setForeground(colors.warning)
        gpu.set(35, 16, string.format("%.2f CR", app.totalOwed))
        
        local timeAgo = os.time() - app.appliedDate
        local hoursAgo = math.floor(timeAgo / 3600)
        local timeStr
        if hoursAgo < 1 then
            timeStr = "Just now"
        elseif hoursAgo == 1 then
            timeStr = "1 hour ago"
        elseif hoursAgo < 24 then
            timeStr = hoursAgo .. " hours ago"
        else
            local daysAgo = math.floor(hoursAgo / 24)
            timeStr = daysAgo .. " day" .. (daysAgo > 1 and "s" or "") .. " ago"
        end
        
        gpu.setForeground(colors.textDim)
        gpu.set(12, 18, "Applied: " .. timeStr)
        
        gpu.setForeground(colors.success)
        gpu.set(12, 20, "[A] Approve")
        gpu.setForeground(colors.error)
        gpu.set(30, 20, "[D] Deny")
        gpu.setForeground(colors.textDim)
        gpu.set(45, 20, "[N] Next")
        gpu.set(58, 20, "[ESC] Back")
        
        drawFooter("Admin Panel • Pending: " .. #pending)
        
        local _, _, char, code = event.pull("key_down")
        
        if code == 1 then
            return
        elseif char == string.byte('a') or char == string.byte('A') then
            gpu.setForeground(colors.warning)
            gpu.set(12, 22, "Confirm approval? (Y/N)")
            local _, _, confirmChar = event.pull("key_down")
            if confirmChar == string.byte('y') or confirmChar == string.byte('Y') then
                showStatus("⟳ Approving loan...", "info")
                local response = approveLoan(app.pendingId)
                if response and response.success then
                    showStatus("✓ Loan approved! Loan ID: " .. response.loanId, "success")
                    os.sleep(2)
                    pending = getPendingLoans()
                    if #pending == 0 then return end
                    currentIndex = math.min(currentIndex, #pending)
                else
                    showStatus("✗ " .. (response and response.message or "Failed"), "error")
                    os.sleep(2)
                end
            end
        elseif char == string.byte('d') or char == string.byte('D') then
            clearScreen()
            drawHeader("◆ DENY LOAN APPLICATION ◆", app.pendingId)
            drawBox(15, 8, 50, 8, colors.bg)
            gpu.setForeground(colors.text)
            local reason = input("Reason:  ", 10, false, 40)
            if reason and reason ~= "" then
                gpu.setForeground(colors.warning)
                gpu.set(17, 14, "Confirm denial? (Y/N)")
                local _, _, confirmChar = event.pull("key_down")
                if confirmChar == string.byte('y') or confirmChar == string.byte('Y') then
                    showStatus("⟳ Denying loan...", "info")
                    local response = denyLoan(app.pendingId, reason)
                    if response and response.success then
                        showStatus("✓ Loan denied", "success")
                        os.sleep(2)
                        pending = getPendingLoans()
                        if #pending == 0 then return end
                        currentIndex = math.min(currentIndex, #pending)
                    else
                        showStatus("✗ " .. (response and response.message or "Failed"), "error")
                        os.sleep(2)
                    end
                end
            end
        elseif char == string.byte('n') or char == string.byte('N') then
            currentIndex = currentIndex + 1
            if currentIndex > #pending then currentIndex = 1 end
        end
    end
end

local function adminPanel()
    -- First verify with server that we're actually an admin
    showStatus("⟳ Verifying admin access...", "info")
    local verifyResponse = sendAndWait({command = "get_pending_loans", username = username, password = password})
    
    if not verifyResponse or not verifyResponse.success then
        clearScreen()
        drawHeader("◆ ACCESS DENIED ◆")
        drawBox(20, 10, 40, 6, colors.bg)
        gpu.setForeground(colors.error)
        centerText(12, "⚠ Admin Access Required")
        gpu.setForeground(colors.textDim)
        centerText(14, verifyResponse and verifyResponse.message or "You do not have admin privileges")
        centerText(16, "Press Enter to continue")
        drawFooter("Access Denied")
        io.read()
        return
    end
    
    while true do
        clearScreen()
        drawHeader("◆ ADMIN PANEL ◆", "Administrative Functions")
        
        drawBox(20, 8, 40, 12, colors.bg)
        
        gpu.setForeground(colors.warning)
        gpu.set(22, 9, "⭐ ADMIN ACCESS ⭐")
        
        gpu.setForeground(colors.text)
        gpu.set(25, 12, "1  View Pending Loans")
        
        local pending = getPendingLoans()
        local pendingCount = #pending
        if pendingCount > 0 then
            gpu.setForeground(colors.warning)
            gpu.set(50, 12, "(" .. pendingCount .. ")")
        end
        
        gpu.setForeground(colors.textDim)
        gpu.set(25, 14, "2  View Server Stats")
        gpu.set(25, 16, "3  Admin Help")
        
        gpu.setForeground(colors.text)
        gpu.set(25, 18, "0  Back to Main Menu")
        
        drawFooter("Admin Panel • User: " .. username .. " • Pending: " .. pendingCount)
        
        local _, _, char = event.pull("key_down")
        
        if char == string.byte('1') then
            viewPendingLoansUI()
        elseif char == string.byte('2') then
            clearScreen()
            drawHeader("◆ SERVER STATISTICS ◆")
            drawBox(20, 8, 40, 8, colors.bg)
            gpu.setForeground(colors.textDim)
            centerText(10, "Use server F5 admin panel")
            centerText(11, "for full server statistics")
            centerText(13, "and management tools")
            gpu.setForeground(colors.text)
            centerText(15, "Press any key to return")
            drawFooter("Admin Panel")
            event.pull("key_down")
        elseif char == string.byte('3') then
            clearScreen()
            drawHeader("◆ ADMIN HELP ◆")
            drawBox(10, 6, 60, 14, colors.bg)
            gpu.setForeground(colors.text)
            gpu.set(12, 7, "Client Admin Functions:")
            gpu.setForeground(colors.textDim)
            gpu.set(12, 9, "• View Pending Loans - Review loan applications")
            gpu.set(12, 10, "• Approve/Deny - Accept or reject applications")
            gpu.set(12, 11, "• Notifications - Get alerts for new requests")
            gpu.setForeground(colors.text)
            gpu.set(12, 13, "Server Admin Panel (F5 on server):")
            gpu.setForeground(colors.textDim)
            gpu.set(12, 14, "• Full account management")
            gpu.set(12, 15, "• Loan forgiveness & credit adjustment")
            gpu.set(12, 16, "• System configuration & RAID")
            gpu.set(12, 17, "• Toggle admin status for users")
            gpu.setForeground(colors.text)
            centerText(19, "Press any key to return")
            drawFooter("Admin Panel • Help")
            event.pull("key_down")
        elseif char == string.byte('0') then
            return
        end
    end
end

local function mainMenu()
    while loggedIn do
        clearScreen()
        drawHeader("◆ ACCOUNT DASHBOARD ◆", username)
        drawBox(15, 6, 50, 5, colors.bg)
        gpu.setForeground(colors.textDim)
        gpu.set(17, 7, "BALANCE")
        gpu.setForeground(colors.balance)
        local balStr = string.format("%.2f CR", balance)
        local balX = math.floor(40 - unicode.len(balStr) / 2)
        gpu.set(balX, 9, balStr)
        local menuY = 13
        gpu.setForeground(colors.text)
        gpu.set(25, menuY, "1  Check Balance")
        gpu.set(25, menuY + 2, "2  Transfer Funds")
        gpu.set(25, menuY + 4, "3  Loan Center")
        gpu.setForeground(colors.warning)
        gpu.set(25, menuY + 6, "4  Admin Panel")
        gpu.setForeground(colors.text)
        gpu.set(25, menuY + 8, "0  Logout")
        drawFooter("Account: " .. username .. " • Connected")
        local _, _, char = event.pull("key_down")
        if char == string.byte('1') then
            showStatus("⟳ Refreshing balance...", "info")
            local response = sendAndWait({command = "balance", username = username, password = password})
            if response and response.success then
                balance = response.balance
                showStatus("✓ Balance: " .. string.format("%.2f", balance) .. " CR", "success")
            else
                showStatus("✗ " .. (response and response.message or "Failed"), "error")
            end
            os.sleep(2)
        elseif char == string.byte('2') then
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
            else
                local amountStr = input("Amount: ", 13, false, 10)
                local amount = tonumber(amountStr)
                if not amount or amount <= 0 then
                    showStatus("✗ Invalid amount", "error")
                    os.sleep(2)
                elseif amount > balance then
                    showStatus("✗ Insufficient funds", "error")
                    os.sleep(2)
                else
                    gpu.setForeground(colors.warning)
                    gpu.set(22, 16, "Confirm transfer?")
                    gpu.set(22, 17, string.format("%.2f CR → %s", amount, recipient))
                    local _, _, confirmChar = event.pull("key_down")
                    if confirmChar == string.byte('y') or confirmChar == string.byte('Y') then
                        showStatus("⟳ Processing transfer...", "info")
                        local response = sendAndWait({command = "transfer", username = username, password = password, recipient = recipient, amount = amount}, 10)
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
                end
            end
        elseif char == string.byte('3') then
            loanMenu()
        elseif char == string.byte('4') then
            -- Try to access admin panel - server will verify
            adminPanel()
        elseif char == string.byte('0') then
            -- Logout
            showStatus("⟳ Logging out...", "info")
            sendAndWait({command = "logout", username = username, password = password})
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
end

local function main()
    clearScreen()
    while not relayConnected do
        if not registerWithRelay() then
            clearScreen()
            gpu.setForeground(colors.text)
            gpu.set(2, 10, "Retry connection? (y/n)")
            local _, _, char = event.pull("key_down")
            if char ~= string.byte('y') and char ~= string.byte('Y') then return end
        end
    end
    while true do
        if not loggedIn then
            local action = welcomeScreen()
            if action == "login" then loginScreen()
            elseif action == "exit" then break end
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
