local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local RunService = game:GetService("RunService")

local database = DataStoreService:GetDataStore("database")
local recoveryStore = DataStoreService:GetDataStore("RecoverySave") -- the Recovery Save Spot
local towers = require(ReplicatedStorage:WaitForChild("TowerShop"))

local SLOT_COUNT = 5
local DATA_VERSION = 2 -- 2 = units with UIDs (old saves are converted automatically)

----------------------------------------------------------------
-- SUMMON SETTINGS
----------------------------------------------------------------
local SUMMON_PRICE = 0         -- <<< how many Stars a summon COSTS (positive number)
local SUMMON_COOLDOWN = 0        -- seconds between summons per player (anti-spam)
local ALLOW_DIRECT_BUY = false   -- false = towers can ONLY be summoned (blocks the old "Buy" exploit)

----------------------------------------------------------------
-- UNIT SETTINGS
----------------------------------------------------------------
local ALLOW_DUPLICATE_EQUIP = true   -- true = you can equip multiple copies of the same tower
local STARTING_STARS = 100
local STARTER_UNITS = { "Brute", "Slinger" } -- what new players get
local STARTER_EQUIPPED = { "Brute" }         -- which of those start equipped

----------------------------------------------------------------
-- ADMIN SETTINGS
----------------------------------------------------------------
local ADMIN_USER_ID = 1920941505 -- the ONLY account that can use admin commands
local COMMAND_PREFIX = "!"

----------------------------------------------------------------
-- CODES (redeemed in the Codes menu, every code works once per player)
----------------------------------------------------------------
--[[
	Add as many as you want, one per line:

		["CODE"] = { Stars = 500 },                              -- Stars
		["CODE"] = { Towers = { "Brute" } },                     -- one Brute
		["CODE"] = { Towers = { Brute = 2, Slinger = 1 } },      -- 2 Brutes + 1 Slinger
		["CODE"] = { Stars = 250, Towers = { "Slinger" } },      -- Stars AND a tower
		["CODE"] = { Stars = 100, Expires = "2026-12-31" },      -- stops working after that day (UTC)
		["CODE"] = { Stars = 100, Enabled = false },             -- switched off for now

	Codes aren't case sensitive and spaces are ignored ("release" works for
	"RELEASE"). They only exist here on the server, so exploiters can't read them.
]]
local CODES = {
	["RELEASE"] = { Stars = 500 },
	["GNOMES"] = { Towers = { "Brute" } },
	["THANKYOU"] = { Stars = 250, Towers = { Slinger = 1 } },
}
local CODE_COOLDOWN = 1      -- seconds between tries, per player
local CODE_MAX_WRONG = 8     -- wrong codes in a row before a short timeout (stops code guessing)
local CODE_TIMEOUT = 30      -- seconds that timeout lasts

----------------------------------------------------------------
-- SIGNING (who can sign is in ReplicatedStorage.Modules.Roles)
----------------------------------------------------------------
local SIGN_PERMISSION = "Sign"   -- the role permission that allows signing units
local SIGN_COOLDOWN = 1          -- seconds between sign requests, per player
local SIGN_MAX_PER_REQUEST = 50  -- most units that can be signed in one go

if SUMMON_PRICE < 0 then
	warn("[Summon] SUMMON_PRICE was negative, which would GIVE Stars. Using " .. -SUMMON_PRICE .. " instead.")
	SUMMON_PRICE = -SUMMON_PRICE
end

-- Clients read these, so there's only one place to change them
ReplicatedStorage:SetAttribute("SummonPrice", SUMMON_PRICE)
ReplicatedStorage:SetAttribute("AllowDuplicateEquip", ALLOW_DUPLICATE_EQUIP)

local data = {}
local dirty = {}    -- [userId] = true when there are unsaved changes
local saving = {}   -- [userId] = true while a save is in progress

----------------------------------------------------------------
-- UNITS
----------------------------------------------------------------
--[[
	Every unit you own is its own entry with a unique id, so you can own the
	same tower as many times as you want:

		playerData.Units = {
			["3f2a9c..."] = { Name = "Brute",   Obtained = 1727000000 },
			["b81e0d..."] = { Name = "Brute",   Obtained = 1727000100 },
			["77c4aa..."] = { Name = "Slinger", Obtained = 1727000200 },
		}
		playerData.Loadout = { "3f2a9c...", "", "77c4aa...", "", "" } -- unit ids per slot

	Also kept up to date for older scripts / your match place:
		playerData.SelectedTowers = { "Brute", "Slinger" } -- equipped tower NAMES in slot order
		playerData.OwnedTowers    = { "Brute", "Slinger" } -- unique tower names you own

	The client sees your units in PlayerGui.UnitInventory (one StringValue per
	unit: Name = uid, Value = tower name). PlayerGui only replicates to its owner,
	so nobody downloads anyone else's inventory.
]]

local INVENTORY_FOLDER = "UnitInventory"

-- tower names that are allowed to exist (TowerShop keys and Names)
local validTowers = {}
for key, info in pairs(towers) do
	if type(info) == "table" then
		validTowers[key] = info.Name or key
		if info.Name then validTowers[info.Name] = info.Name end
	end
end

local function newUid()
	return (HttpService:GenerateGUID(false):gsub("-", ""))
end

local function getInventoryFolder(player)
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not playerGui then return nil end

	local folder = playerGui:FindFirstChild(INVENTORY_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = INVENTORY_FOLDER
		folder.Parent = playerGui
	end
	return folder
end

local function replicateUnit(player, uid, unit)
	local folder = getInventoryFolder(player)
	if not folder then return end

	local value = folder:FindFirstChild(uid)
	if not value then
		value = Instance.new("StringValue")
		value.Name = uid
	end
	value.Value = unit.Name
	value:SetAttribute("Obtained", unit.Obtained or 0)
	-- signature (the hover card shows who signed it); nil removes the attribute
	local signed = type(unit.Signed) == "table" and unit.Signed or nil
	value:SetAttribute("SignedBy", signed and tostring(signed.Name or "?") or nil)
	value:SetAttribute("SignedById", signed and tonumber(signed.By) or nil)
	value:SetAttribute("SignedAt", signed and tonumber(signed.At) or nil)
	value.Parent = folder
end

local function unreplicateUnit(player, uid)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local folder = playerGui and playerGui:FindFirstChild(INVENTORY_FOLDER)
	local value = folder and folder:FindFirstChild(uid)
	if value then
		value:Destroy()
	end
end

local function replicateAllUnits(player)
	local playerData = data[player.UserId]
	if not playerData then return end
	for uid, unit in pairs(playerData.Units) do
		replicateUnit(player, uid, unit)
	end
end

-- wipes the client's unit list and sends the current one (after a reset/recover)
local function rebuildInventory(player)
	local folder = getInventoryFolder(player)
	if folder then
		folder:ClearAllChildren()
	end
	replicateAllUnits(player)
end

-- Adds a brand new unit to a data table. Returns its uid.
local function addUnit(playerData, towerName)
	local name = validTowers[towerName]
	if not name then return nil end
	local uid = newUid()
	playerData.Units = playerData.Units or {}
	playerData.Units[uid] = { Name = name, Obtained = os.time() }
	return uid
end

-- Gives a player (in this server) a brand new unit. Returns its uid.
local function giveUnit(player, towerName)
	local playerData = data[player.UserId]
	if not playerData then return nil end

	local uid = addUnit(playerData, towerName)
	if uid then
		replicateUnit(player, uid, playerData.Units[uid])
	end
	return uid
end

-- Removes a unit (for selling/deleting later). Unequips it if needed.
local function removeUnit(player, uid)
	local playerData = data[player.UserId]
	if not playerData or not playerData.Units[uid] then return false end

	playerData.Units[uid] = nil
	local slot = table.find(playerData.Loadout, uid)
	if slot then
		playerData.Loadout[slot] = ""
	end
	unreplicateUnit(player, uid)
	return true
end

----------------------------------------------------------------
-- DATA SHAPE
----------------------------------------------------------------
local function newPlayerData()
	local playerData = {
		Stars = STARTING_STARS,
		Units = {},
		Loadout = {},
		DataVersion = DATA_VERSION,
	}

	local uidByName = {}
	for _, name in ipairs(STARTER_UNITS) do
		local uid = newUid()
		playerData.Units[uid] = { Name = name, Obtained = os.time() }
		uidByName[name] = uidByName[name] or uid
	end
	for i, name in ipairs(STARTER_EQUIPPED) do
		playerData.Loadout[i] = uidByName[name] or ""
	end

	return playerData
end

-- Old saves (OwnedTowers = names, LoadoutSlots = names) -> units with uids
local function migrate(playerData)
	if (tonumber(playerData.DataVersion) or 1) >= DATA_VERSION then
		playerData.Units = playerData.Units or {}
		return
	end

	local units = {}
	local uidByName = {}
	for _, name in ipairs(playerData.OwnedTowers or {}) do
		if type(name) == "string" and name ~= "" and not uidByName[name] then
			local uid = newUid()
			units[uid] = { Name = name, Obtained = os.time() }
			uidByName[name] = uid
		end
	end

	local oldSlots = playerData.LoadoutSlots or playerData.SelectedTowers or {}
	local loadout = {}
	for i = 1, SLOT_COUNT do
		local name = oldSlots[i]
		loadout[i] = (type(name) == "string" and uidByName[name]) or ""
	end

	playerData.Units = units
	playerData.Loadout = loadout
	playerData.LoadoutSlots = nil
	playerData.DataVersion = DATA_VERSION
	print("[Data] converted an old save to the unit system")
end

-- Loadout always has exactly SLOT_COUNT entries: a uid you own, or ""
local function normalizeLoadout(playerData)
	local old = playerData.Loadout or {}
	local loadout, usedNames = {}, {}

	for i = 1, SLOT_COUNT do
		local uid = old[i]
		local unit = type(uid) == "string" and playerData.Units[uid]
		if unit and not table.find(loadout, uid)
			and (ALLOW_DUPLICATE_EQUIP or not usedNames[unit.Name]) then
			loadout[i] = uid
			usedNames[unit.Name] = true
		else
			loadout[i] = ""
		end
	end

	playerData.Loadout = loadout
end

-- Rebuilds SelectedTowers / OwnedTowers. Returns the tower name in each slot.
local function rebuildLists(playerData)
	local selected, names = {}, {}
	for i = 1, SLOT_COUNT do
		local uid = playerData.Loadout[i]
		local unit = uid ~= "" and playerData.Units[uid] or nil
		names[i] = unit and unit.Name or ""
		if unit then
			table.insert(selected, unit.Name)
		end
	end
	playerData.SelectedTowers = selected

	local seen, owned = {}, {}
	for _, unit in pairs(playerData.Units) do
		if not seen[unit.Name] then
			seen[unit.Name] = true
			table.insert(owned, unit.Name)
		end
	end
	table.sort(owned)
	playerData.OwnedTowers = owned

	return names
end

----------------------------------------------------------------
-- UNIT EXISTS COUNTER (how many of every tower exist in the whole game)
----------------------------------------------------------------
--[[
	Counts every copy of every tower owned by anyone (every server, online AND
	offline) and gives the totals to all clients in ReplicatedStorage.UnitExists
	(one IntValue per tower). The hover card reads it, so hovering never loads.

	OFFLINE PLAYERS COUNT TOO: the first time this runs, ONE server quietly goes
	through every saved player in the background and adds their units. It only
	uses spare DataStore requests, so saving/loading is never slowed down, and it
	saves its progress, so if that server closes another one carries on where it
	stopped. Nobody has to join. Admin: type !exists to see how far it is.

	Why it never lags:
	  * Each player's save remembers what was already counted for them
	    (CountedUnits), so only the DIFFERENCE is ever sent (+1 on a summon, etc).
	    Marking a save as counted is atomic, so nobody is ever counted twice,
	    even if they join right when the background count reaches them.
	  * Changes are batched and sent every EXISTS_SYNC_INTERVAL seconds to ONE
	    shared MemoryStore counter, and the fresh totals are read back on the
	    same timer: about one tiny request every 2 seconds per server.
	  * Clients only get sent a number when it actually changes.
	  * One server at a time saves a permanent copy to a DataStore, so the
	    counts survive the whole game shutting down.
	  * Studio never changes the real counts (Roblox keeps Studio MemoryStores
	    separate): it counts for your test session only.
]]
local EXISTS_SYNC_INTERVAL = 2       -- seconds: send this server's changes + read everyone's totals
local EXISTS_BACKUP_INTERVAL = 300   -- seconds between permanent saves (only one server does it)
local EXISTS_EXPIRATION = 3888000    -- 45 days, the MemoryStore maximum (refreshed on every change)
local EXISTS_KEY = "Totals"
local SCAN_PAGE_SIZE = 50            -- saved players read per page by the background count
local SCAN_BUDGET_RESERVE = 25       -- DataStore requests always left free for real saves/loads
local SCAN_RETRY = 60                -- seconds between checks for a server to run the background count
local EXISTS_LIVE = not RunService:IsStudio()

local existsMap = MemoryStoreService:GetHashMap("UnitExists")
local existsBackupStore = DataStoreService:GetDataStore("UnitExistsBackup")
local EXISTS_SERVER_ID = HttpService:GenerateGUID(false)

local existsFolder = ReplicatedStorage:FindFirstChild("UnitExists")
if not existsFolder then
	existsFolder = Instance.new("Folder")
	existsFolder.Name = "UnitExists"
	existsFolder.Parent = ReplicatedStorage
end
existsFolder:SetAttribute("Ready", false)

local towerNames = {} -- every tower name in TowerShop
for _, name in pairs(validTowers) do
	towerNames[name] = true
end

local existsKnown = {}    -- totals last read from the shared counter
local existsPending = {}  -- this server's changes that haven't been sent yet
local existsSending = {}  -- changes being sent right now
local existsWarned = false
local studioCounted = setmetatable({}, { __mode = "k" }) -- Studio only: [playerData] = counted snapshot

local function existsTotal(name)
	return math.max(0, (existsKnown[name] or 0) + (existsPending[name] or 0) + (existsSending[name] or 0))
end

local function publishExists(name)
	local total = existsTotal(name)
	local value = existsFolder:FindFirstChild(name)
	if not value then
		value = Instance.new("IntValue")
		value.Name = name
		value.Value = total
		value.Parent = existsFolder
	elseif value.Value ~= total then
		value.Value = total -- only replicates when the number really changes
	end
end

local function addExists(name, delta)
	if type(name) ~= "string" or delta == 0 then return end
	existsPending[name] = (existsPending[name] or 0) + delta
	publishExists(name) -- this server sees it straight away
end

-- how many of each tower a data table has
local function countUnits(playerData)
	local counts = {}
	for _, unit in pairs(playerData.Units or {}) do
		if type(unit) == "table" and type(unit.Name) == "string" then
			counts[unit.Name] = (counts[unit.Name] or 0) + 1
		end
	end
	return counts
end

-- same, for a save that may still be in the old format (without converting it)
local function countStored(stored)
	if (tonumber(stored.DataVersion) or 1) >= DATA_VERSION then
		return countUnits(stored)
	end
	local counts = {}
	for _, name in ipairs(stored.OwnedTowers or {}) do
		if type(name) == "string" and name ~= "" then
			counts[name] = 1
		end
	end
	return counts
end

-- what changed between what a data table has now and what was counted for it before
local function existsDiff(playerData, counted)
	local current = countUnits(playerData)
	counted = type(counted) == "table" and counted or {}
	local diff = {}
	for name, amount in pairs(current) do
		local change = amount - (tonumber(counted[name]) or 0)
		if change ~= 0 then diff[name] = change end
	end
	for name, amount in pairs(counted) do
		amount = tonumber(amount) or 0
		if current[name] == nil and amount ~= 0 then
			diff[name] = -amount
		end
	end
	return diff, current
end

local function applyExistsDiff(diff)
	for name, change in pairs(diff) do
		addExists(name, change)
	end
end

-- what was already counted for a data table (Studio keeps its own copy, so real saves never change)
local function getCounted(playerData)
	if EXISTS_LIVE then return playerData.CountedUnits end
	return studioCounted[playerData]
end

local function setCounted(playerData, snapshot)
	if EXISTS_LIVE then
		playerData.CountedUnits = snapshot
	else
		studioCounted[playerData] = snapshot
	end
end

-- brings the global count up to date with this player's units (runs on every sync, very cheap)
local function reconcileExists(playerData)
	local counted = getCounted(playerData)
	if type(counted) ~= "table" then return end -- not counted yet: the background count will do it
	local diff, current = existsDiff(playerData, counted)
	setCounted(playerData, current)
	applyExistsDiff(diff)
end

local function readExistsTotals()
	local ok, totals = pcall(function()
		return existsMap:GetAsync(EXISTS_KEY)
	end)
	if not ok then return nil end
	return type(totals) == "table" and totals or {}
end

local function adoptTotals(totals)
	for name, total in pairs(totals) do
		if type(name) == "string" and tonumber(total) then
			existsKnown[name] = tonumber(total)
		end
	end
end

local function publishAllExists()
	for name in pairs(towerNames) do publishExists(name) end
	for name in pairs(existsKnown) do publishExists(name) end
end

-- sends everything this server counted since last time, in ONE atomic update
local function sendExistsChanges()
	if next(existsPending) == nil then return end
	local batch = existsPending
	existsPending = {}
	for name, change in pairs(batch) do
		existsSending[name] = (existsSending[name] or 0) + change
	end

	local fallback = table.clone(existsKnown) -- if the shared counter was lost, rebuild it from what we know
	local ok, result = pcall(function()
		return existsMap:UpdateAsync(EXISTS_KEY, function(totals)
			totals = type(totals) == "table" and totals or table.clone(fallback)
			for name, change in pairs(batch) do
				totals[name] = math.max(0, (tonumber(totals[name]) or 0) + change)
			end
			return totals
		end, EXISTS_EXPIRATION)
	end)

	for name, change in pairs(batch) do
		existsSending[name] = (existsSending[name] or 0) - change
		if existsSending[name] == 0 then existsSending[name] = nil end
	end
	if ok and type(result) == "table" then
		adoptTotals(result) -- the fresh totals of the whole game come back for free
	else
		for name, change in pairs(batch) do -- try again next time
			existsPending[name] = (existsPending[name] or 0) + change
		end
		if not existsWarned then
			existsWarned = true
			warn("[Exists] couldn't reach MemoryStore, will keep retrying:", result)
		end
	end
	for name in pairs(batch) do
		publishExists(name)
	end
end

-- Joining: marks the player's save as counted, atomically. Whoever marks it
-- first (this server or the background count) is the one that adds their units.
local function claimExists(userId, playerData, isNew)
	if not EXISTS_LIVE then
		studioCounted[playerData] = type(playerData.CountedUnits) == "table"
			and table.clone(playerData.CountedUnits) or countUnits(playerData)
		return
	end
	if isNew then
		playerData.CountedUnits = {} -- brand new player: everything they get from now on is counted
		return
	end
	if type(playerData.CountedUnits) == "table" then return end -- already counted before

	for _ = 1, 3 do
		local won, snapshot = false, nil
		local ok = pcall(function()
			database:UpdateAsync(userId, function(stored)
				if type(stored) ~= "table" then
					won, snapshot = true, {}
					return nil
				end
				if type(stored.CountedUnits) == "table" then
					won, snapshot = false, stored.CountedUnits -- the background count got here first
					return nil
				end
				won, snapshot = true, countStored(stored)
				stored.CountedUnits = snapshot
				return stored
			end)
		end)
		if ok then
			if won then
				applyExistsDiff(snapshot)
				task.spawn(sendExistsChanges) -- sent right away, not on the next timer tick
			end
			playerData.CountedUnits = table.clone(snapshot)
			return
		end
		task.wait(1)
	end
	-- DataStore trouble: this session doesn't count them, the background count or their next join will
end

-- one server at a time keeps a permanent copy (Studio tests never overwrite it)
local function backupExists()
	if not EXISTS_LIVE then return end
	local ok, owner = pcall(function()
		return existsMap:UpdateAsync("BackupKeeper", function(current)
			if current == nil or current == EXISTS_SERVER_ID then
				return EXISTS_SERVER_ID
			end
			return nil -- another server is the keeper
		end, EXISTS_BACKUP_INTERVAL + 60)
	end)
	if not ok or owner ~= EXISTS_SERVER_ID then return end

	local totals = table.clone(existsKnown)
	pcall(function()
		existsBackupStore:SetAsync(EXISTS_KEY, totals)
	end)
	-- also keeps the shared counter alive (it would expire after 45 days without changes)
	pcall(function()
		existsMap:UpdateAsync(EXISTS_KEY, function(current)
			return type(current) == "table" and current or totals
		end, EXISTS_EXPIRATION)
	end)
end

----------------------------------------------------------------
-- BACKGROUND COUNT OF OFFLINE PLAYERS (one server at a time, runs once ever)
----------------------------------------------------------------
local scanRunning, scanFinished = false, false
local existsClosing = false -- set when the server shuts down

local function readScanStatus()
	local ok, status = pcall(function()
		return existsBackupStore:GetAsync("Scan")
	end)
	if not ok then return nil end
	return type(status) == "table" and status or {}
end

local function holdScanLock()
	local ok, owner = pcall(function()
		return existsMap:UpdateAsync("ScanKeeper", function(current)
			if current == nil or current == EXISTS_SERVER_ID then
				return EXISTS_SERVER_ID
			end
			return nil -- another server is counting
		end, 120)
	end)
	return ok and owner == EXISTS_SERVER_ID
end

-- only uses DataStore requests that real saves/loads don't need
local function waitForBudget(requestType, reserve)
	while DataStoreService:GetRequestBudgetForRequestType(requestType) < reserve do
		task.wait(1)
	end
end

-- counts one saved player if nobody has yet. true = counted now
local function countSavedPlayer(key)
	local snapshot = nil
	local ok = pcall(function()
		database:UpdateAsync(key, function(stored)
			snapshot = nil
			if type(stored) ~= "table" or type(stored.CountedUnits) == "table" then
				return nil -- not a save, or already counted
			end
			if stored.Units == nil and stored.OwnedTowers == nil then
				return nil -- not player data
			end
			snapshot = countStored(stored)
			stored.CountedUnits = snapshot
			return stored
		end)
	end)
	if ok and snapshot then
		applyExistsDiff(snapshot)
		return true
	end
	return false
end

local function runScan()
	if scanRunning or scanFinished or not EXISTS_LIVE then return end
	scanRunning = true

	local status = readScanStatus()
	if status and status.Done then
		scanFinished = true
	elseif status and holdScanLock() then
		local checked = tonumber(status.Checked) or 0
		local counted = tonumber(status.Counted) or 0
		waitForBudget(Enum.DataStoreRequestType.ListAsync, 1)
		local ok, pages = pcall(function()
			return database:ListKeysAsync("", SCAN_PAGE_SIZE, status.Cursor or "", true)
		end)
		while ok and pages do
			for _, key in ipairs(pages:GetCurrentPage()) do
				waitForBudget(Enum.DataStoreRequestType.UpdateAsync, SCAN_BUDGET_RESERVE)
				if existsClosing then break end -- server is shutting down: another one carries on
				if countSavedPlayer(key.KeyName) then
					counted += 1
					sendExistsChanges() -- straight to the shared counter, so nothing waits in memory
				end
				checked += 1
			end
			if existsClosing then break end -- the unfinished page is simply redone later

			-- progress is saved after every page, so another server can carry on from here
			local finished = pages.IsFinished
			local progress = { Cursor = pages.Cursor, Checked = checked, Counted = counted, Done = finished, At = os.time() }
			pcall(function()
				existsBackupStore:SetAsync("Scan", progress)
			end)
			if finished then
				scanFinished = true
				print(("[Exists] background count finished: %d saves checked, %d players counted"):format(checked, counted))
				break
			end
			if not holdScanLock() then break end -- another server took over
			waitForBudget(Enum.DataStoreRequestType.ListAsync, 1)
			ok = pcall(function()
				pages:AdvanceToNextPageAsync()
			end)
		end
	end
	scanRunning = false
end

task.spawn(function()
	-- 1) the permanent copy, so something correct shows even before the live counter answers
	local ok, saved = pcall(function()
		return existsBackupStore:GetAsync(EXISTS_KEY)
	end)
	if ok and type(saved) == "table" then
		adoptTotals(saved)
	end

	-- 2) the live counter (if it was lost, e.g. the game was empty for 45 days, restore it)
	local live = readExistsTotals()
	if live and next(live) == nil and next(existsKnown) ~= nil then
		local seed = table.clone(existsKnown)
		pcall(function()
			existsMap:UpdateAsync(EXISTS_KEY, function(current)
				if type(current) == "table" and next(current) ~= nil then return nil end -- someone restored it already
				return seed
			end, EXISTS_EXPIRATION)
		end)
		live = readExistsTotals()
	end
	if live then
		adoptTotals(live)
	end
	publishAllExists()
	existsFolder:SetAttribute("Ready", true)

	local lastBackup, lastScan = -math.huge, -math.huge
	while true do
		task.wait(EXISTS_SYNC_INTERVAL)
		sendExistsChanges()
		local totals = readExistsTotals()
		if totals then
			adoptTotals(totals)
			publishAllExists()
		end
		if os.clock() - lastBackup >= EXISTS_BACKUP_INTERVAL then
			lastBackup = os.clock()
			task.spawn(backupExists)
		end
		if not scanFinished and not scanRunning and os.clock() - lastScan >= SCAN_RETRY then
			lastScan = os.clock()
			task.spawn(runScan)
		end
	end
end)

-- Updates the name lists + sends Stars/loadout to the client through attributes
local function syncData(player)
	local playerData = data[player.UserId]
	if not playerData then return end
	dirty[player.UserId] = true

	reconcileExists(playerData) -- new/removed units change the global exists count
	local names = rebuildLists(playerData)

	player:SetAttribute("Stars", playerData.Stars or 0)                        -- MainGui currency
	player:SetAttribute("LoadoutSlots", table.concat(names, ","))               -- tower NAMES per slot (LoadOut)
	player:SetAttribute("LoadoutUnits", table.concat(playerData.Loadout, ","))  -- unit UIDS per slot (inventory)
end

----------------------------------------------------------------
-- LOAD / SAVE
----------------------------------------------------------------
local function LoadData(player)
	local success = nil
	local playerData = nil
	local attempt = 1

	repeat
		success, playerData = pcall(function()
			return database:GetAsync(player.UserId)
		end)
		attempt += 1
		if not success then
			warn(playerData)
			task.wait()
		end
	until success or attempt == 3

	if not player.Parent then return end -- left while loading

	if success then
		print("Connection success")
		local isNew = not playerData
		if isNew then
			print("New player, giving default data")
			playerData = newPlayerData()
		end
		migrate(playerData)
		normalizeLoadout(playerData)
		claimExists(player.UserId, playerData, isNew) -- counts them in Exists (once ever, never twice)
		if not player.Parent then return end -- left while that happened
		data[player.UserId] = playerData
		replicateAllUnits(player)
		syncData(player)
	else
		warn("Unable to get data for player", player.UserId)
		player:Kick("There was a problem getting your data")
	end
end

----------------------------------------------------------------
-- SAVING
----------------------------------------------------------------
-- Saves happen: every AUTOSAVE_INTERVAL seconds (only if something changed),
-- when a player leaves, and when the server (or a Studio test) shuts down.
local AUTOSAVE_INTERVAL = 30

local function saveUser(userId)
	if not data[userId] then return end

	-- never run two saves for the same player at once
	while saving[userId] do
		task.wait()
	end
	-- read the data AFTER waiting, so a reset/recover that happened meanwhile is what gets saved
	local playerData = data[userId]
	if not playerData then return end
	saving[userId] = true
	dirty[userId] = nil

	local success, err = false, nil
	for attempt = 1, 3 do
		success, err = pcall(function()
			database:UpdateAsync(userId, function(stored)
				-- this session couldn't count them but the background count did:
				-- keep its record instead of wiping it (the next sync adds any difference)
				if playerData.CountedUnits == nil and type(stored) == "table" and type(stored.CountedUnits) == "table" then
					playerData.CountedUnits = stored.CountedUnits
				end
				return playerData
			end)
		end)
		if success then break end
		warn("Save attempt " .. attempt .. " failed for " .. userId .. ": " .. tostring(err))
		task.wait(1)
	end

	saving[userId] = nil
	if success then
		print("Data saved successfully")
	else
		dirty[userId] = true -- try again on the next autosave
		warn("Unable to save data for", userId)
	end
end

-- autosave
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for userId in pairs(dirty) do
			if data[userId] and not saving[userId] then
				task.spawn(saveUser, userId)
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local userId = player.UserId
	saveUser(userId)
	data[userId] = nil
	dirty[userId] = nil
end)

-- Also runs when you press Stop in Studio. It waits until every save is done,
-- otherwise the server closes mid-save and you load old data next time.
game:BindToClose(function()
	for userId in pairs(data) do
		if not saving[userId] then
			task.spawn(saveUser, userId)
		end
	end
	-- the last exists changes of this server go out before it closes
	existsClosing = true -- stops the background count, another server carries on
	local existsDone = false
	task.spawn(function()
		sendExistsChanges()
		backupExists()
		existsDone = true
	end)

	local start = os.clock()
	while os.clock() - start < 25 do
		local busy = not existsDone
		for userId in pairs(data) do
			if saving[userId] then busy = true break end
		end
		if not busy and next(saving) == nil then break end
		task.wait(0.1)
	end
end)

----------------------------------------------------------------
-- EQUIP / UNEQUIP (inventory)
----------------------------------------------------------------
local function nameEquipped(playerData, towerName)
	for _, uid in ipairs(playerData.Loadout) do
		local unit = uid ~= "" and playerData.Units[uid]
		if unit and unit.Name == towerName then
			return true
		end
	end
	return false
end

-- "Equip" / "Unequip" take a unit UID. "Buy" takes a tower name (off by default).
-- Returns: playerData, success
ReplicatedStorage.InteractItem.OnServerInvoke = function(player, id, action)
	if type(id) ~= "string" then return false end

	local playerData = data[player.UserId]
	if not playerData then
		warn("Player data does not exist")
		return false
	end

	local success = false

	if action == "Equip" then
		local unit = playerData.Units[id]
		if unit and not table.find(playerData.Loadout, id)
			and (ALLOW_DUPLICATE_EQUIP or not nameEquipped(playerData, unit.Name)) then
			local emptySlot = table.find(playerData.Loadout, "")
			if emptySlot then
				playerData.Loadout[emptySlot] = id
				success = true
			end
		end

	elseif action == "Unequip" then
		-- the slot becomes empty, other units stay where they are
		local slot = table.find(playerData.Loadout, id)
		if slot then
			playerData.Loadout[slot] = ""
			success = true
		end

	else
		local shopItem = towers[id]
		if ALLOW_DIRECT_BUY and shopItem and (playerData.Stars or 0) >= (shopItem.Price or 0) then
			playerData.Stars -= shopItem.Price or 0
			success = giveUnit(player, id) ~= nil
		end
	end

	syncData(player)
	return playerData, success
end

ReplicatedStorage.GetData.OnServerInvoke = function(player)
	return data[player.UserId]
end

----------------------------------------------------------------
-- SUMMON
----------------------------------------------------------------
-- Every tower in TowerShop can be summoned with an EQUAL chance.
-- Optional per-tower settings in TowerShop:
--   ["Summonable"] = false   -> never drops from summons
--   ["SummonWeight"] = 2     -> twice as likely as a normal tower (default 1)
--   ["Rarity"] = "Epic"      -> shown on the summon screen (default "None")

local summonRemote = ReplicatedStorage:FindFirstChild("SummonUnit")
if not summonRemote then
	summonRemote = Instance.new("RemoteFunction")
	summonRemote.Name = "SummonUnit"
	summonRemote.Parent = ReplicatedStorage
end

local summonPool, summonTotal = {}, 0
for key, info in pairs(towers) do
	if type(info) == "table" and info.Summonable ~= false then
		local weight = tonumber(info.SummonWeight) or 1
		if weight > 0 then
			summonTotal += weight
			table.insert(summonPool, { Name = info.Name or key, Weight = weight })
		end
	end
end
table.sort(summonPool, function(a, b) return a.Name < b.Name end)

for _, entry in ipairs(summonPool) do
	print(("[Summon] %s: %.2f%%"):format(entry.Name, entry.Weight / summonTotal * 100))
end

local rng = Random.new()
local function rollTower()
	if summonTotal <= 0 then return nil end
	local pick = rng:NextNumber() * summonTotal
	for _, entry in ipairs(summonPool) do
		pick -= entry.Weight
		if pick <= 0 then
			return entry.Name
		end
	end
	return summonPool[#summonPool].Name
end

local lastSummon = {}

-- Returns: success, towerName, uid
summonRemote.OnServerInvoke = function(player)
	local playerData = data[player.UserId]
	if not playerData then return false end

	local now = os.clock()
	if lastSummon[player] and now - lastSummon[player] < SUMMON_COOLDOWN then
		return false
	end
	if (playerData.Stars or 0) < SUMMON_PRICE then
		return false
	end

	local towerName = rollTower()
	if not towerName then
		warn("[Summon] no summonable towers in TowerShop")
		return false
	end

	local uid = giveUnit(player, towerName) -- always a NEW unit, duplicates included
	if not uid then return false end

	lastSummon[player] = now
	playerData.Stars -= SUMMON_PRICE
	playerData.JustReset = nil -- they're playing again, so a future reset may back this data up
	syncData(player)
	return true, towerName, uid
end

----------------------------------------------------------------
-- CODES (the list is in the settings at the top: CODES)
----------------------------------------------------------------
local redeemRemote = ReplicatedStorage:FindFirstChild("RedeemCode")
if not redeemRemote then
	redeemRemote = Instance.new("RemoteFunction")
	redeemRemote.Name = "RedeemCode"
	redeemRemote.Parent = ReplicatedStorage
end

-- "  release " -> "RELEASE"
local function codeKey(text)
	return string.upper((string.gsub(text, "%s+", "")))
end

-- "2026-12-31" -> the last second of that day (UTC)
local function parseExpiry(value)
	if type(value) == "number" then return value end
	if type(value) == "string" then
		local y, m, d = string.match(value, "^(%d+)%-(%d+)%-(%d+)")
		if y then
			return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 23, min = 59, sec = 59 })
		end
		warn("[Codes] couldn't read the date '" .. value .. "', use \"YYYY-MM-DD\"")
	end
	return nil
end

-- { "Brute" } / { Brute = 2 } / "Brute" -> { { Name = "Brute", Count = 2 }, ... }
local function readTowerRewards(towersField, codeName)
	local list, byName = {}, {}
	local function add(name, count)
		local real = validTowers[name]
		if not real then
			warn(("[Codes] %s: there's no tower called '%s' in TowerShop"):format(codeName, tostring(name)))
			return
		end
		count = math.max(0, math.floor(tonumber(count) or 0))
		if count == 0 then return end
		if byName[real] then
			byName[real].Count += count
		else
			byName[real] = { Name = real, Count = count }
			table.insert(list, byName[real])
		end
	end
	if type(towersField) == "string" then
		add(towersField, 1)
	elseif type(towersField) == "table" then
		for key, value in pairs(towersField) do
			if type(key) == "number" then
				add(value, 1)
			else
				add(key, value)
			end
		end
	end
	return list
end

local codeList = {}
for name, reward in pairs(CODES) do
	if type(name) == "string" and type(reward) == "table" then
		if codeList[codeKey(name)] then
			warn(("[Codes] '%s' and '%s' are the same code (capitals and spaces don't count), only one is used")
				:format(codeList[codeKey(name)].Name, name))
		end
		codeList[codeKey(name)] = {
			Name = name,
			Stars = math.floor(tonumber(reward.Stars) or 0),
			Towers = readTowerRewards(reward.Towers or reward.Tower, name),
			Expires = parseExpiry(reward.Expires),
			Enabled = reward.Enabled ~= false,
		}
	end
end

local codeTries = {} -- [player] = { Last, Wrong, LockedUntil }

-- Returns: success, message, rewards ({ Stars = n, Towers = { { Name, Count } } })
redeemRemote.OnServerInvoke = function(player, text)
	if type(text) ~= "string" or #text > 64 then return false, "Invalid code" end
	local key = codeKey(text)
	if key == "" then return false, "Type a code first!" end

	local playerData = data[player.UserId]
	if not playerData then return false, "Still loading, try again in a second" end

	local tries = codeTries[player]
	if not tries then
		tries = { Last = 0, Wrong = 0, LockedUntil = 0 }
		codeTries[player] = tries
	end
	local now = os.clock()
	if now < tries.LockedUntil then
		return false, ("Too many tries! Wait %d seconds"):format(math.ceil(tries.LockedUntil - now))
	end
	if now - tries.Last < CODE_COOLDOWN then
		return false, "Slow down!"
	end
	tries.Last = now

	local code = codeList[key]
	if not code or not code.Enabled then
		tries.Wrong += 1
		if tries.Wrong >= CODE_MAX_WRONG then
			tries.Wrong = 0
			tries.LockedUntil = now + CODE_TIMEOUT
		end
		return false, "Invalid code"
	end
	tries.Wrong = 0
	if code.Expires and os.time() > code.Expires then
		return false, "This code has expired"
	end

	playerData.RedeemedCodes = type(playerData.RedeemedCodes) == "table" and playerData.RedeemedCodes or {}
	if playerData.RedeemedCodes[key] then
		return false, "You already redeemed this code"
	end
	playerData.RedeemedCodes[key] = os.time()
	playerData.JustReset = nil -- real progress again, so a future !resetdata backs this up

	if code.Stars ~= 0 then
		playerData.Stars = math.max(0, (tonumber(playerData.Stars) or 0) + code.Stars)
	end
	local towersGiven = {}
	for _, entry in ipairs(code.Towers) do
		for _ = 1, entry.Count do
			giveUnit(player, entry.Name)
		end
		table.insert(towersGiven, { Name = entry.Name, Count = entry.Count })
	end

	syncData(player)                   -- Stars + inventory + exists count update live
	task.spawn(saveUser, player.UserId) -- saved right away, so a code can never be used twice
	return true, "Code redeemed!", { Stars = code.Stars, Towers = towersGiven }
end

Players.PlayerRemoving:Connect(function(player)
	codeTries[player] = nil
end)

----------------------------------------------------------------
-- SIGNING UNITS (players whose role has the "Sign" permission)
----------------------------------------------------------------
--[[
	A signed unit remembers who signed it, forever:
		unit.Signed = { By = 1920941505, Name = "sans", At = 1727000000 }

	There's no way to unsign. If someone else with the Sign permission signs the
	same unit later, their signature replaces the old one.

	Only the server decides who may sign (ReplicatedStorage.Modules.Roles is read
	HERE, on the server), so an exploiter showing the button or firing the remote
	themselves gets "You can't sign units". Players can only sign their own units.
]]
local Roles = nil
task.spawn(function()
	local modules = ReplicatedStorage:WaitForChild("Modules", 30)
	local module = modules and modules:WaitForChild("Roles", 30)
	if not module then
		warn("[Sign] ReplicatedStorage.Modules.Roles is missing, so nobody can sign units")
		return
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" and type(result.HasPermission) == "function" then
		Roles = result
	else
		warn("[Sign] couldn't load the Roles module:", result)
	end
end)

local signRemote = ReplicatedStorage:FindFirstChild("SignUnits")
if not signRemote then
	signRemote = Instance.new("RemoteFunction")
	signRemote.Name = "SignUnits"
	signRemote.Parent = ReplicatedStorage
end

local lastSign = {}

-- Returns: true, units signed, signer name   or   false, why not
signRemote.OnServerInvoke = function(player, uids)
	if not Roles then return false, "Signing is still loading, try again" end
	if not Roles.HasPermission(player, SIGN_PERMISSION) then return false, "You can't sign units" end

	local playerData = data[player.UserId]
	if not playerData then return false, "Still loading, try again in a second" end
	if type(uids) ~= "table" then return false, "Pick some units first" end
	local count = #uids
	if count == 0 then return false, "Pick some units first" end
	if count > SIGN_MAX_PER_REQUEST then
		return false, ("You can sign up to %d units at once"):format(SIGN_MAX_PER_REQUEST)
	end

	local now = os.clock()
	if lastSign[player] and now - lastSign[player] < SIGN_COOLDOWN then return false, "Slow down!" end
	lastSign[player] = now

	local signedNow, done = 0, {}
	for i = 1, count do
		local uid = uids[i]
		local unit = type(uid) == "string" and #uid <= 64 and playerData.Units[uid] or nil
		if type(unit) == "table" and not done[uid] then
			done[uid] = true
			unit.Signed = { By = player.UserId, Name = player.Name, At = os.time() } -- replaces any old signature
			replicateUnit(player, uid, unit)
			signedNow += 1
		end
	end
	if signedNow == 0 then return false, "Those units aren't in your inventory" end

	playerData.JustReset = nil -- real progress, so a future !resetdata backs this up
	syncData(player)
	task.spawn(saveUser, player.UserId) -- saved right away
	return true, signedNow, player.Name
end

Players.PlayerRemoving:Connect(function(player)
	lastSign[player] = nil
end)

----------------------------------------------------------------
-- ADMIN COMMANDS (only ADMIN_USER_ID, typed in chat)
----------------------------------------------------------------
--[[
	!gc [username] [amount]         give Stars (negative takes them away, never below 0)
	!setstars [username] [amount]   set Stars to an exact amount
	!giveunit [username] [tower] [count]  give units (count is optional)
	!resetdata [username]           erase their data (old data goes to the Recovery Save Spot)
	!recoverdata [username]         bring back the data from the Recovery Save Spot
	!data [username]                show their Stars, units, signed units, loadout, codes and recovery save
	!resetcodes [username] [code]   let them redeem that code again (no code = every code)
	!exists                         how far the offline count is + every tower's exists count
	!cmds                           list the commands

	"me" works as a username. Amounts can be written like 500, -250, 1.5k, 2m.
	Works for players in this server, in other servers and offline players.

	RECOVERY SAVE SPOT: one save per player, stored forever. !resetdata puts the
	old data there before erasing. It is NOT overwritten if their data is still a
	fresh reset (so resetting twice by accident can't destroy the real backup).
	!recoverdata keeps the save there too, so you can always recover again.
]]

local adminRemote = ReplicatedStorage:FindFirstChild("AdminMessage")
if not adminRemote then
	adminRemote = Instance.new("RemoteEvent")
	adminRemote.Name = "AdminMessage"
	adminRemote.Parent = ReplicatedStorage
end

local CMD_TOPIC = "AdminDataCommand"
local ACK_TOPIC = "AdminDataReply"
local SERVER_ID = HttpService:GenerateGUID(false)
local RECEIVE_TIMEOUT = 3   -- seconds to wait for another server to say "that player is here"
local RESULT_TIMEOUT = 30   -- seconds to wait for that server to finish

local function withCommas(n)
	local text = tostring(math.floor(math.abs(n)))
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then formatted = formatted:sub(2) end
	return (n < 0 and "-" or "") .. formatted
end

local function timeAgo(t)
	local s = os.time() - (tonumber(t) or os.time())
	if s < 60 then return s .. "s ago" end
	if s < 3600 then return math.floor(s / 60) .. "m ago" end
	if s < 86400 then return math.floor(s / 3600) .. "h ago" end
	return math.floor(s / 86400) .. "d ago"
end

local function unitSummary(playerData)
	local counts, order = {}, {}
	for _, unit in pairs(playerData.Units or {}) do
		if not counts[unit.Name] then
			counts[unit.Name] = 0
			table.insert(order, unit.Name)
		end
		counts[unit.Name] += 1
	end
	table.sort(order)
	local parts = {}
	for _, name in ipairs(order) do
		table.insert(parts, counts[name] > 1 and (name .. " x" .. counts[name]) or name)
	end
	return #parts > 0 and table.concat(parts, ", ") or "none"
end

-- "500", "-250", "1.5k", "2m" -> whole number
local function parseAmount(text)
	if type(text) ~= "string" then return nil end
	local number, suffix = text:lower():match("^([%+%-]?%d*%.?%d+)([kmb]?)$")
	number = tonumber(number)
	if not number then return nil end
	local value = number * (({ k = 1e3, m = 1e6, b = 1e9 })[suffix] or 1)
	value = value < 0 and -math.floor(-value + 0.5) or math.floor(value + 0.5)
	if math.abs(value) > 1e12 then return nil end
	return value
end

local function findTower(text)
	if validTowers[text] then return validTowers[text] end
	local lower = text:lower()
	for key, name in pairs(validTowers) do
		if key:lower() == lower then return name end
	end
	return nil
end

-- username -> { UserId, Name } (exact username, any capitalisation)
local function resolveUser(name, admin)
	if type(name) ~= "string" or name == "" then
		return nil, "missing username"
	end
	if name:lower() == "me" then
		return { UserId = admin.UserId, Name = admin.Name }
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Name:lower() == name:lower() then
			return { UserId = player.UserId, Name = player.Name }
		end
	end
	local ok, userId = pcall(function()
		return Players:GetUserIdFromNameAsync(name)
	end)
	if not ok or not userId then
		return nil, "no Roblox user called '" .. name .. "'"
	end
	local okName, realName = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	return { UserId = userId, Name = okName and realName or name }
end

-- waits until no save is running for this player, so offline edits never race a leave-save
local function waitForSave(userId)
	local start = os.clock()
	while saving[userId] and os.clock() - start < 30 do
		task.wait(0.1)
	end
end

-- Runs fn(playerData, player?) on live data (this server) or straight on the DataStore.
-- fn returns the message. Returns ok, message.
local function changeData(userId, fn)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		local playerData = data[userId]
		if not playerData then return false, "their data is still loading, try again in a second" end
		local message = fn(playerData, player)
		syncData(player)
		task.spawn(saveUser, userId)
		return true, message
	end

	waitForSave(userId)
	local message, found, countChange = nil, false, {}
	local ok, err = pcall(function()
		database:UpdateAsync(userId, function(stored)
			if type(stored) ~= "table" then
				found = false
				return nil -- nothing saved: don't write anything
			end
			found = true
			migrate(stored)
			normalizeLoadout(stored)
			message = fn(stored, nil)
			rebuildLists(stored)
			-- exists count: worked out here, only sent once the save really went through
			-- (a save that was never counted gets counted right now; Studio never changes it)
			if EXISTS_LIVE then
				countChange, stored.CountedUnits = existsDiff(stored, stored.CountedUnits)
			end
			return stored
		end)
	end)
	if not ok then return false, "DataStore error: " .. tostring(err) end
	if not found then return false, "they have no saved data yet (never joined?)" end
	applyExistsDiff(countChange)
	return true, message .. " [offline]"
end

-- Replaces a player's whole data table, live or in the DataStore.
local function replaceData(userId, newData)
	normalizeLoadout(newData)
	rebuildLists(newData)

	local player = Players:GetPlayerByUserId(userId)
	if player and data[userId] then
		-- the new data takes over what was counted for the old one, so syncData
		-- sends exactly the difference to the exists count
		local old = data[userId]
		newData.CountedUnits = type(old.CountedUnits) == "table" and table.clone(old.CountedUnits) or nil
		if not EXISTS_LIVE then
			studioCounted[newData] = studioCounted[old] and table.clone(studioCounted[old]) or nil
		end
		data[userId] = newData
		rebuildInventory(player)
		syncData(player)
		task.spawn(saveUser, userId)
		return true
	end

	waitForSave(userId)
	local countChange = {}
	local ok, err = pcall(function()
		database:UpdateAsync(userId, function(stored)
			local counted = type(stored) == "table" and stored.CountedUnits or nil
			if EXISTS_LIVE then
				countChange, newData.CountedUnits = existsDiff(newData, counted)
			else
				countChange, newData.CountedUnits = {}, counted -- Studio never changes the real count
			end
			return newData
		end)
	end)
	if ok then
		applyExistsDiff(countChange)
	end
	return ok, err
end

local function getData(userId)
	if Players:GetPlayerByUserId(userId) then
		local playerData = data[userId]
		if not playerData then return false, "their data is still loading, try again in a second" end
		return true, playerData
	end
	local ok, stored = pcall(function()
		return database:GetAsync(userId)
	end)
	if not ok then return false, "DataStore error: " .. tostring(stored) end
	if type(stored) ~= "table" then return false, "they have no saved data yet (never joined?)" end
	migrate(stored)
	normalizeLoadout(stored)
	return true, stored
end

local function getRecovery(userId)
	local ok, save = pcall(function()
		return recoveryStore:GetAsync(userId)
	end)
	if not ok then return false, "DataStore error: " .. tostring(save) end
	if type(save) ~= "table" or type(save.Data) ~= "table" then return true, nil end
	return true, save
end

-- Every operation: function(userId, args) -> ok, message
local Ops = {}

Ops.gc = function(userId, args)
	return changeData(userId, function(playerData)
		local before = tonumber(playerData.Stars) or 0
		local after = math.max(0, before + args.Amount)
		playerData.Stars = after
		local change = after - before
		local verb = change >= 0 and ("Gave %s Stars to %s"):format(withCommas(change), args.Name)
			or ("Took %s Stars from %s"):format(withCommas(-change), args.Name)
		local note = (before + args.Amount < 0) and " (can't go below 0)" or ""
		return ("%s, now %s%s"):format(verb, withCommas(after), note)
	end)
end

Ops.setstars = function(userId, args)
	return changeData(userId, function(playerData)
		playerData.Stars = math.max(0, args.Amount)
		return ("%s now has %s Stars"):format(args.Name, withCommas(playerData.Stars))
	end)
end

Ops.giveunit = function(userId, args)
	return changeData(userId, function(playerData, player)
		for _ = 1, args.Count do
			local uid = addUnit(playerData, args.Tower)
			if uid and player then
				replicateUnit(player, uid, playerData.Units[uid])
			end
		end
		return ("Gave %s %dx %s"):format(args.Name, args.Count, args.Tower)
	end)
end

Ops.resetdata = function(userId, args)
	local ok, old = getData(userId)
	if not ok then return false, old end

	local backupNote
	if old.JustReset then
		backupNote = "Recovery save kept as it was (their data was already a fresh reset)"
	else
		local saved, err = pcall(function()
			recoveryStore:SetAsync(userId, { Data = old, SavedAt = os.time(), By = ADMIN_USER_ID })
		end)
		if not saved then
			return false, "ABORTED, nothing was erased: couldn't write the recovery save (" .. tostring(err) .. ")"
		end
		backupNote = "Their old data is in the Recovery Save Spot"
	end

	local fresh = newPlayerData()
	fresh.JustReset = true
	local replaced, err = replaceData(userId, fresh)
	if not replaced then
		return false, "Recovery save written, but the reset failed: " .. tostring(err)
	end
	return true, ("Reset %s's data. %s (!recoverdata %s to undo)"):format(args.Name, backupNote, args.Name)
end

Ops.recoverdata = function(userId, args)
	local ok, save = getRecovery(userId)
	if not ok then return false, save end
	if not save then return false, args.Name .. " has no recovery save" end

	local restored = save.Data
	migrate(restored)
	restored.JustReset = nil
	local replaced, err = replaceData(userId, restored)
	if not replaced then return false, "Recovery failed: " .. tostring(err) end
	return true, ("Recovered %s's data from the save made %s (%s Stars, %s). The save stays in the spot.")
		:format(args.Name, timeAgo(save.SavedAt), withCommas(tonumber(restored.Stars) or 0), unitSummary(restored))
end

-- lets them redeem a code again (args.Code), or every code (args.Code = nil)
Ops.resetcodes = function(userId, args)
	return changeData(userId, function(playerData)
		local redeemed = type(playerData.RedeemedCodes) == "table" and playerData.RedeemedCodes or {}
		if args.Code then
			if not redeemed[args.Code] then
				return ("%s never redeemed %s, nothing to reset"):format(args.Name, args.Code)
			end
			redeemed[args.Code] = nil
			playerData.RedeemedCodes = redeemed
			return ("%s can redeem %s again"):format(args.Name, args.Code)
		end
		local count = 0
		for _ in pairs(redeemed) do count += 1 end
		playerData.RedeemedCodes = {}
		return ("%s can redeem every code again (%d cleared)"):format(args.Name, count)
	end)
end

Ops.data = function(userId, args)
	local ok, playerData = getData(userId)
	if not ok then return false, playerData end

	local slots = {}
	for i = 1, SLOT_COUNT do
		local uid = playerData.Loadout[i]
		local unit = uid ~= "" and playerData.Units[uid]
		slots[i] = unit and unit.Name or "-"
	end

	local codes = {}
	if type(playerData.RedeemedCodes) == "table" then
		for code in pairs(playerData.RedeemedCodes) do
			table.insert(codes, code)
		end
		table.sort(codes)
	end

	local signedCount = 0
	for _, unit in pairs(playerData.Units or {}) do
		if type(unit) == "table" and type(unit.Signed) == "table" then
			signedCount += 1
		end
	end

	local _, save = getRecovery(userId)
	local recovery = save and ("from " .. timeAgo(save.SavedAt)) or "none"
	local where = Players:GetPlayerByUserId(userId) and "in this server" or "saved data"
	return true, ("%s (%s): %s Stars | Units: %s | Signed: %d | Loadout: %s | Codes: %s | Recovery save: %s%s")
		:format(args.Name, where, withCommas(tonumber(playerData.Stars) or 0), unitSummary(playerData), signedCount,
			table.concat(slots, ", "), #codes > 0 and table.concat(codes, ", ") or "none",
			recovery, playerData.JustReset and " | (fresh reset)" or "")
end

local function runOp(op, userId, args)
	local fn = Ops[op]
	if not fn then return false, "unknown operation" end
	local ok, success, message = pcall(fn, userId, args)
	if not ok then return false, "script error: " .. tostring(success) end
	return success, message
end

-- Cross-server: if the player is in another server, THAT server applies the
-- command (so its autosave can't overwrite the change). If no server answers,
-- the player is offline and the DataStore is edited directly.
local pending = {}
local messagingReady = false

task.spawn(function()
	local okReply = pcall(function()
		MessagingService:SubscribeAsync(ACK_TOPIC, function(message)
			local reply = message.Data
			if type(reply) ~= "table" or reply.To ~= SERVER_ID then return end
			local entry = pending[reply.Id]
			if not entry then return end
			entry.Received = true
			if reply.Done then
				entry.Done = true
				entry.Ok = reply.Ok
				entry.Message = reply.Message
			end
		end)
	end)

	local okCommand = pcall(function()
		MessagingService:SubscribeAsync(CMD_TOPIC, function(message)
			local request = message.Data
			if type(request) ~= "table" or request.From == SERVER_ID or request.Admin ~= ADMIN_USER_ID then return end
			local userId = tonumber(request.UserId)
			if not userId or not Players:GetPlayerByUserId(userId) then return end

			task.spawn(function()
				local function reply(payload)
					payload.To, payload.Id = request.From, request.Id
					pcall(function() MessagingService:PublishAsync(ACK_TOPIC, payload) end)
				end
				reply({ Done = false })
				local ok, result = runOp(request.Op, userId, request.Args or {})
				reply({ Done = true, Ok = ok, Message = tostring(result):sub(1, 700) })
			end)
		end)
	end)

	messagingReady = okReply and okCommand
	if not messagingReady then
		warn("[Admin] MessagingService unavailable: commands on players in OTHER servers will edit saved data directly")
	end
end)

local function dispatch(op, target, args)
	args.Name = target.Name
	if Players:GetPlayerByUserId(target.UserId) or not messagingReady then
		return runOp(op, target.UserId, args)
	end

	local id = HttpService:GenerateGUID(false)
	local entry = {}
	pending[id] = entry
	local published = pcall(function()
		MessagingService:PublishAsync(CMD_TOPIC, {
			From = SERVER_ID, Id = id, Op = op, UserId = target.UserId, Args = args, Admin = ADMIN_USER_ID,
		})
	end)

	if published then
		local start = os.clock()
		while not entry.Received and os.clock() - start < RECEIVE_TIMEOUT do task.wait(0.1) end
		if entry.Received then
			start = os.clock()
			while not entry.Done and os.clock() - start < RESULT_TIMEOUT do task.wait(0.1) end
			pending[id] = nil
			if entry.Done then
				return entry.Ok, tostring(entry.Message) .. " [other server]"
			end
			return false, "the other server didn't finish in time, check with !data before retrying"
		end
	end

	pending[id] = nil
	return runOp(op, target.UserId, args) -- nobody has them: offline
end

local function reply(admin, ok, message)
	print(("[Admin] %s %s"):format(ok and "OK:" or "FAILED:", message))
	if admin.Parent then
		adminRemote:FireClient(admin, message, ok)
	end
end

local Commands
Commands = {
	gc = {
		Usage = "!gc [username] [amount]",
		Run = function(admin, args)
			local amount = parseAmount(args[2])
			if not args[1] or not amount then return false, "Usage: " .. Commands.gc.Usage end
			local target, err = resolveUser(args[1], admin)
			if not target then return false, err end
			return dispatch("gc", target, { Amount = amount })
		end,
	},
	setstars = {
		Usage = "!setstars [username] [amount]",
		Run = function(admin, args)
			local amount = parseAmount(args[2])
			if not args[1] or not amount then return false, "Usage: " .. Commands.setstars.Usage end
			local target, err = resolveUser(args[1], admin)
			if not target then return false, err end
			return dispatch("setstars", target, { Amount = amount })
		end,
	},
	giveunit = {
		Usage = "!giveunit [username] [tower] [count]",
		Run = function(admin, args)
			if #args < 2 then return false, "Usage: " .. Commands.giveunit.Usage end
			local count = 1
			if #args >= 3 and tonumber(args[#args]) then
				count = math.clamp(math.floor(tonumber(args[#args])), 1, 100)
				table.remove(args, #args)
			end
			local towerName = findTower(table.concat(args, " ", 2))
			if not towerName then return false, "no tower called '" .. table.concat(args, " ", 2) .. "' in TowerShop" end
			local target, err = resolveUser(args[1], admin)
			if not target then return false, err end
			return dispatch("giveunit", target, { Tower = towerName, Count = count })
		end,
	},
	resetdata = {
		Usage = "!resetdata [username]",
		Run = function(admin, args)
			if not args[1] then return false, "Usage: " .. Commands.resetdata.Usage end
			local target, err = resolveUser(args[1], admin)
			if not target then return false, err end
			return dispatch("resetdata", target, {})
		end,
	},
	recoverdata = {
		Usage = "!recoverdata [username]",
		Run = function(admin, args)
			if not args[1] then return false, "Usage: " .. Commands.recoverdata.Usage end
			local target, err = resolveUser(args[1], admin)
			if not target then return false, err end
			return dispatch("recoverdata", target, {})
		end,
	},
	data = {
		Usage = "!data [username]",
		Run = function(admin, args)
			local target, err = resolveUser(args[1] or "me", admin)
			if not target then return false, err end
			return dispatch("data", target, {})
		end,
	},
	resetcodes = {
		Usage = "!resetcodes [username] [code]",
		Run = function(admin, args)
			if not args[1] then return false, "Usage: " .. Commands.resetcodes.Usage end
			local target, err = resolveUser(args[1], admin)
			if not target then return false, err end
			local code = #args >= 2 and codeKey(table.concat(args, "", 2)) or nil
			return dispatch("resetcodes", target, { Code = code })
		end,
	},
	exists = {
		Usage = "!exists",
		Run = function()
			local counts = {}
			for name in pairs(towerNames) do
				table.insert(counts, name .. " " .. withCommas(existsTotal(name)))
			end
			table.sort(counts)
			local state
			if not EXISTS_LIVE then
				state = "doesn't run in Studio (live servers do it)"
			else
				local status = readScanStatus() or {}
				local progress = ("%s saves checked, %s players counted"):format(
					withCommas(tonumber(status.Checked) or 0), withCommas(tonumber(status.Counted) or 0))
				if status.Done then
					state = "finished (" .. progress .. ")"
				elseif scanRunning then
					state = "running on this server (" .. progress .. ")"
				else
					state = "running on another server or starting soon (" .. progress .. ")"
				end
			end
			return true, "Offline count " .. state .. " | " .. table.concat(counts, ", ")
		end,
	},
	cmds = {
		Usage = "!cmds",
		Run = function()
			local lines = {}
			for _, name in ipairs({ "gc", "setstars", "giveunit", "resetdata", "recoverdata", "data", "resetcodes", "exists" }) do
				table.insert(lines, Commands[name].Usage)
			end
			return true, table.concat(lines, "  |  ")
		end,
	},
}

local commandBusy = false

local function onAdminChat(admin, message)
	if admin.UserId ~= ADMIN_USER_ID then return end -- double check, nobody else ever gets here
	local text = message:match("^%s*(.-)%s*$")
	if text:sub(1, #COMMAND_PREFIX) ~= COMMAND_PREFIX then return end

	local words = {}
	for word in text:sub(#COMMAND_PREFIX + 1):gmatch("%S+") do
		table.insert(words, word)
	end
	local command = Commands[(table.remove(words, 1) or ""):lower()]
	if not command then return end

	task.spawn(function()
		-- one command at a time, so two quick commands never step on each other
		while commandBusy do task.wait() end
		commandBusy = true
		local ok, success, result = pcall(command.Run, admin, words)
		commandBusy = false
		if not ok then
			reply(admin, false, "script error: " .. tostring(success))
		else
			reply(admin, success, tostring(result))
		end
	end)
end

----------------------------------------------------------------
-- PLAYERS
----------------------------------------------------------------
local started = {}

local function onPlayerAdded(player)
	if started[player] then return end
	started[player] = true

	if player.UserId == ADMIN_USER_ID then
		player.Chatted:Connect(function(message)
			onAdminChat(player, message)
		end)
	end

	-- safety: if the inventory folder ever goes missing, rebuild it
	player.CharacterAdded:Connect(function()
		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if data[player.UserId] and playerGui and not playerGui:FindFirstChild(INVENTORY_FOLDER) then
			replicateAllUnits(player)
		end
	end)

	LoadData(player)
end
Players.PlayerAdded:Connect(onPlayerAdded)

Players.PlayerRemoving:Connect(function(player)
	lastSummon[player] = nil
	started[player] = nil
end)

-- Players who joined before this script finished loading (Studio play solo)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end
