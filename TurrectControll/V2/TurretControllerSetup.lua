-- Turret Controller Setup Wizard for OpenComputers 1.7.10
-- Interactive configuration and first-time setup

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local term = require("term")
local gpu = component.gpu

-- Configuration
local CONFIG_DIR = "/home/turret-controller/"
local CONFIG_FILE = CONFIG_DIR .. "config.cfg"

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
    inputBg = 0x1F2937
}

-- Default configuration
local defaultConfig = {
    controllerName = "Turret Controller",
    worldName = "Unknown",
    autoStart = false,
    version = "1.0"
}

-- Check requirements
local function checkRequirements()
    local issues = {}
    
    -- Check for tunnel (linked card)
    if not component.isAvailable("tunnel") then
        table.insert(issues, "LINKED CARD - Required for relay connection")
    end
    
    -- Check for turrets
    local turretCount = 0
    for address in component.list("tierFiveTurretBase") do
        turretCount = turretCount + 1
    end
    
    if turretCount == 0 then
        table.insert(issues, "TURRETS - No turrets detected (optional warning)")
    end
    
    return issues, turretCount
end

-- UI Functions
local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, h, " ")
end

local function drawHeader(title, subtitle)
    gpu.setBackground(colors.header)
    gpu.fill(1, 1, w, 3, " ")
    
    gpu.setForeground(colors.text)
    local titleX = math.floor((w - #title) / 2)
    gpu.set(titleX, 2, title)
    
    if subtitle then
        gpu.setForeground(colors.textDim)
        local subX = math.floor((w - #subtitle) / 2)
        gpu.set(subX, 3, subtitle)
    end
    
    gpu.setBackground(colors.bg)
end

local function drawBox(x, y, width, height, color)
    gpu.setBackground(color or colors.bg)
    gpu.fill(x, y, width, height, " ")
end

local function input(prompt, y, default, maxLen)
    maxLen = maxLen or 30
    gpu.setForeground(colors.text)
    gpu.set(5, y, prompt)
    
    local x = 5 + #prompt
    
    gpu.setBackground(colors.inputBg)
    gpu.fill(x, y, maxLen + 2, 1, " ")
    
    x = x + 1
    
    -- Show default value
    if default and default ~= "" then
        gpu.setForeground(colors.textDim)
        gpu.set(x, y, default)
    end
    
    gpu.setForeground(colors.text)
    gpu.set(x, y, "")
    
    local text = ""
    while true do
        local _, _, char, code = event.pull("key_down")
        
        if code == 28 then -- Enter
            if text == "" and default then
                return default
            end
            break
        elseif code == 14 and #text > 0 then -- Backspace
            text = text:sub(1, -2)
            gpu.setBackground(colors.inputBg)
            gpu.fill(x, y, maxLen, 1, " ")
            gpu.set(x, y, text)
        elseif char >= 32 and char < 127 and #text < maxLen then
            text = text .. string.char(char)
            gpu.set(x, y, text)
        end
    end
    
    gpu.setBackground(colors.bg)
    return text ~= "" and text or default
end

-- Configuration Management
local function loadConfig()
    if not filesystem.exists(CONFIG_FILE) then
        return nil
    end
    
    local file = io.open(CONFIG_FILE, "r")
    if file then
        local content = file:read("*a")
        file:close()
        
        local ok, config = pcall(serialization.unserialize, content)
        if ok and config then
            return config
        end
    end
    
    return nil
end

local function saveConfig(config)
    if not filesystem.exists(CONFIG_DIR) then
        filesystem.makeDirectory(CONFIG_DIR)
    end
    
    local file = io.open(CONFIG_FILE, "w")
    if file then
        file:write(serialization.serialize(config))
        file:close()
        return true
    end
    
    return false
end

-- Welcome Screen
local function welcomeScreen()
    clearScreen()
    drawHeader("◆ TURRET CONTROLLER SETUP ◆", "First-Time Configuration Wizard")
    
    drawBox(10, 6, 60, 14, colors.bg)
    
    gpu.setForeground(colors.accent)
    gpu.set(12, 7, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    gpu.setForeground(colors.text)
    gpu.set(12, 9, "Welcome to the Turret Controller Setup Wizard!")
    
    gpu.setForeground(colors.textDim)
    gpu.set(12, 11, "This wizard will help you configure your controller")
    gpu.set(12, 12, "for the cross-dimensional turret control system.")
    
    gpu.setForeground(colors.text)
    gpu.set(12, 14, "The wizard will:")
    gpu.setForeground(colors.textDim)
    gpu.set(14, 15, "• Check hardware requirements")
    gpu.set(14, 16, "• Set controller name and dimension")
    gpu.set(14, 17, "• Configure auto-start options")
    gpu.set(14, 18, "• Save configuration for future use")
    
    gpu.setForeground(colors.accent)
    gpu.set(12, 20, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    gpu.setForeground(colors.success)
    gpu.set(25, h - 1, "Press any key to continue...")
    
    event.pull("key_down")
end

-- Requirements Check Screen
local function requirementsScreen()
    clearScreen()
    drawHeader("◆ HARDWARE CHECK ◆", "Verifying requirements")
    
    gpu.setForeground(colors.text)
    gpu.set(5, 6, "Checking hardware components...")
    
    local issues, turretCount = checkRequirements()
    
    local y = 8
    
    -- Check linked card
    gpu.setForeground(colors.text)
    gpu.set(5, y, "Linked Card:")
    if component.isAvailable("tunnel") then
        local tunnel = component.tunnel
        gpu.setForeground(colors.success)
        gpu.set(30, y, "✓ FOUND")
        gpu.setForeground(colors.textDim)
        gpu.set(5, y + 1, "  Address: " .. tunnel.address:sub(1, 32))
        gpu.set(5, y + 2, "  Channel: " .. tunnel.getChannel():sub(1, 32))
        y = y + 3
    else
        gpu.setForeground(colors.error)
        gpu.set(30, y, "✗ MISSING")
        y = y + 1
    end
    
    y = y + 1
    
    -- Check turrets
    gpu.setForeground(colors.text)
    gpu.set(5, y, "Turrets:")
    if turretCount > 0 then
        gpu.setForeground(colors.success)
        gpu.set(30, y, "✓ FOUND (" .. turretCount .. ")")
        gpu.setForeground(colors.textDim)
        
        y = y + 1
        local shown = 0
        for address in component.list("tierFiveTurretBase") do
            if shown < 5 then
                gpu.set(5, y, "  " .. address:sub(1, 36))
                y = y + 1
                shown = shown + 1
            end
        end
        
        if turretCount > 5 then
            gpu.set(5, y, "  ... and " .. (turretCount - 5) .. " more")
            y = y + 1
        end
    else
        gpu.setForeground(colors.warning)
        gpu.set(30, y, "⚠ NONE")
        gpu.setForeground(colors.textDim)
        gpu.set(5, y + 1, "  No turrets detected - controller will work")
        gpu.set(5, y + 2, "  but won't manage any turrets until connected")
        y = y + 3
    end
    
    y = y + 2
    
    -- Summary
    if #issues > 0 then
        gpu.setForeground(colors.error)
        gpu.set(5, y, "⚠ CRITICAL ISSUES:")
        y = y + 1
        
        for _, issue in ipairs(issues) do
            if issue:find("LINKED CARD") then
                gpu.setForeground(colors.error)
                gpu.set(7, y, "• " .. issue)
                y = y + 1
            end
        end
        
        gpu.setForeground(colors.text)
        gpu.set(5, y + 1, "Please install required hardware before continuing.")
        gpu.set(5, h - 1, "Press any key to exit...")
        event.pull("key_down")
        return false, turretCount
    else
        gpu.setForeground(colors.success)
        gpu.set(5, y, "✓ All requirements met!")
        
        if turretCount == 0 then
            gpu.setForeground(colors.warning)
            gpu.set(5, y + 2, "Note: No turrets connected, but controller will work.")
        end
        
        gpu.setForeground(colors.text)
        gpu.set(5, h - 1, "Press any key to continue...")
        event.pull("key_down")
        return true, turretCount
    end
end

-- Configuration Screen
local function configurationScreen(existingConfig, turretCount)
    clearScreen()
    drawHeader("◆ CONTROLLER CONFIGURATION ◆", "Set your controller details")
    
    local config = existingConfig or defaultConfig
    
    gpu.setForeground(colors.accent)
    gpu.set(5, 6, "Configure Controller Settings:")
    gpu.setForeground(colors.textDim)
    gpu.set(5, 7, "(Press Enter to accept default values)")
    
    -- Controller Name
    gpu.setForeground(colors.text)
    local controllerName = input("Controller Name: ", 10, config.controllerName, 30)
    
    gpu.setForeground(colors.textDim)
    gpu.set(5, 11, "Examples: 'Nether Fortress', 'Overworld Base', 'End Island'")
    
    -- World/Dimension Name
    gpu.setForeground(colors.text)
    local worldName = input("World/Dimension: ", 13, config.worldName, 30)
    
    gpu.setForeground(colors.textDim)
    gpu.set(5, 14, "Examples: 'Overworld', 'Nether', 'End', 'Twilight Forest'")
    
    -- Auto-start option
    gpu.setForeground(colors.text)
    gpu.set(5, 17, "Auto-start controller on boot? (y/n): ")
    local autoStartInput = input("", 17, config.autoStart and "y" or "n", 1)
    local autoStart = autoStartInput:lower() == "y"
    
    -- Summary
    clearScreen()
    drawHeader("◆ CONFIGURATION SUMMARY ◆", "Please review your settings")
    
    drawBox(10, 6, 60, 12, colors.bg)
    
    gpu.setForeground(colors.accent)
    gpu.set(12, 7, "Configuration Summary:")
    
    gpu.setForeground(colors.text)
    gpu.set(12, 9, "Controller Name:")
    gpu.setForeground(colors.success)
    gpu.set(35, 9, controllerName)
    
    gpu.setForeground(colors.text)
    gpu.set(12, 11, "World/Dimension:")
    gpu.setForeground(colors.success)
    gpu.set(35, 11, worldName)
    
    gpu.setForeground(colors.text)
    gpu.set(12, 13, "Turrets Detected:")
    gpu.setForeground(colors.success)
    gpu.set(35, 13, tostring(turretCount))
    
    gpu.setForeground(colors.text)
    gpu.set(12, 15, "Auto-start:")
    gpu.setForeground(autoStart and colors.success or colors.textDim)
    gpu.set(35, 15, autoStart and "Enabled" or "Disabled")
    
    gpu.setForeground(colors.text)
    gpu.set(12, h - 3, "Is this correct? (y/n): ")
    local confirm = input("", h - 3, "y", 1)
    
    if confirm:lower() ~= "y" then
        return configurationScreen(existingConfig, turretCount)
    end
    
    return {
        controllerName = controllerName,
        worldName = worldName,
        autoStart = autoStart,
        version = "1.0"
    }
end

-- Save Configuration Screen
local function saveConfigScreen(config)
    clearScreen()
    drawHeader("◆ SAVING CONFIGURATION ◆", "Writing settings to disk")
    
    gpu.setForeground(colors.text)
    gpu.set(5, 10, "Saving configuration...")
    
    if saveConfig(config) then
        gpu.setForeground(colors.success)
        gpu.set(5, 12, "✓ Configuration saved successfully!")
        gpu.setForeground(colors.textDim)
        gpu.set(5, 13, "  Location: " .. CONFIG_FILE)
        
        if config.autoStart then
            gpu.setForeground(colors.text)
            gpu.set(5, 15, "Creating autorun.lua...")
            
            local autorunContent = [[
-- Auto-generated by setup wizard
local shell = require("shell")
print("Auto-starting Turret Controller...")
shell.execute("/home/turret-controller.lua")
]]
            
            local autorunFile = io.open("/home/.autorun.lua", "w")
            if autorunFile then
                autorunFile:write(autorunContent)
                autorunFile:close()
                gpu.setForeground(colors.success)
                gpu.set(5, 16, "✓ Auto-start enabled")
            else
                gpu.setForeground(colors.error)
                gpu.set(5, 16, "✗ Could not create autorun file")
            end
        end
        
        return true
    else
        gpu.setForeground(colors.error)
        gpu.set(5, 12, "✗ Failed to save configuration")
        gpu.set(5, 13, "  Please check disk permissions")
        return false
    end
end

-- Completion Screen
local function completionScreen(config)
    clearScreen()
    drawHeader("◆ SETUP COMPLETE ◆", "Your controller is ready!")
    
    drawBox(10, 6, 60, 16, colors.bg)
    
    gpu.setForeground(colors.success)
    gpu.set(12, 7, "✓ Setup completed successfully!")
    
    gpu.setForeground(colors.text)
    gpu.set(12, 9, "Your controller is configured as:")
    gpu.setForeground(colors.accent)
    gpu.set(14, 10, config.controllerName .. " (" .. config.worldName .. ")")
    
    gpu.setForeground(colors.text)
    gpu.set(12, 12, "Next steps:")
    gpu.setForeground(colors.textDim)
    gpu.set(14, 13, "1. Ensure relay is running in main dimension")
    gpu.set(14, 14, "2. Verify linked card is paired with relay")
    gpu.set(14, 15, "3. Run: turret-controller")
    
    if config.autoStart then
        gpu.setForeground(colors.success)
        gpu.set(14, 17, "Auto-start: Controller will run on boot")
    else
        gpu.setForeground(colors.textDim)
        gpu.set(14, 17, "Manual start: Run 'turret-controller' to start")
    end
    
    gpu.setForeground(colors.text)
    gpu.set(12, 19, "Configuration saved to:")
    gpu.setForeground(colors.textDim)
    gpu.set(14, 20, CONFIG_FILE)
    
    gpu.setForeground(colors.text)
    gpu.set(12, 22, "To reconfigure later, run: setup-wizard")
    
    gpu.setForeground(colors.success)
    gpu.set(20, h - 1, "Press any key to exit setup...")
    event.pull("key_down")
end

-- Main Setup Flow
local function main()
    -- Check if already configured
    local existingConfig = loadConfig()
    
    if existingConfig then
        clearScreen()
        drawHeader("◆ CONFIGURATION EXISTS ◆", "Existing setup detected")
        
        gpu.setForeground(colors.text)
        gpu.set(5, 8, "Found existing configuration:")
        gpu.setForeground(colors.accent)
        gpu.set(7, 10, "Controller: " .. existingConfig.controllerName)
        gpu.set(7, 11, "World: " .. existingConfig.worldName)
        gpu.set(7, 12, "Auto-start: " .. (existingConfig.autoStart and "Enabled" or "Disabled"))
        
        gpu.setForeground(colors.text)
        gpu.set(5, 15, "What would you like to do?")
        gpu.set(7, 17, "1. Keep current configuration and exit")
        gpu.set(7, 18, "2. Reconfigure (run setup again)")
        gpu.set(7, 19, "3. View configuration file location")
        
        gpu.set(5, 22, "Choice (1-3): ")
        local _, _, char = event.pull("key_down")
        
        if char == string.byte('1') then
            clearScreen()
            gpu.setForeground(colors.success)
            gpu.set(5, 10, "Using existing configuration.")
            gpu.setForeground(colors.text)
            gpu.set(5, 12, "Run 'turret-controller' to start.")
            return
        elseif char == string.byte('3') then
            clearScreen()
            gpu.setForeground(colors.text)
            gpu.set(5, 10, "Configuration file location:")
            gpu.setForeground(colors.accent)
            gpu.set(5, 12, CONFIG_FILE)
            gpu.setForeground(colors.text)
            gpu.set(5, 14, "To edit manually:")
            gpu.setForeground(colors.textDim)
            gpu.set(5, 15, "  edit " .. CONFIG_FILE)
            gpu.set(5, 18, "Press any key to exit...")
            event.pull("key_down")
            return
        end
        -- If choice 2, continue with setup
    end
    
    -- Run setup wizard
    welcomeScreen()
    
    local passed, turretCount = requirementsScreen()
    if not passed then
        return
    end
    
    local config = configurationScreen(existingConfig, turretCount)
    
    if saveConfigScreen(config) then
        completionScreen(config)
    else
        gpu.setForeground(colors.error)
        gpu.set(5, h - 1, "Setup failed. Press any key to exit...")
        event.pull("key_down")
    end
end

-- Run setup
local success, err = pcall(main)
if not success then
    clearScreen()
    gpu.setForeground(colors.error)
    print("Setup error: " .. tostring(err))
end
