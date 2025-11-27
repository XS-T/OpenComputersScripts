-- Digital Currency Server with Admin Panel + Loans & Credit for OpenComputers 1.7.10
-- Complete working version with all features

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local computer = require("computer")
local gpu = component.gpu
local term = require("term")
local unicode = require("unicode")

-- Configuration
local PORT = 1000
local SERVER_NAME = "CreditBank"
local DATA_DIR = "/home/currency/"
local CONFIG_FILE = DATA_DIR .. "admin.cfg"
local LOAN_FILE = DATA_DIR .. "loans.dat"
local PENDING_LOANS_FILE = DATA_DIR .. "pending_loans.dat"
local CREDIT_FILE = DATA_DIR .. "credit_scores.dat"
local DEFAULT_ADMIN_PASSWORD = "ECU2025"

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
    PAYMENT_BOOST = 5,
    DAYS_UNTIL_LOCK = 7,
    DAYS_UNTIL_DEFAULT = 30,
    AUTO_LOCK_ENABLED = true
}

local modem = component.modem
local accounts = {}
local transactionLog = {}
local accountIndex = {}
local relays = {}
local activeSessions = {}
local loans = {}
local loanIndex = {}
local nextLoanId = 1
local pendingLoans = {}  -- Loans waiting for admin approval
local nextPendingId = 1
local creditScores = {}
local stats = {
    totalAccounts = 0,
    totalTransactions = 0,
    activeSessions = 0,
    relayCount = 0,
    totalLoans = 0,
    activeLoans = 0,
    totalInterestEarned = 0
}

local adminMode = false
local adminAuthenticated = false
local selectedAccount = nil
local adminPasswordHash = nil

local w, h = gpu.getResolution()
gpu.setResolution(80, 25)
w, h = 80, 25

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
    adminRed = 0xFF0000,
    adminBg = 0x1F1F1F,
    excellent = 0x10B981,
    good = 0x3B82F6,
    fair = 0xF59E0B,
    poor = 0xEF4444
}

if not filesystem.exists(DATA_DIR) then
    filesystem.makeDirectory(DATA_DIR)
end

local RAID_ENABLED = false
local RAID_DRIVES = {}
local MAX_FILE_SIZE = 100000
local RAID_REDUNDANCY = 2

if not component.isAvailable("data") then
    print("ERROR: Data card required for encryption!")
    print("Please install a Tier 2 or Tier 3 Data Card")
    return
end

local data = component.data

local function detectRAID()
    RAID_DRIVES = {}
    for address in component.list("filesystem") do
        local fs = component.proxy(address)
        if address ~= computer.getBootAddress() and not fs.isReadOnly() then
            local label = fs.getLabel() or ""
            if label:lower():find("raid") or label:lower():find("bank") then
                local shortAddr = address:sub(1, 3)
                local mountPath = nil
                if filesystem.exists("/mnt/" .. shortAddr) then
                    mountPath = "/mnt/" .. shortAddr
                elseif filesystem.exists("/mnt/" .. label) then
                    mountPath = "/mnt/" .. label
                end
                table.insert(RAID_DRIVES, {
                    address = address,
                    shortAddress = shortAddr,
                    proxy = fs,
                    label = label,
                    path = mountPath,
                    space = fs.spaceTotal()
                })
            end
        end
    end
    RAID_ENABLED = #RAID_DRIVES >= RAID_REDUNDANCY
    if RAID_ENABLED then
        print("RAID Mode: ENABLED")
        print("RAID Drives: " .. #RAID_DRIVES)
        for i, drive in ipairs(RAID_DRIVES) do
            local location = drive.path or ("/" .. drive.shortAddress)
            print("  " .. i .. ". " .. drive.label .. " (" .. math.floor(drive.space / 1024) .. " KB) at " .. location)
        end
    else
        print("RAID Mode: DISABLED (need " .. RAID_REDUNDANCY .. " drives labeled RAID/BANK)")
        print("Detected drives: " .. #RAID_DRIVES)
    end
end

local ENCRYPTION_KEY = data.md5(SERVER_NAME .. "BankingSecurity2024")

local function hashPassword(password)
    if not password or password == "" then return nil end
    return data.md5(password)
end

local function encryptData(plaintext)
    if not plaintext or plaintext == "" then return nil end
    local iv = data.random(16)
    local encrypted = data.encrypt(plaintext, ENCRYPTION_KEY, iv)
    return data.encode64(iv .. encrypted)
end

local function decryptData(ciphertext)
    if not ciphertext or ciphertext == "" then return nil end
    local success, result = pcall(function()
        local combined = data.decode64(ciphertext)
        local iv = combined:sub(1, 16)
        local encrypted = combined:sub(17)
        return data.decrypt(encrypted, ENCRYPTION_KEY, iv)
    end)
    if success then return result else return nil end
end

local function saveConfig()
    local config = {
        adminPasswordHash = adminPasswordHash,
        lastModified = os.time(),
        nextLoanId = nextLoanId
    }
    local file = io.open(CONFIG_FILE, "w")
    if file then
        local plaintext = serialization.serialize(config)
        local encrypted = encryptData(plaintext)
        if encrypted then
            file:write(encrypted)
            file:close()
            return true
        else
            file:close()
            return false
        end
    end
    return false
end

local function loadConfig()
    local file = io.open(CONFIG_FILE, "r")
    if file then
        local encrypted = file:read("*a")
        file:close()
        if encrypted and encrypted ~= "" then
            local plaintext = decryptData(encrypted)
            if plaintext then
                local success, config = pcall(serialization.unserialize, plaintext)
                if success and config and config.adminPasswordHash then
                    adminPasswordHash = config.adminPasswordHash
                    nextLoanId = config.nextLoanId or 1
                    return true
                end
            end
        end
    end
    adminPasswordHash = hashPassword(DEFAULT_ADMIN_PASSWORD)
    return saveConfig()
end

local function changeAdminPassword(newPassword)
    if not newPassword or newPassword == "" then
        return false, "Password cannot be empty"
    end
    adminPasswordHash = hashPassword(newPassword)
    if saveConfig() then
        log("Admin password changed", "ADMIN")
        return true, "Password changed successfully"
    end
    return false, "Failed to save config"
end

local function log(message, category)
    category = category or "INFO"
    local txn = {
        time = os.date("%Y-%m-%d %H:%M:%S"),
        category = category,
        message = message
    }
    table.insert(transactionLog, 1, txn)
    if #transactionLog > 100 then table.remove(transactionLog) end
    local file = io.open(DATA_DIR .. "transactions.log", "a")
    if file then
        file:write(serialization.serialize(txn) .. "\n")
        file:close()
    end
    stats.totalTransactions = stats.totalTransactions + 1
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
    local acc = getAccount(username)
    if acc and acc.created then
        local daysOld = (os.time() - acc.created) / 86400
        score = score + math.min(daysOld / 30 * 50, 50)
    end
    local activeLoans = 0
    for loanId, loan in pairs(loanIndex) do
        if loan.username == username and loan.status == "active" then
            activeLoans = activeLoans + 1
        end
    end
    if activeLoans > 2 then
        score = score - (activeLoans - 2) * 20
    end
    if acc then
        if acc.balance > 1000 then score = score + 25
        elseif acc.balance < 0 then score = score - 25 end
    end
    score = math.max(300, math.min(850, score))
    credit.score = math.floor(score)
    credit.lastUpdated = os.time()
    return credit.score
end

local function getCreditRating(score)
    if score >= 750 then return "EXCELLENT", colors.excellent
    elseif score >= 700 then return "GOOD", colors.good
    elseif score >= 650 then return "FAIR", colors.fair
    elseif score >= 600 then return "POOR", colors.poor
    else return "BAD", colors.error end
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

local function saveCreditScores()
    local plaintext = serialization.serialize(creditScores)
    local encrypted = encryptData(plaintext)
    if not encrypted then return false end
    local file = io.open(CREDIT_FILE, "w")
    if file then
        file:write(encrypted)
        file:close()
        return true
    end
    return false
end

local function loadCreditScores()
    local file = io.open(CREDIT_FILE, "r")
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

-- Loan Functions
local function getLoanEligibility(username)
    local credit = creditScores[username]
    if not credit then
        initializeCreditScore(username)
        credit = creditScores[username]
    end
    local score = credit.score
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
    for loanId, loan in pairs(loanIndex) do
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
    
    -- Create pending loan application
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
        status = "pending"  -- pending, approved, denied
    }
    
    pendingLoans[pendingId] = application
    
    log(string.format("Loan application submitted: %s by %s for %.2f CR", pendingId, username, amount), "LOAN")
    savePendingLoans()
    
    -- Notify all online admins
    notifyAdmins(string.format("NEW LOAN: %s requests %.2f CR", username, amount))
    
    return true, pendingId, application
end

local function approveLoanApplication(pendingId, adminUsername)
    local app = pendingLoans[pendingId]
    if not app then return false, "Application not found" end
    if app.status ~= "pending" then return false, "Application already processed" end
    
    local username = app.username
    local amount = app.amount
    local termDays = app.termDays
    
    -- Create the actual loan
    local loanId = "LOAN" .. string.format("%06d", nextLoanId)
    nextLoanId = nextLoanId + 1
    
    local loan = {
        loanId = loanId,
        username = username,
        principal = amount,
        interestRate = app.interestRate,
        interest = app.interest,
        totalOwed = app.totalOwed,
        remaining = app.totalOwed,
        termDays = termDays,
        issued = os.time(),
        dueDate = os.time() + (termDays * 86400),
        status = "active",
        payments = {},
        lateFees = 0,
        accountLocked = false,
        approvedBy = adminUsername,
        pendingId = pendingId
    }
    
    loanIndex[loanId] = loan
    if not loans[username] then loans[username] = {} end
    table.insert(loans[username], loanId)
    
    -- Add money to account
    local acc = getAccount(username)
    if acc then
        acc.balance = acc.balance + amount
        saveAccounts()
    end
    
    -- Update application status
    app.status = "approved"
    app.approvedDate = os.time()
    app.approvedBy = adminUsername
    app.loanId = loanId
    
    recordCreditEvent(username, "loan_issued", string.format("Loan %s approved and issued: %d CR", loanId, amount))
    stats.totalLoans = stats.totalLoans + 1
    stats.activeLoans = stats.activeLoans + 1
    
    log(string.format("Loan APPROVED: %s → %s to %s: %.2f CR @ %.1f%% by admin %s", 
        pendingId, loanId, username, amount, app.interestRate * 100, adminUsername), "LOAN")
    
    saveLoans()
    savePendingLoans()
    saveConfig()
    
    -- Notify user if online
    notifyUser(username, string.format("Loan approved! %.2f CR added to balance", amount))
    
    return true, loanId, loan
end

local function denyLoanApplication(pendingId, adminUsername, reason)
    local app = pendingLoans[pendingId]
    if not app then return false, "Application not found" end
    if app.status ~= "pending" then return false, "Application already processed" end
    
    app.status = "denied"
    app.deniedDate = os.time()
    app.deniedBy = adminUsername
    app.denyReason = reason or "Not specified"
    
    log(string.format("Loan DENIED: %s by %s (User: %s, Amount: %.2f CR) - Reason: %s", 
        pendingId, adminUsername, app.username, app.amount, app.denyReason), "LOAN")
    
    recordCreditEvent(app.username, "loan_denied", string.format("Loan application %s denied", pendingId))
    
    savePendingLoans()
    
    -- Notify user if online
    notifyUser(app.username, "Loan application denied: " .. app.denyReason)
    
    return true, "Application denied"
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

local function makeLoanPayment(username, loanId, amount)
    local loan = loanIndex[loanId]
    if not loan then return false, "Loan not found" end
    if loan.username ~= username then return false, "This is not your loan" end
    if loan.status ~= "active" then return false, "Loan is not active" end
    if amount <= 0 then return false, "Invalid payment amount" end
    local acc = getAccount(username)
    if not acc or acc.balance < amount then return false, "Insufficient funds" end
    local paymentAmount = math.min(amount, loan.remaining)
    acc.balance = acc.balance - paymentAmount
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
        if onTime then
            local credit = creditScores[username]
            if credit then credit.totalPayments = credit.totalPayments + 1 end
            recordCreditEvent(username, "loan_paid", string.format("Loan %s paid in full (on-time)", loanId))
        else
            local credit = creditScores[username]
            if credit then
                credit.totalPayments = credit.totalPayments + 1
                credit.latePayments = credit.latePayments + 1
            end
            recordCreditEvent(username, "loan_paid_late", string.format("Loan %s paid in full (late)", loanId))
        end
        log(string.format("Loan paid in full: %s by %s (on-time: %s)", loanId, username, tostring(onTime)), "LOAN")
    else
        log(string.format("Loan payment: %s by %s: %.2f CR (remaining: %.2f)", loanId, username, paymentAmount, loan.remaining), "LOAN")
    end
    saveAccounts()
    saveLoans()
    saveCreditScores()
    return true, paymentAmount, loan.remaining
end

local function checkOverdueLoans()
    local now = os.time()
    local overdue = {}
    for loanId, loan in pairs(loanIndex) do
        if loan.status == "active" and now > loan.dueDate then
            local daysOverdue = math.floor((now - loan.dueDate) / 86400)
            local daysSinceLastFee = math.floor((now - (loan.lastLateFee or loan.dueDate)) / 86400)
            if daysSinceLastFee >= 1 then
                local lateFee = loan.remaining * LOAN_CONFIG.LATE_FEE_RATE
                loan.lateFees = loan.lateFees + lateFee
                loan.remaining = loan.remaining + lateFee
                loan.totalOwed = loan.totalOwed + lateFee
                loan.lastLateFee = now
                log(string.format("Late fee applied to %s: %.2f CR (Day %d overdue)", loanId, lateFee, daysOverdue), "LOAN")
            end
            if LOAN_CONFIG.AUTO_LOCK_ENABLED and daysOverdue >= LOAN_CONFIG.DAYS_UNTIL_LOCK and not loan.accountLocked then
                local acc = getAccount(loan.username)
                if acc and not acc.locked then
                    acc.locked = true
                    acc.lockReason = string.format("Loan %s overdue by %d days", loanId, daysOverdue)
                    acc.lockedDate = now
                    loan.accountLocked = true
                    endSession(loan.username)
                    log(string.format("Account LOCKED: %s (Loan %s overdue by %d days)", loan.username, loanId, daysOverdue), "SECURITY")
                    recordCreditEvent(loan.username, "account_locked", string.format("Account locked due to loan %s (%d days overdue)", loanId, daysOverdue))
                end
            end
            if daysOverdue >= LOAN_CONFIG.DAYS_UNTIL_DEFAULT and loan.status ~= "default" then
                loan.status = "default"
                loan.defaultDate = now
                stats.activeLoans = stats.activeLoans - 1
                local credit = creditScores[loan.username]
                if credit then credit.defaults = credit.defaults + 1 end
                recordCreditEvent(loan.username, "loan_default", string.format("Loan %s defaulted after %d days overdue", loanId, daysOverdue))
                log(string.format("Loan DEFAULT: %s by %s (%d days overdue)", loanId, loan.username, daysOverdue), "LOAN")
            end
            table.insert(overdue, loan)
        end
    end
    if #overdue > 0 then
        saveLoans()
        saveCreditScores()
        saveAccounts()
    end
    return overdue
end

local function saveLoans()
    local data = {loans = loans, loanIndex = loanIndex}
    local plaintext = serialization.serialize(data)
    local encrypted = encryptData(plaintext)
    if not encrypted then return false end
    local file = io.open(LOAN_FILE, "w")
    if file then
        file:write(encrypted)
        file:close()
        return true
    end
    return false
end

local function savePendingLoans()
    local data = {pendingLoans = pendingLoans, nextPendingId = nextPendingId}
    local plaintext = serialization.serialize(data)
    local encrypted = encryptData(plaintext)
    if not encrypted then return false end
    local file = io.open(PENDING_LOANS_FILE, "w")
    if file then
        file:write(encrypted)
        file:close()
        return true
    end
    return false
end

local function loadLoans()
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

local function loadPendingLoans()
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
                    return true
                end
            end
        end
    end
    return false
end

-- Session management
local function createSession(username, relayAddress)
    if activeSessions[username] then
        return false, "Account already logged in"
    end
    activeSessions[username] = {
        relay = relayAddress,
        loginTime = os.time(),
        lastActivity = os.time()
    }
    stats.activeSessions = stats.activeSessions + 1
    return true
end

local function validateSession(username, relayAddress)
    local session = activeSessions[username]
    if not session then return false end
    session.lastActivity = os.time()
    return true
end

local function endSession(username)
    if activeSessions[username] then
        activeSessions[username] = nil
        stats.activeSessions = math.max(0, stats.activeSessions - 1)
    end
end

-- Database functions
local function saveAccounts()
    local plaintext = serialization.serialize(accounts)
    local encrypted = encryptData(plaintext)
    if not encrypted then return false end
    local file = io.open(DATA_DIR .. "accounts.dat", "w")
    if file then
        file:write(encrypted)
        file:close()
        return true
    end
    return false
end

local function loadAccounts()
    local file = io.open(DATA_DIR .. "accounts.dat", "r")
    if file then
        local encrypted = file:read("*a")
        file:close()
        if encrypted and encrypted ~= "" then
            local plaintext = decryptData(encrypted)
            if plaintext then
                local success, loadedAccounts = pcall(serialization.unserialize, plaintext)
                if success and loadedAccounts then
                    accounts = loadedAccounts
                    accountIndex = {}
                    for i, acc in ipairs(accounts) do
                        accountIndex[acc.name] = i
                    end
                    stats.totalAccounts = #accounts
                    return true
                end
            end
        end
    end
    return false
end

function getAccount(username)
    local idx = accountIndex[username]
    if idx then return accounts[idx], idx end
    return nil, nil
end

local function verifyPassword(username, password)
    local acc = getAccount(username)
    if not acc or not acc.passwordHash then return false end
    return acc.passwordHash == hashPassword(password)
end

local function createAccount(username, password, initialBalance, relayAddress)
    if not username or username == "" then return false, "Username cannot be empty" end
    if #username > 50 then return false, "Username too long (max 50 characters)" end
    if accountIndex[username] then return false, "Account already exists" end
    if not password or password == "" then return false, "Password cannot be empty" end
    initialBalance = initialBalance or 100.0
    relayAddress = relayAddress or "server"
    local account = {
        name = username,
        passwordHash = hashPassword(password),
        balance = initialBalance,
        relay = relayAddress,
        online = false,
        created = os.time(),
        lastActivity = os.time(),
        transactionCount = 0,
        locked = false,
        isAdmin = false
    }
    table.insert(accounts, account)
    accountIndex[username] = #accounts
    stats.totalAccounts = #accounts
    initializeCreditScore(username)
    log("New account: " .. username .. " (Balance: " .. initialBalance .. ")", "ACCOUNT")
    saveAccounts()
    saveCreditScores()
    return true, "Account created successfully", account
end

local function deleteAccount(username)
    local acc, idx = getAccount(username)
    if not acc then return false, "Account not found" end
    endSession(username)
    table.remove(accounts, idx)
    accountIndex = {}
    for i, a in ipairs(accounts) do accountIndex[a.name] = i end
    stats.totalAccounts = #accounts
    log("ADMIN: Account deleted: " .. username, "ADMIN")
    saveAccounts()
    return true, "Account deleted"
end

local function transferFunds(from, to, amount)
    local fromAcc, fromIdx = getAccount(from)
    local toAcc, toIdx = getAccount(to)
    if not fromAcc then return false, "Source account not found" end
    if not toAcc then return false, "Destination account not found" end
    if fromAcc.locked then return false, "Source account is locked" end
    if toAcc.locked then return false, "Destination account is locked" end
    if fromAcc.balance < amount then return false, "Insufficient funds" end
    if amount <= 0 then return false, "Invalid amount" end
    fromAcc.balance = fromAcc.balance - amount
    toAcc.balance = toAcc.balance + amount
    fromAcc.lastActivity = os.time()
    toAcc.lastActivity = os.time()
    fromAcc.transactionCount = fromAcc.transactionCount + 1
    toAcc.transactionCount = toAcc.transactionCount + 1
    log(string.format("Transfer: %s -> %s: %.2f CR", from, to, amount), "TRANSFER")
    saveAccounts()
    return true, "Transfer successful"
end

-- Admin functions
local function adminSetBalance(username, newBalance)
    local acc = getAccount(username)
    if not acc then return false, "Account not found" end
    local oldBalance = acc.balance
    acc.balance = newBalance
    log(string.format("ADMIN: Balance changed for %s: %.2f -> %.2f CR", username, oldBalance, newBalance), "ADMIN")
    saveAccounts()
    return true, "Balance updated"
end

local function adminLockAccount(username)
    local acc = getAccount(username)
    if not acc then return false, "Account not found" end
    acc.locked = true
    endSession(username)
    log("ADMIN: Account locked: " .. username, "ADMIN")
    saveAccounts()
    return true, "Account locked"
end

local function adminUnlockAccount(username)
    local acc = getAccount(username)
    if not acc then return false, "Account not found" end
    acc.locked = false
    acc.lockReason = nil
    acc.lockedDate = nil
    log("ADMIN: Account unlocked: " .. username, "ADMIN")
    recordCreditEvent(username, "account_unlocked", "Account unlocked by admin")
    saveAccounts()
    saveCreditScores()
    return true, "Account unlocked"
end

local function adminResetPassword(username, newPassword)
    local acc = getAccount(username)
    if not acc then return false, "Account not found" end
    if not newPassword or newPassword == "" then return false, "Password cannot be empty" end
    acc.passwordHash = hashPassword(newPassword)
    log("ADMIN: Password reset for " .. username, "ADMIN")
    saveAccounts()
    return true, "Password reset"
end

-- Admin loan management functions
local function adminViewAllLoans()
    local loanList = {}
    for loanId, loan in pairs(loanIndex) do
        table.insert(loanList, loan)
    end
    table.sort(loanList, function(a, b)
        if a.status ~= b.status then
            if a.status == "active" then return true
            elseif b.status == "active" then return false
            elseif a.status == "default" then return true
            elseif b.status == "default" then return false
            end
        end
        return a.issued > b.issued
    end)
    return loanList
end

local function adminForgiveLoan(loanId)
    local loan = loanIndex[loanId]
    if not loan then return false, "Loan not found" end
    
    local username = loan.username
    loan.remaining = 0
    loan.status = "forgiven"
    loan.forgivenDate = os.time()
    
    -- Unlock account if it was locked for this loan
    local acc = getAccount(username)
    if acc and acc.locked and acc.lockReason and acc.lockReason:find(loanId) then
        acc.locked = false
        acc.lockReason = nil
        acc.lockedDate = nil
    end
    
    stats.activeLoans = stats.activeLoans - 1
    
    recordCreditEvent(username, "loan_forgiven", string.format("Loan %s forgiven by admin", loanId))
    log(string.format("ADMIN: Loan forgiven: %s for %s", loanId, username), "ADMIN")
    
    saveLoans()
    saveAccounts()
    saveCreditScores()
    
    return true, "Loan forgiven"
end

local function adminToggleAdminStatus(username)
    local acc = getAccount(username)
    if not acc then return false, "Account not found" end
    
    acc.isAdmin = not acc.isAdmin
    log(string.format("ADMIN: Admin status for %s set to %s", username, tostring(acc.isAdmin)), "ADMIN")
    saveAccounts()
    
    return true, "Admin status updated"
end

local function adminAdjustCredit(username, newScore, reason)
    local credit = creditScores[username]
    if not credit then
        initializeCreditScore(username)
        credit = creditScores[username]
    end
    
    local oldScore = credit.score
    newScore = math.max(300, math.min(850, newScore))
    credit.score = newScore
    
    local changeDesc = string.format("Manual adjustment by admin: %d → %d", oldScore, newScore)
    if reason and reason ~= "" then
        changeDesc = changeDesc .. " (Reason: " .. reason .. ")"
    end
    
    recordCreditEvent(username, "admin_adjustment", changeDesc)
    log(string.format("ADMIN: Credit score adjusted for %s: %d → %d", username, oldScore, newScore), "ADMIN")
    
    saveCreditScores()
    return true, "Credit score adjusted"
end

local function adminViewLockedAccounts()
    local lockedAccounts = {}
    for _, acc in ipairs(accounts) do
        if acc.locked then
            local daysLocked = 0
            if acc.lockedDate then
                daysLocked = math.floor((os.time() - acc.lockedDate) / 86400)
            end
            table.insert(lockedAccounts, {
                username = acc.name,
                lockReason = acc.lockReason or "Unknown",
                lockedDate = acc.lockedDate or 0,
                daysLocked = daysLocked,
                balance = acc.balance
            })
        end
    end
    table.sort(lockedAccounts, function(a, b)
        return (a.lockedDate or 0) > (b.lockedDate or 0)
    end)
    return lockedAccounts
end

-- Notification functions
local function notifyAdmins(message)
    for _, acc in ipairs(accounts) do
        if acc.isAdmin and acc.online and acc.relay then
            modem.send(acc.relay, NETWORK_PORT, {
                command = "notification",
                message = message,
                timestamp = os.time()
            })
        end
    end
end

local function notifyUser(username, message)
    local acc = getAccount(username)
    if acc and acc.online and acc.relay then
        modem.send(acc.relay, NETWORK_PORT, {
            command = "notification",
            message = message,
            timestamp = os.time()
        })
    end
end

local function registerRelay(address, relayName)
    if not relays[address] then
        relays[address] = {
            address = address,
            name = relayName,
            lastSeen = computer.uptime(),
            clients = 0
        }
        stats.relayCount = stats.relayCount + 1
        log("Relay connected: " .. relayName, "RELAY")
    else
        relays[address].lastSeen = computer.uptime()
    end
end

-- UI Drawing Functions (keeping original style)
local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
end

local function drawHeader(title, subtitle, isAdmin)
    gpu.setBackground(isAdmin and colors.adminRed or colors.header)
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

-- Main Server UI
local function drawServerUI()
    gpu.setBackground(adminMode and colors.adminBg or 0x0000AA)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, w, h, " ")
    gpu.setBackground(adminMode and colors.adminRed or 0x000080)
    gpu.fill(1, 1, w, 3, " ")
    local title = adminMode and "=== ADMIN MODE ===" or ("=== " .. SERVER_NAME .. " ===")
    gpu.set(math.floor((w - #title) / 2), 2, title)
    gpu.setBackground(0x1E1E1E)
    gpu.setForeground(0x00FF00)
    gpu.fill(1, 4, w, 2, " ")
    gpu.set(2, 4, "Accounts: " .. stats.totalAccounts)
    gpu.set(20, 4, "Transactions: " .. stats.totalTransactions)
    gpu.set(45, 4, "Sessions: " .. stats.activeSessions)
    gpu.set(65, 4, "Port: " .. PORT)
    gpu.set(2, 5, "Loans: " .. stats.activeLoans .. "/" .. stats.totalLoans)
    gpu.setForeground(0xFFFF00)
    gpu.set(25, 5, "Mode: WIRELESS")
    if RAID_ENABLED then
        gpu.setForeground(0x00FF00)
        gpu.set(45, 5, "RAID: " .. #RAID_DRIVES .. " drives")
    end
    if adminMode then
        gpu.setForeground(0xFF0000)
        gpu.set(65, 5, "[ADMIN]")
    end
    if not adminMode then
        gpu.setBackground(0x2D2D2D)
        gpu.setForeground(0xFFFF00)
        gpu.fill(1, 7, w, 1, " ")
        gpu.set(2, 7, "Connected Relays:")
        gpu.setForeground(0xFFFFFF)
        gpu.set(2, 8, "Name")
        gpu.set(30, 8, "Address")
        gpu.set(55, 8, "Clients")
        gpu.set(68, 8, "Status")
        local y = 9
        local relayList = {}
        for _, relay in pairs(relays) do table.insert(relayList, relay) end
        table.sort(relayList, function(a, b) return a.lastSeen > b.lastSeen end)
        for i = 1, math.min(5, #relayList) do
            local relay = relayList[i]
            local now = computer.uptime()
            local timeDiff = now - relay.lastSeen
            local isActive = timeDiff < 60
            gpu.setForeground(isActive and 0x00FF00 or 0x888888)
            local name = relay.name or "Unknown"
            if #name > 25 then name = name:sub(1, 22) .. "..." end
            gpu.set(2, y, name)
            gpu.set(30, y, relay.address:sub(1, 16))
            gpu.set(55, y, tostring(relay.clients or 0))
            gpu.setForeground(isActive and 0x00FF00 or 0xFF0000)
            gpu.set(68, y, isActive and "ACTIVE" or "TIMEOUT")
            y = y + 1
        end
        gpu.setForeground(0xFFFF00)
        gpu.fill(1, 15, w, 1, " ")
        gpu.set(2, 15, "Recent Accounts:")
        gpu.setBackground(0x2D2D2D)
        gpu.setForeground(0xFFFFFF)
        gpu.set(2, 16, "Username")
        gpu.set(25, 16, "Balance")
        gpu.set(40, 16, "Session")
        gpu.set(55, 16, "Locked")
        local sortedAccounts = {}
        for _, acc in ipairs(accounts) do table.insert(sortedAccounts, acc) end
        table.sort(sortedAccounts, function(a, b) return (a.lastActivity or 0) > (b.lastActivity or 0) end)
        y = 17
        for i = 1, math.min(3, #sortedAccounts) do
            local acc = sortedAccounts[i]
            gpu.setForeground(0xCCCCCC)
            local name = acc.name
            if #name > 20 then name = name:sub(1, 17) .. "..." end
            gpu.set(2, y, name)
            gpu.setForeground(0x00FF00)
            gpu.set(25, y, string.format("%.2f", acc.balance))
            local hasSession = activeSessions[acc.name] ~= nil
            gpu.setForeground(hasSession and 0x00FF00 or 0x888888)
            gpu.set(40, y, hasSession and "ACTIVE" or "none")
            gpu.setForeground(acc.locked and 0xFF0000 or 0x888888)
            gpu.set(55, y, acc.locked and "YES" or "no")
            y = y + 1
        end
    end
    gpu.setBackground(0x1E1E1E)
    gpu.setForeground(0xFFFF00)
    gpu.fill(1, 21, w, 1, " ")
    gpu.set(2, 21, "Recent Activity:")
    gpu.setBackground(0x2D2D2D)
    local y = 22
    for i = 1, math.min(3, #transactionLog) do
        local entry = transactionLog[i]
        local color = 0xAAAAAA
        if entry.category == "TRANSFER" then color = 0x00FF00
        elseif entry.category == "ERROR" then color = 0xFF0000
        elseif entry.category == "ACCOUNT" then color = 0xFFFF00
        elseif entry.category == "RELAY" then color = 0xFF00FF
        elseif entry.category == "ADMIN" then color = 0xFF0000
        elseif entry.category == "LOAN" then color = 0x00FFFF end
        gpu.setForeground(color)
        local msg = "[" .. entry.time:sub(12) .. "] " .. entry.message
        gpu.set(2, y, msg:sub(1, 76))
        y = y + 1
    end
    gpu.setBackground(adminMode and colors.adminRed or 0x000080)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 25, w, 1, " ")
    local footer = adminMode and "Press F1 or F5 to exit admin mode" or "Press F5 for admin panel"
    gpu.set(2, 25, footer)
end

-- Admin Panel Functions (keeping originals)
local function adminLogin()
    clearScreen()
    drawHeader("◆ ADMIN AUTHENTICATION ◆", "Enter admin password", true)
    drawBox(20, 10, 40, 6, colors.bg)
    gpu.setForeground(colors.warning)
    gpu.set(22, 11, "⚠ RESTRICTED ACCESS")
    local password = input("Password: ", 13, true, 30)
    if hashPassword(password) == adminPasswordHash then
        adminAuthenticated = true
        adminMode = true
        showStatus("✓ Authentication successful", "success")
        log("Admin login successful", "ADMIN")
        os.sleep(1)
        return true
    else
        showStatus("✗ Authentication failed", "error")
        log("Admin login FAILED - incorrect password", "SECURITY")
        os.sleep(2)
        return false
    end
end

local function adminMainMenu()
    clearScreen()
    drawHeader("◆ ADMIN PANEL ◆", "Server Management Console", true)
    drawBox(15, 5, 50, 20, colors.bg)
    gpu.setForeground(colors.adminRed)
    gpu.set(17, 6, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    gpu.setForeground(colors.textDim)
    gpu.set(17, 7, "  Administrative Tools")
    gpu.setForeground(colors.adminRed)
    gpu.set(17, 8, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    gpu.setForeground(colors.text)
    gpu.set(20, 10, "ACCOUNT MANAGEMENT")
    gpu.setForeground(colors.textDim)
    gpu.set(20, 11, "1  Create Account")
    gpu.set(20, 12, "2  Delete Account")
    gpu.set(20, 13, "3  Set Balance")
    gpu.set(20, 14, "4  Lock/Unlock Account")
    gpu.set(20, 15, "5  Reset Password")
    gpu.set(20, 16, "6  View All Accounts")
    gpu.set(20, 17, "D  Toggle Admin Status")
    gpu.setForeground(colors.text)
    gpu.set(20, 18, "LOAN MANAGEMENT")
    gpu.setForeground(colors.textDim)
    gpu.set(20, 19, "7  View All Loans")
    gpu.set(20, 20, "8  View Locked Accounts")
    gpu.set(20, 21, "9  Forgive Loan")
    gpu.set(20, 22, "A  Adjust Credit Score")
    gpu.setForeground(colors.text)
    gpu.set(20, 23, "SYSTEM")
    gpu.setForeground(colors.textDim)
    gpu.set(20, 24, "B  Change Admin Password")
    gpu.set(20, 25, "C  View RAID Drives")
    gpu.setForeground(colors.warning)
    gpu.set(20, 26, "0  Exit Admin Mode")
    
    local pendingCount = 0
    for _, app in pairs(pendingLoans) do
        if app.status == "pending" then pendingCount = pendingCount + 1 end
    end
    
    drawFooter("Admin Tools • Loans: " .. stats.activeLoans .. " • Pending: " .. pendingCount)
    local _, _, char = event.pull("key_down")
    return char
end

local function adminCreateAccountUI()
    clearScreen()
    drawHeader("◆ CREATE ACCOUNT ◆", "Add new user to system", true)
    drawBox(15, 7, 50, 13, colors.bg)
    gpu.setForeground(colors.text)
    local username = input("Username:        ", 9, false, 25)
    if not username or username == "" then
        showStatus("✗ Username required", "error")
        os.sleep(2)
        return
    end
    local password = input("Password:        ", 11, true, 25)
    if not password or password == "" then
        showStatus("✗ Password required", "error")
        os.sleep(2)
        return
    end
    local balanceStr = input("Initial Balance: ", 13, false, 10)
    local balance = tonumber(balanceStr) or 100.0
    gpu.setForeground(colors.textDim)
    gpu.set(17, 16, "Creating account...")
    local ok, msg = createAccount(username, password, balance, "admin")
    if ok then
        showStatus("✓ Account created: " .. username, "success")
    else
        showStatus("✗ " .. msg, "error")
    end
    os.sleep(2)
end

local function adminDeleteAccountUI()
    clearScreen()
    drawHeader("◆ DELETE ACCOUNT ◆", "Remove user from system", true)
    drawBox(15, 7, 50, 10, colors.bg)
    gpu.setForeground(colors.warning)
    gpu.set(17, 8, "⚠ WARNING: This action cannot be undone!")
    gpu.setForeground(colors.text)
    local username = input("Username: ", 11, false, 25)
    if not username or username == "" then
        showStatus("Cancelled", "warning")
        os.sleep(1)
        return
    end
    gpu.setForeground(colors.error)
    gpu.set(17, 14, "Type 'DELETE' to confirm:")
    gpu.setBackground(colors.inputBg)
    gpu.fill(43, 14, 10, 1, " ")
    gpu.set(44, 14, "")
    local confirm = ""
    while true do
        local _, _, char, code = event.pull("key_down")
        if code == 28 then break
        elseif code == 14 and #confirm > 0 then
            confirm = confirm:sub(1, -2)
            gpu.setBackground(colors.inputBg)
            gpu.fill(44, 14, 8, 1, " ")
            gpu.set(44, 14, confirm)
        elseif char >= 32 and char < 127 and #confirm < 8 then
            confirm = confirm .. string.char(char)
            gpu.set(44, 14, confirm)
        end
    end
    gpu.setBackground(colors.bg)
    if confirm ~= "DELETE" then
        showStatus("Cancelled", "warning")
        os.sleep(1)
        return
    end
    local ok, msg = deleteAccount(username)
    if ok then
        showStatus("✓ Account deleted: " .. username, "success")
    else
        showStatus("✗ " .. msg, "error")
    end
    os.sleep(2)
end

local function adminSetBalanceUI()
    clearScreen()
    drawHeader("◆ SET BALANCE ◆", "Modify account balance", true)
    drawBox(15, 7, 50, 11, colors.bg)
    gpu.setForeground(colors.text)
    local username = input("Username:    ", 9, false, 25)
    if not username or username == "" then
        showStatus("Cancelled", "warning")
        os.sleep(1)
        return
    end
    local acc = getAccount(username)
    if not acc then
        showStatus("✗ Account not found", "error")
        os.sleep(2)
        return
    end
    gpu.setForeground(colors.textDim)
    gpu.set(17, 12, "Current balance: " .. string.format("%.2f CR", acc.balance))
    gpu.setForeground(colors.text)
    local newBalStr = input("New Balance: ", 14, false, 10)
    local newBalance = tonumber(newBalStr)
    if not newBalance or newBalance < 0 then
        showStatus("✗ Invalid amount", "error")
        os.sleep(2)
        return
    end
    local ok, msg = adminSetBalance(username, newBalance)
    if ok then
        showStatus("✓ Balance updated", "success")
    else
        showStatus("✗ " .. msg, "error")
    end
    os.sleep(2)
end

local function adminLockUnlockUI()
    clearScreen()
    drawHeader("◆ LOCK/UNLOCK ACCOUNT ◆", "Control account access", true)
    drawBox(15, 7, 50, 12, colors.bg)
    gpu.setForeground(colors.text)
    local username = input("Username: ", 9, false, 25)
    if not username or username == "" then
        showStatus("Cancelled", "warning")
        os.sleep(1)
        return
    end
    local acc = getAccount(username)
    if not acc then
        showStatus("✗ Account not found", "error")
        os.sleep(2)
        return
    end
    gpu.setForeground(colors.textDim)
    gpu.set(17, 12, "Current status: " .. (acc.locked and "LOCKED" or "unlocked"))
    gpu.setForeground(colors.text)
    gpu.set(17, 14, "1  Lock Account")
    gpu.set(17, 15, "2  Unlock Account")
    local _, _, char = event.pull("key_down")
    local ok, msg
    if char == string.byte('1') then
        ok, msg = adminLockAccount(username)
    elseif char == string.byte('2') then
        ok, msg = adminUnlockAccount(username)
    else
        showStatus("Cancelled", "warning")
        os.sleep(1)
        return
    end
    if ok then
        showStatus("✓ " .. msg, "success")
    else
        showStatus("✗ " .. msg, "error")
    end
    os.sleep(2)
end

local function adminResetPasswordUI()
    clearScreen()
    drawHeader("◆ RESET PASSWORD ◆", "Change user password", true)
    drawBox(15, 7, 50, 10, colors.bg)
    gpu.setForeground(colors.text)
    local username = input("Username:     ", 9, false, 25)
    if not username or username == "" then
        showStatus("Cancelled", "warning")
        os.sleep(1)
        return
    end
    local acc = getAccount(username)
    if not acc then
        showStatus("✗ Account not found", "error")
        os.sleep(2)
        return
    end
    local newPassword = input("New Password: ", 12, true, 25)
    if not newPassword or newPassword == "" then
        showStatus("✗ Password required", "error")
        os.sleep(2)
        return
    end
    local ok, msg = adminResetPassword(username, newPassword)
    if ok then
        showStatus("✓ Password reset for " .. username, "success")
    else
        showStatus("✗ " .. msg, "error")
    end
    os.sleep(2)
end

local function adminViewAllAccountsUI()
    clearScreen()
    drawHeader("◆ ALL ACCOUNTS ◆", "Total: " .. stats.totalAccounts, true)
    gpu.setForeground(colors.textDim)
    gpu.set(2, 5, "Username")
    gpu.set(25, 5, "Balance")
    gpu.set(40, 5, "Session")
    gpu.set(55, 5, "Locked")
    gpu.set(68, 5, "Txns")
    gpu.setForeground(colors.border)
    for i = 1, 76 do gpu.set(2 + i, 6, "─") end
    local y = 7
    for i = 1, math.min(16, #accounts) do
        local acc = accounts[i]
        gpu.setForeground(colors.text)
        local name = acc.name
        if #name > 20 then name = name:sub(1, 17) .. "..." end
        gpu.set(2, y, name)
        gpu.setForeground(colors.success)
        gpu.set(25, y, string.format("%.2f", acc.balance))
        local hasSession = activeSessions[acc.name] ~= nil
        gpu.setForeground(hasSession and colors.success or colors.textDim)
        gpu.set(40, y, hasSession and "ACTIVE" or "none")
        gpu.setForeground(acc.locked and colors.error or colors.textDim)
        gpu.set(55, y, acc.locked and "YES" or "no")
        gpu.setForeground(colors.textDim)
        gpu.set(68, y, tostring(acc.transactionCount or 0))
        y = y + 1
    end
    drawFooter("Press any key to return...")
    event.pull("key_down")
end

local function adminChangePasswordUI()
    clearScreen()
    drawHeader("◆ CHANGE ADMIN PASSWORD ◆", "Update admin credentials", true)
    drawBox(15, 8, 50, 10, colors.bg)
    gpu.setForeground(colors.warning)
    gpu.set(17, 9, "⚠ This changes the server admin password")
    gpu.setForeground(colors.text)
    local currentPass = input("Current Password: ", 12, true, 25)
    if hashPassword(currentPass) ~= adminPasswordHash then
        showStatus("✗ Incorrect current password", "error")
        os.sleep(2)
        return
    end
    local newPass = input("New Password:     ", 14, true, 25)
    if not newPass or newPass == "" then
        showStatus("✗ Password cannot be empty", "error")
        os.sleep(2)
        return
    end
    local confirmPass = input("Confirm:          ", 16, true, 25)
    if newPass ~= confirmPass then
        showStatus("✗ Passwords don't match", "error")
        os.sleep(2)
        return
    end
    local ok, msg = changeAdminPassword(newPass)
    if ok then
        showStatus("✓ Admin password changed", "success")
    else
        showStatus("✗ " .. msg, "error")
    end
    os.sleep(2)
end

local function adminViewRAIDUI()
    clearScreen()
    drawHeader("◆ RAID STORAGE ◆", "Distributed Storage Configuration", true)
    local boxHeight = math.min(18, 8 + #RAID_DRIVES * 2)
    drawBox(10, 6, 60, boxHeight, colors.bg)
    gpu.setForeground(colors.accent)
    gpu.set(12, 7, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    local y = 9
    if RAID_ENABLED then
        gpu.setForeground(colors.success)
        gpu.set(12, y, "✓ RAID Mode: ENABLED")
        y = y + 1
        gpu.setForeground(colors.textDim)
        gpu.set(12, y, "  Redundancy: " .. RAID_REDUNDANCY .. "x copies per chunk")
        y = y + 1
        gpu.set(12, y, "  Max chunk size: " .. math.floor(MAX_FILE_SIZE / 1024) .. " KB")
        y = y + 2
        gpu.setForeground(colors.accent)
        gpu.set(12, y, "Connected Drives (" .. #RAID_DRIVES .. "):")
        y = y + 1
        gpu.setForeground(colors.textDim)
        gpu.set(12, y, "─────────────────────────────────────────────────────────")
        y = y + 1
        for i, drive in ipairs(RAID_DRIVES) do
            gpu.setForeground(colors.text)
            local driveNum = string.format("%d.", i)
            gpu.set(14, y, driveNum)
            gpu.setForeground(colors.accent)
            gpu.set(17, y, drive.label)
            gpu.setForeground(colors.textDim)
            local spaceKB = math.floor(drive.space / 1024)
            local spaceMB = math.floor(spaceKB / 1024)
            local spaceStr
            if spaceMB > 0 then
                spaceStr = string.format("%.1f MB", spaceMB)
            else
                spaceStr = spaceKB .. " KB"
            end
            gpu.set(35, y, spaceStr)
            gpu.setForeground(colors.success)
            local location
            if drive.path then
                location = drive.path
            else
                location = "/mnt/" .. (drive.shortAddress or drive.address:sub(1, 3))
            end
            gpu.set(48, y, "✓")
            y = y + 1
            gpu.setForeground(0x555555)
            gpu.set(17, y, location)
            y = y + 1
        end
    else
        gpu.setForeground(colors.error)
        gpu.set(12, y, "✗ RAID Mode: DISABLED")
        y = y + 2
        gpu.setForeground(colors.textDim)
        gpu.set(12, y, "  Reason: Need at least " .. RAID_REDUNDANCY .. " drives")
        y = y + 1
        gpu.set(12, y, "  Detected drives: " .. #RAID_DRIVES)
        y = y + 2
        if #RAID_DRIVES > 0 then
            gpu.setForeground(colors.accent)
            gpu.set(12, y, "Available Drives:")
            y = y + 1
            for i, drive in ipairs(RAID_DRIVES) do
                gpu.setForeground(colors.textDim)
                local driveNum = string.format("%d. %s", i, drive.label)
                gpu.set(14, y, driveNum)
                y = y + 1
            end
            y = y + 1
        end
        gpu.setForeground(colors.warning)
        gpu.set(12, y, "To enable RAID:")
        y = y + 1
        gpu.setForeground(colors.textDim)
        gpu.set(14, y, "1. Label drives with 'RAID' or 'BANK'")
        y = y + 1
        gpu.set(14, y, "2. Install at least " .. RAID_REDUNDANCY .. " drives")
        y = y + 1
        gpu.set(14, y, "3. Restart the server")
    end
    drawFooter("Press any key to continue")
    event.pull("key_down")
end

local function adminViewAllLoansUI()
    clearScreen()
    drawHeader("◆ ALL LOANS ◆", "Total: " .. stats.totalLoans .. " | Active: " .. stats.activeLoans, true)
    
    local loanList = adminViewAllLoans()
    
    gpu.setForeground(colors.textDim)
    gpu.set(2, 5, "Loan ID")
    gpu.set(15, 5, "User")
    gpu.set(30, 5, "Principal")
    gpu.set(43, 5, "Remaining")
    gpu.set(56, 5, "Status")
    gpu.set(68, 5, "Days")
    
    gpu.setForeground(colors.border)
    for i = 1, 76 do gpu.set(2 + i, 6, "─") end
    
    local y = 7
    for i = 1, math.min(16, #loanList) do
        local loan = loanList[i]
        
        gpu.setForeground(colors.text)
        gpu.set(2, y, loan.loanId)
        
        local username = loan.username
        if #username > 12 then username = username:sub(1, 9) .. "..." end
        gpu.set(15, y, username)
        
        gpu.setForeground(colors.textDim)
        gpu.set(30, y, string.format("%.2f", loan.principal))
        gpu.set(43, y, string.format("%.2f", loan.remaining))
        
        -- Color code status
        local statusColor = colors.textDim
        if loan.status == "active" then 
            statusColor = colors.success
            if os.time() > loan.dueDate then statusColor = colors.error end
        elseif loan.status == "paid" then statusColor = colors.good
        elseif loan.status == "default" then statusColor = colors.error
        elseif loan.status == "forgiven" then statusColor = colors.warning
        end
        gpu.setForeground(statusColor)
        gpu.set(56, y, loan.status)
        
        -- Days calculation
        gpu.setForeground(colors.textDim)
        if loan.status == "active" then
            local daysRemaining = math.floor((loan.dueDate - os.time()) / 86400)
            if daysRemaining < 0 then
                gpu.setForeground(colors.error)
                gpu.set(68, y, string.format("-%d", -daysRemaining))
            else
                gpu.set(68, y, tostring(daysRemaining))
            end
        else
            gpu.set(68, y, "-")
        end
        
        y = y + 1
    end
    
    if #loanList > 16 then
        gpu.setForeground(colors.textDim)
        gpu.set(2, y + 1, "Showing 16 of " .. #loanList .. " loans")
    end
    
    drawFooter("Press any key to return...")
    event.pull("key_down")
end

local function adminViewLockedAccountsUI()
    clearScreen()
    drawHeader("◆ LOCKED ACCOUNTS ◆", "Auto-locked due to overdue loans", true)
    
    local lockedAccounts = adminViewLockedAccounts()
    
    if #lockedAccounts == 0 then
        drawBox(20, 10, 40, 5, colors.bg)
        gpu.setForeground(colors.success)
        centerText(12, "✓ No locked accounts")
        gpu.setForeground(colors.textDim)
        centerText(14, "Press any key to return")
    else
        gpu.setForeground(colors.textDim)
        gpu.set(2, 5, "Username")
        gpu.set(20, 5, "Lock Reason")
        gpu.set(50, 5, "Days")
        gpu.set(60, 5, "Balance")
        
        gpu.setForeground(colors.border)
        for i = 1, 76 do gpu.set(2 + i, 6, "─") end
        
        local y = 7
        for i = 1, math.min(15, #lockedAccounts) do
            local acc = lockedAccounts[i]
            
            gpu.setForeground(colors.error)
            local username = acc.username
            if #username > 16 then username = username:sub(1, 13) .. "..." end
            gpu.set(2, y, username)
            
            gpu.setForeground(colors.textDim)
            local reason = acc.lockReason
            if #reason > 28 then reason = reason:sub(1, 25) .. "..." end
            gpu.set(20, y, reason)
            
            gpu.setForeground(colors.warning)
            gpu.set(50, y, tostring(acc.daysLocked))
            
            gpu.setForeground(colors.text)
            gpu.set(60, y, string.format("%.2f", acc.balance))
            
            y = y + 1
        end
        
        if #lockedAccounts > 15 then
            gpu.setForeground(colors.textDim)
            gpu.set(2, y + 1, "Showing 15 of " .. #lockedAccounts .. " locked accounts")
        end
    end
    
    drawFooter("Press any key to return...")
    event.pull("key_down")
end

local function adminForgiveLoanUI()
    clearScreen()
    drawHeader("◆ FORGIVE LOAN ◆", "Clear loan debt and unlock account", true)
    
    drawBox(15, 7, 50, 12, colors.bg)
    
    gpu.setForeground(colors.warning)
    gpu.set(17, 8, "⚠ This will:")
    gpu.setForeground(colors.textDim)
    gpu.set(17, 9, "  • Set remaining balance to 0")
    gpu.set(17, 10, "  • Mark loan as 'forgiven'")
    gpu.set(17, 11, "  • Unlock account if locked for this loan")
    gpu.set(17, 12, "  • Add credit history event")
    
    gpu.setForeground(colors.text)
    local loanId = input("Loan ID: ", 15, false, 15)
    
    if not loanId or loanId == "" then
        showStatus("Cancelled", "warning")
        os.sleep(1)
        return
    end
    
    local loan = loanIndex[loanId]
    if not loan then
        showStatus("✗ Loan not found", "error")
        os.sleep(2)
        return
    end
    
    gpu.setForeground(colors.textDim)
    gpu.set(17, 17, "User: " .. loan.username)
    gpu.set(17, 18, "Remaining: " .. string.format("%.2f CR", loan.remaining))
    
    gpu.setForeground(colors.warning)
    gpu.set(17, 20, "Confirm forgiveness? (Y/N)")
    
    local _, _, char = event.pull("key_down")
    
    if char == string.byte('y') or char == string.byte('Y') then
        local ok, msg = adminForgiveLoan(loanId)
        if ok then
            showStatus("✓ Loan forgiven: " .. loanId, "success")
        else
            showStatus("✗ " .. msg, "error")
        end
        os.sleep(2)
    else
        showStatus("Cancelled", "warning")
        os.sleep(1)
    end
end

local function adminAdjustCreditUI()
    clearScreen()
    drawHeader("◆ ADJUST CREDIT SCORE ◆", "Manual credit score modification", true)
    
    drawBox(15, 7, 50, 14, colors.bg)
    
    gpu.setForeground(colors.warning)
    gpu.set(17, 8, "⚠ Use with caution!")
    gpu.setForeground(colors.textDim)
    gpu.set(17, 9, "  Valid range: 300-850")
    
    gpu.setForeground(colors.text)
    local username = input("Username:   ", 12, false, 25)
    
    if not username or username == "" then
        showStatus("Cancelled", "warning")
        os.sleep(1)
        return
    end
    
    local acc = getAccount(username)
    if not acc then
        showStatus("✗ Account not found", "error")
        os.sleep(2)
        return
    end
    
    local credit = creditScores[username]
    if not credit then
        initializeCreditScore(username)
        credit = creditScores[username]
    end
    
    gpu.setForeground(colors.textDim)
    local currentRating = getCreditRating(credit.score)
    gpu.set(17, 14, "Current: " .. credit.score .. " (" .. currentRating .. ")")
    
    gpu.setForeground(colors.text)
    local newScoreStr = input("New Score:  ", 16, false, 5)
    local newScore = tonumber(newScoreStr)
    
    if not newScore or newScore < 300 or newScore > 850 then
        showStatus("✗ Invalid score (must be 300-850)", "error")
        os.sleep(2)
        return
    end
    
    local reason = input("Reason:     ", 18, false, 30)
    
    gpu.setForeground(colors.warning)
    gpu.set(17, 20, "Confirm adjustment? (Y/N)")
    
    local _, _, char = event.pull("key_down")
    
    if char == string.byte('y') or char == string.byte('Y') then
        local ok, msg = adminAdjustCredit(username, newScore, reason)
        if ok then
            showStatus("✓ Credit score adjusted", "success")
        else
            showStatus("✗ " .. msg, "error")
        end
        os.sleep(2)
    else
        showStatus("Cancelled", "warning")
        os.sleep(1)
    end
end

local function adminToggleAdminUI()
    clearScreen()
    drawHeader("◆ TOGGLE ADMIN STATUS ◆", "Grant or revoke admin privileges", true)
    
    drawBox(15, 7, 50, 10, colors.bg)
    
    gpu.setForeground(colors.warning)
    gpu.set(17, 8, "⚠ Admin users can approve loans and access admin panel!")
    
    gpu.setForeground(colors.text)
    local username = input("Username: ", 12, false, 25)
    
    if not username or username == "" then
        showStatus("Cancelled", "warning")
        os.sleep(1)
        return
    end
    
    local acc = getAccount(username)
    if not acc then
        showStatus("✗ Account not found", "error")
        os.sleep(2)
        return
    end
    
    gpu.setForeground(colors.textDim)
    local currentStatus = acc.isAdmin and "YES" or "NO"
    local newStatus = acc.isAdmin and "NO" or "YES"
    gpu.set(17, 14, "Current admin status: " .. currentStatus)
    gpu.set(17, 15, "New admin status:     " .. newStatus)
    
    gpu.setForeground(colors.warning)
    gpu.set(17, 17, "Confirm change? (Y/N)")
    
    local _, _, char = event.pull("key_down")
    
    if char == string.byte('y') or char == string.byte('Y') then
        local ok, msg = adminToggleAdminStatus(username)
        if ok then
            showStatus("✓ Admin status updated", "success")
        else
            showStatus("✗ " .. msg, "error")
        end
        os.sleep(2)
    else
        showStatus("Cancelled", "warning")
        os.sleep(1)
    end
end

-- Network message handler
local function handleMessage(eventType, _, sender, port, distance, message)
    if port ~= PORT then return end
    local success, data = pcall(serialization.unserialize, message)
    if not success or not data then return end
    if data.type == "relay_ping" then
        registerRelay(sender, data.relay_name or "Unknown")
        local response = {type = "server_response", serverName = SERVER_NAME}
        modem.send(sender, PORT, serialization.serialize(response))
        if not adminMode then drawServerUI() end
        return
    end
    if data.type == "relay_heartbeat" then
        registerRelay(sender, data.relay_name or "Unknown")
        if relays[sender] and data.clients then relays[sender].clients = data.clients end
        if not adminMode then drawServerUI() end
        return
    end
    local relayAddress = sender
    local response = {type = "response"}
    if data.command == "login" then
        if not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Invalid username or password"
        else
            local acc = getAccount(data.username)
            if acc.locked then
                response.success = false
                response.locked = true
                response.lockReason = acc.lockReason or "Contact administrator"
                response.lockedDate = acc.lockedDate
                response.message = "Account locked: " .. (acc.lockReason or "Contact admin")
                log(string.format("Login DENIED (locked): %s", data.username), "SECURITY")
            else
                local ok, msg = createSession(data.username, relayAddress)
                if not ok then
                    response.success = false
                    response.message = msg
                else
                    acc.online = true
                    acc.relay = relayAddress
                    acc.lastActivity = os.time()
                    response.success = true
                    response.balance = acc.balance
                    response.creditScore = creditScores[data.username] and creditScores[data.username].score or 650
                    response.creditRating = getCreditRating(response.creditScore)
                    response.message = "Login successful"
                    log("Login: " .. data.username .. (acc.isAdmin and " (ADMIN)" or ""), "AUTH")
                    saveAccounts()
                end
            end
        end
    elseif data.command == "balance" then
        if not validateSession(data.username, relayAddress) then
            response.success = false
            response.message = "Session invalid. Please login again."
        elseif not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Authentication failed"
        else
            local acc = getAccount(data.username)
            if acc then
                acc.lastActivity = os.time()
                response.success = true
                response.balance = acc.balance
            else
                response.success = false
                response.message = "Account not found"
            end
        end
    elseif data.command == "transfer" then
        if not validateSession(data.username, relayAddress) then
            response.success = false
            response.message = "Session invalid. Please login again."
        elseif not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Authentication failed"
        else
            local ok, msg = transferFunds(data.username, data.recipient, data.amount)
            response.success = ok
            response.message = msg
            if ok then
                local acc = getAccount(data.username)
                response.balance = acc.balance
            end
        end
    elseif data.command == "get_credit_score" then
        if not validateSession(data.username, relayAddress) then
            response.success = false
            response.message = "Session invalid"
        elseif not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Authentication failed"
        else
            local credit = creditScores[data.username]
            if not credit then
                initializeCreditScore(data.username)
                credit = creditScores[data.username]
            end
            calculateCreditScore(data.username)
            response.success = true
            response.score = credit.score
            response.rating, _ = getCreditRating(credit.score)
            response.history = credit.history or {}
        end
    elseif data.command == "get_loan_eligibility" then
        if not validateSession(data.username, relayAddress) then
            response.success = false
            response.message = "Session invalid"
        elseif not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Authentication failed"
        else
            local eligibility = getLoanEligibility(data.username)
            response.success = true
            response.eligible = eligibility.eligible
            response.maxLoan = eligibility.maxLoan
            response.interestRate = eligibility.interestRate
            response.creditScore = eligibility.creditScore
            response.creditRating, _ = getCreditRating(eligibility.creditScore)
            response.activeLoans = eligibility.activeLoans
            response.totalOwed = eligibility.totalOwed
        end
    elseif data.command == "apply_loan" then
        if not validateSession(data.username, relayAddress) then
            response.success = false
            response.message = "Session invalid"
        elseif not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Authentication failed"
        else
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
                    status = "pending"
                }
            else
                response.message = pendingIdOrMsg
            end
        end
    elseif data.command == "get_my_loans" then
        if not validateSession(data.username, relayAddress) then
            response.success = false
            response.message = "Session invalid"
        elseif not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Authentication failed"
        else
            local userLoanIds = loans[data.username] or {}
            local loanList = {}
            for _, loanId in ipairs(userLoanIds) do
                local loan = loanIndex[loanId]
                if loan then
                    table.insert(loanList, {loanId = loan.loanId, principal = loan.principal, remaining = loan.remaining, dueDate = loan.dueDate, status = loan.status})
                end
            end
            response.success = true
            response.loans = loanList
        end
    elseif data.command == "make_loan_payment" then
        if not validateSession(data.username, relayAddress) then
            response.success = false
            response.message = "Session invalid"
        elseif not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Authentication failed"
        else
            local ok, paidOrMsg, remaining = makeLoanPayment(data.username, data.loanId, data.amount)
            response.success = ok
            if ok then
                response.paid = paidOrMsg
                response.remaining = remaining
                response.balance = getAccount(data.username).balance
            else
                response.message = paidOrMsg
            end
        end
    elseif data.command == "get_pending_loans" then
        if not validateSession(data.username, relayAddress) then
            response.success = false
            response.message = "Session invalid"
        elseif not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Authentication failed"
        else
            local acc = getAccount(data.username)
            if not acc or not acc.isAdmin then
                response.success = false
                response.message = "Admin access required"
            else
                response.success = true
                response.pendingLoans = getPendingLoans()
            end
        end
    elseif data.command == "approve_loan" then
        if not validateSession(data.username, relayAddress) then
            response.success = false
            response.message = "Session invalid"
        elseif not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Authentication failed"
        else
            local acc = getAccount(data.username)
            if not acc or not acc.isAdmin then
                response.success = false
                response.message = "Admin access required"
            else
                local ok, loanIdOrMsg, loan = approveLoanApplication(data.pendingId, data.username)
                response.success = ok
                if ok then
                    response.loanId = loanIdOrMsg
                    response.message = "Loan approved"
                else
                    response.message = loanIdOrMsg
                end
            end
        end
    elseif data.command == "deny_loan" then
        if not validateSession(data.username, relayAddress) then
            response.success = false
            response.message = "Session invalid"
        elseif not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Authentication failed"
        else
            local acc = getAccount(data.username)
            if not acc or not acc.isAdmin then
                response.success = false
                response.message = "Admin access required"
            else
                local ok, msg = denyLoanApplication(data.pendingId, data.username, data.reason)
                response.success = ok
                response.message = msg
            end
        end
    elseif data.command == "list_accounts" then
        response.success = true
        response.accounts = {}
        for i = 1, math.min(50, #accounts) do
            local acc = accounts[i]
            local isOnline = activeSessions[acc.name] ~= nil
            table.insert(response.accounts, {name = acc.name, online = isOnline})
        end
        response.total = #accounts
    elseif data.command == "logout" then
        if not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Authentication failed"
        else
            endSession(data.username)
            local acc = getAccount(data.username)
            if acc then
                acc.online = false
                saveAccounts()
                log("Logout: " .. data.username, "AUTH")
            end
            response.success = true
            response.message = "Logged out successfully"
        end
    end
    modem.send(sender, PORT, serialization.serialize(response))
    if not adminMode then drawServerUI() end
end

-- Key press handler for admin mode
local function handleKeyPress(eventType, _, _, code)
    if code == 63 then
        if adminMode then
            adminMode = false
            adminAuthenticated = false
            drawServerUI()
            log("Admin mode exited", "ADMIN")
            while true do
                local e = {event.pull(0.1)}
                if e[1] == "key_up" and e[4] == 63 then break end
            end
        else
            while true do
                local e = {event.pull(0.1)}
                if e[1] == "key_up" and e[4] == 63 then break end
            end
            if adminLogin() then
                while adminMode do
                    local choice = adminMainMenu()
                    if choice == string.byte('1') then adminCreateAccountUI()
                    elseif choice == string.byte('2') then adminDeleteAccountUI()
                    elseif choice == string.byte('3') then adminSetBalanceUI()
                    elseif choice == string.byte('4') then adminLockUnlockUI()
                    elseif choice == string.byte('5') then adminResetPasswordUI()
                    elseif choice == string.byte('6') then adminViewAllAccountsUI()
                    elseif choice == string.byte('7') then adminViewAllLoansUI()
                    elseif choice == string.byte('8') then adminViewLockedAccountsUI()
                    elseif choice == string.byte('9') then adminForgiveLoanUI()
                    elseif choice == string.byte('a') or choice == string.byte('A') then adminAdjustCreditUI()
                    elseif choice == string.byte('b') or choice == string.byte('B') then adminChangePasswordUI()
                    elseif choice == string.byte('c') or choice == string.byte('C') then adminViewRAIDUI()
                    elseif choice == string.byte('d') or choice == string.byte('D') then adminToggleAdminUI()
                    elseif choice == string.byte('0') then
                        adminMode = false
                        adminAuthenticated = false
                        log("Admin mode exited", "ADMIN")
                    end
                end
                drawServerUI()
            end
        end
    elseif code == 59 then
        if adminMode then
            adminMode = false
            adminAuthenticated = false
            drawServerUI()
            log("Admin mode exited via F1", "ADMIN")
        end
    end
end

-- Main server loop
local function main()
    print("Starting " .. SERVER_NAME .. " Server...")
    print("Mode: Wireless + Loans + Credit + Auto-Lock")
    print("Data directory: " .. DATA_DIR)
    detectRAID()
    if not loadConfig() then print("WARNING: Could not load config, using defaults") end
    print("Admin password hash loaded")
    if loadAccounts() then
        print("Loaded " .. stats.totalAccounts .. " accounts")
        if RAID_ENABLED then print("Data stored across " .. #RAID_DRIVES .. " RAID drives") end
    end
    loadCreditScores()
    loadLoans()
    loadPendingLoans()
    print("Loaded " .. (function() local count = 0 for _ in pairs(pendingLoans) do count = count + 1 end return count end)() .. " pending loan applications")
    modem.open(PORT)
    modem.setStrength(400)
    print("Listening on port " .. PORT)
    print("Wireless range: 400 blocks")
    event.listen("modem_message", handleMessage)
    event.listen("key_down", handleKeyPress)
    drawServerUI()
    log("Server started - loans and credit system enabled", "SYSTEM")
    print("Server running! Press F5 for admin panel")
    event.timer(3600, function() checkOverdueLoans() end, math.huge)
    event.timer(60, function()
        local now = computer.uptime()
        for address, relay in pairs(relays) do
            if now - relay.lastSeen > 120 then relays[address] = nil end
        end
        local currentTime = os.time()
        for username, session in pairs(activeSessions) do
            if currentTime - session.lastActivity > 1800 then
                endSession(username)
                local acc = getAccount(username)
                if acc then acc.online = false end
                log("Session timeout: " .. username, "SECURITY")
            end
        end
        for _, acc in ipairs(accounts) do acc.online = (activeSessions[acc.name] ~= nil) end
        saveAccounts()
        stats.relayCount = 0
        for _ in pairs(relays) do stats.relayCount = stats.relayCount + 1 end
        if not adminMode then drawServerUI() end
    end, math.huge)
    while true do os.sleep(1) end
end

local success, err = pcall(main)
if not success then print("Error: " .. tostring(err)) end
modem.close(PORT)
print("Server stopped")
