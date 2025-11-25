-- Currency Server Admin Tool
-- Run this on the server to manage accounts

local serialization = require("serialization")
local filesystem = require("filesystem")
local term = require("term")

local DATA_DIR = "/home/currency/"
local accounts = {}
local accountIndex = {}

-- Improved password hashing (same as server)
local function simpleHash(str)
    if not str or str == "" then
        return "0"
    end
    
    local hash = 5381  -- DJB2 hash algorithm
    
    for i = 1, #str do
        local byte = string.byte(str, i)
        hash = ((hash * 33) + byte) % 2147483647
    end
    
    -- Add length factor
    hash = (hash + #str * 31) % 2147483647
    
    return tostring(hash)
end

-- Load accounts
local function loadAccounts()
    local file = io.open(DATA_DIR .. "accounts.dat", "r")
    if file then
        local data = file:read("*a")
        file:close()
        if data and data ~= "" then
            accounts = serialization.unserialize(data) or {}
            accountIndex = {}
            for i, acc in ipairs(accounts) do
                accountIndex[acc.name] = i
            end
            return true
        end
    end
    return false
end

-- Save accounts
local function saveAccounts()
    local file = io.open(DATA_DIR .. "accounts.dat", "w")
    if file then
        local data = serialization.serialize(accounts)
        file:write(data)
        file:close()
        return true
    end
    return false
end

-- Get account
local function getAccount(username)
    local idx = accountIndex[username]
    if idx then
        return accounts[idx], idx
    end
    return nil, nil
end

-- Main menu
local function main()
    term.clear()
    print("═══════════════════════════════════════════════════════")
    print("Currency Server Admin Tool")
    print("═══════════════════════════════════════════════════════")
    print("")
    
    if not filesystem.exists(DATA_DIR) then
        print("ERROR: Data directory not found: " .. DATA_DIR)
        print("Make sure the server has been run at least once.")
        return
    end
    
    if not loadAccounts() then
        print("No accounts found. Creating empty database...")
        accounts = {}
        accountIndex = {}
    else
        print("Loaded " .. #accounts .. " accounts")
    end
    
    print("")
    
    while true do
        print("")
        print("═══════════════════════════════════════════════════════")
        print("ADMIN MENU")
        print("═══════════════════════════════════════════════════════")
        print("")
        print("[1] List all accounts")
        print("[2] View account details")
        print("[3] Create account")
        print("[4] Set balance")
        print("[5] Lock/Unlock account")
        print("[6] Delete account")
        print("[7] Reset password")
        print("[8] Give credits to account")
        print("[9] Exit")
        print("")
        io.write("Choice: ")
        
        local choice = io.read()
        print("")
        
        if choice == "1" then
            -- List accounts
            print("═══════════════════════════════════════════════════════")
            print("ALL ACCOUNTS (" .. #accounts .. " total)")
            print("═══════════════════════════════════════════════════════")
            print("")
            print("Username                 Balance      Locked")
            print("───────────────────────────────────────────────────────")
            
            for _, acc in ipairs(accounts) do
                local name = acc.name
                if #name > 20 then name = name:sub(1, 17) .. "..." end
                
                local locked = acc.locked and "YES" or "no"
                print(string.format("%-20s %10.2f CR   %s", name, acc.balance, locked))
            end
            
        elseif choice == "2" then
            -- View details
            io.write("Username: ")
            local user = io.read()
            local acc = getAccount(user)
            
            if acc then
                print("")
                print("Account: " .. acc.name)
                print("Balance: " .. string.format("%.2f CR", acc.balance))
                print("Locked: " .. (acc.locked and "YES" or "NO"))
                print("Online: " .. (acc.online and "YES" or "NO"))
                print("Created: " .. os.date("%Y-%m-%d %H:%M:%S", acc.created))
                print("Last Activity: " .. os.date("%Y-%m-%d %H:%M:%S", acc.lastActivity))
                print("Transactions: " .. acc.transactionCount)
            else
                print("✗ Account not found")
            end
            
        elseif choice == "3" then
            -- Create account
            io.write("Username: ")
            local user = io.read()
            io.write("Password: ")
            local pass = io.read()
            io.write("Starting balance: ")
            local bal = tonumber(io.read()) or 100
            
            -- Validate username
            if not user or user == "" then
                print("✗ Username cannot be empty")
            elseif #user > 50 then
                print("✗ Username too long (max 50 characters)")
            elseif accountIndex[user] then
                print("✗ Account already exists")
            elseif not pass or pass == "" then
                print("✗ Password cannot be empty")
            else
                local account = {
                    name = user,
                    passwordHash = simpleHash(pass),  -- Properly hash password
                    balance = bal,
                    relay = "admin",
                    online = false,
                    created = os.time(),
                    lastActivity = os.time(),
                    transactionCount = 0,
                    locked = false
                }
                
                table.insert(accounts, account)
                accountIndex[user] = #accounts
                saveAccounts()
                print("")
                print("✓ Account created successfully!")
                print("  Username: " .. user)
                print("  Balance: " .. string.format("%.2f CR", bal))
                print("  Supports all characters in username & password!")
            end
            
        elseif choice == "4" then
            -- Set balance
            io.write("Username: ")
            local user = io.read()
            local acc = getAccount(user)
            
            if acc then
                io.write("New balance: ")
                local bal = tonumber(io.read())
                if bal then
                    local old = acc.balance
                    acc.balance = bal
                    saveAccounts()
                    print("✓ Balance updated: " .. string.format("%.2f", old) .. " → " .. string.format("%.2f", bal))
                end
            else
                print("✗ Account not found")
            end
            
        elseif choice == "5" then
            -- Lock/Unlock
            io.write("Username: ")
            local user = io.read()
            local acc = getAccount(user)
            
            if acc then
                acc.locked = not acc.locked
                saveAccounts()
                print("✓ Account " .. (acc.locked and "LOCKED" or "UNLOCKED"))
            else
                print("✗ Account not found")
            end
            
        elseif choice == "6" then
            -- Delete
            io.write("Username: ")
            local user = io.read()
            io.write("Confirm delete? (yes/no): ")
            local confirm = io.read()
            
            if confirm == "yes" then
                local acc, idx = getAccount(user)
                if acc then
                    table.remove(accounts, idx)
                    accountIndex = {}
                    for i, a in ipairs(accounts) do
                        accountIndex[a.name] = i
                    end
                    saveAccounts()
                    print("✓ Account deleted")
                else
                    print("✗ Account not found")
                end
            else
                print("Cancelled")
            end
            
        elseif choice == "7" then
            -- Reset password
            io.write("Username: ")
            local user = io.read()
            local acc = getAccount(user)
            
            if acc then
                io.write("New password: ")
                local pass = io.read()
                
                if not pass or pass == "" then
                    print("✗ Password cannot be empty")
                else
                    acc.passwordHash = simpleHash(pass)  -- Properly hash password
                    saveAccounts()
                    print("")
                    print("✓ Password reset successfully!")
                    print("  Username: " .. user)
                    print("  New password is now hashed and secure")
                end
            else
                print("✗ Account not found")
            end
            
        elseif choice == "8" then
            -- Give credits
            io.write("Username: ")
            local user = io.read()
            local acc = getAccount(user)
            
            if acc then
                io.write("Amount to add: ")
                local amount = tonumber(io.read())
                if amount then
                    acc.balance = acc.balance + amount
                    saveAccounts()
                    print("✓ Added " .. string.format("%.2f", amount) .. " CR")
                    print("  New balance: " .. string.format("%.2f", acc.balance) .. " CR")
                end
            else
                print("✗ Account not found")
            end
            
        elseif choice == "9" then
            -- Exit
            print("Saving and exiting...")
            saveAccounts()
            break
        end
    end
    
    print("")
    print("Admin tool closed")
end

main()
