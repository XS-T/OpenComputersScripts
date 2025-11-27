-- Digital Currency Client with Loans - COMPLETE
-- OpenComputers 1.7.10

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local term = require("term")
local unicode = require("unicode")
local computer = require("computer")

local tunnel = component.tunnel
local gpu = component.gpu

local SERVER_PORT = 1000
local username = nil
local password = nil
local balance = 0
local loggedIn = false
local creditScore = 650
local creditRating = "FAIR"

local w, h = gpu.getResolution()
gpu.setResolution(80, 25)
w, h = 80, 25

local colors = {
    bg = 0x0F0F0F, header = 0x1E3A8A, accent = 0x3B82F6,
    success = 0x10B981, error = 0xEF4444, warning = 0xF59E0B,
    text = 0xFFFFFF, textDim = 0x9CA3AF, border = 0x374151,
    inputBg = 0x1F2937, excellent = 0x10B981, good = 0x3B82F6,
    fair = 0xF59E0B, poor = 0xEF4444
}

local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    term.clear()
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

local function drawBox(x, y, width, height, color)
    gpu.setBackground(color or colors.bg)
    gpu.fill(x, y, width, height, " ")
end

local function centerText(y, text, fg)
    local x = math.floor((w - unicode.len(text)) / 2)
    gpu.setForeground(fg or colors.text)
    gpu.set(x, y, text)
end

local function sendCommand(command, data)
    data.command = command
    tunnel.send(serialization.serialize(data))
    local timeoutTimer = event.timer(5, function() end)
    while true do
        local eventData = {event.pull(5, "modem_message")}
        if eventData[1] == "modem_message" then
            local message = eventData[6]
            local success, response = pcall(serialization.unserialize, message)
            if success and response and response.type == "response" then
                event.cancel(timeoutTimer)
                return response
            end
        elseif eventData[1] == nil then
            event.cancel(timeoutTimer)
            return nil
        end
    end
end

local function loginScreen()
    clearScreen()
    drawHeader("◆ DIGITAL BANKING ◆", "Secure Login")
    drawBox(15, 7, 50, 10, colors.bg)
    gpu.setForeground(colors.accent)
    centerText(8, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    local user = input("Username: ", 10, false, 25)
    if not user or user == "" then return false end
    local pass = input("Password: ", 12, true, 25)
    if not pass or pass == "" then return false end
    showStatus("⟳ Connecting to server...", "info")
    local response = sendCommand("login", {username = user, password = pass})
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

local function updateBalance()
    local response = sendCommand("balance", {username = username, password = password})
    if response and response.success then
        balance = response.balance
        return true
    else
        showStatus("✗ Failed to update balance", "error")
        return false
    end
end

local function viewBalance()
    clearScreen()
    drawHeader("◆ ACCOUNT BALANCE ◆", username)
    if updateBalance() then
        drawBox(20, 8, 40, 6, colors.bg)
        gpu.setForeground(colors.textDim)
        centerText(9, "Current Balance")
        gpu.setForeground(colors.success)
        local balStr = string.format("%.2f CR", balance)
        gpu.setResolution(80, 25)
        centerText(11, balStr)
        gpu.setForeground(colors.textDim)
        centerText(13, "Credit Score: " .. creditScore .. " (" .. creditRating .. ")")
    end
    centerText(16, "Press Enter to continue")
    drawFooter("Balance Inquiry")
    io.read()
end

local function transferFunds()
    clearScreen()
    drawHeader("◆ TRANSFER FUNDS ◆", username)
    drawBox(15, 7, 50, 12, colors.bg)
    gpu.setForeground(colors.text)
    gpu.set(17, 8, "Current Balance: " .. string.format("%.2f CR", balance))
    local recipient = input("Recipient:  ", 10, false, 25)
    if not recipient or recipient == "" then return end
    local amountStr = input("Amount:     ", 12, false, 15)
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
    showStatus("⟳ Processing transfer...", "info")
    local response = sendCommand("transfer", {username = username, password = password, recipient = recipient, amount = amount})
    if response and response.success then
        balance = response.balance
        showStatus("✓ Transfer successful!", "success")
        os.sleep(2)
    else
        showStatus("✗ " .. (response and response.message or "Transfer failed"), "error")
        os.sleep(2)
    end
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
    local response = sendCommand("get_credit_score", {username = username, password = password})
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
    local response = sendCommand("get_loan_eligibility", {username = username, password = password})
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
    local eligResponse = sendCommand("get_loan_eligibility", {username = username, password = password})
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
    local response = sendCommand("apply_loan", {username = username, password = password, amount = amount, term = term})
    if response and response.success then
        balance = response.balance
        showStatus("✓ Loan approved! ID: " .. response.loanId, "success")
        os.sleep(3)
    else
        showStatus("✗ " .. (response and response.message or "Application failed"), "error")
        os.sleep(2)
    end
end

local function viewMyLoans()
    clearScreen()
    drawHeader("◆ MY LOANS ◆", username)
    showStatus("⟳ Loading loans...", "info")
    local response = sendCommand("get_my_loans", {username = username, password = password})
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
    local loansResponse = sendCommand("get_my_loans", {username = username, password = password})
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
    local response = sendCommand("make_loan_payment", {username = username, password = password, loanId = loanId, amount = amount})
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

local function mainMenu()
    while loggedIn do
        clearScreen()
        drawHeader("◆ MAIN MENU ◆", username)
        drawBox(20, 7, 40, 13, colors.bg)
        gpu.setForeground(colors.text)
        centerText(8, "Balance: " .. string.format("%.2f CR", balance))
        gpu.setForeground(colors.accent)
        centerText(10, "1  View Balance")
        centerText(11, "2  Transfer Funds")
        centerText(12, "3  Loan Center")
        centerText(14, "0  Logout")
        drawFooter("Main Menu - Select option")
        local _, _, char = event.pull("key_down")
        if char == string.byte('1') then viewBalance()
        elseif char == string.byte('2') then transferFunds()
        elseif char == string.byte('3') then loanMenu()
        elseif char == string.byte('0') then
            local response = sendCommand("logout", {username = username, password = password})
            loggedIn = false
            username = nil
            password = nil
            showStatus("✓ Logged out", "success")
            os.sleep(1)
            break
        end
    end
end

local function main()
    clearScreen()
    while true do
        if loginScreen() then
            mainMenu()
        end
    end
end

main()
