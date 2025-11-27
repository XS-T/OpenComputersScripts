-- Digital Currency Server with Loans & Credit Scores - COMPLETE
-- OpenComputers 1.7.10

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
local adminPasswordHash = nil

local w, h = gpu.getResolution()
gpu.setResolution(80, 25)
w, h = 80, 25

local colors = {
    bg = 0x0F0F0F, header = 0x1E3A8A, accent = 0x3B82F6,
    success = 0x10B981, error = 0xEF4444, warning = 0xF59E0B,
    text = 0xFFFFFF, textDim = 0x9CA3AF, border = 0x374151,
    inputBg = 0x1F2937, adminRed = 0xFF0000, adminBg = 0x1F1F1F,
    excellent = 0x10B981, good = 0x3B82F6, fair = 0xF59E0B, poor = 0xEF4444
}

if not filesystem.exists(DATA_DIR) then
    filesystem.makeDirectory(DATA_DIR)
end

local RAID_ENABLED = false
local RAID_DRIVES = {}
local MAX_FILE_SIZE = 100000
local RAID_REDUNDANCY = 2

if not component.isAvailable("data") then
    print("ERROR: Data card required!")
    return
end

local data = component.data
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

local function detectRAID()
    RAID_DRIVES = {}
    for address in component.list("filesystem") do
        local fs = component.proxy(address)
        if address ~= computer.getBootAddress() and not fs.isReadOnly() then
            local label = fs.getLabel() or ""
            if label:lower():find("raid") or label:lower():find("bank") then
                table.insert(RAID_DRIVES, {
                    address = address,
                    proxy = fs,
                    label = label,
                    space = fs.spaceTotal()
                })
            end
        end
    end
    RAID_ENABLED = #RAID_DRIVES >= RAID_REDUNDANCY
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
        end
        file:close()
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

local function createLoan(username, amount, termDays)
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
    local interest = amount * eligibility.interestRate
    local totalOwed = amount + interest
    local loanId = "LOAN" .. string.format("%06d", nextLoanId)
    nextLoanId = nextLoanId + 1
    local loan = {
        loanId = loanId,
        username = username,
        principal = amount,
        interestRate = eligibility.interestRate,
        interest = interest,
        totalOwed = totalOwed,
        remaining = totalOwed,
        termDays = termDays,
        issued = os.time(),
        dueDate = os.time() + (termDays * 86400),
        status = "active",
        payments = {},
        lateFees = 0
    }
    loanIndex[loanId] = loan
    if not loans[username] then loans[username] = {} end
    table.insert(loans[username], loanId)
    local acc = getAccount(username)
    if acc then
        acc.balance = acc.balance + amount
        saveAccounts()
    end
    recordCreditEvent(username, "loan_issued", string.format("Loan %s issued: %d CR", loanId, amount))
    stats.totalLoans = stats.totalLoans + 1
    stats.activeLoans = stats.activeLoans + 1
    log(string.format("Loan issued: %s to %s: %.2f CR @ %.1f%% for %d days", 
        loanId, username, amount, eligibility.interestRate * 100, termDays), "LOAN")
    saveLoans()
    saveConfig()
    return true, loanId, loan
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
    local accountsToLock = {}
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
                    table.insert(accountsToLock, {
                        username = loan.username,
                        loanId = loanId,
                        daysOverdue = daysOverdue
                    })
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
    return overdue, accountsToLock
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

local function createSession(username, relayAddress)
    if activeSessions[username] then return false, "Account already logged in" end
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
    if #username > 50 then return false, "Username too long" end
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
        locked = false
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

local function adminUnlockAccount(username, reason)
    local acc = getAccount(username)
    if not acc then return false, "Account not found" end
    if not acc.locked then return false, "Account is not locked" end
    acc.locked = false
    local previousReason = acc.lockReason
    acc.lockReason = nil
    acc.lockedDate = nil
    local unlockReason = reason or "Admin override"
    log(string.format("ADMIN: Account unlocked: %s (Reason: %s, Was: %s)", username, unlockReason, previousReason or "unknown"), "ADMIN")
    recordCreditEvent(username, "account_unlocked", string.format("Account unlocked by admin: %s", unlockReason))
    saveAccounts()
    saveCreditScores()
    return true, "Account unlocked", previousReason
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

local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    term.clear()
end

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
    gpu.set(2, 5, "Loans: " .. stats.activeLoans)
    gpu.setForeground(0xFFFF00)
    gpu.set(20, 5, "Mode: WIRELESS")
    if adminMode then
        gpu.setForeground(0xFF0000)
        gpu.set(65, 5, "[ADMIN]")
    end
    gpu.setBackground(adminMode and colors.adminRed or 0x000080)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 25, w, 1, " ")
    local footer = adminMode and "Press F5 to exit admin mode" or "Press F5 for admin panel"
    gpu.set(2, 25, footer)
end

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
                    log("Login: " .. data.username, "AUTH")
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
            local ok, loanIdOrMsg, loan = createLoan(data.username, data.amount, data.term)
            response.success = ok
            if ok then
                response.loanId = loanIdOrMsg
                response.balance = getAccount(data.username).balance
                response.loan = {
                    principal = loan.principal,
                    interest = loan.interest,
                    totalOwed = loan.totalOwed,
                    dueDate = loan.dueDate
                }
            else
                response.message = loanIdOrMsg
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

local function handleKeyPress(eventType, _, _, code)
    if code == 63 then
        if adminMode then
            adminMode = false
            drawServerUI()
        else
            adminMode = true
            drawServerUI()
        end
    end
end

local function main()
    print("Starting " .. SERVER_NAME .. " Server...")
    detectRAID()
    loadConfig()
    loadAccounts()
    loadCreditScores()
    loadLoans()
    modem.open(PORT)
    modem.setStrength(400)
    event.listen("modem_message", handleMessage)
    event.listen("key_down", handleKeyPress)
    drawServerUI()
    log("Server started", "SYSTEM")
    event.timer(3600, function() checkOverdueLoans() end, math.huge)
    while true do os.sleep(1) end
end

local success, err = pcall(main)
if not success then print("Error: " .. tostring(err)) end
modem.close(PORT)
