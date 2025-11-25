-- GPS Tracking Server for OpenComputers 1.7.10
-- Tracks player/drone/entity locations via network
-- Integrates with existing relay infrastructure

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")
local computer = require("computer")
local gpu = component.gpu
local term = require("term")

-- Configuration
local PORT = 1001  -- Different port from currency server
local SERVER_NAME = "GPSTracker"
local DATA_DIR = "/home/gps/"

-- Network components
local modem = component.modem

-- Data structures
local trackedEntities = {}  -- entityId -> {name, x, y, z, dimension, lastUpdate, relay, type}
local locationHistory = {}  -- entityId -> array of recent positions
local relays = {}
local stats = {
    totalEntities = 0,
    totalUpdates = 0,
    relayCount = 0
}

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
    textDim = 0x9CA3AF
}

-- Initialize data directory
if not filesystem.exists(DATA_DIR) then
    filesystem.makeDirectory(DATA_DIR)
end

-- Utility functions
local function log(message, category)
    category = category or "INFO"
    local entry = {
        time = os.date("%Y-%m-%d %H:%M:%S"),
        category = category,
        message = message
    }
    
    local file = io.open(DATA_DIR .. "gps.log", "a")
    if file then
        file:write(serialization.serialize(entry) .. "\n")
        file:close()
    end
    
    stats.totalUpdates = stats.totalUpdates + 1
end

local function saveData()
    local file = io.open(DATA_DIR .. "entities.dat", "w")
    if file then
        file:write(serialization.serialize(trackedEntities))
        file:close()
        return true
    end
    return false
end

local function loadData()
    local file = io.open(DATA_DIR .. "entities.dat", "r")
    if file then
        local data = file:read("*a")
        file:close()
        
        if data and data ~= "" then
            local success, loaded = pcall(serialization.unserialize, data)
            if success and loaded then
                trackedEntities = loaded
                stats.totalEntities = 0
                for _ in pairs(trackedEntities) do
                    stats.totalEntities = stats.totalEntities + 1
                end
                return true
            end
        end
    end
    return false
end

-- Calculate distance between two points
local function calculateDistance(x1, y1, z1, x2, y2, z2)
    local dx = x2 - x1
    local dy = y2 - y1
    local dz = z2 - z1
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Register or update entity location
local function updateLocation(entityId, name, x, y, z, dimension, entityType, relayAddress)
    dimension = dimension or "overworld"
    entityType = entityType or "unknown"
    
    local now = os.time()
    
    if not trackedEntities[entityId] then
        stats.totalEntities = stats.totalEntities + 1
    end
    
    -- Store previous location for history
    if trackedEntities[entityId] then
        if not locationHistory[entityId] then
            locationHistory[entityId] = {}
        end
        
        table.insert(locationHistory[entityId], {
            x = trackedEntities[entityId].x,
            y = trackedEntities[entityId].y,
            z = trackedEntities[entityId].z,
            time = trackedEntities[entityId].lastUpdate
        })
        
        -- Keep only last 50 positions
        if #locationHistory[entityId] > 50 then
            table.remove(locationHistory[entityId], 1)
        end
    end
    
    trackedEntities[entityId] = {
        name = name,
        x = x,
        y = y,
        z = z,
        dimension = dimension,
        lastUpdate = now,
        relay = relayAddress,
        type = entityType
    }
    
    log(string.format("Location updated: %s (%s) at [%.1f, %.1f, %.1f] in %s", 
        name, entityType, x, y, z, dimension), "LOCATION")
    
    saveData()
    return true
end

-- Get entity location
local function getLocation(entityId)
    local entity = trackedEntities[entityId]
    if entity then
        return {
            success = true,
            name = entity.name,
            x = entity.x,
            y = entity.y,
            z = entity.z,
            dimension = entity.dimension,
            type = entity.type,
            lastUpdate = entity.lastUpdate,
            age = os.time() - entity.lastUpdate
        }
    end
    return {success = false, message = "Entity not found"}
end

-- Get all entities in range
local function getEntitiesInRange(x, y, z, range, dimension)
    dimension = dimension or "overworld"
    local results = {}
    
    for id, entity in pairs(trackedEntities) do
        if entity.dimension == dimension then
            local dist = calculateDistance(x, y, z, entity.x, entity.y, entity.z)
            if dist <= range then
                table.insert(results, {
                    id = id,
                    name = entity.name,
                    x = entity.x,
                    y = entity.y,
                    z = entity.z,
                    distance = dist,
                    type = entity.type,
                    lastUpdate = entity.lastUpdate
                })
            end
        end
    end
    
    -- Sort by distance
    table.sort(results, function(a, b) return a.distance < b.distance end)
    
    return results
end

-- Get all tracked entities
local function getAllEntities()
    local results = {}
    for id, entity in pairs(trackedEntities) do
        table.insert(results, {
            id = id,
            name = entity.name,
            x = entity.x,
            y = entity.y,
            z = entity.z,
            dimension = entity.dimension,
            type = entity.type,
            lastUpdate = entity.lastUpdate,
            age = os.time() - entity.lastUpdate
        })
    end
    
    -- Sort by last update (most recent first)
    table.sort(results, function(a, b) return a.lastUpdate > b.lastUpdate end)
    
    return results
end

-- Relay management
local function registerRelay(address, relayName)
    if not relays[address] then
        relays[address] = {
            address = address,
            name = relayName,
            lastSeen = computer.uptime()
        }
        stats.relayCount = stats.relayCount + 1
        log("GPS Relay connected: " .. relayName, "RELAY")
    else
        relays[address].lastSeen = computer.uptime()
    end
end

-- UI Drawing
local function drawServerUI()
    gpu.setBackground(0x0000AA)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, w, h, " ")
    
    -- Header
    gpu.setBackground(0x000080)
    gpu.fill(1, 1, w, 3, " ")
    local title = "=== " .. SERVER_NAME .. " ==="
    gpu.set(math.floor((w - #title) / 2), 2, title)
    
    -- Stats panel
    gpu.setBackground(0x1E1E1E)
    gpu.setForeground(0x00FF00)
    gpu.fill(1, 4, w, 2, " ")
    gpu.set(2, 4, "Tracked Entities: " .. stats.totalEntities)
    gpu.set(30, 4, "Updates: " .. stats.totalUpdates)
    gpu.set(50, 4, "Relays: " .. stats.relayCount)
    gpu.set(65, 4, "Port: " .. PORT)
    
    gpu.setForeground(0xFFFF00)
    gpu.set(2, 5, "Mode: GPS TRACKING")
    
    -- Relays
    gpu.setBackground(0x2D2D2D)
    gpu.setForeground(0xFFFF00)
    gpu.fill(1, 7, w, 1, " ")
    gpu.set(2, 7, "Connected Relays:")
    
    gpu.setForeground(0xFFFFFF)
    gpu.set(2, 8, "Name")
    gpu.set(30, 8, "Address")
    gpu.set(55, 8, "Status")
    
    local y = 9
    local relayList = {}
    for _, relay in pairs(relays) do
        table.insert(relayList, relay)
    end
    table.sort(relayList, function(a, b) return a.lastSeen > b.lastSeen end)
    
    for i = 1, math.min(3, #relayList) do
        local relay = relayList[i]
        local now = computer.uptime()
        local timeDiff = now - relay.lastSeen
        local isActive = timeDiff < 60
        
        gpu.setForeground(isActive and 0x00FF00 or 0x888888)
        local name = relay.name or "Unknown"
        if #name > 25 then name = name:sub(1, 22) .. "..." end
        gpu.set(2, y, name)
        gpu.set(30, y, relay.address:sub(1, 16))
        
        gpu.setForeground(isActive and 0x00FF00 or 0xFF0000)
        gpu.set(55, y, isActive and "ACTIVE" or "TIMEOUT")
        y = y + 1
    end
    
    -- Tracked entities
    gpu.setForeground(0xFFFF00)
    gpu.fill(1, 13, w, 1, " ")
    gpu.set(2, 13, "Recently Active Entities:")
    
    gpu.setBackground(0x2D2D2D)
    gpu.setForeground(0xFFFFFF)
    gpu.set(2, 14, "Name")
    gpu.set(25, 14, "Type")
    gpu.set(38, 14, "Position")
    gpu.set(60, 14, "Age")
    
    local entities = getAllEntities()
    y = 15
    for i = 1, math.min(8, #entities) do
        local entity = entities[i]
        local age = os.time() - entity.lastUpdate
        local isStale = age > 300  -- 5 minutes
        
        gpu.setForeground(isStale and 0x888888 or 0xCCCCCC)
        local name = entity.name
        if #name > 20 then name = name:sub(1, 17) .. "..." end
        gpu.set(2, y, name)
        
        gpu.setForeground(0xFFFF00)
        gpu.set(25, y, entity.type:sub(1, 10))
        
        gpu.setForeground(0x00FF00)
        local pos = string.format("%.0f,%.0f,%.0f", entity.x, entity.y, entity.z)
        gpu.set(38, y, pos)
        
        gpu.setForeground(isStale and 0xFF0000 or 0x888888)
        local ageStr
        if age < 60 then
            ageStr = age .. "s"
        elseif age < 3600 then
            ageStr = math.floor(age / 60) .. "m"
        else
            ageStr = math.floor(age / 3600) .. "h"
        end
        gpu.set(60, y, ageStr)
        
        y = y + 1
    end
    
    -- Footer
    gpu.setBackground(0x000080)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 25, w, 1, " ")
    gpu.set(2, 25, "GPS Tracking Server - Real-time location monitoring")
end

-- Message handler
local function handleMessage(eventType, _, sender, port, distance, message)
    if port ~= PORT then return end
    
    local success, data = pcall(serialization.unserialize, message)
    if not success or not data then return end
    
    -- Handle relay ping
    if data.type == "relay_ping" then
        registerRelay(sender, data.relay_name or "GPS Relay")
        
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
        registerRelay(sender, data.relay_name or "GPS Relay")
        drawServerUI()
        return
    end
    
    local response = {type = "response"}
    
    -- Command routing
    if data.command == "update_location" then
        if not data.entityId or not data.x or not data.y or not data.z then
            response.success = false
            response.message = "Missing required fields"
        else
            updateLocation(
                data.entityId,
                data.name or data.entityId,
                data.x,
                data.y,
                data.z,
                data.dimension,
                data.entityType,
                sender
            )
            response.success = true
            response.message = "Location updated"
        end
        
    elseif data.command == "get_location" then
        if not data.entityId then
            response.success = false
            response.message = "Entity ID required"
        else
            response = getLocation(data.entityId)
        end
        
    elseif data.command == "find_nearby" then
        if not data.x or not data.y or not data.z then
            response.success = false
            response.message = "Position required"
        else
            local range = data.range or 100
            local entities = getEntitiesInRange(data.x, data.y, data.z, range, data.dimension)
            response.success = true
            response.entities = entities
            response.count = #entities
        end
        
    elseif data.command == "list_all" then
        local entities = getAllEntities()
        response.success = true
        response.entities = entities
        response.total = #entities
        
    elseif data.command == "get_history" then
        if not data.entityId then
            response.success = false
            response.message = "Entity ID required"
        else
            local history = locationHistory[data.entityId]
            if history then
                response.success = true
                response.history = history
            else
                response.success = false
                response.message = "No history available"
            end
        end
        
    elseif data.command == "remove_entity" then
        if not data.entityId then
            response.success = false
            response.message = "Entity ID required"
        else
            if trackedEntities[data.entityId] then
                trackedEntities[data.entityId] = nil
                locationHistory[data.entityId] = nil
                stats.totalEntities = stats.totalEntities - 1
                saveData()
                response.success = true
                response.message = "Entity removed"
                log("Entity removed: " .. data.entityId, "ADMIN")
            else
                response.success = false
                response.message = "Entity not found"
            end
        end
    end
    
    modem.send(sender, PORT, serialization.serialize(response))
    drawServerUI()
end

-- Main server loop
local function main()
    print("Starting " .. SERVER_NAME .. " Server...")
    print("Data directory: " .. DATA_DIR)
    
    if loadData() then
        print("Loaded " .. stats.totalEntities .. " tracked entities")
    end
    
    modem.open(PORT)
    modem.setStrength(400)
    print("Listening on port " .. PORT)
    print("Wireless range: 400 blocks")
    
    event.listen("modem_message", handleMessage)
    
    drawServerUI()
    
    log("GPS server started", "SYSTEM")
    print("GPS Server running!")
    
    -- Maintenance timer
    event.timer(60, function()
        -- Cleanup old relays
        local now = computer.uptime()
        for address, relay in pairs(relays) do
            if now - relay.lastSeen > 120 then
                relays[address] = nil
            end
        end
        
        -- Mark stale entities (over 1 hour old)
        local staleCount = 0
        for id, entity in pairs(trackedEntities) do
            if os.time() - entity.lastUpdate > 3600 then
                staleCount = staleCount + 1
            end
        end
        
        stats.relayCount = 0
        for _ in pairs(relays) do
            stats.relayCount = stats.relayCount + 1
        end
        
        drawServerUI()
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
print("GPS Server stopped")
