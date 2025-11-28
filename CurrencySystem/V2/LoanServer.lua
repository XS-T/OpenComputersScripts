-- Loan Server for OpenComputers 1.7.10
-- WITH ADMIN PANEL for loan approval/denial
-- VERSION 1.4.0 - COMPLETE WITH ADMIN

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local computer = require("computer")
local thread = require("thread")
local gpu = component.gpu
local term = require("term")
local unicode = require("unicode")

local PORT = 1001
local CURRENCY_SERVER_PORT = 1000
local SERVER_NAME = "Empire Credit Union"  -- Must match relay for encryption
local DISPLAY_NAME = "Empire Credit Union - Loans"
local DATA_DIR = "/home/loans/"
local DEFAULT_ADMIN_PASSWORD = "LOANS2025"

local LOAN_CONFIG = {
    EXCELLENT = {min = 750, rate = 0.05},
    GOOD = {min = 700, rate = 0.08},
    FAIR = {min = 650, rate = 0.12},
    POOR = {min = 600, rate = 0.18},
    BAD = {min = 0, rate = 0.25},
    MAX_LOAN_EXCELLENT = 10000,
    MAX_LOAN_GOOD = 5000,
    MAX_LOAN_FAIR = 2000,
    MAX_LOAN_POOR = 500,
    MAX_LOAN_BAD = 0,
    MIN_LOAN_AMOUNT = 100,
    MAX_LOAN_TERM_DAYS = 30
}

if not component.isAvailable("modem") then
    print("ERROR: Wireless Network Card required!")
    return
end

if not component.isAvailable("data") then
    print("ERROR: Data Card required!")
    return
end

local modem = component.modem
local data = component.data

-- Encryption keys
local RELAY_ENCRYPTION_KEY = data.md5(SERVER_NAME .. "RelaySecure2024")
local INTER_SERVER_KEY = data.md5("CurrencyLoanServerComm2024")
local DATA_ENCRYPTION_KEY = data.md5(SERVER_NAME .. "LoanSecurity2024")

-- Relay encryption
local function encryptRelayMessage(plaintext)
    if not plaintext or plaintext == "" then return nil end
    local iv = data.random(16)
    local encrypted = data.encrypt(plaintext, RELAY_ENCRYPTION_KEY, iv)
    return data.encode64(iv .. encrypted)
end

local function decryptRelayMessage(ciphertext)
    if not ciphertext or ciphertext == "" then return nil end
    local success, result = pcall(function()
        local combined = data.decode64(ciphertext)
        local iv = combined:sub(1, 16)
        local encrypted = combined:sub(17)
        return data.decrypt(encrypted, RELAY_ENCRYPTION_KEY, iv)
    end)
    return success and result or nil
end

-- Inter-server encryption
local function encryptServerMessage(plaintext)
    if not plaintext or plaintext == "" then return nil end
    local iv = data.random(16)
    local encrypted = data.encrypt(plaintext, INTER_SERVER_KEY, iv)
    return data.encode64(iv .. encrypted)
end

local function decryptServerMessage(ciphertext)
    if not ciphertext or ciphertext == "" then return nil end
    local success, result = pcall(function()
        local combined = data.decode64(ciphertext)
        local iv = combined:sub(1, 16)
        local encrypted = combined:sub(17)
        return data.decrypt(encrypted, INTER_SERVER_KEY, iv)
    end)
    return success and result or nil
end

-- Data encryption
local function encryptData(plaintext)
    if not plaintext or plaintext == "" then return nil end
    local iv = data.random(16)
    local encrypted = data.encrypt(plaintext, DATA_ENCRYPTION_KEY, iv)
    return data.encode64(iv .. encrypted)
end

local function decryptData(ciphertext)
    if not ciphertext or ciphertext == "" then return nil end
    local success, result = pcall(function()
        local combined = data.decode64(ciphertext)
        local iv = combined:sub(1, 16)
        local encrypted = combined:sub(17)
        return data.decrypt(encrypted, DATA_ENCRYPTION_KEY, iv)
    end)
    return success and result or nil
end

local function hashPassword(password)
    if not password or password == "" then return nil end
    return data.md5(password)
end

-- State
local loans = {}
local loanIndex = {}
local pendingLoans = {}
local creditScores = {}
local nextLoanId = 1
local nextPendingId = 1
local currencyServerAddress = nil
local transactionLog = {}
local adminPasswordHash = nil
local adminMode = false
local adminAuthenticated = false

local stats = {
    totalLoans = 0,
    activeLoans = 0,
    pendingLoans = 0,
    activeThreads = 0,
    totalRequests = 0,
    currencyServerRequests = 0
}

local w, h = gpu.getResolution()
gpu.setResolution(80, 25)
w, h = 80, 25

local colors = {
    bg = 0x0F0F0F, header = 0x1E3A8A, accent = 0x3B82F6, success = 0x10B981,
    error = 0xEF4444, warning = 0xF59E0B, text = 0xFFFFFF, textDim = 0x9CA3AF,
    adminRed = 0xFF0000, adminBg = 0x1F1F1F
}

if not filesystem.exists(DATA_DIR) then
    filesystem.makeDirectory(DATA_DIR)
end

local function log(message, category)
    local txn = {time = os.date("%Y-%m-%d %H:%M:%S"), category = category or "INFO", message = message}
    table.insert(transactionLog, 1, txn)
    if #transactionLog > 100 then table.remove(transactionLog) end
    local file = io.open(DATA_DIR .. "loan_transactions.log", "a")
    if file then
        file:write(serialization.serialize(txn) .. "\n")
        file:close()
    end
end

-- Credit Score Functions
local function initializeCreditScore(username)
    creditScores[username] = {
        score = 650,
        history = {},
        lastUpdated = os.time(),
        totalPayments = 0,
        latePayments = 0,
        defaults = 0
    }
end

local function calculateCreditScore(username)
    local credit = creditScores[username]
    if not credit then
        initializeCreditScore(username)
        credit = creditScores[username]
    end
    
    local score = 650
    if credit.totalPayments > 0 then
        local onTimeRate = (credit.totalPayments - credit.latePayments) / credit.totalPayments
        score = score + (onTimeRate * 150) - 75
    end
    
    score = score - (credit.defaults * 100)
    
    local activeLoans = 0
    for _, loan in pairs(loanIndex) do
        if loan.username == username and loan.status == "active" then
            activeLoans = activeLoans + 1
        end
    end
    if activeLoans > 2 then
        score = score - (activeLoans - 2) * 20
    end
    
    score = math.max(300, math.min(850, score))
    credit.score = math.floor(score)
    credit.lastUpdated = os.time()
    return credit.score
end

local function getCreditRating(score)
    if score >= 750 then return "EXCELLENT"
    elseif score >= 700 then return "GOOD"
    elseif score >= 650 then return "FAIR"
    elseif score >= 600 then return "POOR"
    else return "BAD" end
end

local function recordCreditEvent(username, eventType, description)
    local credit = creditScores[username]
    if not credit then
        initializeCreditScore(username)
        credit = creditScores[username]
    end
    table.insert(credit.history, 1, {
        time = os.time(),
        type = eventType,
        description = description,
        scoreBefore = credit.score
    })
    if #credit.history > 50 then table.remove(credit.history) end
    calculateCreditScore(username)
    saveCreditScores()
end

-- Currency Server Communication
local function callCurrencyServer(command, requestData)
    if not currencyServerAddress then
        return {success = false, message = "Currency server not connected"}
    end
    
    stats.currencyServerRequests = stats.currencyServerRequests + 1
    
    requestData.type = "loan_server_request"
    requestData.command = command
    
    local message = serialization.serialize(requestData)
    local encrypted = encryptServerMessage(message)
    
    modem.send(currencyServerAddress, CURRENCY_SERVER_PORT, encrypted)
    
    local deadline = computer.uptime() + 5
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, sender, port, _, msg = table.unpack(eventData)
            if sender == currencyServerAddress and port == PORT then  -- Currency sends response on OUR port (1001)
                local decrypted = decryptServerMessage(msg)
                if decrypted then
                    local success, response = pcall(serialization.unserialize, decrypted)
                    if success and response and response.type == "loan_server_response" then
                        return response
                    end
                end
            end
        end
    end
    
    return {success = false, message = "Currency server timeout"}
end

-- Loan Functions
local function getLoanEligibility(username)
    local credit = creditScores[username]
    if not credit then
        initializeCreditScore(username)
        credit = creditScores[username]
    end
    
    local score = credit.score
    local rating = getCreditRating(score)
    local maxLoan, interestRate
    
    if score >= LOAN_CONFIG.EXCELLENT.min then
        maxLoan = LOAN_CONFIG.MAX_LOAN_EXCELLENT
        interestRate = LOAN_CONFIG.EXCELLENT.rate
    elseif score >= LOAN_CONFIG.GOOD.min then
        maxLoan = LOAN_CONFIG.MAX_LOAN_GOOD
        interestRate = LOAN_CONFIG.GOOD.rate
    elseif score >= LOAN_CONFIG.FAIR.min then
        maxLoan = LOAN_CONFIG.MAX_LOAN_FAIR
        interestRate = LOAN_CONFIG.FAIR.rate
    elseif score >= LOAN_CONFIG.POOR.min then
        maxLoan = LOAN_CONFIG.MAX_LOAN_POOR
        interestRate = LOAN_CONFIG.POOR.rate
    else
        maxLoan = LOAN_CONFIG.MAX_LOAN_BAD
        interestRate = LOAN_CONFIG.BAD.rate
    end
    
    local totalOwed = 0
    local activeLoans = 0
    for _, loan in pairs(loanIndex) do
        if loan.username == username and loan.status == "active" then
            totalOwed = totalOwed + loan.remaining
            activeLoans = activeLoans + 1
        end
    end
    
    maxLoan = math.max(0, maxLoan - totalOwed)
    
    return {
        eligible = maxLoan >= LOAN_CONFIG.MIN_LOAN_AMOUNT,
        maxLoan = maxLoan,
        interestRate = interestRate,
        creditScore = score,
        creditRating = rating,
        activeLoans = activeLoans,
        totalOwed = totalOwed
    }
end

local function submitLoanApplication(username, amount, termDays)
    if amount < LOAN_CONFIG.MIN_LOAN_AMOUNT then
        return false, "Minimum loan amount is " .. LOAN_CONFIG.MIN_LOAN_AMOUNT .. " CR"
    end
    if termDays < 1 or termDays > LOAN_CONFIG.MAX_LOAN_TERM_DAYS then
        return false, "Loan term must be 1-" .. LOAN_CONFIG.MAX_LOAN_TERM_DAYS .. " days"
    end
    
    local eligibility = getLoanEligibility(username)
    if not eligibility.eligible then
        return false, "Not eligible for loans"
    end
    if amount > eligibility.maxLoan then
        return false, "Maximum loan amount is " .. eligibility.maxLoan .. " CR"
    end
    
    local pendingId = "PENDING" .. string.format("%06d", nextPendingId)
    nextPendingId = nextPendingId + 1
    
    local interest = amount * eligibility.interestRate
    local totalOwed = amount + interest
    
    local application = {
        pendingId = pendingId,
        username = username,
        amount = amount,
        termDays = termDays,
        interestRate = eligibility.interestRate,
        interest = interest,
        totalOwed = totalOwed,
        creditScore = eligibility.creditScore,
        creditRating = eligibility.creditRating,
        appliedDate = os.time(),
        status = "pending"
    }
    
    pendingLoans[pendingId] = application
    stats.pendingLoans = stats.pendingLoans + 1
    
    log(string.format("Loan application: %s by %s for %.2f CR", pendingId, username, amount), "LOAN")
    savePendingLoans()
    
    return true, pendingId, application
end

local function approveLoanApplication(pendingId, adminUsername)
    local app = pendingLoans[pendingId]
    if not app then return false, "Application not found" end
    if app.status ~= "pending" then return false, "Already processed" end
    
    local verifyResult = callCurrencyServer("verify_account", {username = app.username})
    if not verifyResult.success or not verifyResult.exists then
        return false, "Account not found on currency server"
    end
    
    local loanId = "LOAN" .. string.format("%06d", nextLoanId)
    nextLoanId = nextLoanId + 1
    
    local loan = {
        loanId = loanId,
        username = app.username,
        principal = app.amount,
        interestRate = app.interestRate,
        interest = app.interest,
        totalOwed = app.totalOwed,
        remaining = app.totalOwed,
        termDays = app.termDays,
        issued = os.time(),
        dueDate = os.time() + (app.termDays * 86400),
        status = "active",
        payments = {},
        lateFees = 0,
        accountLocked = false,
        approvedBy = adminUsername,
        pendingId = pendingId
    }
    
    loanIndex[loanId] = loan
    if not loans[app.username] then loans[app.username] = {} end
    table.insert(loans[app.username], loanId)
    
    local addResult = callCurrencyServer("add_balance", {
        username = app.username,
        amount = app.amount
    })
    
    if not addResult.success then
        loanIndex[loanId] = nil
        if loans[app.username] then
            for i, id in ipairs(loans[app.username]) do
                if id == loanId then
                    table.remove(loans[app.username], i)
                    break
                end
            end
        end
        return false, "Failed to add funds: " .. (addResult.message or "Unknown error")
    end
    
    app.status = "approved"
    app.approvedDate = os.time()
    app.approvedBy = adminUsername
    app.loanId = loanId
    
    recordCreditEvent(app.username, "loan_issued", string.format("Loan %s approved: %d CR", loanId, app.amount))
    stats.totalLoans = stats.totalLoans + 1
    stats.activeLoans = stats.activeLoans + 1
    stats.pendingLoans = stats.pendingLoans - 1
    
    log(string.format("Loan APPROVED: %s → %s (%.2f CR)", pendingId, loanId, app.amount), "LOAN")
    
    saveLoans()
    savePendingLoans()
    saveConfig()
    
    return true, loanId, loan
end

local function denyLoanApplication(pendingId, adminUsername, reason)
    local app = pendingLoans[pendingId]
    if not app then return false, "Application not found" end
    if app.status ~= "pending" then return false, "Already processed" end
    
    app.status = "denied"
    app.deniedDate = os.time()
    app.deniedBy = adminUsername
    app.denyReason = reason or "Not specified"
    
    recordCreditEvent(app.username, "loan_denied", string.format("Application %s denied", pendingId))
    stats.pendingLoans = stats.pendingLoans - 1
    
    log(string.format("Loan DENIED: %s (User: %s)", pendingId, app.username), "LOAN")
    
    savePendingLoans()
    return true, "Application denied"
end

local function makeLoanPayment(username, loanId, amount)
    local loan = loanIndex[loanId]
    if not loan then return false, "Loan not found" end
    if loan.username ~= username then return false, "Not your loan" end
    if loan.status ~= "active" then return false, "Loan not active" end
    if amount <= 0 then return false, "Invalid amount" end
    
    local deductResult = callCurrencyServer("deduct_balance", {
        username = username,
        amount = amount
    })
    
    if not deductResult.success then
        return false, deductResult.message or "Payment failed"
    end
    
    local paymentAmount = math.min(amount, loan.remaining)
    loan.remaining = loan.remaining - paymentAmount
    
    table.insert(loan.payments, {
        time = os.time(),
        amount = paymentAmount,
        remainingAfter = loan.remaining
    })
    
    if loan.remaining <= 0.01 then
        loan.status = "paid"
        loan.paidDate = os.time()
        stats.activeLoans = stats.activeLoans - 1
        
        local onTime = os.time() <= loan.dueDate
        local credit = creditScores[username]
        if credit then
            credit.totalPayments = credit.totalPayments + 1
            if not onTime then credit.latePayments = credit.latePayments + 1 end
        end
        
        recordCreditEvent(username, onTime and "loan_paid" or "loan_paid_late", 
                         string.format("Loan %s paid in full", loanId))
        log(string.format("Loan paid: %s by %s (on-time: %s)", loanId, username, tostring(onTime)), "LOAN")
    else
        log(string.format("Payment: %s by %s: %.2f CR (remaining: %.2f)", loanId, username, paymentAmount, loan.remaining), "LOAN")
    end
    
    saveLoans()
    saveCreditScores()
    
    return true, paymentAmount, loan.remaining
end

local function getPendingLoans()
    local pending = {}
    for id, app in pairs(pendingLoans) do
        if app.status == "pending" then
            table.insert(pending, app)
        end
    end
    table.sort(pending, function(a, b) return a.appliedDate < b.appliedDate end)
    return pending
end

-- Save/Load Functions
function saveConfig()
    local config = {nextLoanId = nextLoanId, nextPendingId = nextPendingId, adminPasswordHash = adminPasswordHash}
    local file = io.open(DATA_DIR .. "loan_config.cfg", "w")
    if file then
        file:write(encryptData(serialization.serialize(config)))
        file:close()
        return true
    end
    return false
end

function loadConfig()
    local file = io.open(DATA_DIR .. "loan_config.cfg", "r")
    if file then
        local encrypted = file:read("*a")
        file:close()
        if encrypted and encrypted ~= "" then
            local plaintext = decryptData(encrypted)
            if plaintext then
                local success, config = pcall(serialization.unserialize, plaintext)
                if success and config then
                    nextLoanId = config.nextLoanId or 1
                    nextPendingId = config.nextPendingId or 1
                    adminPasswordHash = config.adminPasswordHash
                    return true
                end
            end
        end
    end
    adminPasswordHash = hashPassword(DEFAULT_ADMIN_PASSWORD)
    return saveConfig()
end

function saveLoans()
    local file = io.open(DATA_DIR .. "loans.dat", "w")
    if file then
        file:write(encryptData(serialization.serialize({loans = loans, loanIndex = loanIndex})))
        file:close()
        return true
    end
    return false
end

function loadLoans()
    local file = io.open(DATA_DIR .. "loans.dat", "r")
    if file then
        local encrypted = file:read("*a")
        file:close()
        if encrypted and encrypted ~= "" then
            local plaintext = decryptData(encrypted)
            if plaintext then
                local success, saveData = pcall(serialization.unserialize, plaintext)
                if success and saveData then
                    loans = saveData.loans or {}
                    loanIndex = saveData.loanIndex or {}
                    stats.activeLoans = 0
                    for _, loan in pairs(loanIndex) do
                        if loan.status == "active" then stats.activeLoans = stats.activeLoans + 1 end
                    end
                    stats.totalLoans = 0
                    for _ in pairs(loanIndex) do stats.totalLoans = stats.totalLoans + 1 end
                    return true
                end
            end
        end
    end
    return false
end

function savePendingLoans()
    local file = io.open(DATA_DIR .. "pending_loans.dat", "w")
    if file then
        file:write(encryptData(serialization.serialize({pendingLoans = pendingLoans})))
        file:close()
        return true
    end
    return false
end

function loadPendingLoans()
    local file = io.open(DATA_DIR .. "pending_loans.dat", "r")
    if file then
        local encrypted = file:read("*a")
        file:close()
        if encrypted and encrypted ~= "" then
            local plaintext = decryptData(encrypted)
            if plaintext then
                local success, saveData = pcall(serialization.unserialize, plaintext)
                if success and saveData then
                    pendingLoans = saveData.pendingLoans or {}
                    stats.pendingLoans = 0
                    for _, app in pairs(pendingLoans) do
                        if app.status == "pending" then stats.pendingLoans = stats.pendingLoans + 1 end
                    end
                    return true
                end
            end
        end
    end
    return false
end

function saveCreditScores()
    local file = io.open(DATA_DIR .. "credit_scores.dat", "w")
    if file then
        file:write(encryptData(serialization.serialize(creditScores)))
        file:close()
        return true
    end
    return false
end

function loadCreditScores()
    local file = io.open(DATA_DIR .. "credit_scores.dat", "r")
    if file then
        local encrypted = file:read("*a")
        file:close()
        if encrypted and encrypted ~= "" then
            local plaintext = decryptData(encrypted)
            if plaintext then
                local success, loadedScores = pcall(serialization.unserialize, plaintext)
                if success and loadedScores then
                    creditScores = loadedScores
                    return true
                end
            end
        end
    end
    return false
end

-- UI Functions
local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
end

local function input(prompt, y, hidden, maxLen)
    maxLen = maxLen or 30
    gpu.setForeground(colors.text)
    gpu.set(2, y, prompt)
    local x = 2 + unicode.len(prompt)
    gpu.setBackground(0x1F2937)
    gpu.fill(x, y, maxLen + 2, 1, " ")
    x = x + 1
    gpu.set(x, y, "")
    local text = ""
    while true do
        local _, _, char, code = event.pull("key_down")
        if code == 28 then break
        elseif code == 14 and unicode.len(text) > 0 then
            text = unicode.sub(text, 1, -2)
            gpu.setBackground(0x1F2937)
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

local function drawServerUI()
    local headerColor = adminMode and colors.adminRed or 0x000080
    local bgColor = adminMode and colors.adminBg or 0x0000AA
    
    gpu.setBackground(bgColor)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, w, h, " ")
    gpu.setBackground(headerColor)
    gpu.fill(1, 1, w, 3, " ")
    local title = adminMode and "=== ADMIN MODE - LOAN SERVER ===" or ("=== " .. DISPLAY_NAME .. " (Loan Server) ===")
    gpu.set(math.floor((w - #title) / 2), 2, title)
    
    gpu.setBackground(0x1E1E1E)
    gpu.setForeground(0x00FF00)
    gpu.fill(1, 4, w, 2, " ")
    gpu.set(2, 4, "Total Loans: " .. stats.totalLoans)
    gpu.set(20, 4, "Active: " .. stats.activeLoans)
    gpu.set(35, 4, "Pending: " .. stats.pendingLoans)
    gpu.set(52, 4, "Port: " .. PORT)
    gpu.set(65, 4, "Threads: " .. stats.activeThreads)
    
    gpu.setForeground(0xFFFF00)
    gpu.set(2, 5, "Mode: Loans Only")
    gpu.setForeground(0xAAAAAA)
    gpu.set(25, 5, "Requests: " .. stats.totalRequests)
    gpu.set(45, 5, "CServer Calls: " .. stats.currencyServerRequests)
    
    if currencyServerAddress then
        gpu.setForeground(0x00FF00)
        gpu.set(65, 5, "Currency: ✓")
    else
        gpu.setForeground(0xFF0000)
        gpu.set(65, 5, "Currency: ✗")
    end
    
    gpu.setBackground(0x2D2D2D)
    gpu.setForeground(0xFFFF00)
    gpu.fill(1, 7, w, 1, " ")
    gpu.set(2, 7, "Recent Loans:")
    
    gpu.setForeground(0xFFFFFF)
    gpu.set(2, 8, "Loan ID")
    gpu.set(18, 8, "User")
    gpu.set(35, 8, "Amount")
    gpu.set(50, 8, "Remaining")
    gpu.set(65, 8, "Status")
    
    local sortedLoans = {}
    for _, loan in pairs(loanIndex) do table.insert(sortedLoans, loan) end
    table.sort(sortedLoans, function(a, b) return a.issued > b.issued end)
    
    local y = 9
    for i = 1, math.min(10, #sortedLoans) do
        local loan = sortedLoans[i]
        gpu.setForeground(0xCCCCCC)
        gpu.set(2, y, loan.loanId)
        local name = loan.username
        if #name > 12 then name = name:sub(1, 10) .. ".." end
        gpu.set(18, y, name)
        gpu.setForeground(0x00FF00)
        gpu.set(35, y, string.format("%.2f", loan.principal))
        gpu.setForeground(loan.status == "active" and 0xFFFF00 or 0x00FF00)
        gpu.set(50, y, string.format("%.2f", loan.remaining))
        local statusColor = loan.status == "active" and 0xFFFF00 or loan.status == "paid" and 0x00FF00 or 0xFF0000
        gpu.setForeground(statusColor)
        gpu.set(65, y, loan.status:upper())
        y = y + 1
    end
    
    gpu.setBackground(0x1E1E1E)
    gpu.setForeground(0xFFFF00)
    gpu.fill(1, 20, w, 1, " ")
    gpu.set(2, 20, "Recent Activity:")
    
    gpu.setBackground(0x2D2D2D)
    y = 21
    for i = 1, math.min(4, #transactionLog) do
        local entry = transactionLog[i]
        local color = 0xAAAAAA
        if entry.category == "LOAN" then color = 0x00FFFF
        elseif entry.category == "ERROR" then color = 0xFF0000
        elseif entry.category == "SYSTEM" then color = 0x00FF00
        elseif entry.category == "ADMIN" then color = 0xFF0000 end
        gpu.setForeground(color)
        local msg = "[" .. entry.time:sub(12) .. "] " .. entry.message
        gpu.set(2, y, msg:sub(1, 76))
        y = y + 1
    end
    
    local footerColor = adminMode and colors.adminRed or 0x000080
    gpu.setBackground(footerColor)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 25, w, 1, " ")
    local footer = adminMode and "Press F1 or F5 to exit admin mode" or "Press F5 for admin panel | Loan Server"
    gpu.set(2, 25, footer)
end

-- Admin UI
local function adminLogin()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 3, " ")
    gpu.setForeground(0xFFFFFF)
    local title = "◆ ADMIN AUTHENTICATION ◆"
    gpu.set(math.floor((w - #title) / 2), 2, title)
    gpu.setBackground(colors.bg)
    
    gpu.setForeground(colors.warning)
    gpu.set(25, 10, "⚠ RESTRICTED ACCESS - LOAN SERVER")
    local password = input("Password: ", 12, true, 30)
    if hashPassword(password) == adminPasswordHash then
        adminAuthenticated = true
        adminMode = true
        gpu.setForeground(colors.success)
        gpu.set(30, 14, "✓ Authentication successful")
        log("Admin login successful", "ADMIN")
        os.sleep(1)
        return true
    else
        gpu.setForeground(colors.error)
        gpu.set(30, 14, "✗ Authentication failed")
        log("Admin login FAILED", "SECURITY")
        os.sleep(2)
        return false
    end
end

local function adminMainMenu()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 3, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(math.floor((w - 30) / 2), 2, "◆ LOAN SERVER ADMIN PANEL ◆")
    gpu.setBackground(colors.bg)
    
    gpu.setForeground(colors.text)
    gpu.set(25, 6, "LOAN MANAGEMENT")
    gpu.setForeground(colors.textDim)
    gpu.set(25, 8, "1  View Pending Applications")
    gpu.set(25, 9, "2  Approve Loan")
    gpu.set(25, 10, "3  Deny Loan")
    gpu.set(25, 11, "4  View All Loans")
    gpu.set(25, 12, "5  View Credit Scores")
    gpu.set(25, 13, "6  Change Admin Password")
    gpu.setForeground(colors.warning)
    gpu.set(25, 15, "0  Exit Admin Mode")
    
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, h, w, 1, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(2, h, "Loan Admin • Pending: " .. stats.pendingLoans .. " | Active: " .. stats.activeLoans)
    gpu.setBackground(colors.bg)
    
    local _, _, char = event.pull("key_down")
    return char
end

local function adminViewPending()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(25, 1, "◆ PENDING LOAN APPLICATIONS ◆")
    gpu.setBackground(colors.bg)
    
    local pending = getPendingLoans()
    
    if #pending == 0 then
        gpu.setForeground(colors.textDim)
        gpu.set(30, 10, "No pending applications")
        gpu.set(25, 12, "Press any key to continue...")
        event.pull("key_down")
        return
    end
    
    gpu.setForeground(colors.text)
    gpu.set(2, 4, "ID")
    gpu.set(18, 4, "User")
    gpu.set(32, 4, "Amount")
    gpu.set(45, 4, "Term")
    gpu.set(54, 4, "Rate")
    gpu.set(64, 4, "Credit")
    
    local y = 5
    for i = 1, math.min(18, #pending) do
        local app = pending[i]
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
    
    gpu.setForeground(colors.textDim)
    gpu.set(25, h-1, "Press any key to continue...")
    event.pull("key_down")
end

local function adminApproveLoan()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(30, 1, "◆ APPROVE LOAN ◆")
    gpu.setBackground(colors.bg)
    
    local pending = getPendingLoans()
    if #pending == 0 then
        gpu.setForeground(colors.error)
        gpu.set(25, 10, "No pending applications to approve")
        os.sleep(2)
        return
    end
    
    gpu.setForeground(colors.text)
    local y = 4
    for i = 1, math.min(10, #pending) do
        local app = pending[i]
        gpu.set(5, y, string.format("[%d] %s - %s - %.0f CR", i, app.pendingId:sub(-6), app.username, app.amount))
        y = y + 1
    end
    
    gpu.set(5, y + 2, "Enter number to approve (or 0 to cancel):")
    local choice = input("Choice: ", y + 3, false, 3)
    local num = tonumber(choice)
    
    if not num or num == 0 or num > #pending then
        return
    end
    
    local app = pending[num]
    gpu.setForeground(colors.warning)
    gpu.set(5, y + 5, "Approving: " .. app.username .. " for " .. app.amount .. " CR")
    gpu.set(5, y + 6, "Processing...")
    
    local ok, loanId, msg = approveLoanApplication(app.pendingId, "Admin")
    
    if ok then
        gpu.setForeground(colors.success)
        gpu.set(5, y + 7, "✓ Loan approved: " .. loanId)
    else
        gpu.setForeground(colors.error)
        gpu.set(5, y + 7, "✗ Error: " .. msg)
    end
    
    os.sleep(2)
    drawServerUI()
end

local function adminDenyLoan()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(32, 1, "◆ DENY LOAN ◆")
    gpu.setBackground(colors.bg)
    
    local pending = getPendingLoans()
    if #pending == 0 then
        gpu.setForeground(colors.error)
        gpu.set(25, 10, "No pending applications to deny")
        os.sleep(2)
        return
    end
    
    gpu.setForeground(colors.text)
    local y = 4
    for i = 1, math.min(10, #pending) do
        local app = pending[i]
        gpu.set(5, y, string.format("[%d] %s - %s - %.0f CR", i, app.pendingId:sub(-6), app.username, app.amount))
        y = y + 1
    end
    
    gpu.set(5, y + 2, "Enter number to deny (or 0 to cancel):")
    local choice = input("Choice: ", y + 3, false, 3)
    local num = tonumber(choice)
    
    if not num or num == 0 or num > #pending then
        return
    end
    
    local app = pending[num]
    local reason = input("Reason: ", y + 5, false, 40)
    
    gpu.setForeground(colors.warning)
    gpu.set(5, y + 7, "Denying application...")
    
    local ok, msg = denyLoanApplication(app.pendingId, "Admin", reason)
    
    if ok then
        gpu.setForeground(colors.success)
        gpu.set(5, y + 8, "✓ Application denied")
    else
        gpu.setForeground(colors.error)
        gpu.set(5, y + 8, "✗ Error: " .. msg)
    end
    
    os.sleep(2)
    drawServerUI()
end

-- Message handler with THREADING
local function handleMessage(eventType, _, sender, port, distance, message)
    if port ~= PORT and port ~= CURRENCY_SERVER_PORT then return end
    
    stats.totalRequests = stats.totalRequests + 1
    
    thread.create(function()
        stats.activeThreads = stats.activeThreads + 1
        
        local decryptedRelay = decryptRelayMessage(message)
        local decryptedServer = decryptServerMessage(message)
        
        local messageToProcess = decryptedRelay or decryptedServer or message
        local isFromRelay = (decryptedRelay ~= nil)
        local isFromServer = (decryptedServer ~= nil)
        
        local success, requestData = pcall(serialization.unserialize, messageToProcess)
        if not success or not requestData then
            stats.activeThreads = stats.activeThreads - 1
            return
        end
        
        -- Currency server discovery response (ENCRYPTED on PORT 1001)
        if requestData.type == "currency_server_response" and port == PORT and isFromServer then
            currencyServerAddress = sender
            log("Currency server connected: " .. sender:sub(1, 8), "SYSTEM")
            drawServerUI()
            stats.activeThreads = stats.activeThreads - 1
            return
        end
        
        -- Relay ping (ENCRYPTED)
        if requestData.type == "relay_ping" and isFromRelay then
            local response = {type = "server_response", serverName = DISPLAY_NAME}
            local encrypted = encryptRelayMessage(serialization.serialize(response))
            modem.send(sender, PORT, encrypted)
            stats.activeThreads = stats.activeThreads - 1
            return
        end
        
        -- Client loan requests (ENCRYPTED from relay)
        if isFromRelay then
            local response = {type = "response"}
            local requestUsername = requestData.username
            
            if requestData.command == "get_credit_score" then
                local credit = creditScores[requestData.username]
                if not credit then initializeCreditScore(requestData.username); credit = creditScores[requestData.username] end
                calculateCreditScore(requestData.username)
                response.success = true
                response.score = credit.score
                response.rating = getCreditRating(credit.score)
                response.history = credit.history or {}
                
            elseif requestData.command == "get_loan_eligibility" then
                local eligibility = getLoanEligibility(requestData.username)
                response.success, response.eligible, response.maxLoan = true, eligibility.eligible, eligibility.maxLoan
                response.interestRate, response.creditScore = eligibility.interestRate, eligibility.creditScore
                response.creditRating, response.activeLoans, response.totalOwed = eligibility.creditRating, eligibility.activeLoans, eligibility.totalOwed
                
            elseif requestData.command == "apply_loan" then
                local ok, pendingIdOrMsg, application = submitLoanApplication(requestData.username, requestData.amount, requestData.term)
                response.success = ok
                if ok then
                    response.pendingId = pendingIdOrMsg
                    response.message = "Loan application submitted"
                    response.application = {
                        pendingId = pendingIdOrMsg,
                        amount = application.amount,
                        interest = application.interest,
                        totalOwed = application.totalOwed,
                        termDays = application.termDays,
                        status = "pending"
                    }
                else
                    response.message = pendingIdOrMsg
                end
                
            elseif requestData.command == "get_my_loans" then
                local userLoanIds = loans[requestData.username] or {}
                local loanList = {}
                for _, loanId in ipairs(userLoanIds) do
                    local loan = loanIndex[loanId]
                    if loan then
                        table.insert(loanList, {
                            loanId = loan.loanId,
                            principal = loan.principal,
                            remaining = loan.remaining,
                            dueDate = loan.dueDate,
                            status = loan.status
                        })
                    end
                end
                response.success = true
                response.loans = loanList
                
            elseif requestData.command == "make_loan_payment" then
                local ok, paidOrMsg, remaining = makeLoanPayment(requestData.username, requestData.loanId, requestData.amount)
                response.success = ok
                if ok then
                    response.paid = paidOrMsg
                    response.remaining = remaining
                    local balResult = callCurrencyServer("get_balance", {username = requestData.username})
                    if balResult.success then response.balance = balResult.balance end
                else
                    response.message = paidOrMsg
                end
                
            elseif requestData.command == "get_pending_loans" then
                response.success = true
                response.pendingLoans = getPendingLoans()
                
            elseif requestData.command == "approve_loan" then
                local ok, loanIdOrMsg = approveLoanApplication(requestData.pendingId, requestData.username or "Admin")
                response.success, response.message = ok, ok and "Loan approved" or loanIdOrMsg
                if ok then response.loanId = loanIdOrMsg end
                
            elseif requestData.command == "deny_loan" then
                local ok, msg = denyLoanApplication(requestData.pendingId, requestData.username or "Admin", requestData.reason)
                response.success, response.message = ok, msg
            end
            
            if requestUsername and not response.username then response.username = requestUsername end
            
            local encrypted = encryptRelayMessage(serialization.serialize(response))
            modem.send(sender, PORT, encrypted)
        end
        
        if not adminMode then drawServerUI() end
        stats.activeThreads = stats.activeThreads - 1
    end):detach()
end

-- Key press handler
local function handleKeyPress(eventType, _, _, code)
    if code == 63 or code == 59 then  -- F5 or F1
        if adminMode then
            adminMode = false
            adminAuthenticated = false
            drawServerUI()
            log("Admin mode exited", "ADMIN")
        else
            if adminLogin() then
                while adminMode do
                    local choice = adminMainMenu()
                    if choice == string.byte('1') then
                        adminViewPending()
                    elseif choice == string.byte('2') then
                        adminApproveLoan()
                    elseif choice == string.byte('3') then
                        adminDenyLoan()
                    elseif choice == string.byte('0') then
                        adminMode = false
                        adminAuthenticated = false
                        log("Admin mode exited", "ADMIN")
                    end
                end
                drawServerUI()
            end
        end
    end
end

-- Find currency server
local function findCurrencyServer()
    log("Searching for currency server...", "SYSTEM")
    local ping = encryptServerMessage(serialization.serialize({type = "loan_server_ping", serverName = DISPLAY_NAME}))
    modem.broadcast(CURRENCY_SERVER_PORT, ping)
    os.sleep(2)
end

local function main()
    print("Starting Loan Server...")
    loadConfig(); loadLoans(); loadPendingLoans(); loadCreditScores()
    print("Loaded - Loans: " .. stats.totalLoans .. ", Pending: " .. stats.pendingLoans)
    
    modem.open(PORT)
    modem.open(CURRENCY_SERVER_PORT)
    modem.setStrength(400)
    
    event.listen("modem_message", handleMessage)
    event.listen("key_down", handleKeyPress)
    
    print("Searching for currency server...")
    findCurrencyServer()
    
    drawServerUI()
    log("Loan Server started", "SYSTEM")
    print("Server running! Press F5 for admin panel")
    
    event.timer(30, function()
        if not currencyServerAddress then findCurrencyServer() end
        if not adminMode then drawServerUI() end
    end, math.huge)
    
    event.timer(5, function()
        if not adminMode then drawServerUI() end
    end, math.huge)
    
    while true do os.sleep(1) end
end

pcall(main)
modem.close(PORT)
modem.close(CURRENCY_SERVER_PORT)
print("Loan Server stopped")
