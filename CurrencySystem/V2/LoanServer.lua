-- Loan Server (Loans & Credit Only) for OpenComputers 1.7.10
-- Modular Architecture - Credit Scores, Loans, Applications
-- PORT 1001 | Communicates with Currency Server
-- VERSION 1.0.0

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local computer = require("computer")
local thread = require("thread")
local gpu = component.gpu
local term = require("term")
local unicode = require("unicode")

-- Configuration
local PORT = 1001
local CURRENCY_SERVER_PORT = 1000
local SERVER_NAME = "Empire Credit Union - Loans"
local DATA_DIR = "/home/loans/"
local CONFIG_FILE = DATA_DIR .. "loan_config.cfg"
local LOAN_FILE = DATA_DIR .. "loans.dat"
local PENDING_LOANS_FILE = DATA_DIR .. "pending_loans.dat"
local CREDIT_FILE = DATA_DIR .. "credit_scores.dat"

-- Loan Configuration
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
    MAX_LOAN_TERM_DAYS = 30,
    LATE_FEE_RATE = 0.10,
    DEFAULT_PENALTY = 100,
    DAYS_UNTIL_LOCK = 7,
    DAYS_UNTIL_DEFAULT = 30,
    AUTO_LOCK_ENABLED = true
}

if not component.isAvailable("modem") then
    print("ERROR: Wireless Network Card required!")
    return
end

if not component.isAvailable("data") then
    print("ERROR: Data Card (Tier 2+) required!")
    return
end

local modem = component.modem
local data = component.data

-- Encryption
local RELAY_ENCRYPTION_KEY = data.md5(SERVER_NAME .. "RelaySecure2024")
local DATA_ENCRYPTION_KEY = data.md5(SERVER_NAME .. "LoanSecurity2024")

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

-- State
local loans = {}
local loanIndex = {}
local pendingLoans = {}
local creditScores = {}
local nextLoanId = 1
local nextPendingId = 1
local currencyServerAddress = nil
local transactionLog = {}

local stats = {
    totalLoans = 0,
    activeLoans = 0,
    pendingLoans = 0,
    totalInterestEarned = 0,
    activeThreads = 0,
    totalRequests = 0
}

local adminMode = false
local w, h = 80, 25
gpu.setResolution(w, h)

local colors = {
    bg = 0x0F0F0F, header = 0x1E3A8A, accent = 0x3B82F6, success = 0x10B981,
    error = 0xEF4444, warning = 0xF59E0B, text = 0xFFFFFF, textDim = 0x9CA3AF,
    excellent = 0x10B981, good = 0x3B82F6, fair = 0xF59E0B, poor = 0xEF4444
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
    
    score = score - (credit.defaults * LOAN_CONFIG.DEFAULT_PENALTY)
    
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
local function callCurrencyServer(command, data)
    if not currencyServerAddress then
        return {success = false, message = "Currency server not connected"}
    end
    
    data.type = "loan_server_request"
    data.command = command
    
    local message = serialization.serialize(data)
    modem.send(currencyServerAddress, CURRENCY_SERVER_PORT, message)
    
    -- Wait for response
    local deadline = computer.uptime() + 5
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, sender, port, _, msg = table.unpack(eventData)
            if sender == currencyServerAddress and port == CURRENCY_SERVER_PORT then
                local success, response = pcall(serialization.unserialize, msg)
                if success and response and response.type == "loan_server_response" then
                    return response
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
    
    -- Verify account exists on currency server
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
    
    -- Add funds to account via currency server
    local addResult = callCurrencyServer("add_balance", {
        username = app.username,
        amount = app.amount
    })
    
    if not addResult.success then
        -- Rollback
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
    
    log(string.format("Loan DENIED: %s (User: %s, Amount: %.2f)", pendingId, app.username, app.amount), "LOAN")
    
    savePendingLoans()
    return true, "Application denied"
end

local function makeLoanPayment(username, loanId, amount)
    local loan = loanIndex[loanId]
    if not loan then return false, "Loan not found" end
    if loan.username ~= username then return false, "Not your loan" end
    if loan.status ~= "active" then return false, "Loan not active" end
    if amount <= 0 then return false, "Invalid amount" end
    
    -- Verify balance and deduct via currency server
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
    local config = {nextLoanId = nextLoanId, nextPendingId = nextPendingId, lastModified = os.time()}
    local file = io.open(CONFIG_FILE, "w")
    if file then
        local encrypted = encryptData(serialization.serialize(config))
        if encrypted then file:write(encrypted) end
        file:close()
        return true
    end
    return false
end

function loadConfig()
    local file = io.open(CONFIG_FILE, "r")
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
                    return true
                end
            end
        end
    end
    return false
end

function saveLoans()
    local data = {loans = loans, loanIndex = loanIndex}
    local file = io.open(LOAN_FILE, "w")
    if file then
        local encrypted = encryptData(serialization.serialize(data))
        if encrypted then file:write(encrypted) end
        file:close()
        return true
    end
    return false
end

function loadLoans()
    local file = io.open(LOAN_FILE, "r")
    if file then
        local encrypted = file:read("*a")
        file:close()
        if encrypted and encrypted ~= "" then
            local plaintext = decryptData(encrypted)
            if plaintext then
                local success, data = pcall(serialization.unserialize, plaintext)
                if success and data then
                    loans = data.loans or {}
                    loanIndex = data.loanIndex or {}
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
    local data = {pendingLoans = pendingLoans, nextPendingId = nextPendingId}
    local file = io.open(PENDING_LOANS_FILE, "w")
    if file then
        local encrypted = encryptData(serialization.serialize(data))
        if encrypted then file:write(encrypted) end
        file:close()
        return true
    end
    return false
end

function loadPendingLoans()
    local file = io.open(PENDING_LOANS_FILE, "r")
    if file then
        local encrypted = file:read("*a")
        file:close()
        if encrypted and encrypted ~= "" then
            local plaintext = decryptData(encrypted)
            if plaintext then
                local success, data = pcall(serialization.unserialize, plaintext)
                if success and data then
                    pendingLoans = data.pendingLoans or {}
                    nextPendingId = data.nextPendingId or 1
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
    local file = io.open(CREDIT_FILE, "w")
    if file then
        local encrypted = encryptData(serialization.serialize(creditScores))
        if encrypted then file:write(encrypted) end
        file:close()
        return true
    end
    return false
end

function loadCreditScores()
    local file = io.open(CREDIT_FILE, "r")
    if file then
        local encrypted = file:read("*a")
        file:close()
        if encrypted and encrypted ~= "" then
            local plaintext = decryptData(encrypted)
            if plaintext then
                local success, data = pcall(serialization.unserialize, plaintext)
                if success and data then
                    creditScores = data
                    return true
                end
            end
        end
    end
    return false
end

-- UI Functions (simplified)
local function drawServerUI()
    term.clear()
    print("═══════════════════════════════════════════════════════")
    print("Loan Server - " .. SERVER_NAME)
    print("═══════════════════════════════════════════════════════")
    print("")
    print("Port: " .. PORT)
    print("Total Loans: " .. stats.totalLoans)
    print("Active Loans: " .. stats.activeLoans)
    print("Pending Applications: " .. stats.pendingLoans)
    print("Active Threads: " .. stats.activeThreads)
    print("")
    if currencyServerAddress then
        print("Currency Server: ✓ Connected (" .. currencyServerAddress:sub(1, 8) .. ")")
    else
        print("Currency Server: ✗ Searching...")
    end
    print("")
    print("Recent Activity:")
    for i = 1, math.min(5, #transactionLog) do
        print("  " .. transactionLog[i].time:sub(12) .. " " .. transactionLog[i].message:sub(1, 60))
    end
    print("")
    print("Press F5 for admin panel | Loan Server Running")
end

-- Network message handler
local function handleMessage(eventType, _, sender, port, distance, message)
    if port ~= PORT and port ~= CURRENCY_SERVER_PORT then return end
    
    stats.totalRequests = stats.totalRequests + 1
    
    thread.create(function()
        stats.activeThreads = stats.activeThreads + 1
        
        local decryptedMessage = decryptRelayMessage(message)
        local isEncrypted = (decryptedMessage ~= nil)
        local messageToProcess = decryptedMessage or message
        
        local success, data = pcall(serialization.unserialize, messageToProcess)
        if not success or not data then
            stats.activeThreads = stats.activeThreads - 1
            return
        end
        
        -- Handle currency server discovery
        if data.type == "currency_server_response" and port == CURRENCY_SERVER_PORT then
            currencyServerAddress = sender
            log("Currency server connected: " .. sender:sub(1, 8), "SYSTEM")
            drawServerUI()
            stats.activeThreads = stats.activeThreads - 1
            return
        end
        
        -- Handle relay ping
        if data.type == "relay_ping" then
            local response = {type = "server_response", serverName = SERVER_NAME}
            local serializedResponse = serialization.serialize(response)
            local responseToSend = isEncrypted and encryptRelayMessage(serializedResponse) or serializedResponse
            modem.send(sender, PORT, responseToSend)
            stats.activeThreads = stats.activeThreads - 1
            return
        end
        
        -- Handle loan requests
        local response = {type = "response"}
        local requestUsername = data.username
        
        if data.command == "get_credit_score" then
            local credit = creditScores[data.username]
            if not credit then
                initializeCreditScore(data.username)
                credit = creditScores[data.username]
            end
            calculateCreditScore(data.username)
            response.success = true
            response.score = credit.score
            response.rating = getCreditRating(credit.score)
            response.history = credit.history or {}
            
        elseif data.command == "get_loan_eligibility" then
            local eligibility = getLoanEligibility(data.username)
            response.success = true
            response.eligible = eligibility.eligible
            response.maxLoan = eligibility.maxLoan
            response.interestRate = eligibility.interestRate
            response.creditScore = eligibility.creditScore
            response.creditRating = eligibility.creditRating
            response.activeLoans = eligibility.activeLoans
            response.totalOwed = eligibility.totalOwed
            
        elseif data.command == "apply_loan" then
            local ok, pendingIdOrMsg, application = submitLoanApplication(data.username, data.amount, data.term)
            response.success = ok
            if ok then
                response.pendingId = pendingIdOrMsg
                response.message = "Loan application submitted. Awaiting admin approval."
                response.application = {
                    pendingId = pendingIdOrMsg,
                    amount = application.amount,
                    interest = application.interest,
                    totalOwed = application.totalOwed,
                    termDays = application.termDays,
                    status = "pending",
                    creditScore = application.creditScore,
                    creditRating = application.creditRating
                }
            else
                response.message = pendingIdOrMsg
            end
            
        elseif data.command == "get_my_loans" then
            local userLoanIds = loans[data.username] or {}
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
            
        elseif data.command == "make_loan_payment" then
            local ok, paidOrMsg, remaining = makeLoanPayment(data.username, data.loanId, data.amount)
            response.success = ok
            if ok then
                response.paid = paidOrMsg
                response.remaining = remaining
                -- Get new balance from currency server
                local balResult = callCurrencyServer("get_balance", {username = data.username})
                if balResult.success then
                    response.balance = balResult.balance
                end
            else
                response.message = paidOrMsg
            end
            
        elseif data.command == "get_pending_loans" then
            response.success = true
            response.pendingLoans = getPendingLoans()
            
        elseif data.command == "approve_loan" then
            local ok, loanIdOrMsg = approveLoanApplication(data.pendingId, data.username or "Admin")
            response.success = ok
            if ok then
                response.loanId = loanIdOrMsg
                response.message = "Loan approved"
            else
                response.message = loanIdOrMsg
            end
            
        elseif data.command == "deny_loan" then
            local ok, msg = denyLoanApplication(data.pendingId, data.username or "Admin", data.reason)
            response.success = ok
            response.message = msg
        end
        
        -- Add username for routing
        if requestUsername and not response.username then
            response.username = requestUsername
        end
        
        local serializedResponse = serialization.serialize(response)
        local responseToSend = isEncrypted and encryptRelayMessage(serializedResponse) or serializedResponse
        modem.send(sender, PORT, responseToSend)
        
        drawServerUI()
        stats.activeThreads = stats.activeThreads - 1
    end):detach()
end

-- Find currency server
local function findCurrencyServer()
    log("Searching for currency server...", "SYSTEM")
    local ping = serialization.serialize({type = "loan_server_ping"})
    modem.broadcast(CURRENCY_SERVER_PORT, ping)
    os.sleep(2)
end

-- Main
local function main()
    print("Starting Loan Server...")
    print("Port: " .. PORT)
    
    loadConfig()
    loadLoans()
    loadPendingLoans()
    loadCreditScores()
    
    print("Loaded:")
    print("  Loans: " .. stats.totalLoans)
    print("  Pending: " .. stats.pendingLoans)
    print("  Credit Scores: " .. (function() local c=0 for _ in pairs(creditScores) do c=c+1 end return c end)())
    
    modem.open(PORT)
    modem.open(CURRENCY_SERVER_PORT)
    modem.setStrength(400)
    
    event.listen("modem_message", handleMessage)
    
    findCurrencyServer()
    drawServerUI()
    
    log("Loan Server started", "SYSTEM")
    print("Server running!")
    
    -- Periodic currency server ping
    event.timer(30, function()
        if not currencyServerAddress then
            findCurrencyServer()
        end
    end, math.huge)
    
    while true do os.sleep(1) end
end

local success, err = pcall(main)
if not success then
    print("Error: " .. tostring(err))
end

modem.close(PORT)
modem.close(CURRENCY_SERVER_PORT)
print("Loan Server stopped")
