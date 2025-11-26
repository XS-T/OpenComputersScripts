-- Digital Currency Server with Admin Panel for OpenComputers 1.7.10
-- Integrated admin tools with password protection
-- Beautiful modern UI

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

-- Default admin password (will be hashed)
local DEFAULT_ADMIN_PASSWORD = "ECU2025"

-- Network components
local modem = component.modem

-- Data structures
local accounts = {}
local transactionLog = {}
local accountIndex = {}
local relays = {}
local activeSessions = {}
local stats = {
    totalAccounts = 0,
    totalTransactions = 0,
    activeSessions = 0,
    relayCount = 0
}

-- UI State
local adminMode = false
local adminAuthenticated = false
local selectedAccount = nil
local adminPasswordHash = nil

-- Screen setup
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
    adminRed = 0xFF0000,
    adminBg = 0x1F1F1F
}

-- Initialize data directory
if not filesystem.exists(DATA_DIR) then
    filesystem.makeDirectory(DATA_DIR)
end

-- RAID Configuration
local RAID_ENABLED = false
local RAID_DRIVES = {}
local MAX_FILE_SIZE = 100000 -- 100KB per chunk for RAID split
local RAID_REDUNDANCY = 2 -- Number of copies per chunk

-- Check for data card
if not component.isAvailable("data") then
    print("ERROR: Data card required for encryption!")
    print("Please install a Tier 2 or Tier 3 Data Card")
    return
end

local data = component.data

-- Detect RAID drives
local function detectRAID()
    RAID_DRIVES = {}
    
    -- Scan all filesystem components (this is what 'df' uses)
    for address in component.list("filesystem") do
        local fs = component.proxy(address)
        
        -- Skip boot drive and read-only drives
        if address ~= computer.getBootAddress() and not fs.isReadOnly() then
            local label = fs.getLabel() or ""
            
            -- Check if label contains "raid" or "bank" (case insensitive)
            -- This matches exactly what 'df' shows in the filesystem column
            if label:lower():find("raid") or label:lower():find("bank") then
                local shortAddr = address:sub(1, 3)
                
                -- Try to determine mount point
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
        if #RAID_DRIVES > 0 then
            print("Found drives but need more:")
            for i, drive in ipairs(RAID_DRIVES) do
                print("  " .. i .. ". " .. drive.label)
            end
        end
    end
end

-- Encryption key for database (generated from server name + salt)
local ENCRYPTION_KEY = data.md5(SERVER_NAME .. "BankingSecurity2024")

-- Encryption functions using data card
local function hashPassword(password)
    if not password or password == "" then
        return nil
    end
    return data.md5(password)
end

local function encryptData(plaintext)
    if not plaintext or plaintext == "" then
        return nil
    end
    -- Use AES encryption with our key
    local iv = data.random(16) -- 16 byte initialization vector
    local encrypted = data.encrypt(plaintext, ENCRYPTION_KEY, iv)
    -- Combine IV and encrypted data (IV needed for decryption)
    return data.encode64(iv .. encrypted)
end

local function decryptData(ciphertext)
    if not ciphertext or ciphertext == "" then
        return nil
    end
    
    local success, result = pcall(function()
        -- Decode from base64
        local combined = data.decode64(ciphertext)
        -- Extract IV (first 16 bytes) and encrypted data
        local iv = combined:sub(1, 16)
        local encrypted = combined:sub(17)
        -- Decrypt
        return data.decrypt(encrypted, ENCRYPTION_KEY, iv)
    end)
    
    if success then
        return result
    else
        return nil
    end
end

-- RAID Functions
local function splitData(data, chunkSize)
    local chunks = {}
    local pos = 1
    local chunkNum = 1
    
    while pos <= #data do
        local chunk = data:sub(pos, pos + chunkSize - 1)
        table.insert(chunks, {
            id = chunkNum,
            data = chunk,
            checksum = data.md5(chunk)
        })
        pos = pos + chunkSize
        chunkNum = chunkNum + 1
    end
    
    return chunks
end

local function saveToRAID(filename, content)
    if not RAID_ENABLED or #content < MAX_FILE_SIZE then
        -- Use normal save for small files or when RAID disabled
        return false
    end
    
    -- Split data into chunks
    local chunks = splitData(content, MAX_FILE_SIZE)
    
    -- Create metadata
    local metadata = {
        filename = filename,
        totalChunks = #chunks,
        timestamp = os.time(),
        checksum = data.md5(content)
    }
    
    -- Save metadata to primary drive
    local metaFile = io.open(DATA_DIR .. filename .. ".meta", "w")
    if metaFile then
        metaFile:write(serialization.serialize(metadata))
        metaFile:close()
    else
        return false
    end
    
    -- Distribute chunks across RAID drives with redundancy
    for i, chunk in ipairs(chunks) do
        local chunkData = serialization.serialize(chunk)
        
        -- Save to multiple drives for redundancy
        local savedCount = 0
        for j = 1, RAID_REDUNDANCY do
            local driveIndex = ((i - 1 + (j - 1)) % #RAID_DRIVES) + 1
            local drive = RAID_DRIVES[driveIndex]
            
            local success, err = pcall(function()
                local chunkPath = "/" .. filename .. ".chunk" .. i .. ".copy" .. j
                
                -- Use /mnt/ path if available, otherwise use proxy directly
                if drive.path then
                    -- Mounted drive - use filesystem API
                    local fullPath = drive.path .. chunkPath
                    local file = io.open(fullPath, "w")
                    if file then
                        file:write(chunkData)
                        file:close()
                        savedCount = savedCount + 1
                    end
                else
                    -- Component proxy
                    local file = drive.proxy.open(chunkPath, "w")
                    if file then
                        drive.proxy.write(file, chunkData)
                        drive.proxy.close(file)
                        savedCount = savedCount + 1
                    end
                end
            end)
            
            if not success then
                print("Warning: Failed to save chunk " .. i .. " to drive " .. drive.label)
            end
        end
        
        if savedCount == 0 then
            return false -- Failed to save chunk
        end
    end
    
    return true
end

local function loadFromRAID(filename)
    if not RAID_ENABLED then
        return nil
    end
    
    -- Load metadata
    local metaFile = io.open(DATA_DIR .. filename .. ".meta", "r")
    if not metaFile then
        return nil
    end
    
    local metaData = metaFile:read("*a")
    metaFile:close()
    
    local success, metadata = pcall(serialization.unserialize, metaData)
    if not success or not metadata then
        return nil
    end
    
    -- Reconstruct data from chunks
    local chunks = {}
    for i = 1, metadata.totalChunks do
        local chunkLoaded = false
        
        -- Try to load from any redundant copy
        for j = 1, RAID_REDUNDANCY do
            local driveIndex = ((i - 1 + (j - 1)) % #RAID_DRIVES) + 1
            local drive = RAID_DRIVES[driveIndex]
            
            local success, result = pcall(function()
                local chunkPath = "/" .. filename .. ".chunk" .. i .. ".copy" .. j
                local chunkData
                
                -- Use /mnt/ path if available, otherwise use proxy directly
                if drive.path then
                    -- Mounted drive - use filesystem API
                    local fullPath = drive.path .. chunkPath
                    local file = io.open(fullPath, "r")
                    if file then
                        chunkData = file:read("*a")
                        file:close()
                    end
                else
                    -- Component proxy
                    local file = drive.proxy.open(chunkPath, "r")
                    if file then
                        local size = drive.proxy.size(chunkPath)
                        chunkData = drive.proxy.read(file, size)
                        drive.proxy.close(file)
                    end
                end
                
                if chunkData then
                    local chunk = serialization.unserialize(chunkData)
                    
                    -- Verify checksum
                    if chunk and data.md5(chunk.data) == chunk.checksum then
                        chunks[i] = chunk
                        chunkLoaded = true
                        return true
                    end
                end
                return false
            end)
            
            if success and result and chunkLoaded then
                break -- Successfully loaded chunk
            end
        end
        
        if not chunkLoaded then
            print("Error: Failed to load chunk " .. i)
            return nil
        end
    end
    
    -- Combine chunks
    local content = ""
    for i = 1, metadata.totalChunks do
        if chunks[i] then
            content = content .. chunks[i].data
        else
            return nil
        end
    end
    
    -- Verify final checksum
    if data.md5(content) ~= metadata.checksum then
        print("Error: Data corruption detected!")
        return nil
    end
    
    return content
end

-- Config functions
local function saveConfig()
    local config = {
        adminPasswordHash = adminPasswordHash,
        lastModified = os.time()
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
                    return true
                end
            end
        end
    end
    
    -- Create default config
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
    if not session then
        return false
    end
    
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
    
    if not encrypted then
        return false
    end
    
    -- Try RAID first if enabled and data is large
    if RAID_ENABLED and #encrypted > MAX_FILE_SIZE then
        if saveToRAID("accounts.dat", encrypted) then
            return true
        else
            print("Warning: RAID save failed, falling back to single file")
        end
    end
    
    -- Fallback to regular file save
    local file = io.open(DATA_DIR .. "accounts.dat", "w")
    if file then
        file:write(encrypted)
        file:close()
        return true
    end
    
    return false
end

local function loadAccounts()
    -- Try RAID first if enabled
    if RAID_ENABLED then
        local encrypted = loadFromRAID("accounts.dat")
        if encrypted then
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
    
    -- Fallback to regular file
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

local function log(message, category)
    category = category or "INFO"
    local txn = {
        time = os.date("%Y-%m-%d %H:%M:%S"),
        category = category,
        message = message
    }
    
    table.insert(transactionLog, 1, txn)
    if #transactionLog > 100 then
        table.remove(transactionLog)
    end
    
    local file = io.open(DATA_DIR .. "transactions.log", "a")
    if file then
        file:write(serialization.serialize(txn) .. "\n")
        file:close()
    end
    
    stats.totalTransactions = stats.totalTransactions + 1
end

-- Account management
local function getAccount(username)
    local idx = accountIndex[username]
    if idx then
        return accounts[idx], idx
    end
    return nil, nil
end

local function verifyPassword(username, password)
    local acc = getAccount(username)
    if not acc or not acc.passwordHash then
        return false
    end
    
    return acc.passwordHash == hashPassword(password)
end

local function createAccount(username, password, initialBalance, relayAddress)
    -- Validate username
    if not username or username == "" then
        return false, "Username cannot be empty"
    end
    
    if #username > 50 then
        return false, "Username too long (max 50 characters)"
    end
    
    if accountIndex[username] then
        return false, "Account already exists"
    end
    
    if not password or password == "" then
        return false, "Password cannot be empty"
    end
    
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
    
    log("New account: " .. username .. " (Balance: " .. initialBalance .. ")", "ACCOUNT")
    saveAccounts()
    return true, "Account created successfully", account
end

local function deleteAccount(username)
    local acc, idx = getAccount(username)
    if not acc then
        return false, "Account not found"
    end
    
    -- End session if active
    endSession(username)
    
    -- Remove from accounts
    table.remove(accounts, idx)
    
    -- Rebuild index
    accountIndex = {}
    for i, a in ipairs(accounts) do
        accountIndex[a.name] = i
    end
    
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
    
    log("ADMIN: Account unlocked: " .. username, "ADMIN")
    saveAccounts()
    return true, "Account unlocked"
end

local function adminResetPassword(username, newPassword)
    local acc = getAccount(username)
    if not acc then return false, "Account not found" end
    
    if not newPassword or newPassword == "" then
        return false, "Password cannot be empty"
    end
    
    acc.passwordHash = hashPassword(newPassword)
    
    log("ADMIN: Password reset for " .. username, "ADMIN")
    saveAccounts()
    return true, "Password reset"
end

-- Relay management
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

-- UI Drawing Functions
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

local function drawBox(x, y, width, height, color)
    gpu.setBackground(color or colors.bg)
    gpu.fill(x, y, width, height, " ")
end

-- Main Server UI
local function drawServerUI()
    gpu.setBackground(adminMode and colors.adminBg or 0x0000AA)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, w, h, " ")
    
    -- Header
    gpu.setBackground(adminMode and colors.adminRed or 0x000080)
    gpu.fill(1, 1, w, 3, " ")
    local title = adminMode and "=== ADMIN MODE ===" or ("=== " .. SERVER_NAME .. " ===")
    gpu.set(math.floor((w - #title) / 2), 2, title)
    
    -- Stats panel
    gpu.setBackground(0x1E1E1E)
    gpu.setForeground(0x00FF00)
    gpu.fill(1, 4, w, 2, " ")
    gpu.set(2, 4, "Accounts: " .. stats.totalAccounts)
    gpu.set(20, 4, "Transactions: " .. stats.totalTransactions)
    gpu.set(45, 4, "Sessions: " .. stats.activeSessions)
    gpu.set(65, 4, "Port: " .. PORT)
    
    gpu.set(2, 5, "Relays: " .. stats.relayCount)
    gpu.setForeground(0xFFFF00)
    gpu.set(20, 5, "Mode: WIRELESS")
    
    if RAID_ENABLED then
        gpu.setForeground(0x00FF00)
        gpu.set(40, 5, "RAID: " .. #RAID_DRIVES .. " drives")
    end
    
    if adminMode then
        gpu.setForeground(0xFF0000)
        gpu.set(65, 5, "[ADMIN]")
    end
    
    if not adminMode then
        -- Show relays
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
        for _, relay in pairs(relays) do
            table.insert(relayList, relay)
        end
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
        
        -- Accounts list
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
        for _, acc in ipairs(accounts) do
            table.insert(sortedAccounts, acc)
        end
        table.sort(sortedAccounts, function(a, b) 
            return (a.lastActivity or 0) > (b.lastActivity or 0)
        end)
        
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
    
    -- Recent transactions
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
        end
        
        gpu.setForeground(color)
        local msg = "[" .. entry.time:sub(12) .. "] " .. entry.message
        gpu.set(2, y, msg:sub(1, 76))
        y = y + 1
    end
    
    -- Footer
    gpu.setBackground(adminMode and colors.adminRed or 0x000080)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 25, w, 1, " ")
    local footer = adminMode and "Press F1 or F5 to exit admin mode" or "Press F5 for admin panel"
    gpu.set(2, 25, footer)
end

-- Admin Panel Functions
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
    
    drawBox(15, 6, 50, 16, colors.bg)
    
    gpu.setForeground(colors.adminRed)
    gpu.set(17, 7, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    gpu.setForeground(colors.textDim)
    gpu.set(17, 8, "  Administrative Tools")
    gpu.setForeground(colors.adminRed)
    gpu.set(17, 9, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    gpu.setForeground(colors.text)
    gpu.set(20, 12, "1  Create Account")
    gpu.set(20, 13, "2  Delete Account")
    gpu.set(20, 14, "3  Set Balance")
    gpu.set(20, 15, "4  Lock/Unlock Account")
    gpu.set(20, 16, "5  Reset Password")
    gpu.set(20, 17, "6  View All Accounts")
    gpu.set(20, 18, "7  Change Admin Password")
    gpu.set(20, 19, "8  View RAID Drives")
    gpu.set(20, 20, "9  Exit Admin Mode")
    
    drawFooter("Admin Tools • Authenticated")
    
    local _, _, char = event.pull("key_down")
    return char
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
    for i = 1, 76 do
        gpu.set(2 + i, 6, "─")
    end
    
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

-- Network message handler
local function handleMessage(eventType, _, sender, port, distance, message)
    if port ~= PORT then return end
    
    local success, data = pcall(serialization.unserialize, message)
    if not success or not data then return end
    
    -- Handle relay ping
    if data.type == "relay_ping" then
        registerRelay(sender, data.relay_name or "Unknown")
        
        local response = {
            type = "server_response",
            serverName = SERVER_NAME
        }
        modem.send(sender, PORT, serialization.serialize(response))
        if not adminMode then drawServerUI() end
        return
    end
    
    -- Handle relay heartbeat
    if data.type == "relay_heartbeat" then
        registerRelay(sender, data.relay_name or "Unknown")
        if relays[sender] and data.clients then
            relays[sender].clients = data.clients
        end
        if not adminMode then drawServerUI() end
        return
    end
    
    -- All other messages come from relays with client info
    local relayAddress = sender
    
    local response = {type = "response"}
    
    -- Command routing
    if data.command == "login" then
        if not verifyPassword(data.username, data.password) then
            response.success = false
            response.message = "Invalid username or password"
        else
            local acc = getAccount(data.username)
            if acc.locked then
                response.success = false
                response.message = "Account is locked"
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
        
    elseif data.command == "list_accounts" then
        response.success = true
        response.accounts = {}
        for i = 1, math.min(50, #accounts) do
            local acc = accounts[i]
            local isOnline = activeSessions[acc.name] ~= nil
            table.insert(response.accounts, {
                name = acc.name,
                online = isOnline
            })
        end
        response.total = #accounts
        
    elseif data.command == "logout" then
        -- Verify password before allowing logout
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
    
    if not adminMode then
        drawServerUI()
    end
end

-- Key press handler for admin mode
local function handleKeyPress(eventType, _, _, code)
    if code == 63 then -- F5 key - Toggle admin mode
        if adminMode then
            -- Exit admin mode (no password needed)
            adminMode = false
            adminAuthenticated = false
            drawServerUI()
            log("Admin mode exited", "ADMIN")
            
            -- Wait for key release
            while true do
                local e = {event.pull(0.1)}
                if e[1] == "key_up" and e[4] == 63 then
                    break
                end
            end
        else
            -- Wait for F5 key to be released before entering admin mode
            while true do
                local e = {event.pull(0.1)}
                if e[1] == "key_up" and e[4] == 63 then
                    break
                end
            end
            
            -- Enter admin mode
            if adminLogin() then
                -- Admin panel loop
                while adminMode do
                    local choice = adminMainMenu()
                    
                    if choice == string.byte('1') then
                        adminCreateAccountUI()
                    elseif choice == string.byte('2') then
                        adminDeleteAccountUI()
                    elseif choice == string.byte('3') then
                        adminSetBalanceUI()
                    elseif choice == string.byte('4') then
                        adminLockUnlockUI()
                    elseif choice == string.byte('5') then
                        adminResetPasswordUI()
                    elseif choice == string.byte('6') then
                        adminViewAllAccountsUI()
                    elseif choice == string.byte('7') then
                        adminChangePasswordUI()
                    elseif choice == string.byte('8') then
                        adminViewRAIDUI()
                    elseif choice == string.byte('9') then
                        adminMode = false
                        adminAuthenticated = false
                        log("Admin mode exited", "ADMIN")
                    end
                end
                
                drawServerUI()
            end
        end
    elseif code == 59 then -- F1 key - Return to normal mode (no password needed)
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
    print("Mode: Wireless (no encryption)")
    print("Data directory: " .. DATA_DIR)
    
    -- Detect RAID configuration
    detectRAID()
    
    -- Load config
    if not loadConfig() then
        print("WARNING: Could not load config, using defaults")
    end
    print("Admin password hash loaded")
    
    if loadAccounts() then
        print("Loaded " .. stats.totalAccounts .. " accounts")
        if RAID_ENABLED then
            print("Data stored across " .. #RAID_DRIVES .. " RAID drives")
        end
    end
    
    modem.open(PORT)
    modem.setStrength(400)
    print("Listening on port " .. PORT)
    print("Wireless range: 400 blocks")
    
    event.listen("modem_message", handleMessage)
    event.listen("key_down", handleKeyPress)
    
    drawServerUI()
    
    log("Server started - wireless mode", "SYSTEM")
    print("Server running! Press F5 for admin panel")
    
    -- Maintenance timer
    event.timer(60, function()
        -- Cleanup old relays
        local now = computer.uptime()
        for address, relay in pairs(relays) do
            if now - relay.lastSeen > 120 then
                relays[address] = nil
            end
        end
        
        -- Cleanup stale sessions (30 minute timeout)
        local currentTime = os.time()
        for username, session in pairs(activeSessions) do
            if currentTime - session.lastActivity > 1800 then
                endSession(username)
                local acc = getAccount(username)
                if acc then
                    acc.online = false
                end
                log("Session timeout: " .. username, "SECURITY")
            end
        end
        
        -- Update online status based on active sessions
        for _, acc in ipairs(accounts) do
            acc.online = (activeSessions[acc.name] ~= nil)
        end
        
        saveAccounts()
        
        stats.relayCount = 0
        for _ in pairs(relays) do
            stats.relayCount = stats.relayCount + 1
        end
        
        if not adminMode then
            drawServerUI()
        end
    end, math.huge)
    
    while true do
        os.sleep(1)
    end
end

local success, err = pcall(main)
if not success then
    print("Error: " .. tostring(err))
end

modem.close(PORT)
print("Server stopped")
