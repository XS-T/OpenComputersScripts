-- Digital Currency Client (Dual-Server) with ADMIN FEATURES
-- Connects to Currency Server (banking) AND Loan Server (loans)
-- VERSION 2.0.0 - WITH ADMIN PANEL

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
local creditScore, creditRating = nil, nil  -- Fetched from server
local isAdmin = false

local w, h = 80, 25
gpu.setResolution(w, h)

local colors = {
    bg = 0x0F0F0F, header = 0x1E3A8A, accent = 0x3B82F6, success = 0x10B981,
    error = 0xEF4444, warning = 0xF59E0B, text = 0xFFFFFF, textDim = 0x9CA3AF,
    border = 0x374151, inputBg = 0x1F2937, balance = 0x10B981, adminRed = 0xFF0000
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
    local x = math.floor((w - #msg) / 2)
    gpu.set(x, h - 1, msg)
end

local function drawHeader(title, subtitle)
    gpu.setBackground(colors.header)
    gpu.fill(1, 1, w, 3, " ")
    centerText(2, title, colors.text)
    if subtitle then
        centerText(3, subtitle, colors.textDim)
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

local function input(prompt, y, hidden, maxLen)
    maxLen = maxLen or 30
    gpu.setForeground(colors.text)
    gpu.set(2, y, prompt)
    local x = 2 + #prompt
    gpu.setBackground(colors.inputBg)
    gpu.fill(x, y, maxLen + 2, 1, " ")
    x = x + 1
    gpu.set(x, y, "")
    local text = ""
    while true do
        local _, _, char, code = event.pull("key_down")
        if code == 28 then break
        elseif code == 14 and #text > 0 then
            text = text:sub(1, -2)
            gpu.setBackground(colors.inputBg)
            gpu.fill(x, y, maxLen, 1, " ")
            if hidden then
                gpu.set(x, y, string.rep("•", #text))
            else
                gpu.set(x, y, text)
            end
        elseif char >= 32 and char < 127 and #text < maxLen then
            text = text .. string.char(char)
            if hidden then
                gpu.set(x, y, string.rep("•", #text))
            else
                gpu.set(x, y, text)
            end
        end
    end
    gpu.setBackground(colors.bg)
    return text
end

-- Communication functions
local function sendToRelay(data)
    data.tunnelAddress = tunnel.address
    data.tunnelChannel = tunnel.getChannel()
    local msg = serialization.serialize(data)
    tunnel.send(msg)
end

local function waitForResponse(timeout)
    timeout = timeout or 10
    local deadline = computer.uptime() + timeout
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, _, _, _, message = table.unpack(eventData)
            local success, data = pcall(serialization.unserialize, message)
            if success and data and data.type == "response" then
                return data
            end
        end
    end
    return {success = false, message = "Request timeout"}
end

-- Connect to relay
local function connectToRelay()
    clearScreen()
    drawHeader("◆ Empire Credit Union ◆", "Connecting to relay...")
    centerText(10, "Establishing secure connection...", colors.textDim)
    
    sendToRelay({type = "client_register"})
    
    local deadline = computer.uptime() + 5
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, _, _, _, message = table.unpack(eventData)
            local success, data = pcall(serialization.unserialize, message)
            if success and data and data.type == "relay_ack" then
                relayConnected = true
                showStatus("✓ Connected to relay", "success")
                os.sleep(1)
                return true
            end
        end
    end
    
    showStatus("✗ Could not connect to relay", "error")
    os.sleep(2)
    return false
end

-- Fetch credit score from server
local function fetchCreditScore()
    if not username then return end
    
    sendToRelay({
        command = "get_credit_score",
        username = username,
        password = password
    })
    
    local response = waitForResponse(5)
    if response and response.success then
        creditScore = response.score
        creditRating = response.rating
    end
end

-- Login screen
local function loginScreen()
    clearScreen()
    drawHeader("◆ Empire Credit Union ◆", "Please log in to continue")
    
    gpu.setForeground(colors.text)
    gpu.set(25, 8, "════════════════════════════")
    centerText(9, "LOGIN", colors.accent)
    gpu.set(25, 10, "════════════════════════════")
    
    local user = input("Username: ", 12, false, 20)
    if user == "" then return false end
    
    local pass = input("Password: ", 14, true, 30)
    if pass == "" then return false end
    
    showStatus("Authenticating...", "info")
    
    sendToRelay({
        command = "login",
        username = user,
        password = pass
    })
    
    local response = waitForResponse()
    
    if response.success then
        username = user
        password = pass
        balance = response.balance or 0
        isAdmin = response.isAdmin or false
        loggedIn = true
        
        -- Fetch credit score from loan server
        fetchCreditScore()
        
        showStatus("✓ Login successful", "success")
        os.sleep(1)
        return true
    else
        showStatus("✗ " .. (response.message or "Login failed"), "error")
        os.sleep(2)
        return false
    end
end

-- Main menu
local function mainMenu()
    clearScreen()
    local title = "◆ Empire Credit Union ◆"
    if isAdmin then
        title = "◆ ADMIN - Empire Credit Union ◆"
    end
    drawHeader(title, "User: " .. username)
    
    gpu.setForeground(colors.balance)
    local balText = string.format("Balance: %.2f CR", balance)
    centerText(5, balText)
    
    if creditScore then
        gpu.setForeground(colors.textDim)
        centerText(6, string.format("Credit: %d (%s)", creditScore, creditRating))
    end
    
    gpu.setForeground(colors.text)
    centerText(9, "═══ BANKING ═══")
    gpu.setForeground(colors.textDim)
    centerText(10, "1  Check Balance")
    centerText(11, "2  Transfer Funds")
    centerText(12, "3  View Accounts")
    
    gpu.setForeground(colors.text)
    centerText(14, "═══ LOANS ═══")
    gpu.setForeground(colors.textDim)
    centerText(15, "4  Check Eligibility")
    centerText(16, "5  Apply for Loan")
    centerText(17, "6  My Loans")
    centerText(18, "7  Make Payment")
    
    if isAdmin then
        gpu.setForeground(colors.adminRed)
        centerText(20, "═══ ADMIN ═══")
        gpu.setForeground(colors.textDim)
        centerText(21, "A  Admin Panel")
    end
    
    gpu.setForeground(colors.warning)
    centerText(23, "0  Logout")
    
    drawFooter("Empire Credit Union • Select an option")
    
    local _, _, char = event.pull("key_down")
    return char
end

-- Check balance
local function checkBalance()
    clearScreen()
    drawHeader("◆ Check Balance ◆")
    
    showStatus("Fetching balance...", "info")
    
    sendToRelay({
        command = "balance",
        username = username,
        password = password
    })
    
    local response = waitForResponse()
    
    if response.success then
        balance = response.balance
        
        gpu.setForeground(colors.success)
        local balText = string.format("%.2f CR", balance)
        local x = math.floor((w - #balText) / 2)
        gpu.setResolution(w, h)
        
        centerText(10, "Current Balance", colors.textDim)
        gpu.setForeground(colors.balance)
        gpu.setResolution(120, 40)
        centerText(12, balText)
        gpu.setResolution(w, h)
        
        showStatus("✓ Balance updated", "success")
    else
        showStatus("✗ " .. (response.message or "Failed to fetch balance"), "error")
    end
    
    drawFooter("Press any key to continue...")
    event.pull("key_down")
end

-- Transfer funds
local function transferFunds()
    clearScreen()
    drawHeader("◆ Transfer Funds ◆")
    
    gpu.setForeground(colors.textDim)
    centerText(8, string.format("Available: %.2f CR", balance))
    
    local recipient = input("Recipient: ", 11, false, 20)
    if recipient == "" then return end
    
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
    
    showStatus("Processing transfer...", "info")
    
    sendToRelay({
        command = "transfer",
        username = username,
        password = password,
        recipient = recipient,
        amount = amount
    })
    
    local response = waitForResponse()
    
    if response.success then
        balance = response.balance
        showStatus(string.format("✓ Transferred %.2f CR to %s", amount, recipient), "success")
    else
        showStatus("✗ " .. (response.message or "Transfer failed"), "error")
    end
    
    drawFooter("Press any key to continue...")
    event.pull("key_down")
end

-- View accounts
local function viewAccounts()
    clearScreen()
    drawHeader("◆ All Accounts ◆")
    
    showStatus("Fetching accounts...", "info")
    
    sendToRelay({
        command = "list_accounts",
        username = username,
        password = password
    })
    
    local response = waitForResponse()
    
    if response.success and response.accounts then
        gpu.setForeground(colors.text)
        gpu.set(15, 6, "Username")
        gpu.set(45, 6, "Status")
        
        gpu.setForeground(colors.textDim)
        local y = 8
        for i, acc in ipairs(response.accounts) do
            if i > 15 then break end
            gpu.set(15, y, acc.name)
            gpu.setForeground(acc.online and colors.success or colors.textDim)
            gpu.set(45, y, acc.online and "ONLINE" or "offline")
            gpu.setForeground(colors.textDim)
            y = y + 1
        end
        
        showStatus(string.format("Showing %d of %d accounts", math.min(15, #response.accounts), response.total or #response.accounts), "success")
    else
        showStatus("✗ Failed to fetch accounts", "error")
    end
    
    drawFooter("Press any key to continue...")
    event.pull("key_down")
end

-- Check loan eligibility
local function checkEligibility()
    clearScreen()
    drawHeader("◆ Loan Eligibility ◆")
    
    showStatus("Checking eligibility...", "info")
    
    sendToRelay({
        command = "get_loan_eligibility",
        username = username,
        password = password
    })
    
    local response = waitForResponse()
    
    if response.success then
        creditScore = response.creditScore
        creditRating = response.creditRating
        
        gpu.setForeground(colors.text)
        centerText(8, "Credit Score: " .. creditScore, colors.accent)
        centerText(9, "Rating: " .. creditRating, colors.textDim)
        
        if response.eligible then
            gpu.setForeground(colors.success)
            centerText(11, "✓ You are eligible for loans!")
            gpu.setForeground(colors.text)
            centerText(13, string.format("Maximum Loan: %.2f CR", response.maxLoan))
            centerText(14, string.format("Interest Rate: %.1f%%", response.interestRate * 100))
            centerText(15, string.format("Active Loans: %d", response.activeLoans))
        else
            gpu.setForeground(colors.error)
            centerText(11, "✗ Not eligible for loans")
            gpu.setForeground(colors.textDim)
            centerText(13, "Improve your credit score to qualify")
        end
        
        showStatus("Eligibility check complete", "success")
    else
        showStatus("✗ " .. (response.message or "Failed to check eligibility"), "error")
    end
    
    drawFooter("Press any key to continue...")
    event.pull("key_down")
end

-- Apply for loan
local function applyForLoan()
    clearScreen()
    drawHeader("◆ Apply for Loan ◆")
    
    local amountStr = input("Loan Amount (CR): ", 10, false, 10)
    local amount = tonumber(amountStr)
    
    if not amount or amount <= 0 then
        showStatus("✗ Invalid amount", "error")
        os.sleep(2)
        return
    end
    
    local termStr = input("Term (days): ", 12, false, 3)
    local term = tonumber(termStr)
    
    if not term or term <= 0 then
        showStatus("✗ Invalid term", "error")
        os.sleep(2)
        return
    end
    
    showStatus("Submitting application...", "info")
    
    sendToRelay({
        command = "apply_loan",
        username = username,
        password = password,
        amount = amount,
        term = term
    })
    
    local response = waitForResponse()
    
    if response.success then
        clearScreen()
        drawHeader("◆ Loan Application Submitted ◆")
        
        gpu.setForeground(colors.success)
        centerText(10, "✓ Application Submitted")
        
        gpu.setForeground(colors.text)
        centerText(12, "Application ID: " .. response.pendingId)
        centerText(13, string.format("Amount: %.2f CR", response.application.amount))
        centerText(14, string.format("Interest: %.2f CR", response.application.interest))
        centerText(15, string.format("Total Owed: %.2f CR", response.application.totalOwed))
        
        gpu.setForeground(colors.textDim)
        centerText(17, "Your application is pending admin approval")
        
        showStatus("Application submitted successfully", "success")
    else
        showStatus("✗ " .. (response.message or "Application failed"), "error")
    end
    
    drawFooter("Press any key to continue...")
    event.pull("key_down")
end

-- View my loans
local function viewMyLoans()
    clearScreen()
    drawHeader("◆ My Loans ◆")
    
    showStatus("Fetching loans...", "info")
    
    sendToRelay({
        command = "get_my_loans",
        username = username,
        password = password
    })
    
    local response = waitForResponse()
    
    if response.success then
        if #response.loans == 0 then
            gpu.setForeground(colors.textDim)
            centerText(12, "No active loans")
        else
            gpu.setForeground(colors.text)
            gpu.set(5, 6, "Loan ID")
            gpu.set(25, 6, "Principal")
            gpu.set(40, 6, "Remaining")
            gpu.set(60, 6, "Status")
            
            local y = 8
            for i, loan in ipairs(response.loans) do
                gpu.setForeground(colors.textDim)
                gpu.set(5, y, loan.loanId)
                gpu.set(25, y, string.format("%.2f CR", loan.principal))
                gpu.setForeground(loan.status == "active" and colors.warning or colors.success)
                gpu.set(40, y, string.format("%.2f CR", loan.remaining))
                gpu.set(60, y, loan.status:upper())
                y = y + 1
            end
        end
        
        showStatus(string.format("Showing %d loans", #response.loans), "success")
    else
        showStatus("✗ Failed to fetch loans", "error")
    end
    
    drawFooter("Press any key to continue...")
    event.pull("key_down")
end

-- Make loan payment
local function makePayment()
    clearScreen()
    drawHeader("◆ Make Loan Payment ◆")
    
    gpu.setForeground(colors.textDim)
    centerText(8, string.format("Available Balance: %.2f CR", balance))
    
    local loanId = input("Loan ID: ", 11, false, 20)
    if loanId == "" then return end
    
    local amountStr = input("Payment Amount: ", 13, false, 10)
    local amount = tonumber(amountStr)
    
    if not amount or amount <= 0 then
        showStatus("✗ Invalid amount", "error")
        os.sleep(2)
        return
    end
    
    showStatus("Processing payment...", "info")
    
    sendToRelay({
        command = "make_loan_payment",
        username = username,
        password = password,
        loanId = loanId,
        amount = amount
    })
    
    local response = waitForResponse()
    
    if response.success then
        balance = response.balance or balance
        showStatus(string.format("✓ Paid %.2f CR | Remaining: %.2f CR", response.paid, response.remaining), "success")
    else
        showStatus("✗ " .. (response.message or "Payment failed"), "error")
    end
    
    drawFooter("Press any key to continue...")
    event.pull("key_down")
end

-- ADMIN PANEL
local function adminPanel()
    while true do
        clearScreen()
        gpu.setBackground(colors.adminRed)
        gpu.fill(1, 1, w, 3, " ")
        gpu.setForeground(0xFFFFFF)
        centerText(2, "◆ ADMIN PANEL ◆")
        gpu.setBackground(colors.bg)
        
        gpu.setForeground(colors.text)
        centerText(7, "═══ CURRENCY ADMIN ═══")
        gpu.setForeground(colors.textDim)
        centerText(8, "1  Create Account")
        centerText(9, "2  Set Balance")
        centerText(10, "3  Lock Account")
        centerText(11, "4  Unlock Account")
        
        gpu.setForeground(colors.text)
        centerText(13, "═══ LOAN ADMIN ═══")
        gpu.setForeground(colors.textDim)
        centerText(14, "5  View Pending Loans")
        centerText(15, "6  Approve Loan")
        centerText(16, "7  Deny Loan")
        
        gpu.setForeground(colors.warning)
        centerText(19, "0  Back to Main Menu")
        
        gpu.setBackground(colors.adminRed)
        gpu.fill(1, h, w, 1, " ")
        gpu.setForeground(0xFFFFFF)
        gpu.set(2, h, "Admin Panel • " .. username)
        gpu.setBackground(colors.bg)
        
        local _, _, char = event.pull("key_down")
        
        if char == string.byte('0') then
            break
        elseif char == string.byte('1') then
            adminCreateAccount()
        elseif char == string.byte('2') then
            adminSetBalance()
        elseif char == string.byte('5') then
            adminViewPendingLoans()
        elseif char == string.byte('6') then
            adminApproveLoan()
        elseif char == string.byte('7') then
            adminDenyLoan()
        end
    end
end

local function adminCreateAccount()
    clearScreen()
    drawHeader("◆ ADMIN - Create Account ◆")
    
    local newUser = input("New Username: ", 10, false, 20)
    if newUser == "" then return end
    
    local newPass = input("New Password: ", 12, true, 30)
    if newPass == "" then return end
    
    local balStr = input("Initial Balance: ", 14, false, 10)
    local initBalance = tonumber(balStr) or 100
    
    showStatus("Creating account...", "info")
    
    sendToRelay({
        command = "admin_create_account",
        username = username,
        password = password,
        newUsername = newUser,
        newPassword = newPass,
        initialBalance = initBalance
    })
    
    local response = waitForResponse()
    
    if response.success then
        showStatus("✓ Account created: " .. newUser, "success")
    else
        showStatus("✗ " .. (response.message or "Failed to create account"), "error")
    end
    
    os.sleep(2)
end

local function adminSetBalance()
    clearScreen()
    drawHeader("◆ ADMIN - Set Balance ◆")
    
    local targetUser = input("Username: ", 10, false, 20)
    if targetUser == "" then return end
    
    local balStr = input("New Balance: ", 12, false, 10)
    local newBalance = tonumber(balStr)
    
    if not newBalance or newBalance < 0 then
        showStatus("✗ Invalid balance", "error")
        os.sleep(2)
        return
    end
    
    showStatus("Updating balance...", "info")
    
    sendToRelay({
        command = "admin_set_balance",
        username = username,
        password = password,
        targetUsername = targetUser,
        newBalance = newBalance
    })
    
    local response = waitForResponse()
    
    if response.success then
        showStatus("✓ Balance updated", "success")
    else
        showStatus("✗ " .. (response.message or "Failed to update balance"), "error")
    end
    
    os.sleep(2)
end

local function adminViewPendingLoans()
    clearScreen()
    drawHeader("◆ ADMIN - Pending Loans ◆")
    
    showStatus("Fetching pending loans...", "info")
    
    sendToRelay({
        command = "get_pending_loans",
        username = username,
        password = password
    })
    
    local response = waitForResponse()
    
    if response.success then
        if #response.pendingLoans == 0 then
            gpu.setForeground(colors.textDim)
            centerText(12, "No pending loan applications")
        else
            gpu.setForeground(colors.text)
            gpu.set(2, 6, "ID")
            gpu.set(18, 6, "User")
            gpu.set(32, 6, "Amount")
            gpu.set(45, 6, "Term")
            gpu.set(54, 6, "Rate")
            gpu.set(64, 6, "Credit")
            
            local y = 8
            for i, app in ipairs(response.pendingLoans) do
                if i > 15 then break end
                gpu.setForeground(colors.textDim)
                gpu.set(2, y, app.pendingId:sub(-6))
                gpu.set(18, y, app.username:sub(1, 12))
                gpu.setForeground(colors.success)
                gpu.set(32, y, string.format("%.0f CR", app.amount))
                gpu.setForeground(colors.textDim)
                gpu.set(45, y, app.termDays .. " days")
                gpu.set(54, y, string.format("%.1f%%", app.interestRate * 100))
                local scoreColor = app.creditScore >= 700 and colors.success or app.creditScore >= 650 and colors.warning or colors.error
                gpu.setForeground(scoreColor)
                gpu.set(64, y, tostring(app.creditScore))
                y = y + 1
            end
        end
        
        showStatus(string.format("Showing %d pending loans", #response.pendingLoans), "success")
    else
        showStatus("✗ Failed to fetch pending loans", "error")
    end
    
    drawFooter("Press any key to continue...")
    event.pull("key_down")
end

local function adminApproveLoan()
    clearScreen()
    drawHeader("◆ ADMIN - Approve Loan ◆")
    
    local pendingId = input("Pending ID (e.g. PENDING000001): ", 10, false, 30)
    if pendingId == "" then return end
    
    showStatus("Approving loan...", "info")
    
    sendToRelay({
        command = "approve_loan",
        username = username,
        password = password,
        pendingId = pendingId
    })
    
    local response = waitForResponse()
    
    if response.success then
        showStatus("✓ Loan approved: " .. (response.loanId or ""), "success")
    else
        showStatus("✗ " .. (response.message or "Failed to approve loan"), "error")
    end
    
    os.sleep(2)
end

local function adminDenyLoan()
    clearScreen()
    drawHeader("◆ ADMIN - Deny Loan ◆")
    
    local pendingId = input("Pending ID (e.g. PENDING000001): ", 10, false, 30)
    if pendingId == "" then return end
    
    local reason = input("Reason: ", 12, false, 40)
    
    showStatus("Denying loan...", "info")
    
    sendToRelay({
        command = "deny_loan",
        username = username,
        password = password,
        pendingId = pendingId,
        reason = reason
    })
    
    local response = waitForResponse()
    
    if response.success then
        showStatus("✓ Loan denied", "success")
    else
        showStatus("✗ " .. (response.message or "Failed to deny loan"), "error")
    end
    
    os.sleep(2)
end

-- Main program
local function main()
    if not connectToRelay() then
        return
    end
    
    if not loginScreen() then
        return
    end
    
    while loggedIn do
        local choice = mainMenu()
        
        if choice == string.byte('1') then
            checkBalance()
        elseif choice == string.byte('2') then
            transferFunds()
        elseif choice == string.byte('3') then
            viewAccounts()
        elseif choice == string.byte('4') then
            checkEligibility()
        elseif choice == string.byte('5') then
            applyForLoan()
        elseif choice == string.byte('6') then
            viewMyLoans()
        elseif choice == string.byte('7') then
            makePayment()
        elseif choice == string.byte('A') or choice == string.byte('a') then
            if isAdmin then
                adminPanel()
            end
        elseif choice == string.byte('0') then
            sendToRelay({
                command = "logout",
                username = username,
                password = password
            })
            loggedIn = false
        end
    end
    
    clearScreen()
    centerText(12, "Logged out. Goodbye!", colors.textDim)
    os.sleep(2)
end

main()
