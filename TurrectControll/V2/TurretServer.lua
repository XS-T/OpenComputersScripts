-- Central Turret Management Server for OpenComputers 1.7.10
-- Manages multiple remote turret controllers across different dimensions
-- Controllers connect via RELAY (which uses linked cards for cross-dimensional support)
-- Clients also connect via same RELAY system

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local computer = require("computer")
local gpu = component.gpu
local term = require("term")
local unicode = require("unicode")

-- Configuration
local PORT = 19321
local SERVER_NAME = "Central Turret Control"
local DATA_DIR = "/home/turrets/"
local DATA_FILE = DATA_DIR .. "trusted.dat"
local ADMIN_FILE = DATA_DIR .. "admins.dat"

-- Network components
local modem = component.modem

if not modem or not modem.isWireless() then
    print("ERROR: Wireless Network Card required!")
    return
end

-- Check for data card (for encryption)
if not component.isAvailable("data") then
    print("ERROR: Data card required for encryption!")
    print("Please install a Tier 2 or Tier 3 Data Card")
    return
end

local data = component.data

-- Encryption key derived from server name
local ENCRYPTION_KEY = data.md5(SERVER_NAME .. "TurretSecure2024")

-- Data structures
local trustedPlayers = {} -- Global trusted players list
local controllerTrustedPlayers = {} -- Per-controller: controllerId -> {players}
local turretControllers = {} -- address -> {name, world, lastSeen, turretCount, id}
local relays = {} -- relay address -> {name, lastSeen, controllers, managers}
local adminAccounts = {} -- username -> {passwordHash, created, lastLogin, permissions}
local activeSessions = {} -- sessionToken -> {username, loginTime, lastActivity}
local stats = {
    totalControllers = 0,
    totalTurrets = 0,
    totalTrusted = 0,
    relayCount = 0,
    commandsProcessed = 0
}

-- Admin mode state
local adminMode = false
local adminAuthenticated = false

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
    border = 0x374151
}

-- Activity log
local activityLog = {}

-- Initialize data directory
if not filesystem.exists(DATA_DIR) then
    filesystem.makeDirectory(DATA_DIR)
end

-- Utility functions
local function contains(list, item)
    for _, v in ipairs(list) do
        if v == item then return true end
    end
    return false
end

local function removeFromList(list, item)
    for i = #list, 1, -1 do
        if list[i] == item then
            table.remove(list, i)
        end
    end
end

-- Encryption functions
local function encryptMessage(plaintext)
    if not plaintext or plaintext == "" then
        return nil
    end
    local iv = data.random(16)
    local encrypted = data.encrypt(plaintext, ENCRYPTION_KEY, iv)
    return data.encode64(iv .. encrypted)
end

local function decryptMessage(ciphertext)
    if not ciphertext or ciphertext == "" then
        return nil
    end
    
    local success, result = pcall(function()
        local combined = data.decode64(ciphertext)
        local iv = combined:sub(1, 16)
        local encrypted = combined:sub(17)
        return data.decrypt(encrypted, ENCRYPTION_KEY, iv)
    end)
    
    if success then
        return result
    else
        return nil
    end
end

local function hashPassword(password)
    if not password or password == "" then
        return nil
    end
    return data.md5(password .. "TurretSalt")
end

local function generateSessionToken()
    return data.encode64(data.random(32))
end

-- Admin account management
local function saveAdminAccounts()
    local plaintext = serialization.serialize(adminAccounts)
    local encrypted = encryptMessage(plaintext)
    
    if encrypted then
        local file = io.open(ADMIN_FILE, "w")
        if file then
            file:write(encrypted)
            file:close()
            return true
        end
    end
    return false
end

local function loadAdminAccounts()
    if not filesystem.exists(ADMIN_FILE) then
        -- Create default admin account
        adminAccounts["admin"] = {
            passwordHash = hashPassword("admin123"),
            created = os.time(),
            lastLogin = 0,
            permissions = "full"
        }
        saveAdminAccounts()
        return true
    end
    
    local file = io.open(ADMIN_FILE, "r")
    if file then
        local encrypted = file:read("*a")
        file:close()
        
        if encrypted and encrypted ~= "" then
            local plaintext = decryptMessage(encrypted)
            
            if plaintext then
                local success, accounts = pcall(serialization.unserialize, plaintext)
                if success and accounts then
                    adminAccounts = accounts
                    return true
                end
            end
        end
    end
    return false
end

local function createAdminAccount(username, password)
    if not username or username == "" then
        return false, "Username required"
    end
    
    if adminAccounts[username] then
        return false, "Account already exists"
    end
    
    if not password or password == "" then
        return false, "Password required"
    end
    
    adminAccounts[username] = {
        passwordHash = hashPassword(password),
        created = os.time(),
        lastLogin = 0,
        permissions = "full"
    }
    
    saveAdminAccounts()
    log("Admin account created: " .. username, "ADMIN")
    return true, "Account created"
end

local function deleteAdminAccount(username)
    if not adminAccounts[username] then
        return false, "Account not found"
    end
    
    if username == "admin" then
        return false, "Cannot delete default admin"
    end
    
    adminAccounts[username] = nil
    saveAdminAccounts()
    log("Admin account deleted: " .. username, "ADMIN")
    return true, "Account deleted"
end

local function verifyAdminCredentials(username, password)
    local account = adminAccounts[username]
    if not account then
        return false
    end
    
    return account.passwordHash == hashPassword(password)
end

local function createSession(username)
    local token = generateSessionToken()
    activeSessions[token] = {
        username = username,
        loginTime = os.time(),
        lastActivity = os.time()
    }
    
    -- Update last login
    if adminAccounts[username] then
        adminAccounts[username].lastLogin = os.time()
        saveAdminAccounts()
    end
    
    return token
end

local function validateSession(token)
    local session = activeSessions[token]
    if not session then
        return false, nil
    end
    
    -- Session timeout: 30 minutes
    if os.time() - session.lastActivity > 1800 then
        activeSessions[token] = nil
        return false, nil
    end
    
    session.lastActivity = os.time()
    return true, session.username
end

local function endSession(token)
    activeSessions[token] = nil
end

-- Data persistence
local function saveTrustedPlayers()
    local file = io.open(DATA_FILE, "w")
    if file then
        file:write(serialization.serialize(trustedPlayers))
        file:close()
        return true
    end
    return false
end

local function loadTrustedPlayers()
    if not filesystem.exists(DATA_FILE) then
        return false
    end
    
    local file = io.open(DATA_FILE, "r")
    if file then
        local content = file:read("*a")
        file:close()
        
        local ok, data = pcall(serialization.unserialize, content)
        if ok and type(data) == "table" then
            trustedPlayers = data
            stats.totalTrusted = #trustedPlayers
            return true
        end
    end
    return false
end

-- Activity logging
local function log(message, category)
    category = category or "INFO"
    local entry = {
        time = os.date("%H:%M:%S"),
        category = category,
        message = message
    }
    
    table.insert(activityLog, 1, entry)
    if #activityLog > 50 then
        table.remove(activityLog)
    end
    
    stats.commandsProcessed = stats.commandsProcessed + 1
end

-- Controller management
local function registerController(address, controllerName, worldName, turretCount)
    if not turretControllers[address] then
        local controllerId = address  -- Use address as unique ID
        
        turretControllers[address] = {
            address = address,
            id = controllerId,
            name = controllerName or "Unknown",
            world = worldName or "Unknown",
            turretCount = turretCount or 0,
            lastSeen = computer.uptime(),
            lastHeartbeat = computer.uptime()
        }
        
        -- Initialize empty per-controller list if not exists
        if not controllerTrustedPlayers[controllerId] then
            controllerTrustedPlayers[controllerId] = {}
        end
        
        stats.totalControllers = stats.totalControllers + 1
        log("Controller: " .. controllerName .. " (" .. worldName .. ")", "CONTROLLER")
    else
        turretControllers[address].lastSeen = computer.uptime()
        turretControllers[address].turretCount = turretCount or turretControllers[address].turretCount
    end
    
    -- Recalculate total turrets
    stats.totalTurrets = 0
    for _, ctrl in pairs(turretControllers) do
        stats.totalTurrets = stats.totalTurrets + ctrl.turretCount
    end
end

-- Relay management
local function registerRelay(address, relayName)
    if not relays[address] then
        relays[address] = {
            address = address,
            name = relayName,
            lastSeen = computer.uptime(),
            controllers = 0,
            managers = 0
        }
        stats.relayCount = stats.relayCount + 1
        log("Relay connected: " .. relayName, "RELAY")
    else
        relays[address].lastSeen = computer.uptime()
    end
end

-- Broadcast command to all controllers via relay
local function broadcastToControllers(command, relayAddress)
    local msg = serialization.serialize(command)
    local encrypted = encryptMessage(msg)
    
    if relayAddress then
        -- Send to specific relay
        modem.send(relayAddress, PORT, encrypted or msg)
        return true
    else
        -- Broadcast to all relays
        modem.broadcast(PORT, encrypted or msg)
        return true
    end
end

-- UI Drawing
local function drawServerUI()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
    
    -- Header
    gpu.setBackground(colors.header)
    gpu.fill(1, 1, w, 3, " ")
    local title = "=== " .. SERVER_NAME .. " ==="
    gpu.set(math.floor((w - #title) / 2), 2, title)
    gpu.setForeground(colors.textDim)
    local subtitle = "Cross-Dimensional Turret Management"
    gpu.set(math.floor((w - #subtitle) / 2), 3, subtitle)
    
    -- Stats panel
    gpu.setBackground(0x1E1E1E)
    gpu.setForeground(colors.success)
    gpu.fill(1, 4, w, 2, " ")
    gpu.set(2, 4, "Controllers: " .. stats.totalControllers)
    gpu.set(22, 4, "Total Turrets: " .. stats.totalTurrets)
    gpu.set(45, 4, "Trusted: " .. stats.totalTrusted)
    gpu.set(65, 4, "Port: " .. PORT)
    
    gpu.set(2, 5, "Relays: " .. stats.relayCount)
    gpu.setForeground(colors.warning)
    gpu.set(22, 5, "Commands: " .. stats.commandsProcessed)
    
    -- Show turret controllers by world
    gpu.setBackground(0x2D2D2D)
    gpu.setForeground(colors.warning)
    gpu.fill(1, 7, w, 1, " ")
    gpu.set(2, 7, "Turret Controllers (via Linked Cards):")
    
    gpu.setForeground(colors.text)
    gpu.set(2, 8, "World/Dimension")
    gpu.set(30, 8, "Controller")
    gpu.set(52, 8, "Turrets")
    gpu.set(62, 8, "HB")
    gpu.set(68, 8, "Status")
    
    local y = 9
    local controllerList = {}
    for _, ctrl in pairs(turretControllers) do
        table.insert(controllerList, ctrl)
    end
    table.sort(controllerList, function(a, b) return a.world < b.world end)
    
    for i = 1, math.min(5, #controllerList) do
        local ctrl = controllerList[i]
        local now = computer.uptime()
        local timeDiff = now - ctrl.lastHeartbeat
        local isActive = timeDiff < 90  -- 90 seconds (3 missed heartbeats)
        
        gpu.setForeground(isActive and colors.accent or 0x888888)
        local world = ctrl.world or "Unknown"
        if #world > 25 then world = world:sub(1, 22) .. "..." end
        gpu.set(2, y, world)
        
        gpu.setForeground(isActive and colors.text or 0x888888)
        local name = ctrl.name or "Unknown"
        if #name > 18 then name = name:sub(1, 15) .. "..." end
        gpu.set(30, y, name)
        
        gpu.setForeground(isActive and colors.success or 0x888888)
        gpu.set(52, y, tostring(ctrl.turretCount or 0))
        
        -- Show time since last heartbeat
        local hbTime = math.floor(timeDiff)
        gpu.setForeground(isActive and colors.textDim or 0x888888)
        gpu.set(62, y, hbTime .. "s")
        
        gpu.setForeground(isActive and colors.success or colors.error)
        gpu.set(68, y, isActive and "ONLINE" or "OFFLINE")
        y = y + 1
    end
    
    if #controllerList == 0 then
        gpu.setForeground(colors.textDim)
        gpu.set(2, y, "  (no controllers connected)")
    end
    
    -- Show relays
    y = math.max(y + 1, 15)
    gpu.setBackground(0x2D2D2D)
    gpu.setForeground(colors.warning)
    gpu.fill(1, y, w, 1, " ")
    gpu.set(2, y, "Connected Relays:")
    y = y + 1
    
    local relayList = {}
    for _, relay in pairs(relays) do
        table.insert(relayList, relay)
    end
    table.sort(relayList, function(a, b) return a.lastSeen > b.lastSeen end)
    
    for i = 1, math.min(3, #relayList) do
        local relay = relayList[i]
        local now = computer.uptime()
        local isActive = (now - relay.lastSeen) < 90
        
        gpu.setForeground(isActive and colors.success or 0x888888)
        local name = relay.name or "Unknown"
        if #name > 30 then name = name:sub(1, 27) .. "..." end
        gpu.set(4, y, "• " .. name)
        
        gpu.setForeground(isActive and colors.textDim or 0x888888)
        local info = "Ctrl:" .. (relay.controllers or 0) .. " Mgr:" .. (relay.managers or 0)
        gpu.set(40, y, info)
        
        gpu.setForeground(isActive and colors.success or colors.error)
        gpu.set(68, y, isActive and "ACTIVE" or "TIMEOUT")
        y = y + 1
    end
    
    -- Trusted players list
    y = math.max(y + 1, 19)
    gpu.setForeground(colors.warning)
    gpu.fill(1, y, w, 1, " ")
    gpu.set(2, y, "Trusted Players (Global - All Dimensions):")
    y = y + 1
    
    gpu.setBackground(0x2D2D2D)
    gpu.setForeground(colors.text)
    
    local maxPlayers = math.min(3, #trustedPlayers)
    for i = 1, maxPlayers do
        local player = trustedPlayers[i]
        gpu.set(4, y, "• " .. player)
        y = y + 1
    end
    
    if #trustedPlayers == 0 then
        gpu.setForeground(colors.textDim)
        gpu.set(4, y, "(no trusted players)")
        y = y + 1
    elseif #trustedPlayers > 3 then
        gpu.setForeground(colors.textDim)
        gpu.set(4, y, "... and " .. (#trustedPlayers - 3) .. " more")
        y = y + 1
    end
    
    -- Recent activity
    gpu.setBackground(0x1E1E1E)
    gpu.setForeground(colors.warning)
    gpu.fill(1, 23, w, 1, " ")
    gpu.set(2, 23, "Recent Activity:")
    
    gpu.setBackground(0x2D2D2D)
    y = 24
    for i = 1, math.min(1, #activityLog) do
        local entry = activityLog[i]
        local color = 0xAAAAAA
        if entry.category == "SUCCESS" then color = colors.success
        elseif entry.category == "ERROR" then color = colors.error
        elseif entry.category == "RELAY" then color = 0xFF00FF
        elseif entry.category == "CONTROLLER" then color = colors.accent
        elseif entry.category == "TURRET" then color = colors.warning
        end
        
        gpu.setForeground(color)
        local msg = "[" .. entry.time .. "] " .. entry.message
        gpu.set(2, y, msg:sub(1, 76))
        y = y + 1
    end
    
    -- Footer
    gpu.setBackground(colors.header)
    gpu.setForeground(colors.text)
    gpu.fill(1, 25, w, 1, " ")
    local footer = "Central Server • " .. stats.totalTurrets .. " turrets • " .. stats.totalControllers .. " dimensions"
    gpu.set(2, 25, footer)
end

-- Network message handler
local function handleMessage(eventType, _, sender, port, distance, message)
    if port ~= PORT then return end
    
    -- Try to decrypt message first
    local decrypted = decryptMessage(message)
    local messageToUse = decrypted or message -- Fallback to plain for backward compat
    
    local success, data = pcall(serialization.unserialize, messageToUse)
    if not success or not data then
        log("Bad message from " .. sender:sub(1, 8), "ERROR")
        return
    end
    
    -- Handle relay ping (no auth needed)
    if data.type == "relay_ping" then
        registerRelay(sender, data.relay_name or "Unknown")
        
        local response = {
            type = "server_response",
            serverName = SERVER_NAME
        }
        
        local responseMsg = serialization.serialize(response)
        local encrypted = encryptMessage(responseMsg)
        modem.send(sender, PORT, encrypted or responseMsg)
        
        if not adminMode then drawServerUI() end
        return
    end
    
    -- Handle relay heartbeat (no auth needed)
    if data.type == "relay_heartbeat" then
        registerRelay(sender, data.relay_name or "Unknown")
        if relays[sender] then
            relays[sender].controllers = data.controllers or 0
            relays[sender].managers = data.managers or 0
        end
        if not adminMode then drawServerUI() end
        return
    end
    
    -- Handle turret controller registration (no auth needed)
    if data.type == "controller_register" then
        local controllerId = data.tunnelAddress or sender
        registerController(controllerId, data.controllerName or data.controller_name, data.worldName or data.world_name, data.turret_count)
        
        local response = {
            type = "sync_trusted",
            players = trustedPlayers,
            controller_players = controllerTrustedPlayers[controllerId] or {}
        }
        
        local responseMsg = serialization.serialize(response)
        local encrypted = encryptMessage(responseMsg)
        modem.send(sender, PORT, encrypted or responseMsg)
        
        log("Synced " .. #trustedPlayers .. " global + " .. #(controllerTrustedPlayers[controllerId] or {}) .. " local to " .. (data.controllerName or data.controller_name or "controller"), "CONTROLLER")
        if not adminMode then drawServerUI() end
        return
    end
    
    -- Handle turret controller heartbeat (no auth needed)
    if data.type == "controller_heartbeat" then
        local controllerId = data.tunnelAddress or sender
        local ctrl = turretControllers[controllerId]
        
        if ctrl then
            ctrl.lastHeartbeat = computer.uptime()
            ctrl.lastSeen = computer.uptime()
            ctrl.turretCount = data.turret_count or ctrl.turretCount
            ctrl.name = data.controllerName or data.controller_name or ctrl.name
            ctrl.world = data.worldName or data.world_name or ctrl.world
        else
            registerController(controllerId, data.controllerName or data.controller_name, data.worldName or data.world_name, data.turret_count)
        end
        
        stats.totalTurrets = 0
        for _, c in pairs(turretControllers) do
            stats.totalTurrets = stats.totalTurrets + c.turretCount
        end
        
        if not adminMode then drawServerUI() end
        return
    end
    
    -- ALL MANAGER COMMANDS BELOW REQUIRE AUTHENTICATION
    
    -- Handle manager login
    if data.command == "managerLogin" then
        local username = data.username
        local password = data.password
        
        local response = { status = "fail" }
        
        if verifyAdminCredentials(username, password) then
            local sessionToken = createSession(username)
            response.status = "success"
            response.sessionToken = sessionToken
            response.username = username
            log("Manager login: " .. username, "ADMIN")
        else
            response.reason = "Invalid credentials"
            log("Failed login attempt: " .. (username or "unknown"), "SECURITY")
        end
        
        local responseMsg = serialization.serialize(response)
        local encrypted = encryptMessage(responseMsg)
        modem.send(sender, PORT, encrypted or responseMsg)
        return
    end
    
    -- Verify session for all other manager commands
    local sessionToken = data.sessionToken
    local isValid, username = validateSession(sessionToken)
    
    if not isValid then
        local response = {
            status = "fail",
            reason = "Invalid or expired session"
        }
        local responseMsg = serialization.serialize(response)
        local encrypted = encryptMessage(responseMsg)
        modem.send(sender, PORT, encrypted or responseMsg)
        return
    end
    
    -- Log who performed the action
    local actionUser = " [by " .. username .. "]"
    
    local response = { status = "fail" }
    
    -- Command: Add trusted player
    if data.command == "addTrustedPlayer" and type(data.player) == "string" then
        local player = data.player
        local scope = data.scope or "global"
        
        if scope == "global" then
            log("Add player (GLOBAL): " .. player .. actionUser, "TURRET")
            
            if not contains(trustedPlayers, player) then
                table.insert(trustedPlayers, player)
                stats.totalTrusted = #trustedPlayers
                saveTrustedPlayers()
                
                local broadcast = {
                    type = "add_player",
                    player = player,
                    scope = "global"
                }
                broadcastToControllers(broadcast, sender)
                
                response.status = "success"
                log("✓ Added globally: " .. player .. actionUser, "SUCCESS")
            else
                response.status = "success"
                response.message = "Player already trusted globally"
            end
            
        elseif scope == "specific" and data.target_controller then
            local targetId = data.target_controller
            local targetWorld = data.target_world or "Unknown"
            
            log("Add player (SPECIFIC): " .. player .. " to " .. targetWorld .. actionUser, "TURRET")
            
            if not controllerTrustedPlayers[targetId] then
                controllerTrustedPlayers[targetId] = {}
            end
            
            if not contains(controllerTrustedPlayers[targetId], player) then
                table.insert(controllerTrustedPlayers[targetId], player)
                saveTrustedPlayers()
                
                local specificCmd = {
                    type = "add_player",
                    player = player,
                    scope = "specific",
                    target_controller = targetId
                }
                local cmdMsg = serialization.serialize(specificCmd)
                local encrypted = encryptMessage(cmdMsg)
                modem.send(sender, PORT, encrypted or cmdMsg)
                
                response.status = "success"
                log("✓ Added to " .. targetWorld .. ": " .. player .. actionUser, "SUCCESS")
            else
                response.status = "success"
                response.message = "Player already trusted on that controller"
            end
        else
            response.reason = "Invalid scope or missing target"
        end
        
    -- Command: Remove trusted player
    elseif data.command == "removeTrustedPlayer" and type(data.player) == "string" then
        local player = data.player
        local scope = data.scope or "global"
        
        if scope == "global" then
            log("Remove player (GLOBAL): " .. player .. actionUser, "TURRET")
            
            if contains(trustedPlayers, player) then
                removeFromList(trustedPlayers, player)
                stats.totalTrusted = #trustedPlayers
                saveTrustedPlayers()
                
                local broadcast = {
                    type = "remove_player",
                    player = player,
                    scope = "global"
                }
                broadcastToControllers(broadcast, sender)
                
                response.status = "success"
                log("✓ Removed globally: " .. player .. actionUser, "SUCCESS")
            else
                response.status = "success"
                response.message = "Player not in global list"
            end
            
        elseif scope == "specific" and data.target_controller then
            local targetId = data.target_controller
            local targetWorld = data.target_world or "Unknown"
            
            log("Remove player (SPECIFIC): " .. player .. " from " .. targetWorld .. actionUser, "TURRET")
            
            if controllerTrustedPlayers[targetId] and contains(controllerTrustedPlayers[targetId], player) then
                removeFromList(controllerTrustedPlayers[targetId], player)
                saveTrustedPlayers()
                
                local specificCmd = {
                    type = "remove_player",
                    player = player,
                    scope = "specific",
                    target_controller = targetId
                }
                local cmdMsg = serialization.serialize(specificCmd)
                local encrypted = encryptMessage(cmdMsg)
                modem.send(sender, PORT, encrypted or cmdMsg)
                
                response.status = "success"
                log("✓ Removed from " .. targetWorld .. ": " .. player .. actionUser, "SUCCESS")
            else
                response.status = "success"
                response.message = "Player not in controller list"
            end
        else
            response.reason = "Invalid scope or missing target"
        end
        
    -- Command: Get trusted players
    elseif data.command == "getTrustedPlayers" then
        response.status = "success"
        response.players = trustedPlayers
        log("Sent player list to " .. username, "INFO")
        
    -- Command: Get controllers
    elseif data.command == "getControllers" then
        response.status = "success"
        response.controllers = {}
        
        for _, ctrl in pairs(turretControllers) do
            local now = computer.uptime()
            local isActive = (now - ctrl.lastHeartbeat) < 90
            
            if isActive then
                table.insert(response.controllers, {
                    id = ctrl.id,
                    name = ctrl.name,
                    world = ctrl.world,
                    turrets = ctrl.turretCount
                })
            end
        end
        
        log("Sent controller list to " .. username, "INFO")
        
    else
        response.reason = "Unknown command: " .. tostring(data.command)
        log("Unknown command from " .. username, "ERROR")
    end
    
    local responseMsg = serialization.serialize(response)
    local encrypted = encryptMessage(responseMsg)
    modem.send(sender, PORT, encrypted or responseMsg)
    
    if not adminMode then drawServerUI() end
end
    
    -- Handle relay ping
    if data.type == "relay_ping" then
        registerRelay(sender, data.relay_name or "Unknown")
        
        local response = {
            type = "server_response",
            serverName = SERVER_NAME
        }
        modem.send(sender, PORT, serialization.serialize(response))
        drawServerUI()
        return
    end
    
    -- Handle relay heartbeat
    if data.type == "relay_heartbeat" then
        registerRelay(sender, data.relay_name or "Unknown")
        if relays[sender] then
            relays[sender].controllers = data.controllers or 0
            relays[sender].managers = data.managers or 0
        end
        drawServerUI()
        return
    end
    
    -- Handle turret controller registration (from relay)
    if data.type == "controller_register" then
        local controllerId = data.tunnelAddress or sender
        registerController(controllerId, data.controllerName or data.controller_name, data.worldName or data.world_name, data.turret_count)
        
        -- Send BOTH global and per-controller trusted player lists
        local response = {
            type = "sync_trusted",
            players = trustedPlayers,  -- Global list
            controller_players = controllerTrustedPlayers[controllerId] or {}  -- Controller-specific list
        }
        modem.send(sender, PORT, serialization.serialize(response))
        
        log("Synced " .. #trustedPlayers .. " global + " .. #(controllerTrustedPlayers[controllerId] or {}) .. " local to " .. (data.controllerName or data.controller_name or "controller"), "CONTROLLER")
        drawServerUI()
        return
    end
    
    -- Handle turret controller heartbeat (from relay)
    if data.type == "controller_heartbeat" then
        local controllerId = data.tunnelAddress or sender
        local ctrl = turretControllers[controllerId]
        
        if ctrl then
            ctrl.lastHeartbeat = computer.uptime()
            ctrl.lastSeen = computer.uptime()
            ctrl.turretCount = data.turret_count or ctrl.turretCount
            ctrl.name = data.controllerName or data.controller_name or ctrl.name
            ctrl.world = data.worldName or data.world_name or ctrl.world
        else
            -- First heartbeat, register controller
            registerController(controllerId, data.controllerName or data.controller_name, data.worldName or data.world_name, data.turret_count)
        end
        
        -- Recalculate total turrets
        stats.totalTurrets = 0
        for _, c in pairs(turretControllers) do
            stats.totalTurrets = stats.totalTurrets + c.turretCount
        end
        
        drawServerUI()
        return
    end
    
    -- Handle manager sync request
    if data.type == "request_sync" then
        local response = {
            type = "sync_trusted",
            players = trustedPlayers
        }
        modem.send(sender, PORT, serialization.serialize(response))
        log("Re-synced to manager", "INFO")
        drawServerUI()
        return
    end
    
    -- All other messages are commands from client managers (via relay)
    local response = { status = "fail" }
    
    -- Command: Add trusted player
    if data.command == "addTrustedPlayer" and type(data.player) == "string" then
        local player = data.player
        local scope = data.scope or "global"  -- Default to global
        
        if scope == "global" then
            -- Add to global list
            log("Add player (GLOBAL): " .. player, "TURRET")
            
            if not contains(trustedPlayers, player) then
                table.insert(trustedPlayers, player)
                stats.totalTrusted = #trustedPlayers
                saveTrustedPlayers()
                
                -- Broadcast to all controllers via relay
                local broadcast = {
                    type = "add_player",
                    player = player,
                    scope = "global"
                }
                broadcastToControllers(broadcast, sender)
                
                response.status = "success"
                log("✓ Added globally: " .. player, "SUCCESS")
            else
                response.status = "success"
                response.message = "Player already trusted globally"
            end
            
        elseif scope == "specific" and data.target_controller then
            -- Add to specific controller only
            local targetId = data.target_controller
            local targetWorld = data.target_world or "Unknown"
            
            log("Add player (SPECIFIC): " .. player .. " to " .. targetWorld, "TURRET")
            
            -- Initialize if needed
            if not controllerTrustedPlayers[targetId] then
                controllerTrustedPlayers[targetId] = {}
            end
            
            if not contains(controllerTrustedPlayers[targetId], player) then
                table.insert(controllerTrustedPlayers[targetId], player)
                saveTrustedPlayers()  -- Save all data
                
                -- Send to ONLY that controller
                local specificCmd = {
                    type = "add_player",
                    player = player,
                    scope = "specific",
                    target_controller = targetId
                }
                modem.send(sender, PORT, serialization.serialize(specificCmd))
                
                response.status = "success"
                log("✓ Added to " .. targetWorld .. ": " .. player, "SUCCESS")
            else
                response.status = "success"
                response.message = "Player already trusted on that controller"
            end
        else
            response.reason = "Invalid scope or missing target"
        end
        
    -- Command: Remove trusted player
    elseif data.command == "removeTrustedPlayer" and type(data.player) == "string" then
        local player = data.player
        local scope = data.scope or "global"
        
        if scope == "global" then
            -- Remove from global list
            log("Remove player (GLOBAL): " .. player, "TURRET")
            
            if contains(trustedPlayers, player) then
                removeFromList(trustedPlayers, player)
                stats.totalTrusted = #trustedPlayers
                saveTrustedPlayers()
                
                -- Broadcast to all controllers via relay
                local broadcast = {
                    type = "remove_player",
                    player = player,
                    scope = "global"
                }
                broadcastToControllers(broadcast, sender)
                
                response.status = "success"
                log("✓ Removed globally: " .. player, "SUCCESS")
            else
                response.status = "success"
                response.message = "Player not in global list"
            end
            
        elseif scope == "specific" and data.target_controller then
            -- Remove from specific controller only
            local targetId = data.target_controller
            local targetWorld = data.target_world or "Unknown"
            
            log("Remove player (SPECIFIC): " .. player .. " from " .. targetWorld, "TURRET")
            
            if controllerTrustedPlayers[targetId] and contains(controllerTrustedPlayers[targetId], player) then
                removeFromList(controllerTrustedPlayers[targetId], player)
                saveTrustedPlayers()
                
                -- Send to ONLY that controller
                local specificCmd = {
                    type = "remove_player",
                    player = player,
                    scope = "specific",
                    target_controller = targetId
                }
                modem.send(sender, PORT, serialization.serialize(specificCmd))
                
                response.status = "success"
                log("✓ Removed from " .. targetWorld .. ": " .. player, "SUCCESS")
            else
                response.status = "success"
                response.message = "Player not in controller list"
            end
        else
            response.reason = "Invalid scope or missing target"
        end
        
    -- Command: Get trusted players
    elseif data.command == "getTrustedPlayers" then
        response.status = "success"
        response.players = trustedPlayers
        log("Sent player list to manager", "INFO")
        
    -- Command: Get controllers (for manager UI)
    elseif data.command == "getControllers" then
        response.status = "success"
        response.controllers = {}
        
        for _, ctrl in pairs(turretControllers) do
            local now = computer.uptime()
            local isActive = (now - ctrl.lastHeartbeat) < 90
            
            if isActive then  -- Only send active controllers
                table.insert(response.controllers, {
                    id = ctrl.id,  -- Include ID for targeting
                    name = ctrl.name,
                    world = ctrl.world,
                    turrets = ctrl.turretCount
                })
            end
        end
        
        log("Sent controller list to manager", "INFO")
        
    else
        response.reason = "Unknown command: " .. tostring(data.command)
        log("Unknown command from " .. sender:sub(1, 8), "ERROR")
    end
    
    modem.send(sender, PORT, serialization.serialize(response))
    drawServerUI()
    end
end
-- Admin Panel UI Functions
local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
end

local function drawAdminHeader(title, subtitle)
    gpu.setBackground(colors.error)
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

local function adminInput(prompt, y, hidden, maxLen)
    maxLen = maxLen or 30
    gpu.setForeground(colors.text)
    gpu.set(5, y, prompt)
    
    local x = 5 + #prompt
    
    gpu.setBackground(0x1F2937)
    gpu.fill(x, y, maxLen + 2, 1, " ")
    
    x = x + 1
    gpu.set(x, y, "")
    
    local text = ""
    while true do
        local _, _, char, code = event.pull("key_down")
        
        if code == 28 then -- Enter
            break
        elseif code == 14 and #text > 0 then -- Backspace
            text = text:sub(1, -2)
            gpu.setBackground(0x1F2937)
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

local function adminLogin()
    clearScreen()
    drawAdminHeader("◆ ADMIN AUTHENTICATION ◆", "Server Administration Access")
    
    gpu.setForeground(colors.warning)
    gpu.set(5, 6, "⚠ RESTRICTED ACCESS - AUTHORIZED PERSONNEL ONLY")
    
    gpu.setForeground(colors.text)
    local username = adminInput("Username: ", 10, false, 20)
    local password = adminInput("Password: ", 12, true, 30)
    
    gpu.setForeground(colors.textDim)
    gpu.set(5, 15, "Authenticating...")
    
    if verifyAdminCredentials(username, password) then
        adminAuthenticated = true
        adminMode = true
        
        -- Update last login
        if adminAccounts[username] then
            adminAccounts[username].lastLogin = os.time()
            saveAdminAccounts()
        end
        
        gpu.setForeground(colors.success)
        gpu.set(5, 15, "✓ Authentication successful")
        log("Admin panel accessed by: " .. username, "ADMIN")
        os.sleep(1)
        return true, username
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 15, "✗ Authentication failed")
        log("Failed admin panel login: " .. username, "SECURITY")
        os.sleep(2)
        return false, nil
    end
end

local function adminMainMenu()
    clearScreen()
    drawAdminHeader("◆ ADMIN PANEL ◆", "Server Management Console")
    
    gpu.setForeground(colors.text)
    gpu.set(5, 6, "1  View All Admin Accounts")
    gpu.set(5, 7, "2  Create Admin Account")
    gpu.set(5, 8, "3  Delete Admin Account")
    gpu.set(5, 9, "4  View Activity Log")
    gpu.set(5, 10, "5  View Active Sessions")
    gpu.set(5, 11, "6  Exit Admin Mode")
    
    gpu.setForeground(colors.textDim)
    gpu.set(5, 14, "Total Admins: " .. (function() local c=0; for _ in pairs(adminAccounts) do c=c+1 end return c end)())
    gpu.set(5, 15, "Active Sessions: " .. (function() local c=0; for _ in pairs(activeSessions) do c=c+1 end return c end)())
    
    gpu.setForeground(colors.error)
    gpu.set(5, h, "Press F5 to exit admin mode")
    
    local _, _, char = event.pull("key_down")
    return char
end

local function adminViewAccounts()
    clearScreen()
    drawAdminHeader("◆ ADMIN ACCOUNTS ◆", "Registered administrators")
    
    gpu.setForeground(colors.textDim)
    gpu.set(5, 6, "Username")
    gpu.set(25, 6, "Last Login")
    gpu.set(50, 6, "Permissions")
    
    local y = 8
    for username, account in pairs(adminAccounts) do
        gpu.setForeground(colors.text)
        gpu.set(5, y, username)
        
        gpu.setForeground(colors.textDim)
        if account.lastLogin and account.lastLogin > 0 then
            gpu.set(25, y, os.date("%Y-%m-%d %H:%M", account.lastLogin))
        else
            gpu.set(25, y, "Never")
        end
        
        gpu.setForeground(colors.success)
        gpu.set(50, y, account.permissions or "full")
        
        y = y + 1
        if y >= h - 2 then break end
    end
    
    gpu.setForeground(colors.textDim)
    gpu.set(5, h, "Press any key to return...")
    event.pull("key_down")
end

local function adminCreateAccount()
    clearScreen()
    drawAdminHeader("◆ CREATE ADMIN ACCOUNT ◆", "Add new administrator")
    
    gpu.setForeground(colors.text)
    local username = adminInput("Username: ", 8, false, 20)
    
    if not username or username == "" then
        gpu.setForeground(colors.error)
        gpu.set(5, 12, "✗ Username required")
        os.sleep(2)
        return
    end
    
    local password = adminInput("Password: ", 10, true, 30)
    
    if not password or password == "" then
        gpu.setForeground(colors.error)
        gpu.set(5, 12, "✗ Password required")
        os.sleep(2)
        return
    end
    
    gpu.setForeground(colors.textDim)
    gpu.set(5, 13, "Creating account...")
    
    local ok, msg = createAdminAccount(username, password)
    
    if ok then
        gpu.setForeground(colors.success)
        gpu.set(5, 13, "✓ Account created: " .. username)
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 13, "✗ " .. msg)
    end
    
    os.sleep(2)
end

local function adminDeleteAccount()
    clearScreen()
    drawAdminHeader("◆ DELETE ADMIN ACCOUNT ◆", "Remove administrator")
    
    gpu.setForeground(colors.warning)
    gpu.set(5, 6, "⚠ WARNING: This action cannot be undone!")
    
    gpu.setForeground(colors.text)
    local username = adminInput("Username: ", 9, false, 20)
    
    if not username or username == "" then
        gpu.setForeground(colors.error)
        gpu.set(5, 12, "Cancelled")
        os.sleep(1)
        return
    end
    
    gpu.setForeground(colors.error)
    gpu.set(5, 12, "Type 'DELETE' to confirm: ")
    local confirm = adminInput("", 12, false, 10)
    
    if confirm ~= "DELETE" then
        gpu.setForeground(colors.warning)
        gpu.set(5, 14, "Cancelled")
        os.sleep(1)
        return
    end
    
    local ok, msg = deleteAdminAccount(username)
    
    if ok then
        gpu.setForeground(colors.success)
        gpu.set(5, 15, "✓ Account deleted: " .. username)
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 15, "✗ " .. msg)
    end
    
    os.sleep(2)
end

local function adminViewActivityLog()
    clearScreen()
    drawAdminHeader("◆ ACTIVITY LOG ◆", "Recent server actions")
    
    local y = 6
    for i = 1, math.min(15, #activityLog) do
        local entry = activityLog[i]
        local color = colors.textDim
        if entry.category == "SUCCESS" then color = colors.success
        elseif entry.category == "ERROR" then color = colors.error
        elseif entry.category == "ADMIN" then color = colors.warning
        elseif entry.category == "SECURITY" then color = colors.error
        end
        
        gpu.setForeground(color)
        local msg = "[" .. entry.time .. "] " .. entry.message
        gpu.set(5, y, msg:sub(1, 70))
        y = y + 1
    end
    
    gpu.setForeground(colors.textDim)
    gpu.set(5, h, "Press any key to return...")
    event.pull("key_down")
end

local function adminViewSessions()
    clearScreen()
    drawAdminHeader("◆ ACTIVE SESSIONS ◆", "Currently logged-in managers")
    
    gpu.setForeground(colors.textDim)
    gpu.set(5, 6, "Username")
    gpu.set(25, 6, "Login Time")
    gpu.set(50, 6, "Last Activity")
    
    local y = 8
    local sessionCount = 0
    for token, session in pairs(activeSessions) do
        sessionCount = sessionCount + 1
        
        gpu.setForeground(colors.text)
        gpu.set(5, y, session.username)
        
        gpu.setForeground(colors.textDim)
        gpu.set(25, y, os.date("%H:%M:%S", session.loginTime))
        
        local timeSince = os.time() - session.lastActivity
        gpu.setForeground(timeSince < 60 and colors.success or colors.warning)
        gpu.set(50, y, timeSince .. "s ago")
        
        y = y + 1
        if y >= h - 2 then break end
    end
    
    if sessionCount == 0 then
        gpu.setForeground(colors.textDim)
        gpu.set(5, 8, "No active sessions")
    end
    
    gpu.setForeground(colors.textDim)
    gpu.set(5, h, "Press any key to return...")
    event.pull("key_down")
end

-- Key press handler for admin mode
local function handleKeyPress(eventType, _, _, code)
    if code == 63 then -- F5 key - Toggle admin mode
        if adminMode then
            -- Exit admin mode
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
            -- Wait for F5 key to be released
            while true do
                local e = {event.pull(0.1)}
                if e[1] == "key_up" and e[4] == 63 then
                    break
                end
            end
            
            -- Enter admin mode
            local success, username = adminLogin()
            if success then
                -- Admin panel loop
                while adminMode do
                    local choice = adminMainMenu()
                    
                    if choice == string.byte('1') then
                        adminViewAccounts()
                    elseif choice == string.byte('2') then
                        adminCreateAccount()
                    elseif choice == string.byte('3') then
                        adminDeleteAccount()
                    elseif choice == string.byte('4') then
                        adminViewActivityLog()
                    elseif choice == string.byte('5') then
                        adminViewSessions()
                    elseif choice == string.byte('6') then
                        adminMode = false
                        adminAuthenticated = false
                        log("Admin mode exited by: " .. username, "ADMIN")
                    end
                end
                
                drawServerUI()
            end
        end
    end
end

-- Main server loop
local function main()
    print("Starting " .. SERVER_NAME .. "...")
    print("Mode: Central Management Server")
    print("Data directory: " .. DATA_DIR)
    print("")
    
    -- Load admin accounts
    print("Loading admin accounts...")
    if loadAdminAccounts() then
        local adminCount = 0
        for _ in pairs(adminAccounts) do adminCount = adminCount + 1 end
        print("Loaded " .. adminCount .. " admin accounts")
    else
        print("Created default admin account")
        print("  Username: admin")
        print("  Password: admin123")
        print("  CHANGE THIS IMMEDIATELY!")
    end
    print("")
    
    -- Load trusted players
    if loadTrustedPlayers() then
        print("Loaded " .. #trustedPlayers .. " trusted players")
    else
        print("No saved data, starting fresh")
    end
    
    modem.open(PORT)
    modem.setStrength(400)
    print("Listening on port " .. PORT)
    print("Wireless range: 400 blocks")
    print("Encryption: ENABLED (Data Card)")
    print("")
    print("Architecture:")
    print("  Relay ←wireless→ This Server (ENCRYPTED)")
    print("  Controllers ←linked cards→ Relay")
    print("  Managers ←linked cards→ Relay (AUTH REQUIRED)")
    print("")
    print("Waiting for connections...")
    print("")
    print("Press F5 to access Admin Panel")
    
    event.listen("modem_message", handleMessage)
    event.listen("key_down", handleKeyPress)
    
    drawServerUI()
    
    log("Central server started with encryption", "SYSTEM")
    
    -- Maintenance timer
    event.timer(60, function()
        -- Cleanup old controllers
        local now = computer.uptime()
        for address, ctrl in pairs(turretControllers) do
            if now - ctrl.lastHeartbeat > 180 then
                turretControllers[address] = nil
                stats.totalControllers = math.max(0, stats.totalControllers - 1)
                log("Controller timeout: " .. ctrl.name, "ERROR")
            end
        end
        
        -- Cleanup old relays
        for address, relay in pairs(relays) do
            if now - relay.lastSeen > 120 then
                relays[address] = nil
                stats.relayCount = math.max(0, stats.relayCount - 1)
            end
        end
        
        -- Cleanup expired sessions
        local currentTime = os.time()
        for token, session in pairs(activeSessions) do
            if currentTime - session.lastActivity > 1800 then
                activeSessions[token] = nil
                log("Session expired: " .. session.username, "SECURITY")
            end
        end
        
        -- Recalculate total turrets
        stats.totalTurrets = 0
        for _, ctrl in pairs(turretControllers) do
            stats.totalTurrets = stats.totalTurrets + ctrl.turretCount
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
