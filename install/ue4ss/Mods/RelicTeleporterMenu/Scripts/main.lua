--[[
    Palworld Relic Teleporter
    UE4SS Lua entry point

    Responsibilities:
      1. Read relic actor positions from PalworldStatues.txt.
      2. Filter out notes and unrelated ObtainFX objects.
      3. Export the filtered list to a TSV file for the popup.
      4. Launch the PowerShell/Windows Forms popup when F8 is pressed.
      5. Receive the selected relic index from the popup.
      6. Teleport the local player on the Unreal Engine game thread.
]]

local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local MOD_NAME = "RelicTeleporterMenu"

-- This file must be placed in Pal\Binaries\Win64.
local SOURCE_FILE = "PalworldStatues.txt"

-- Small vertical offset applied to the destination to reduce the chance of
-- spawning inside the pedestal or terrain.
local Z_OFFSET = 10.0

-- ============================================================================
-- Runtime state
-- ============================================================================

local relics = {}
local relicsLoaded = false

-- ============================================================================
-- Logging and validation helpers
-- ============================================================================

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, message))
end

-- UE4SS UObject wrappers may still exist after the underlying Unreal object has
-- been destroyed. Always validate objects before calling game functions.
local function isValid(object)
    return object ~= nil
        and object.IsValid ~= nil
        and object:IsValid()
end

-- Resolve the directory containing this main.lua file.
local function getScriptDirectory()
    local source = debug.getinfo(1, "S").source or ""

    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end

    return source:match("^(.*)[/\\]") or "."
end

local SCRIPT_DIRECTORY = getScriptDirectory()

-- Files used to communicate with the external Windows Forms popup.
local MENU_SCRIPT = SCRIPT_DIRECTORY .. "\\RelicMenu.ps1"
local MENU_DATA_FILE = SCRIPT_DIRECTORY .. "\\RelicMenuData.tsv"
local COMMAND_FILE = SCRIPT_DIRECTORY .. "\\RelicMenuCommand.txt"
local LOCK_FILE = SCRIPT_DIRECTORY .. "\\RelicMenu.lock"
local UI_COMMAND_FILE = SCRIPT_DIRECTORY .. "\\RelicMenuUiCommand.txt"

local function fileExists(path)
    local file = io.open(path, "r")

    if file then
        file:close()
        return true
    end

    return false
end

local function writeTextFile(path, content)
    local file, openError = io.open(path, "w")

    if not file then
        log(string.format(
            "Could not write '%s': %s",
            path,
            tostring(openError)
        ))
        return false
    end

    file:write(content or "")
    file:close()
    return true
end

-- ============================================================================
-- Relic data loading
-- ============================================================================

-- Locate PalworldStatues.txt from the game's Win64 directory.
local function getSourcePath()
    local success, directories = pcall(IterateGameDirectories)

    if success
        and directories
        and directories.Game
        and directories.Game.Binaries
        and directories.Game.Binaries.Win64
    then
        local win64Path = directories.Game.Binaries.Win64.__absolute_path

        if win64Path then
            return win64Path .. "\\" .. SOURCE_FILE
        end
    end

    -- Fallback to the current working directory.
    return SOURCE_FILE
end

-- Convert an Unreal actor class such as
-- BP_LevelObject_Relic_FlameBambi_C into a readable popup label.
local function getRelicDisplayName(actorType)
    local name = actorType or "Relic"

    name = name:gsub("^BP_LevelObject_Relic_", "")
    name = name:gsub("^BP_LevelObject_Relic", "")
    name = name:gsub("_C$", "")
    name = name:gsub("_", " ")

    if name == "" then
        return "Standard Relic"
    end

    return name
end

-- Parse the dump and keep only actor types beginning with
-- BP_LevelObject_Relic. This excludes notes, tower pickups and other objects
-- that also contain an ObtainFX component.
local function loadRelicsFromFile(forceReload)
    if relicsLoaded and not forceReload then
        return true
    end

    relics = {}

    local sourcePath = getSourcePath()
    local file, openError = io.open(sourcePath, "r")

    if not file then
        relicsLoaded = false
        log(string.format(
            "Could not open '%s': %s",
            sourcePath,
            tostring(openError)
        ))
        log("Place PalworldStatues.txt in Pal\\Binaries\\Win64.")
        return false
    end

    local pendingActorType = nil
    local seen = {}

    for line in file:lines() do
        -- Example:
        -- Actor : BP_LevelObject_Relic_C /Game/Pal/Maps/...
        local actorType = line:match("^Actor%s*:%s*([^%s]+)")

        if actorType then
            if actorType:match("^BP_LevelObject_Relic") then
                pendingActorType = actorType
            else
                pendingActorType = nil
            end
        elseif pendingActorType then
            -- Example:
            -- Position : X=-26300.373 | Y=-88939.810 | Z=3833.230
            local x, y, z = line:match(
                "^Position%s*:%s*X=([%-%d%.]+)%s*|%s*Y=([%-%d%.]+)%s*|%s*Z=([%-%d%.]+)"
            )

            if x and y and z then
                x = tonumber(x)
                y = tonumber(y)
                z = tonumber(z)

                if x and y and z then
                    -- Prevent duplicate entries in case the source dump contains
                    -- the same actor and coordinates more than once.
                    local uniqueKey = string.format(
                        "%s|%.3f|%.3f|%.3f",
                        pendingActorType,
                        x,
                        y,
                        z
                    )

                    if not seen[uniqueKey] then
                        seen[uniqueKey] = true

                        table.insert(relics, {
                            actorType = pendingActorType,
                            displayName = getRelicDisplayName(pendingActorType),
                            x = x,
                            y = y,
                            z = z
                        })
                    end
                end

                pendingActorType = nil
            end
        end
    end

    file:close()

    -- Keep a deterministic order so list indices remain stable between reloads.
    table.sort(relics, function(a, b)
        if a.actorType ~= b.actorType then
            return a.actorType < b.actorType
        end

        if a.x ~= b.x then
            return a.x < b.x
        end

        if a.y ~= b.y then
            return a.y < b.y
        end

        return a.z < b.z
    end)

    relicsLoaded = #relics > 0

    if relicsLoaded then
        log(string.format(
            "Loaded %d relics from '%s'.",
            #relics,
            sourcePath
        ))
    else
        log("No BP_LevelObject_Relic entries were found in the source file.")
    end

    return relicsLoaded
end

-- Write a small tab-separated file that PowerShell can display in the grid.
local function writeMenuData()
    local file, openError = io.open(MENU_DATA_FILE, "w")

    if not file then
        log(string.format(
            "Could not create popup data: %s",
            tostring(openError)
        ))
        return false
    end

    file:write("Index\tRelic\tActorType\tX\tY\tZ\n")

    for index, relic in ipairs(relics) do
        file:write(string.format(
            "%d\t%s\t%s\t%.3f\t%.3f\t%.3f\n",
            index,
            relic.displayName,
            relic.actorType,
            relic.x,
            relic.y,
            relic.z
        ))
    end

    file:close()
    return true
end

-- ============================================================================
-- Palworld player access and teleportation
-- ============================================================================

local function getPlayerPawn()
    local success, controller = pcall(function()
        return UEHelpers:GetPlayerController()
    end)

    if not success or not isValid(controller) then
        return nil, nil
    end

    local pawn = controller.Pawn

    if not isValid(pawn) then
        return nil, nil
    end

    local world = pawn:GetWorld()

    if not isValid(world) then
        return nil, nil
    end

    return pawn, world
end

local function teleportToRelic(index)
    local pawn, world = getPlayerPawn()

    if not isValid(pawn) or not isValid(world) then
        log("No active game was detected. Load a save before teleporting.")
        return
    end

    if not relicsLoaded and not loadRelicsFromFile(false) then
        return
    end

    index = tonumber(index)

    if not index or not relics[index] then
        log(string.format(
            "Invalid relic index: %s",
            tostring(index)
        ))
        return
    end

    local target = relics[index]

    -- Reuse FVector and FRotator structures returned by the game. This avoids
    -- manually constructing Unreal Engine structures through UE4SS.
    local success, teleportResult = pcall(function()
        local destination = pawn:K2_GetActorLocation()
        destination.X = target.x
        destination.Y = target.y
        destination.Z = target.z + Z_OFFSET

        local rotation = pawn:K2_GetActorRotation()
        return pawn:K2_TeleportTo(destination, rotation)
    end)

    if not success then
        log(string.format(
            "Teleportation to relic %d failed: %s",
            index,
            tostring(teleportResult)
        ))
        return
    end

    if teleportResult == false then
        log(string.format(
            "Palworld rejected the teleportation to relic %d.",
            index
        ))
        return
    end

    log(string.format(
        "Teleported to %d/%d | %s | X=%.3f Y=%.3f Z=%.3f",
        index,
        #relics,
        target.actorType,
        target.x,
        target.y,
        target.z
    ))
end

-- ============================================================================
-- Popup launch and file-based communication
-- ============================================================================

-- Quote a Windows command-line argument while preserving spaces in paths.
local function quoteCommandArgument(value)
    return '"' .. tostring(value):gsub('"', '\\"') .. '"'
end

local function openRelicMenu()
    local pawn = getPlayerPawn()

    if not isValid(pawn) then
        log("Load a save before opening the relic menu.")
        return
    end

    if not fileExists(MENU_SCRIPT) then
        log(string.format(
            "Required popup script is missing: %s",
            MENU_SCRIPT
        ))
        return
    end

    -- Reload the source every time F8 is pressed so changes to the dump are
    -- reflected without restarting Palworld.
    if not loadRelicsFromFile(true) then
        return
    end

    if not writeMenuData() then
        return
    end

    -- Clear stale commands before opening or reactivating the popup.
    writeTextFile(COMMAND_FILE, "")
    writeTextFile(UI_COMMAND_FILE, "")

    -- The PowerShell script uses a lock file. If a popup already exists, the
    -- new process only asks the existing window to reload and return to front.
    local command = table.concat({
        "cmd.exe /c start \"\" powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-STA",
        "-ExecutionPolicy Bypass",
        "-WindowStyle Hidden",
        "-File", quoteCommandArgument(MENU_SCRIPT),
        "-DataFile", quoteCommandArgument(MENU_DATA_FILE),
        "-CommandFile", quoteCommandArgument(COMMAND_FILE),
        "-LockFile", quoteCommandArgument(LOCK_FILE),
        "-UiCommandFile", quoteCommandArgument(UI_COMMAND_FILE)
    }, " ")

    local success, executeResult = pcall(function()
        return os.execute(command)
    end)

    if not success then
        log(string.format(
            "Could not open the relic menu: %s",
            tostring(executeResult)
        ))
        return
    end

    log("Relic menu opened.")
end

-- Poll the command file written by the popup. A short polling interval keeps
-- the interface responsive without performing Unreal calls outside the game
-- thread.
LoopAsync(150, function()
    local file = io.open(COMMAND_FILE, "r")

    if not file then
        return false
    end

    local command = file:read("*a") or ""
    file:close()

    command = command:match("^%s*(.-)%s*$") or ""

    if command ~= "" then
        -- Clear the command immediately so it cannot be executed twice.
        writeTextFile(COMMAND_FILE, "")

        local selectedIndex = tonumber(command:match("^(%d+)$"))

        if selectedIndex then
            -- Unreal Engine actor functions must run on the game thread.
            ExecuteInGameThread(function()
                teleportToRelic(selectedIndex)
            end)
        else
            log(string.format(
                "Unknown popup command: %s",
                command
            ))
        end
    end

    return false
end)

-- F8 opens the popup or brings the existing popup back to the foreground.
RegisterKeyBind(Key.F8, function()
    openRelicMenu()
end)

log("Mod loaded. Press F8 in game to open the clickable relic list.")
