-- Turret Client Manager for OpenComputers 1.7.10
-- Connects to relay via TUNNEL (linked card)
-- Manages turrets across all dimensions or specific worlds

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local term = require("term")
local computer = require("computer")
local gpu = component.gpu
local unicode = require("unicode")

-- Check for tunnel
if not component.isAvailable("tunnel") then
    print("═══════════════════════════════════════════════════════")
    print("ERROR: LINKED CARD REQUIRED!")
    print("═══════════════════════════════════════════════════════")
    print("")
    print("This manager requires a linked card to connect to relay.")
    print("")
    print("SETUP:")
    print("1. Get a linked card pair (craft 2 linked cards + ender pearl)")
    print("2. Install one card in this computer (manager)")
    print("3. Install the paired card in the relay computer")
    print("4. The relay will forward to the central server")
    print("")
    return
end

local tunnel = component.tunnel

-- State
local relayConnected = false
local clientId = tunnel.address
local cachedPlayers = {}
local availableControllers = {} -- List of connected controllers

-- UI Config
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
    inputBg = 0x1F2937
}

-- Draw functions
local function drawBox(x, y, width, height, color, title)
    gpu.setBackground(color or colors.bg)
    gpu.fill(x, y, width, height, " ")
    
    if title then
        gpu.setBackground(colors.header)
        gpu.fill(x, y, width, 1, " ")
        gpu.setForeground(colors.text)
        local titleX = x + math.floor((width - unicode.len(title)) / 2)
        gpu.set(titleX, y, title)
        gpu.setBackground(color or colors.bg)
    end
end

local function drawLine(x, y, width, char)
    char = char or "─"
    gpu.set(x, y, string.rep(char, width))
end

local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
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

local function drawButton(x, y, text, selected)
    local bg = selected and colors.accent or colors.border
    local fg = selected and colors.text or colors.textDim
    
    gpu.setBackground(bg)
    gpu.setForeground(fg)
    gpu.set(x, y, " " .. text .. " ")
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
end

-- Send message and wait for response
local function sendAndWait(data, timeout)
    timeout = timeout or 5
    
    if not relayConnected then
        return {
            status = "fail",
            reason = "Not connected to relay"
        }
    end
    
    -- Add tunnel info
    data.tunnelAddress = tunnel.address
    data.tunnelChannel = tunnel.getChannel()
    
    local message = serialization.serialize(data)
    tunnel.send(message)
    
    local deadline = computer.uptime() + timeout
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, _, port, distance, msg = table.unpack(eventData)
            
            local isTunnel = (port == 0 or distance == nil or distance == math.huge)
            
            if isTunnel then
                local success, response = pcall(serialization.unserialize, msg)
                if success and response and response.status then
                    return response
                end
            end
        end
    end
    
    return nil
end

-- Register with relay
local function registerWithRelay()
    clearScreen()
    drawHeader("◆ CONNECTING TO RELAY ◆", "Establishing secure tunnel connection")
    
    drawBox(20, 8, 40, 12, colors.bg)
    
    gpu.setForeground(colors.accent)
    gpu.set(22, 10, "Tunnel Component Check:")
    
    gpu.setForeground(colors.text)
    gpu.set(22, 11, "Address: " .. tunnel.address:sub(1, 20))
    gpu.set(22, 12, "Channel: " .. tunnel.getChannel():sub(1, 20))
    gpu.setForeground(colors.textDim)
    gpu.set(22, 13, "Manager ID: " .. clientId:sub(1, 20))
    
    gpu.setForeground(colors.text)
    gpu.set(22, 15, "⟳ Sending registration...")
    
    drawFooter("Tunnel: " .. tunnel.address:sub(1, 16))
    
    local registration = serialization.serialize({
        type = "manager_register",
        tunnelAddress = tunnel.address,
        tunnelChannel = tunnel.getChannel()
    })
    
    local sendOk = pcall(tunnel.send, registration)
    if not sendOk then
        gpu.setForeground(colors.error)
        gpu.set(22, 17, "✗ Send error")
        showStatus("Press any key to retry...", "error")
        event.pull("key_down")
        return false
    end
    
    gpu.setForeground(colors.success)
    gpu.set(22, 17, "✓ Sent via tunnel")
    gpu.set(22, 18, "Waiting for relay ACK...")
    
    local deadline = computer.uptime() + 5
    
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, _, port, distance, msg = table.unpack(eventData)
            
            local isTunnel = (port == 0 or distance == nil or distance == math.huge)
            
            if isTunnel then
                local success, response = pcall(serialization.unserialize, msg)
                if success and response and response.type == "relay_ack" then
                    relayConnected = true
                    
                    clearScreen()
                    drawHeader("◆ CONNECTION ESTABLISHED ◆")
                    
                    drawBox(20, 10, 40, 6, colors.bg)
                    gpu.setForeground(colors.success)
                    gpu.set(22, 11, "✓ Connected to relay")
                    gpu.setForeground(colors.text)
                    gpu.set(22, 12, "  " .. response.relay_name)
                    
                    if response.server_connected then
                        gpu.setForeground(colors.success)
                        gpu.set(22, 14, "✓ Central server online")
                    else
                        gpu.setForeground(colors.warning)
                        gpu.set(22, 14, "⚠ Server searching...")
                    end
                    
                    showStatus("Press any key to continue...", "success")
                    event.pull("key_down")
                    return true
                end
            end
        end
    end
    
    gpu.setForeground(colors.error)
    gpu.set(22, 17, "✗ Connection failed")
    showStatus("Press any key to retry...", "error")
    event.pull("key_down")
    return false
end

-- Main menu
local function mainMenu()
    clearScreen()
    drawHeader("◆ TURRET MANAGER ◆", "Cross-Dimensional Control")
    
    -- Info box
    drawBox(15, 6, 50, 5, colors.bg)
    gpu.setForeground(colors.accent)
    gpu.set(17, 7, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    gpu.setForeground(colors.textDim)
    gpu.set(17, 8, "  Manage turrets across all dimensions")
    gpu.set(17, 9, "  Changes apply globally or per-world")
    gpu.setForeground(colors.accent)
    gpu.set(17, 10, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    -- Menu options
    local menuY = 13
    gpu.setForeground(colors.text)
    gpu.set(25, menuY, "1  Add Trusted Player (ALL)")
    gpu.set(25, menuY + 2, "2  Remove Trusted Player (ALL)")
    gpu.set(25, menuY + 4, "3  View All Trusted Players")
    gpu.set(25, menuY + 6, "4  View Controllers")
    gpu.set(25, menuY + 8, "5  Exit")
    
    drawFooter("Manager • Tunnel: " .. tunnel.getChannel():sub(1, 16))
    
    local _, _, char = event.pull("key_down")
    return char
end

-- Add player screen
local function addPlayerScreen()
    clearScreen()
    drawHeader("◆ ADD TRUSTED PLAYER ◆", "Allow player to bypass ALL turrets")
    
    drawBox(20, 8, 40, 10, colors.bg)
    
    gpu.setForeground(colors.text)
    local player = input("Player Name: ", 11, false, 25)
    
    if not player or player == "" then
        showStatus("✗ Player name required", "error")
        os.sleep(2)
        return
    end
    
    gpu.setForeground(colors.warning)
    gpu.set(22, 14, "This will add to ALL dimensions!")
    drawButton(30, 16, "CONFIRM [Y]", true)
    drawButton(44, 16, "CANCEL [N]", false)
    
    local _, _, confirmChar = event.pull("key_down")
    
    if confirmChar == string.byte('y') or confirmChar == string.byte('Y') or confirmChar == 28 then
        showStatus("⟳ Adding player globally...", "info")
        
        local response = sendAndWait({
            command = "addTrustedPlayer",
            player = player
        }, 8)
        
        if response and response.status == "success" then
            local exists = false
            for _, p in ipairs(cachedPlayers) do
                if p == player then
                    exists = true
                    break
                end
            end
            if not exists then
                table.insert(cachedPlayers, player)
            end
            
            showStatus("✓ Player added to all turrets!", "success")
        elseif response then
            showStatus("✗ " .. (response.reason or "Failed to add player"), "error")
        else
            showStatus("✗ No response from server", "error")
        end
    else
        showStatus("Cancelled", "warning")
    end
    
    os.sleep(2)
end

-- Remove player screen
local function removePlayerScreen()
    clearScreen()
    drawHeader("◆ REMOVE TRUSTED PLAYER ◆", "Revoke access from ALL turrets")
    
    drawBox(20, 8, 40, 10, colors.bg)
    
    gpu.setForeground(colors.text)
    local player = input("Player Name: ", 11, false, 25)
    
    if not player or player == "" then
        showStatus("✗ Player name required", "error")
        os.sleep(2)
        return
    end
    
    gpu.setForeground(colors.error)
    gpu.set(22, 14, "Remove from ALL dimensions?")
    drawButton(30, 16, "CONFIRM [Y]", true)
    drawButton(44, 16, "CANCEL [N]", false)
    
    local _, _, confirmChar = event.pull("key_down")
    
    if confirmChar == string.byte('y') or confirmChar == string.byte('Y') or confirmChar == 28 then
        showStatus("⟳ Removing player globally...", "info")
        
        local response = sendAndWait({
            command = "removeTrustedPlayer",
            player = player
        }, 8)
        
        if response and response.status == "success" then
            for i = #cachedPlayers, 1, -1 do
                if cachedPlayers[i] == player then
                    table.remove(cachedPlayers, i)
                end
            end
            
            showStatus("✓ Player removed from all turrets!", "success")
        elseif response then
            showStatus("✗ " .. (response.reason or "Failed to remove player"), "error")
        else
            showStatus("✗ No response from server", "error")
        end
    else
        showStatus("Cancelled", "warning")
    end
    
    os.sleep(2)
end

-- View players screen
local function viewPlayersScreen()
    showStatus("⟳ Loading trusted players...", "info")
    
    local response = sendAndWait({
        command = "getTrustedPlayers"
    }, 8)
    
    if response and response.status == "success" and response.players then
        cachedPlayers = response.players
        
        clearScreen()
        drawHeader("◆ TRUSTED PLAYERS ◆", "Global list across all dimensions")
        
        gpu.setForeground(colors.textDim)
        gpu.set(10, 6, "PLAYER NAME")
        gpu.set(50, 6, "STATUS")
        
        drawLine(10, 7, 60, "─")
        
        local y = 8
        for i = 1, math.min(15, #cachedPlayers) do
            local player = cachedPlayers[i]
            gpu.setForeground(colors.text)
            gpu.set(10, y, "• " .. player)
            
            gpu.setForeground(colors.success)
            gpu.set(50, y, "Global")
            y = y + 1
        end
        
        if #cachedPlayers == 0 then
            gpu.setForeground(colors.textDim)
            gpu.set(10, 8, "(no trusted players)")
        end
        
        if #cachedPlayers > 15 then
            gpu.setForeground(colors.textDim)
            gpu.set(10, y + 1, "... and " .. (#cachedPlayers - 15) .. " more")
        end
        
        drawFooter("Press any key to return...")
        event.pull("key_down")
    else
        showStatus("✗ Failed to load players", "error")
        os.sleep(2)
    end
end

-- View controllers screen
local function viewControllersScreen()
    showStatus("⟳ Loading controller info...", "info")
    
    local response = sendAndWait({
        command = "getControllers"
    }, 8)
    
    clearScreen()
    drawHeader("◆ TURRET CONTROLLERS ◆", "Active controllers by dimension")
    
    if response and response.status == "success" and response.controllers then
        gpu.setForeground(colors.textDim)
        gpu.set(5, 6, "WORLD/DIMENSION")
        gpu.set(35, 6, "CONTROLLER NAME")
        gpu.set(60, 6, "TURRETS")
        
        drawLine(5, 7, 70, "─")
        
        local y = 8
        for i = 1, math.min(12, #response.controllers) do
            local ctrl = response.controllers[i]
            gpu.setForeground(colors.accent)
            local world = ctrl.world or "Unknown"
            if #world > 25 then world = world:sub(1, 22) .. "..." end
            gpu.set(5, y, world)
            
            gpu.setForeground(colors.text)
            local name = ctrl.name or "Unknown"
            if #name > 20 then name = name:sub(1, 17) .. "..." end
            gpu.set(35, y, name)
            
            gpu.setForeground(colors.success)
            gpu.set(60, y, tostring(ctrl.turrets or 0))
            
            y = y + 1
        end
        
        if not response.controllers or #response.controllers == 0 then
            gpu.setForeground(colors.textDim)
            gpu.set(5, 8, "(no controllers connected)")
        end
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 10, "✗ Could not load controller information")
        gpu.setForeground(colors.textDim)
        gpu.set(5, 12, "This feature requires server support")
    end
    
    drawFooter("Press any key to return...")
    event.pull("key_down")
end

-- Main loop
local function main()
    clearScreen()
    
    -- Register with relay first
    while not relayConnected do
        if not registerWithRelay() then
            clearScreen()
            gpu.setForeground(colors.text)
            gpu.set(2, 10, "Retry connection? (y/n)")
            local _, _, char = event.pull("key_down")
            if char ~= string.byte('y') and char ~= string.byte('Y') then
                return
            end
        end
    end
    
    -- Main loop
    while true do
        local action = mainMenu()
        
        if action == string.byte('1') then
            addPlayerScreen()
        elseif action == string.byte('2') then
            removePlayerScreen()
        elseif action == string.byte('3') then
            viewPlayersScreen()
        elseif action == string.byte('4') then
            viewControllersScreen()
        elseif action == string.byte('5') then
            break
        end
    end
    
    clearScreen()
    gpu.setForeground(colors.success)
    local msg = "Thank you for using Turret Manager!"
    local msgX = math.floor((w - unicode.len(msg)) / 2)
    gpu.set(msgX, 12, msg)
end

local success, err = pcall(main)
if not success then
    clearScreen()
    gpu.setForeground(colors.error)
    print("Error: " .. tostring(err))
end

-- Final cleanup
if relayConnected then
    local dereg = serialization.serialize({
        type = "manager_disconnect",
        tunnelAddress = tunnel.address,
        tunnelChannel = tunnel.getChannel()
    })
    pcall(tunnel.send, dereg)
end
