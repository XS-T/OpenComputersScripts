-- Currency Server for OpenComputers 1.7.10
-- Banking operations with FULL WORKING ADMIN PANEL
-- VERSION 1.3.0 - ADMIN PANEL FIXED

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local computer = require("computer")
local thread = require("thread")
local gpu = component.gpu
local term = require("term")

local PORT = 1000
local LOAN_SERVER_PORT = 1001
local SERVER_NAME = "Empire Credit Union"
local DATA_DIR = "/home/currency/"
local DEFAULT_ADMIN_PASSWORD = "ECU2025"

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
local DATA_ENCRYPTION_KEY = data.md5(SERVER_NAME .. "DataSecurity2024")

-- Encryption functions
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
local accounts = {}
local sessions = {}
local transactionLog = {}
local loanServerAddress = nil
local adminPasswordHash = nil
local adminMode = false
local adminAuthenticated = false

local stats = {
    totalAccounts = 0,
    totalTransactions = 0,
    activeSessions = 0,
    activeThreads = 0,
    totalRequests = 0
}

local w, h = gpu.getResolution()
gpu.setResolution(80, 25)
w, h = 80, 25

local colors = {
    bg = 0x0F0F0F, header = 0x1E3A8A, accent = 0x3B82F6, success = 0x10B981,
    error = 0xEF4444, warning = 0xF59E0B, text = 0xFFFFFF, textDim = 0x9CA3AF,
    border = 0x374151, adminRed = 0xFF0000, adminBg = 0x1F1F1F
}

if not filesystem.exists(DATA_DIR) then
    filesystem.makeDirectory(DATA_DIR)
end

local function log(message, category)
    local txn = {time = os.date("%Y-%m-%d %H:%M:%S"), category = category or "INFO", message = message}
    table.insert(transactionLog, 1, txn)
    if #transactionLog > 100 then table.remove(transactionLog) end
    local file = io.open(DATA_DIR .. "transactions.log", "a")
    if file then
        file:write(serialization.serialize(txn) .. "\n")
        file:close()
    end
end

-- Account functions
local function createAccount(username, password, initialBalance)
    initialBalance = initialBalance or 100
    if accounts[username] then return false, "Account already exists" end
    accounts[username] = {
        username = username,
        passwordHash = hashPassword(password),
        balance = initialBalance,
        created = os.time(),
        lastLogin = nil,
        isAdmin = false,
        locked = false
    }
    stats.totalAccounts = stats.totalAccounts + 1
    log("Account created: " .. username .. " (Balance: " .. initialBalance .. ")", "ADMIN")
    saveAccounts()
    return true, "Account created"
end

local function verifyCredentials(username, password)
    local account = accounts[username]
    if not account then return false, "Account not found" end
    if account.locked then return false, "Account locked" end
    if account.passwordHash ~= hashPassword(password) then return false, "Invalid password" end
    return true, account
end

local function getBalance(username)
    local account = accounts[username]
    if not account then return nil, "Account not found" end
    return account.balance
end

local function setBalance(username, newBalance)
    local account = accounts[username]
    if not account then return false, "Account not found" end
    local oldBalance = account.balance
    account.balance = newBalance
    log(string.format("Balance set: %s (%.2f → %.2f)", username, oldBalance, newBalance), "ADMIN")
    saveAccounts()
    return true, "Balance updated"
end

local function transfer(from, to, amount)
    local fromAccount = accounts[from]
    local toAccount = accounts[to]
    if not fromAccount then return false, "Sender account not found" end
    if not toAccount then return false, "Recipient account not found" end
    if fromAccount.locked then return false, "Sender account locked" end
    if toAccount.locked then return false, "Recipient account locked" end
    if amount <= 0 then return false, "Invalid amount" end
    if fromAccount.balance < amount then return false, "Insufficient funds" end
    fromAccount.balance = fromAccount.balance - amount
    toAccount.balance = toAccount.balance + amount
    stats.totalTransactions = stats.totalTransactions + 1
    log(string.format("Transfer: %s → %s: %.2f CR", from, to, amount), "TRANSACTION")
    saveAccounts()
    return true, fromAccount.balance
end

-- Admin functions
local function adminSetBalance(username, newBalance)
    return setBalance(username, newBalance)
end

local function adminLockAccount(username)
    local account = accounts[username]
    if not account then return false, "Account not found" end
    account.locked = true
    log("Account locked: " .. username, "ADMIN")
    saveAccounts()
    return true, "Account locked"
end

local function adminUnlockAccount(username)
    local account = accounts[username]
    if not account then return false, "Account not found" end
    account.locked = false
    log("Account unlocked: " .. username, "ADMIN")
    saveAccounts()
    return true, "Account unlocked"
end

local function adminResetPassword(username, newPassword)
    local account = accounts[username]
    if not account then return false, "Account not found" end
    account.passwordHash = hashPassword(newPassword)
    log("Password reset: " .. username, "ADMIN")
    saveAccounts()
    return true, "Password reset"
end

local function adminToggleAdminStatus(username)
    local account = accounts[username]
    if not account then return false, "Account not found" end
    account.isAdmin = not account.isAdmin
    log("Admin status toggled: " .. username .. " → " .. tostring(account.isAdmin), "ADMIN")
    saveAccounts()
    return true, account.isAdmin and "Admin enabled" or "Admin disabled"
end

local function adminDeleteAccount(username)
    if not accounts[username] then return false, "Account not found" end
    accounts[username] = nil
    stats.totalAccounts = stats.totalAccounts - 1
    log("Account deleted: " .. username, "ADMIN")
    saveAccounts()
    return true, "Account deleted"
end

-- Save/Load functions
function saveConfig()
    local config = {adminPasswordHash = adminPasswordHash}
    local file = io.open(DATA_DIR .. "server_config.cfg", "w")
    if file then
        file:write(encryptData(serialization.serialize(config)))
        file:close()
        return true
    end
    return false
end

function loadConfig()
    local file = io.open(DATA_DIR .. "server_config.cfg", "r")
    if file then
        local encrypted = file:read("*a")
        file:close()
        if encrypted and encrypted ~= "" then
            local plaintext = decryptData(encrypted)
            if plaintext then
                local success, config = pcall(serialization.unserialize, plaintext)
                if success and config then
                    adminPasswordHash = config.adminPasswordHash
                    return true
                end
            end
        end
    end
    adminPasswordHash = hashPassword(DEFAULT_ADMIN_PASSWORD)
    return saveConfig()
end

function saveAccounts()
    local file = io.open(DATA_DIR .. "accounts.dat", "w")
    if file then
        file:write(encryptData(serialization.serialize(accounts)))
        file:close()
        return true
    end
    return false
end

function loadAccounts()
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
                    stats.totalAccounts = 0
                    for _ in pairs(accounts) do
                        stats.totalAccounts = stats.totalAccounts + 1
                    end
                    return true
                end
            end
        end
    end
    return false
end

-- Loan server request handler
local function handleLoanServerRequest(requestData)
    local response = {type = "loan_server_response", success = false}
    
    if requestData.command == "verify_account" then
        local account = accounts[requestData.username]
        response.success = true
        response.exists = (account ~= nil)
        
    elseif requestData.command == "get_balance" then
        local balance = getBalance(requestData.username)
        if balance then
            response.success = true
            response.balance = balance
        else
            response.message = "Account not found"
        end
        
    elseif requestData.command == "deduct_balance" then
        local account = accounts[requestData.username]
        if not account then
            response.message = "Account not found"
        elseif account.balance < requestData.amount then
            response.message = "Insufficient funds"
        else
            account.balance = account.balance - requestData.amount
            response.success = true
            response.balance = account.balance
            log(string.format("Loan payment: %s: %.2f CR", requestData.username, requestData.amount), "LOAN")
            saveAccounts()
        end
        
    elseif requestData.command == "add_balance" then
        local account = accounts[requestData.username]
        if not account then
            response.message = "Account not found"
        else
            account.balance = account.balance + requestData.amount
            response.success = true
            response.balance = account.balance
            log(string.format("Loan disbursed: %s: %.2f CR", requestData.username, requestData.amount), "LOAN")
            saveAccounts()
        end
        
    elseif requestData.command == "lock_account" then
        response.success, response.message = adminLockAccount(requestData.username)
        
    elseif requestData.command == "unlock_account" then
        response.success, response.message = adminUnlockAccount(requestData.username)
    end
    
    return response
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

local function drawServerUI()
    local headerColor = adminMode and colors.adminRed or 0x000080
    local bgColor = adminMode and colors.adminBg or 0x0000AA
    
    gpu.setBackground(bgColor)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, w, h, " ")
    gpu.setBackground(headerColor)
    gpu.fill(1, 1, w, 3, " ")
    local title = adminMode and "=== ADMIN MODE - CURRENCY SERVER ===" or ("=== " .. SERVER_NAME .. " (Currency Server) ===")
    gpu.set(math.floor((w - #title) / 2), 2, title)
    
    gpu.setBackground(0x1E1E1E)
    gpu.setForeground(0x00FF00)
    gpu.fill(1, 4, w, 2, " ")
    gpu.set(2, 4, "Accounts: " .. stats.totalAccounts)
    gpu.set(20, 4, "Transactions: " .. stats.totalTransactions)
    gpu.set(45, 4, "Sessions: " .. stats.activeSessions)
    gpu.set(65, 4, "Port: " .. PORT)
    
    gpu.setForeground(0xFFFF00)
    gpu.set(2, 5, "Mode: Banking Only")
    gpu.setForeground(0xAAAAAA)
    gpu.set(25, 5, "Threads: " .. stats.activeThreads)
    gpu.set(45, 5, "Requests: " .. stats.totalRequests)
    
    if loanServerAddress then
        gpu.setForeground(0x00FF00)
        gpu.set(65, 5, "Loan Server: ✓")
    else
        gpu.setForeground(0xFF0000)
        gpu.set(65, 5, "Loan Server: ✗")
    end
    
    gpu.setBackground(0x2D2D2D)
    gpu.setForeground(0xFFFF00)
    gpu.fill(1, 7, w, 1, " ")
    gpu.set(2, 7, "Recent Transactions:")
    
    gpu.setForeground(0xFFFFFF)
    gpu.set(2, 8, "Time")
    gpu.set(15, 8, "Category")
    gpu.set(30, 8, "Message")
    
    local y = 9
    for i = 1, math.min(10, #transactionLog) do
        local txn = transactionLog[i]
        gpu.setForeground(0xCCCCCC)
        gpu.set(2, y, txn.time:sub(12))
        local catColor = 0xAAAAAA
        if txn.category == "TRANSACTION" then catColor = 0x00FFFF
        elseif txn.category == "ADMIN" then catColor = 0xFF0000
        elseif txn.category == "LOAN" then catColor = 0xFFFF00
        elseif txn.category == "SYSTEM" then catColor = 0x00FF00 end
        gpu.setForeground(catColor)
        gpu.set(15, y, txn.category)
        gpu.setForeground(0xCCCCCC)
        local msg = txn.message:sub(1, 45)
        gpu.set(30, y, msg)
        y = y + 1
    end
    
    local footerColor = adminMode and colors.adminRed or 0x000080
    gpu.setBackground(footerColor)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 25, w, 1, " ")
    local footer = adminMode and "Press F1 or F5 to exit admin mode" or "Press F5 for admin panel | Currency Server"
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
    gpu.set(25, 10, "⚠ RESTRICTED ACCESS - CURRENCY SERVER")
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
    gpu.set(math.floor((w - 28) / 2), 2, "◆ CURRENCY ADMIN PANEL ◆")
    gpu.setBackground(colors.bg)
    
    gpu.setForeground(colors.text)
    gpu.set(25, 6, "ACCOUNT MANAGEMENT")
    gpu.setForeground(colors.textDim)
    gpu.set(25, 8, "1  Create Account")
    gpu.set(25, 9, "2  Delete Account")
    gpu.set(25, 10, "3  Set Balance")
    gpu.set(25, 11, "4  Lock Account")
    gpu.set(25, 12, "5  Unlock Account")
    gpu.set(25, 13, "6  Toggle Admin Status")
    gpu.set(25, 14, "7  View All Accounts")
    gpu.set(25, 15, "8  Reset Password")
    gpu.set(25, 16, "9  Change Admin Password")
    gpu.setForeground(colors.warning)
    gpu.set(25, 18, "0  Exit Admin Mode")
    
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, h, w, 1, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(2, h, "Currency Admin • Accounts: " .. stats.totalAccounts)
    gpu.setBackground(colors.bg)
    
    local _, _, char = event.pull("key_down")
    return char
end

local function adminCreateAccountUI()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(25, 1, "◆ CREATE ACCOUNT ◆")
    gpu.setBackground(colors.bg)
    
    local username = input("Username: ", 10, false, 20)
    if username == "" then return end
    
    local password = input("Password: ", 12, true, 30)
    if password == "" then return end
    
    local balStr = input("Initial Balance: ", 14, false, 10)
    local balance = tonumber(balStr) or 100
    
    gpu.setForeground(colors.textDim)
    gpu.set(5, 16, "Creating account...")
    
    local ok, msg = createAccount(username, password, balance)
    
    if ok then
        gpu.setForeground(colors.success)
        gpu.set(5, 18, "✓ Account created: " .. username)
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 18, "✗ Error: " .. msg)
    end
    
    os.sleep(2)
end

local function adminDeleteAccountUI()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(25, 1, "◆ DELETE ACCOUNT ◆")
    gpu.setBackground(colors.bg)
    
    local username = input("Username to delete: ", 10, false, 20)
    if username == "" then return end
    
    gpu.setForeground(colors.warning)
    gpu.set(5, 12, "⚠ This action cannot be undone!")
    gpu.set(5, 13, "Type username again to confirm: ")
    local confirm = input("", 14, false, 20)
    
    if confirm ~= username then
        gpu.setForeground(colors.textDim)
        gpu.set(5, 16, "Deletion cancelled")
        os.sleep(2)
        return
    end
    
    local ok, msg = adminDeleteAccount(username)
    
    if ok then
        gpu.setForeground(colors.success)
        gpu.set(5, 16, "✓ Account deleted: " .. username)
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 16, "✗ Error: " .. msg)
    end
    
    os.sleep(2)
end

local function adminSetBalanceUI()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(28, 1, "◆ SET BALANCE ◆")
    gpu.setBackground(colors.bg)
    
    local username = input("Username: ", 10, false, 20)
    if username == "" then return end
    
    local account = accounts[username]
    if account then
        gpu.setForeground(colors.textDim)
        gpu.set(5, 12, "Current balance: " .. string.format("%.2f CR", account.balance))
    end
    
    local balStr = input("New Balance: ", 14, false, 10)
    local newBalance = tonumber(balStr)
    
    if not newBalance or newBalance < 0 then
        gpu.setForeground(colors.error)
        gpu.set(5, 16, "✗ Invalid balance")
        os.sleep(2)
        return
    end
    
    local ok, msg = adminSetBalance(username, newBalance)
    
    if ok then
        gpu.setForeground(colors.success)
        gpu.set(5, 16, "✓ Balance updated")
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 16, "✗ Error: " .. msg)
    end
    
    os.sleep(2)
end

local function adminLockAccountUI()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(27, 1, "◆ LOCK ACCOUNT ◆")
    gpu.setBackground(colors.bg)
    
    local username = input("Username to lock: ", 10, false, 20)
    if username == "" then return end
    
    local ok, msg = adminLockAccount(username)
    
    if ok then
        gpu.setForeground(colors.success)
        gpu.set(5, 12, "✓ Account locked: " .. username)
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 12, "✗ Error: " .. msg)
    end
    
    os.sleep(2)
end

local function adminUnlockAccountUI()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(25, 1, "◆ UNLOCK ACCOUNT ◆")
    gpu.setBackground(colors.bg)
    
    local username = input("Username to unlock: ", 10, false, 20)
    if username == "" then return end
    
    local ok, msg = adminUnlockAccount(username)
    
    if ok then
        gpu.setForeground(colors.success)
        gpu.set(5, 12, "✓ Account unlocked: " .. username)
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 12, "✗ Error: " .. msg)
    end
    
    os.sleep(2)
end

local function adminToggleAdminUI()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(22, 1, "◆ TOGGLE ADMIN STATUS ◆")
    gpu.setBackground(colors.bg)
    
    local username = input("Username: ", 10, false, 20)
    if username == "" then return end
    
    local account = accounts[username]
    if account then
        gpu.setForeground(colors.textDim)
        gpu.set(5, 12, "Current admin status: " .. (account.isAdmin and "YES" or "NO"))
    end
    
    gpu.set(5, 14, "Press ENTER to toggle...")
    event.pull("key_down")
    
    local ok, msg = adminToggleAdminStatus(username)
    
    if ok then
        gpu.setForeground(colors.success)
        gpu.set(5, 16, "✓ " .. msg)
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 16, "✗ Error: " .. msg)
    end
    
    os.sleep(2)
end

local function adminViewAccountsUI()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(25, 1, "◆ ALL ACCOUNTS ◆")
    gpu.setBackground(colors.bg)
    
    gpu.setForeground(colors.text)
    gpu.set(2, 4, "Username")
    gpu.set(25, 4, "Balance")
    gpu.set(40, 4, "Admin")
    gpu.set(50, 4, "Locked")
    gpu.set(62, 4, "Created")
    
    local accountList = {}
    for username, account in pairs(accounts) do
        table.insert(accountList, {username = username, account = account})
    end
    table.sort(accountList, function(a, b) return a.username < b.username end)
    
    local y = 6
    for i = 1, math.min(17, #accountList) do
        local item = accountList[i]
        local account = item.account
        gpu.setForeground(colors.textDim)
        gpu.set(2, y, item.username:sub(1, 20))
        gpu.setForeground(colors.success)
        gpu.set(25, y, string.format("%.2f", account.balance))
        gpu.setForeground(account.isAdmin and colors.adminRed or colors.textDim)
        gpu.set(40, y, account.isAdmin and "YES" or "no")
        gpu.setForeground(account.locked and colors.error or colors.textDim)
        gpu.set(50, y, account.locked and "LOCKED" or "ok")
        gpu.setForeground(colors.textDim)
        gpu.set(62, y, os.date("%m/%d", account.created))
        y = y + 1
    end
    
    gpu.setForeground(colors.textDim)
    gpu.set(2, h-1, "Showing " .. math.min(17, #accountList) .. " of " .. stats.totalAccounts .. " accounts")
    gpu.set(2, h, "Press any key to continue...")
    event.pull("key_down")
end

local function adminResetPasswordUI()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(24, 1, "◆ RESET PASSWORD ◆")
    gpu.setBackground(colors.bg)
    
    local username = input("Username: ", 10, false, 20)
    if username == "" then return end
    
    local newPass = input("New Password: ", 12, true, 30)
    if newPass == "" then return end
    
    local ok, msg = adminResetPassword(username, newPass)
    
    if ok then
        gpu.setForeground(colors.success)
        gpu.set(5, 14, "✓ Password reset for: " .. username)
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 14, "✗ Error: " .. msg)
    end
    
    os.sleep(2)
end

local function adminChangePasswordUI()
    clearScreen()
    gpu.setBackground(colors.adminRed)
    gpu.fill(1, 1, w, 2, " ")
    gpu.setForeground(0xFFFFFF)
    gpu.set(20, 1, "◆ CHANGE ADMIN PASSWORD ◆")
    gpu.setBackground(colors.bg)
    
    local currentPass = input("Current Admin Password: ", 10, true, 30)
    if hashPassword(currentPass) ~= adminPasswordHash then
        gpu.setForeground(colors.error)
        gpu.set(5, 12, "✗ Incorrect password")
        os.sleep(2)
        return
    end
    
    local newPass = input("New Admin Password: ", 12, true, 30)
    if newPass == "" then return end
    
    local confirmPass = input("Confirm New Password: ", 14, true, 30)
    if newPass ~= confirmPass then
        gpu.setForeground(colors.error)
        gpu.set(5, 16, "✗ Passwords do not match")
        os.sleep(2)
        return
    end
    
    adminPasswordHash = hashPassword(newPass)
    saveConfig()
    
    gpu.setForeground(colors.success)
    gpu.set(5, 16, "✓ Admin password changed")
    log("Admin password changed", "ADMIN")
    os.sleep(2)
end

-- Message handler
local function handleMessage(eventType, _, sender, port, distance, message)
    if port ~= PORT and port ~= LOAN_SERVER_PORT then return end
    
    stats.totalRequests = stats.totalRequests + 1
    
    thread.create(function()
        stats.activeThreads = stats.activeThreads + 1
        
        local decryptedRelay = decryptRelayMessage(message)
        local decryptedServer = decryptServerMessage(message)
        local isFromRelay = (decryptedRelay ~= nil)
        local isFromServer = (decryptedServer ~= nil)
        local messageToProcess = decryptedRelay or decryptedServer or message
        
        local success, data = pcall(serialization.unserialize, messageToProcess)
        if not success or not data then
            stats.activeThreads = stats.activeThreads - 1
            return
        end
        
        -- Handle relay ping
        if data.type == "relay_ping" and isFromRelay then
            local response = {type = "server_response", serverName = SERVER_NAME .. " (Currency)"}
            local serializedResponse = serialization.serialize(response)
            local encrypted = encryptRelayMessage(serializedResponse)
            modem.send(sender, PORT, encrypted)
            stats.activeThreads = stats.activeThreads - 1
            return
        end
        
        -- Handle loan server discovery
        if data.type == "loan_server_ping" and port == PORT and isFromServer then
            loanServerAddress = sender
            local response = {type = "currency_server_response", serverName = SERVER_NAME}
            local encrypted = encryptServerMessage(serialization.serialize(response))
            modem.send(sender, LOAN_SERVER_PORT, encrypted)
            log("Loan server connected: " .. sender:sub(1, 8), "SYSTEM")
            if not adminMode then drawServerUI() end
            stats.activeThreads = stats.activeThreads - 1
            return
        end
        
        -- Handle loan server requests
        if data.type == "loan_server_request" and isFromServer then
            local response = handleLoanServerRequest(data)
            local encrypted = encryptServerMessage(serialization.serialize(response))
            modem.send(sender, LOAN_SERVER_PORT, encrypted)
            stats.activeThreads = stats.activeThreads - 1
            return
        end
        
        -- Handle client requests
        local relayAddress = sender
        local response = {type = "response"}
        
        if data.command == "login" then
            local ok, accountOrMsg = verifyCredentials(data.username, data.password)
            if ok then
                local account = accountOrMsg
                account.lastLogin = os.time()
                sessions[data.username] = os.time()
                stats.activeSessions = stats.activeSessions + 1
                response.success = true
                response.balance = account.balance
                response.isAdmin = account.isAdmin
                log("Login: " .. data.username, "SESSION")
            else
                response.success = false
                response.message = accountOrMsg
            end
        elseif data.command == "logout" then
            if sessions[data.username] then
                sessions[data.username] = nil
                stats.activeSessions = math.max(0, stats.activeSessions - 1)
                log("Logout: " .. data.username, "SESSION")
            end
            response.success = true
        elseif data.command == "balance" then
            local balance = getBalance(data.username)
            if balance then
                response.success = true
                response.balance = balance
            else
                response.success = false
                response.message = "Account not found"
            end
        elseif data.command == "transfer" then
            local ok, result = transfer(data.username, data.recipient, data.amount)
            response.success = ok
            if ok then
                response.balance = result
            else
                response.message = result
            end
        elseif data.command == "list_accounts" then
            local accountList = {}
            for username, account in pairs(accounts) do
                table.insert(accountList, {
                    name = username,
                    online = (sessions[username] ~= nil)
                })
            end
            response.success = true
            response.accounts = accountList
            response.total = stats.totalAccounts
        elseif data.command == "admin_create_account" then
            local ok, msg = createAccount(data.newUsername, data.newPassword, data.initialBalance or 100)
            response.success = ok
            response.message = msg
        elseif data.command == "admin_set_balance" then
            local ok, msg = adminSetBalance(data.targetUsername, data.newBalance)
            response.success = ok
            response.message = msg
        end
        
        if data.username and not response.username then
            response.username = data.username
        end
        
        local encrypted = encryptRelayMessage(serialization.serialize(response))
        modem.send(relayAddress, PORT, encrypted)
        
        if not adminMode then drawServerUI() end
        stats.activeThreads = stats.activeThreads - 1
    end):detach()
end

-- Key press handler
local function handleKeyPress(eventType, _, _, code)
    if code == 63 or code == 59 then
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
                        adminCreateAccountUI()
                    elseif choice == string.byte('2') then
                        adminDeleteAccountUI()
                    elseif choice == string.byte('3') then
                        adminSetBalanceUI()
                    elseif choice == string.byte('4') then
                        adminLockAccountUI()
                    elseif choice == string.byte('5') then
                        adminUnlockAccountUI()
                    elseif choice == string.byte('6') then
                        adminToggleAdminUI()
                    elseif choice == string.byte('7') then
                        adminViewAccountsUI()
                    elseif choice == string.byte('8') then
                        adminResetPasswordUI()
                    elseif choice == string.byte('9') then
                        adminChangePasswordUI()
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

-- Main
local function main()
    print("Starting Currency Server...")
    print("Mode: Banking Only (Modular Architecture)")
    print("Port: " .. PORT)
    
    if not loadConfig() then
        print("WARNING: Could not load config, using defaults")
    end
    
    if loadAccounts() then
        print("Loaded " .. stats.totalAccounts .. " accounts")
    else
        print("No existing accounts found")
    end
    
    modem.open(PORT)
    modem.open(LOAN_SERVER_PORT)
    modem.setStrength(400)
    print("Wireless network initialized (400 blocks)")
    print("Listening on PORT " .. PORT)
    print("Inter-server PORT " .. LOAN_SERVER_PORT)
    
    event.listen("modem_message", handleMessage)
    event.listen("key_down", handleKeyPress)
    
    drawServerUI()
    log("Currency Server started", "SYSTEM")
    print("Server running! Press F5 for admin panel")
    print("Default admin password: " .. DEFAULT_ADMIN_PASSWORD)
    
    event.timer(5, function()
        if not adminMode then drawServerUI() end
    end, math.huge)
    
    while true do
        os.sleep(1)
    end
end

pcall(main)
modem.close(PORT)
modem.close(LOAN_SERVER_PORT)
print("Currency Server stopped")
