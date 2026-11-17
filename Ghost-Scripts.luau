-- Ghost's Scripts | plain WindUI | v4: file-backed settings, dynamic script library

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
while not player do
	task.wait(0.1)
	player = Players.LocalPlayer
end
local WINDUI_URL = "https://cdn.jsdelivr.net/gh/Footagesus/WindUI@main/dist/main.lua"
local DEFAULT_FONT_ASSET = "rbxassetid://12187365364" -- Inter
local SOURCES = {
	["Infinite Yield"] = "https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source",
	["Vex"] = "https://raw.githubusercontent.com/Vezise/2026/refs/heads/main/Vez/VexExplorer/VEXExplorer.lua",
	["Cobalt"] = "https://gitlab.com/upio/cobalt/-/releases/permalink/latest/downloads/Cobalt.luau",
	["AK Admin"] = "https://absent.wtf/AKADMIN.lua",
	["Executor Tester"] = "https://raw.githubusercontent.com/GmilerlolYT/ExecutorTester/refs/heads/main/Hi",
}

-- Scripts known to hook deep engine functions; warned about in the run popup.
-- (Cobalt confirmed crashing with an access violation inside
-- RobloxPlayerBeta.exe when run alongside executor injection.)
local RISKY_SCRIPT_NOTES = {
	["Cobalt"] = "Warning: Cobalt hooks deep engine functions for network interception and is known to hard-crash some injected sessions (confirmed access violation). Use with care.",
}

-- All saved preferences (custom scripts, toggle key, font, recent pick,
-- auto-update) live in one JSON file so they survive rejoining. Player
-- attributes do not persist between sessions, so they are only read once
-- here to migrate older saved values.
local SETTINGS_FILE = "GhostsScripts/settings.json"
local SETTINGS = {}
do
	local fileExists = type(isfile) == "function" and isfile(SETTINGS_FILE)
	if fileExists then
		local ok, content = pcall(readfile, SETTINGS_FILE)
		if ok and type(content) == "string" and #content > 0 then
			local decodedOk, decoded = pcall(function() return HttpService:JSONDecode(content) end)
			if decodedOk and type(decoded) == "table" then
				SETTINGS = decoded
			end
		end
	else
		-- first run: carry over anything saved the old attribute way
		local migrated = {}
		local savedCustom = player:GetAttribute("GhostsScripts.CustomSources")
		if type(savedCustom) == "string" and #savedCustom > 0 then
			local ok, decoded = pcall(function() return HttpService:JSONDecode(savedCustom) end)
			if ok and type(decoded) == "table" then migrated.CustomSources = decoded end
		end
		for attrName, settingKey in pairs({
			["GhostsScripts.ToggleKey"] = "ToggleKey",
			["GhostsScripts.FontAsset"] = "FontAsset",
			["GhostsScripts.LastScript"] = "LastScript",
			["GhostsScripts.AutoUpdate"] = "AutoUpdate",
		}) do
			local value = player:GetAttribute(attrName)
			if value ~= nil and migrated[settingKey] == nil then
				migrated[settingKey] = value
			end
		end
		SETTINGS = migrated
	end
end

local function saveSetting(key, value)
	SETTINGS[key] = value
	if type(writefile) == "function" then
		pcall(function() writefile(SETTINGS_FILE, HttpService:JSONEncode(SETTINGS)) end)
	end
end

-- Every setting with its untouched value. The Share tab uses this so an
-- export always contains a COMPLETE set of preferences, even for settings the
-- user never changed.
local SETTING_DEFAULTS = {
	ToggleKey = "RightShift",
	FontAsset = DEFAULT_FONT_ASSET,
	AutoUpdate = true,
	HopMode = "Lowest ping",
	ExcludeFullServers = true,
	AntiAFK = true,
	AutoRejoin = true,
}

-- Scripts the user added through the Downloads tab.
local customSources = {}
local savedCustomTable = SETTINGS.CustomSources
if type(savedCustomTable) == "table" then
	for customName, customUrl in pairs(savedCustomTable) do
		if type(customName) == "string" and #customName > 0
			and type(customUrl) == "string" and customUrl:match("^https?://")
			and not SOURCES[customName] then
			SOURCES[customName] = customUrl
			customSources[customName] = true
		end
	end
end
local function saveCustomSources()
	local out = {}
	for customName in pairs(customSources) do
		out[customName] = SOURCES[customName]
	end
	saveSetting("CustomSources", out)
end

-- Pinned scripts float to the top of the library; the pin state persists
-- through the settings file.
local favoriteSet = {}
local savedFavorites = SETTINGS.Favorites
if type(savedFavorites) == "table" then
	for _, favoriteName in ipairs(savedFavorites) do
		if type(favoriteName) == "string" then
			favoriteSet[favoriteName] = true
		end
	end
end

local function compareNames(a, b)
	local aPinned = favoriteSet[a] == true
	local bPinned = favoriteSet[b] == true
	if aPinned ~= bPinned then
		return aPinned
	end
	return string.lower(a) < string.lower(b)
end

local scriptNames = {}
for scriptName in pairs(SOURCES) do
	table.insert(scriptNames, scriptName)
end
table.sort(scriptNames, compareNames)

local function saveFavorites()
	local out = {}
	for _, scriptName in ipairs(scriptNames) do
		if favoriteSet[scriptName] then
			table.insert(out, scriptName)
		end
	end
	saveSetting("Favorites", out)
end

local isExiting = false

-- Library pagination is shared by the Downloads and Scripts tab selectors.
local SCRIPTS_PER_PAGE = 5
local MAX_PAGES = 100

-- WindUI element builders return the content module; some builds also return a
-- type string before it. Take the last return value so both shapes work.
local function elementFrom(...)
	local results = { ... }
	return results[#results]
end

local executorRequest = request or http_request
local function requestHttpGet(url)
	if type(executorRequest) ~= "function" then
		return game:HttpGet(url)
	end
	local lastError = "No response"
	for attempt = 1, 3 do
		local requestOk, response = pcall(function()
			return executorRequest({ Url = url, Method = "GET" })
		end)
		if requestOk and type(response) == "table" and response.Success
			and type(response.Body) == "string" and #response.Body > 0 then
			return response.Body
		end
		if requestOk and type(response) == "table" then
			lastError = tostring(response.StatusCode) .. " " .. tostring(response.StatusMessage)
		else
			lastError = tostring(response)
		end
		if attempt < 3 then task.wait(0.2 * attempt) end
	end
	error("HTTP request failed: " .. lastError)
end

local windUISourceOk, windUISource = pcall(requestHttpGet, WINDUI_URL)
if not windUISourceOk then
	local fallbackOk, fallbackSource = pcall(function() return game:HttpGet(WINDUI_URL) end)
	if fallbackOk and type(fallbackSource) == "string" and #fallbackSource > 0 then
		windUISource = fallbackSource
	else
		error("[Ghost's Scripts] WindUI download failed: " .. tostring(windUISource))
	end
end
local iconPackageMarker = "https://raw.githubusercontent.com/Footagesus/Icons/refs/heads/main/lucide/dist/Icons.lua"
local iconExploitMarker = "local function IsExploit()\nreturn request and true or false\nend"
local iconPackagePos = string.find(windUISource, iconPackageMarker, 1, true)
local iconExploitPos = string.find(windUISource, iconExploitMarker, 1, true)
if not iconPackagePos or not iconExploitPos or iconExploitPos > iconPackagePos then
	error("[Ghost's Scripts] WindUI bundled icon path could not be selected.")
end
-- Use WindUI's bundled icon tables rather than the optional remote icon fetch.
windUISource = string.sub(windUISource, 1, iconExploitPos - 1)
	.. "local function IsExploit()\nreturn false\nend"
	.. string.sub(windUISource, iconExploitPos + #iconExploitMarker)

local WindUIChunk, windUIError = loadstring(windUISource, "@WindUI")
if not WindUIChunk then error("[Ghost's Scripts] WindUI failed to compile: " .. tostring(windUIError)) end
local windUIOk, WindUI = pcall(WindUIChunk)
if not windUIOk then error("[Ghost's Scripts] WindUI failed to initialize: " .. tostring(WindUI)) end
local savedFontAsset = SETTINGS.FontAsset or player:GetAttribute("GhostsScripts.FontAsset") or DEFAULT_FONT_ASSET
if not pcall(function() WindUI:SetFont(savedFontAsset) end) then
	savedFontAsset = DEFAULT_FONT_ASSET
	WindUI:SetFont(DEFAULT_FONT_ASSET)
end

-- Monochrome look: recolor the Dark theme's toggle accent from WindUI's
-- green (#33C759) to gray. OFF states use the darker ElementBackground, so a
-- brighter gray (#808089) for ON keeps the two states clearly apart while
-- staying inside the menu's gray palette. Mutating the theme table before
-- the window is built means every toggle picks it up at creation.
do
	local themesOk, themes = pcall(function() return WindUI:GetThemes() end)
	if themesOk and type(themes) == "table" then
		local darkTheme = themes["Dark"]
		if type(darkTheme) == "table" then
			darkTheme.Toggle = Color3.fromHex("#808089")
			pcall(function() WindUI:SetTheme("Dark") end)
		end
	end
end

local savedKey = SETTINGS.ToggleKey or player:GetAttribute("GhostsScripts.ToggleKey") or "RightShift"
local initialKey = Enum.KeyCode[savedKey] or Enum.KeyCode.RightShift
local DEFAULT_WINDOW_SIZE = UDim2.fromOffset(700, 500)

local Window = WindUI:CreateWindow({
	Title = "Ghost's Scripts",
	Icon = "ghost",
	Author = "Script Library",
	Folder = "GhostsScripts",
	Size = DEFAULT_WINDOW_SIZE,
	MinSize = Vector2.new(572, 360),
	MaxSize = Vector2.new(1056, 720),
	Theme = "Dark",
	Transparent = true,
	Acrylic = true,
	ToggleKey = initialKey,
	Resizable = true,
	HideSearchBar = true,
})

-- Black matte look: slightly translucent dark background (no blur). The
-- value snaps to 0.1 steps inside WindUI; 0.2 = subtle see-through.
pcall(function() Window:SetBackgroundTransparency(0.2) end)

local HomeTab = Window:Tab({ Title = "Home", Icon = "house", Locked = false })
local ScriptsTab = Window:Tab({ Title = "Scripts", Icon = "terminal", Locked = false })
local DownloadsTab = Window:Tab({ Title = "Downloads", Icon = "download", Locked = false })
local ServerTab = Window:Tab({ Title = "Server Hop", Icon = "globe", Locked = false })
local ShareTab = Window:Tab({ Title = "Share", Icon = "share-2", Locked = false })
local SettingsTab = Window:Tab({ Title = "Settings", Icon = "settings", Locked = false })

local function homeInfo(readValue, fallback)
	local ok, value = pcall(readValue)
	if ok and value ~= nil and tostring(value) ~= "" then
		return tostring(value)
	end
	return fallback
end

local function prettyPlaceName(name)
	name = tostring(name or "")
	if name:lower() == "ugc" then return "UGC" end
	return name
end

local executorName, executorVersion = "Unknown", "Unavailable"
if type(identifyexecutor) == "function" then
	local ok, name, versionText = pcall(identifyexecutor)
	if ok then
		if name ~= nil then executorName = tostring(name) end
		if versionText ~= nil and tostring(versionText) ~= "" then executorVersion = tostring(versionText) end
	end
end
if executorVersion == "Unavailable" and type(getexecutorversion) == "function" then
	executorVersion = homeInfo(getexecutorversion, "Unavailable")
end

local robloxVersion = homeInfo(function()
	if type(version) == "function" then return version() end
	return nil
end, "Unavailable")
local placeId = homeInfo(function() return game.PlaceId end, "Unavailable")
local universeId = homeInfo(function() return game.GameId end, "Unavailable")
local playerName = homeInfo(function()
	return player.DisplayName .. " (@" .. player.Name .. ")"
end, "Unknown player")
local userId = homeInfo(function() return player.UserId end, "Unavailable")

local function serverIdText()
	local serverId = homeInfo(function() return game.JobId end, "Studio / local session")
	if #serverId > 24 then
		serverId = string.sub(serverId, 1, 10) .. "…" .. string.sub(serverId, -8)
	end
	return serverId
end

-- Home tab paragraphs keep references so the 5 second refresh loop can update
-- them in place without recreating any element.
local homeRefs = {}
local availableScriptCount = #scriptNames

HomeTab:Section({ Title = "Welcome", Icon = "sparkles", Opened = true })
homeRefs.welcome = elementFrom(HomeTab:Paragraph({
	Title = "Ghost's Scripts",
	Desc = "Your client dashboard · " .. tostring(availableScriptCount) .. " scripts available.",
}))
HomeTab:Section({ Title = "Runtime", Icon = "cpu", Opened = true })
homeRefs.executor = elementFrom(HomeTab:Paragraph({
	Title = "Executor",
	Desc = executorName .. " · " .. executorVersion,
}))
homeRefs.roblox = elementFrom(HomeTab:Paragraph({
	Title = "Roblox client",
	Desc = "Version " .. robloxVersion,
}))
HomeTab:Section({ Title = "Experience", Icon = "map-pin", Opened = true })
homeRefs.experience = elementFrom(HomeTab:Paragraph({
	Title = prettyPlaceName(homeInfo(function() return game.Name end, "Unknown experience")),
	Desc = "Place ID: " .. placeId .. " · Universe ID: " .. universeId
		.. " · Place version: " .. homeInfo(function() return game.PlaceVersion end, "Unavailable"),
}))
HomeTab:Section({ Title = "Session", Icon = "users", Opened = true })
homeRefs.session = elementFrom(HomeTab:Paragraph({
	Title = playerName,
	Desc = "User ID: " .. userId .. " · Players in server: "
		.. homeInfo(function() return #Players:GetPlayers() end, "Unavailable")
		.. "\nServer: " .. serverIdText(),
}))
HomeTab:Button({
	Title = "Browse scripts",
	Desc = "Open the script selection tab.",
	Icon = "arrow-right",
	Callback = function()
		pcall(function() ScriptsTab:Select() end)
	end,
})
HomeTab:Button({
	Title = "Open downloads",
	Desc = "See which scripts are cached, downloading or failed.",
	Icon = "download",
	Callback = function()
		pcall(function() DownloadsTab:Select() end)
	end,
})
HomeTab:Button({
	Title = "Server hop",
	Desc = "Leave this server by ping or player count.",
	Icon = "globe",
	Callback = function()
		pcall(function() ServerTab:Select() end)
	end,
})
HomeTab:Button({
	Title = "Open settings",
	Desc = "Change your menu shortcut and appearance.",
	Icon = "settings",
	Callback = function()
		pcall(function() SettingsTab:Select() end)
	end,
})

-- live refresh for the Home dashboard, called every 5 seconds
local function refreshHome()
	local placeNameNow = prettyPlaceName(homeInfo(function() return game.Name end, "Unknown experience"))
	local placeVersionNow = homeInfo(function() return game.PlaceVersion end, "Unavailable")
	local playerCountNow = homeInfo(function() return #Players:GetPlayers() end, "Unavailable")
	if homeRefs.experience then
		pcall(function()
			homeRefs.experience:SetTitle(placeNameNow)
			homeRefs.experience:SetDesc(
				"Place ID: " .. placeId .. " · Universe ID: " .. universeId
					.. " · Place version: " .. placeVersionNow
			)
		end)
	end
	if homeRefs.session then
		pcall(function()
			homeRefs.session:SetDesc(
				"User ID: " .. userId .. " · Players in server: " .. playerCountNow
					.. "\nServer: " .. serverIdText()
			)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Script source store: download state, cache, statuses for the Downloads tab.
-- ---------------------------------------------------------------------------
local scriptStore = {} -- [name] = { state = "idle"|"downloading"|"cached"|"failed", source, size, fetchedAt, error }
local prefetchFreshAt = {} -- [name] = os.time() when a run dialog last pre-fetched a fresh copy
local sessionRunCount = {} -- [name] = times the script was launched this session
local cacheGeneration = {} -- [name] = bumped whenever a cache entry is deleted; in-flight downloads discard their result if it changed
local downloadRows = {} -- [name] = { stack = HStack content, paragraph = Paragraph content }
local downloadSummary = nil
-- Auto-update defaults to ON; an explicit saved choice always wins.
local autoUpdate = true
if SETTINGS.AutoUpdate ~= nil then
	autoUpdate = SETTINGS.AutoUpdate == true
elseif player:GetAttribute("GhostsScripts.AutoUpdate") ~= nil then
	autoUpdate = player:GetAttribute("GhostsScripts.AutoUpdate") == true
end

local function fetchScriptSource(url)
	local requestFunction = request or http_request
	local lastError = "No response"
	for attempt = 1, 3 do
		local getOk, response = pcall(function()
			return game:HttpGet(url)
		end)
		if getOk and type(response) == "string" and #response > 0 then
			return response
		end
		lastError = tostring(response)

		if type(requestFunction) == "function" then
			local requestOk, requestResponse = pcall(function()
				return requestFunction({ Url = url, Method = "GET" })
			end)
			if requestOk and type(requestResponse) == "table" and requestResponse.Success
				and type(requestResponse.Body) == "string" and #requestResponse.Body > 0 then
				return requestResponse.Body
			end
			if requestOk and type(requestResponse) == "table" then
				lastError = tostring(requestResponse.StatusMessage or requestResponse.StatusCode or lastError)
			elseif not requestOk then
				lastError = tostring(requestResponse)
			end
		end

		if attempt < 3 then task.wait(0.4 * attempt) end
	end
	error("Could not download script source after 3 attempts: " .. lastError)
end

local refreshDownloadRow
local refreshDownloadSummary

local function describeStatus(scriptName)
	local entry = scriptStore[scriptName]
	if not entry then return "Not downloaded" end
	if entry.state == "downloading" then return "Downloading…" end
	if entry.state == "failed" then return "Failed: " .. tostring(entry.error or "unknown error") end
	if entry.state == "cached" then
		local age = os.time() - (entry.fetchedAt or os.time())
		local ageText
		if age < 5 then
			ageText = "just now"
		elseif age < 60 then
			ageText = tostring(age) .. "s ago"
		elseif age < 3600 then
			ageText = tostring(math.floor(age / 60)) .. "m ago"
		else
			ageText = tostring(math.floor(age / 3600)) .. "h ago"
		end
		return string.format("Cached · %.1f KB · fetched %s", (entry.size or #entry.source) / 1024, ageText)
	end
	return "Not downloaded"
end

refreshDownloadRow = function(scriptName)
	local row = downloadRows[scriptName]
	if row and row.paragraph then
		pcall(function() row.paragraph:SetDesc(describeStatus(scriptName)) end)
	end
end

refreshDownloadSummary = function()
	if not downloadSummary then return end
	local cached, failed, busy = 0, 0, 0
	for _, scriptName in ipairs(scriptNames) do
		local entry = scriptStore[scriptName]
		if entry then
			if entry.state == "cached" then
				cached += 1
			elseif entry.state == "failed" then
				failed += 1
			elseif entry.state == "downloading" then
				busy += 1
			end
		end
	end
	local text = string.format("%d/%d cached · %d failed · %d in progress", cached, #scriptNames, failed, busy)
	if autoUpdate then
		text = text .. "\nAuto-update is ON: running a script fetches the newest version first."
	end
	pcall(function() downloadSummary:SetDesc(text) end)
end

-- Clears one script's cache and invalidates any in-flight download for it,
-- so the next run always starts a clean fresh download.
local function clearScriptCache(scriptName)
	scriptStore[scriptName] = nil
	cacheGeneration[scriptName] = (cacheGeneration[scriptName] or 0) + 1
	refreshDownloadRow(scriptName)
	refreshDownloadSummary()
end

-- Downloads a script source. force = true re-fetches even when cached.
-- Returns source, nil on success or nil, errorMessage on failure.
local function downloadScript(scriptName, force)
	local sourceUrl = SOURCES[scriptName]
	if not sourceUrl then
		return nil, "No source is configured for " .. tostring(scriptName)
	end

	local entry = scriptStore[scriptName]
	if entry and entry.state == "cached" and not force then
		return entry.source
	end
	if entry and entry.state == "downloading" then
		-- another download of this script is already running; wait for it
		while scriptStore[scriptName] and scriptStore[scriptName].state == "downloading" do
			if isExiting then return nil, "shutting down" end
			task.wait(0.05)
		end
		local finished = scriptStore[scriptName]
		if finished and finished.state == "cached" then
			return finished.source
		end
		return nil, (finished and finished.error) or "download failed"
	end

	local generation = cacheGeneration[scriptName] or 0
	scriptStore[scriptName] = { state = "downloading" }
	refreshDownloadRow(scriptName)
	refreshDownloadSummary()

	local ok, sourceOrError = pcall(fetchScriptSource, sourceUrl)
	local sourceIsInvalid = not ok
		or type(sourceOrError) ~= "string"
		or #sourceOrError == 0
		or sourceOrError:match("^%s*Not Found%s*$") ~= nil
		or sourceOrError:match("^%s*<") ~= nil
	if sourceIsInvalid then
		local message = "unknown error"
		if not ok then
			message = tostring(sourceOrError)
		elseif type(sourceOrError) ~= "string" or #sourceOrError == 0 then
			message = "the download returned an empty response"
		elseif sourceOrError:match("^%s*Not Found%s*$") then
			message = "the source URL returned Not Found"
		else
			message = "the source URL returned an HTML page instead of a script"
		end
		scriptStore[scriptName] = { state = "failed", error = message }
		refreshDownloadRow(scriptName)
		refreshDownloadSummary()
		return nil, message
	end

	if (cacheGeneration[scriptName] or 0) ~= generation then
		-- the cache entry was deleted while this download was in flight;
		-- discard the result so the next run downloads a clean copy
		scriptStore[scriptName] = nil
		refreshDownloadRow(scriptName)
		refreshDownloadSummary()
		return nil, "cache was cleared while downloading"
	end
	scriptStore[scriptName] = {
		state = "cached",
		source = sourceOrError,
		size = #sourceOrError,
		fetchedAt = os.time(),
	}
	refreshDownloadRow(scriptName)
	refreshDownloadSummary()
	return sourceOrError
end

local function loadScriptSource(scriptName)
	local source, err = downloadScript(scriptName, false)
	if not source then error(err or "download failed") end
	return source
end

local function cobaltIsInitialized()
	if type(getgenv) ~= "function" then return false end
	local ok, value = pcall(function() return getgenv().CobaltInitialized end)
	return ok and value == true
end

-- ---------------------------------------------------------------------------
-- Scripts tab: recent selection + dropdown + run (confirmation kept).
-- ---------------------------------------------------------------------------
local savedRecent = SETTINGS.LastScript or player:GetAttribute("GhostsScripts.LastScript")
if not (savedRecent and SOURCES[savedRecent]) then
	savedRecent = "Infinite Yield"
end
local selectedScript = savedRecent

local scriptTabElements = {}
local scriptRows = {} -- [name] = { stack = HStack content, paragraph = Paragraph content }
local scriptsIndicatorRef = nil
local scriptsCurrentPage = 1
local scriptsSearchQuery = ""
local currentPage -- downloads pagination page; declared here so pinning can reset it
local rebuildLibraryTabs -- forward: rebuilds both library tabs (defined in the Downloads section)

-- Prefers an element's own Destroy method, falling back to destroying its
-- visible frame directly (Sections and HStacks only expose ElementFrame).
local function destroyTrackedElement(el)
	if not el then return end
	pcall(function()
		if type(el.Destroy) == "function" then
			el:Destroy()
		elseif el.ElementFrame then
			el.ElementFrame:Destroy()
		end
	end)
end

-- Clears everything this script built on the Scripts tab. Newest first, so
-- WindUI's internal element indexes stay valid while they are removed.
local function destroyScriptTabContent()
	for index = #scriptTabElements, 1, -1 do
		destroyTrackedElement(scriptTabElements[index])
		scriptTabElements[index] = nil
	end
	scriptsIndicatorRef = nil
	table.clear(scriptRows)
end

-- Confirms and runs a script. Shared by every row's Run button so the
-- confirmation popup is always kept.
local function startRunFlow(scriptName)
	local sourceUrl = SOURCES[scriptName]
	if not sourceUrl then
		WindUI:Notify({ Title = "Script unavailable", Content = "No source is configured for this selection.", Duration = 4 })
		return
	end
	if scriptName == "Cobalt" and cobaltIsInitialized() then
		WindUI:Notify({
			Title = "Cobalt already running",
			Content = "Unload the current Cobalt session or restart the client before launching it again.",
			Duration = 5,
		})
		return
	end
	local willRefetch = autoUpdate
	selectedScript = scriptName
	saveSetting("LastScript", scriptName)
	-- While the user reads the dialog, prefetch the selected script (a fresh
	-- copy when auto-update is on) plus the rest of the library, so confirming
	-- Run executes from cache with no waiting.
	task.spawn(function()
		local source = downloadScript(scriptName, willRefetch)
		if source then
			prefetchFreshAt[scriptName] = os.time()
		end
	end)
	task.spawn(function()
		for _, otherName in ipairs(scriptNames) do
			if isExiting then return end
			if otherName ~= scriptName then
				downloadScript(otherName, false)
			end
		end
	end)
	local stabilityNote = RISKY_SCRIPT_NOTES[scriptName]
	local cacheEntry = scriptStore[scriptName]
	local cacheNote = nil
	if not (cacheEntry and cacheEntry.state == "cached" and cacheEntry.source) then
		cacheNote = "This script is not fully cached yet — it will be downloaded completely before it launches."
	end
	WindUI:Popup({
		Title = "Run " .. scriptName .. "?",
		Icon = "shield-alert",
		Content = (willRefetch
				and "Auto-update is on: the newest version will be downloaded, then executed. Continue only if you trust its source."
				or "This executes the selected downloaded Luau source in your client. Continue only if you trust its source.")
			.. (stabilityNote and ("\n\n" .. stabilityNote) or "")
			.. (cacheNote and ("\n\n" .. cacheNote) or ""),
		Buttons = {
			{ Title = "Cancel", Variant = "Tertiary", Callback = function() end },
			{
				Title = "Run",
				Icon = "arrow-right",
				Variant = "Primary",
				Callback = function()
					-- Execution is only allowed from a fully cached source. If
					-- the script is not cached yet, download it first and it
					-- launches automatically once the download completes.
					task.spawn(function()
						local entry = scriptStore[scriptName]
						if not (entry and entry.state == "cached" and entry.source) then
							WindUI:Notify({
								Title = "Not cached yet",
								Content = scriptName .. " is downloading first — it will launch automatically.",
								Icon = "download",
								Duration = 4,
							})
						end
						local freshAt = prefetchFreshAt[scriptName]
						local needForce = willRefetch and not (freshAt and os.time() - freshAt <= 30)
						local source, downloadError = downloadScript(scriptName, needForce)
						if not source then
							WindUI:Notify({ Title = "Launch failed", Content = tostring(downloadError):sub(1, 140), Duration = 5 })
							return
						end
						local chunk, compileError = loadstring(source, "@GhostsScripts/" .. scriptName)
						if not chunk then
							WindUI:Notify({ Title = "Launch failed", Content = tostring(compileError or "Could not compile script"):sub(1, 140), Duration = 5 })
							return
						end
						-- A script erroring must never die silently in this
						-- thread; surface it so the user always knows why.
						local runOk, runError = pcall(chunk)
						if not runOk then
							WindUI:Notify({
								Title = "Script error",
								Content = scriptName .. " crashed: " .. tostring(runError):sub(1, 110),
								Duration = 6,
							})
							return
						end
						sessionRunCount[scriptName] = (sessionRunCount[scriptName] or 0) + 1
						if scriptName == "Cobalt" then
							WindUI:Notify({ Title = "Cobalt initializing", Content = "Waiting for Cobalt to finish loading.", Duration = 3 })
							-- Cobalt is a large bundle and can legitimately take
							-- a while; poll instead of a fixed 3 second guess.
							task.spawn(function()
								local deadline = os.clock() + 12
								while os.clock() < deadline do
									if cobaltIsInitialized() then
										WindUI:Notify({ Title = "Cobalt launched", Content = "Cobalt finished initializing.", Duration = 4 })
										return
									end
									task.wait(0.5)
								end
								WindUI:Notify({ Title = "Cobalt did not initialize", Content = "Check the Roblox output for the startup error.", Duration = 5 })
							end)
						else
							WindUI:Notify({ Title = "Script launched", Content = scriptName .. " started.", Duration = 4 })
						end
					end)
				end,
			},
		},
	})
end

-- Some scripts keep hooks and state alive after they exit, so running them
-- twice in one session breaks them (Cobalt is a confirmed case: its hooks
-- are never removed). Warn on every same-session re-run and let the user
-- decide instead of letting it fail confusingly.
local function runScriptFlow(scriptName)
	if (sessionRunCount[scriptName] or 0) > 0 then
		local reRunNote = RISKY_SCRIPT_NOTES[scriptName]
			or "Running it again can conflict with state left behind from the first run."
		WindUI:Popup({
			Title = "Run " .. scriptName .. " again?",
			Icon = "triangle-alert",
			Content = "This script already ran in this session. " .. reRunNote .. " A rejoin gives a clean state.",
			Buttons = {
				{ Title = "Cancel", Variant = "Tertiary", Callback = function() end },
				{
					Title = "Run anyway",
					Icon = "play",
					Variant = "Primary",
					Callback = function()
						startRunFlow(scriptName)
					end,
				},
			},
		})
		return
	end
	startRunFlow(scriptName)
end

-- Instantly reshapes the Scripts tab library: filters rows by the search
-- query and shows only the current page's slice by toggling visibility.
local function applyScriptsView()
	local filtered = {}
	local loweredQuery = string.lower(scriptsSearchQuery)
	for _, scriptName in ipairs(scriptNames) do
		local row = scriptRows[scriptName]
		if row then
			if scriptsSearchQuery == "" or string.find(string.lower(scriptName), loweredQuery, 1, true) == 1 then
				table.insert(filtered, scriptName)
			end
		end
	end
	local pageCount = math.max(1, math.ceil(#filtered / SCRIPTS_PER_PAGE))
	scriptsCurrentPage = math.clamp(scriptsCurrentPage, 1, pageCount)
	local firstIndex = (scriptsCurrentPage - 1) * SCRIPTS_PER_PAGE + 1
	local lastIndex = math.min(#filtered, scriptsCurrentPage * SCRIPTS_PER_PAGE)
	local visibleSet = {}
	for index = firstIndex, lastIndex do
		visibleSet[filtered[index]] = true
	end
	for _, scriptName in ipairs(scriptNames) do
		local row = scriptRows[scriptName]
		if row and row.stack and row.stack.ElementFrame then
			row.stack.ElementFrame.Visible = visibleSet[scriptName] == true
		end
	end
	if scriptsIndicatorRef then
		local title = "Page " .. tostring(scriptsCurrentPage) .. " / " .. tostring(pageCount)
		local desc
		if scriptsSearchQuery ~= "" then
			if #filtered == 0 then
				desc = "No scripts match your search."
			else
				desc = "Matches " .. tostring(firstIndex) .. "–" .. tostring(lastIndex)
					.. " of " .. tostring(#filtered) .. " · " .. tostring(#scriptNames) .. " total"
			end
		else
			desc = "Scripts " .. tostring(firstIndex) .. "–" .. tostring(lastIndex) .. " of " .. tostring(#scriptNames)
		end
		pcall(function()
			scriptsIndicatorRef:SetTitle(title)
			scriptsIndicatorRef:SetDesc(desc)
		end)
	end
end

-- One compact row per script: name + download status on the left, one small
-- run button (with confirmation) on the right.
local function buildScriptRow(scriptName)
	local name = scriptName
	local stack = ScriptsTab:HStack({})
	local paragraph = elementFrom(stack:Paragraph({
		Title = name,
		Desc = describeStatus(name),
	}))
	local isPinned = favoriteSet[name] == true
	local starButton = elementFrom(stack:Button({
		Title = "",
		Icon = isPinned and "star" or "star-off",
		Callback = function()
			if favoriteSet[name] then
				favoriteSet[name] = nil
			else
				favoriteSet[name] = true
			end
			saveFavorites()
			currentPage = 1
			scriptsCurrentPage = 1
			table.sort(scriptNames, compareNames)
			rebuildLibraryTabs()
			WindUI:Notify({
				Title = favoriteSet[name] and "Pinned" or "Unpinned",
				Content = favoriteSet[name]
					and (name .. " now sits at the top of the library.")
					or (name .. " returned to alphabetical order."),
				Icon = "star",
				Duration = 3,
			})
		end,
	}))
	local runButton = elementFrom(stack:Button({
		Title = "",
		Icon = "play",
		Callback = function()
			runScriptFlow(name)
		end,
	}))
	pcall(function()
		if paragraph.ElementFrame then
			paragraph.ElementFrame.Size = UDim2.new(1, -116, 0, 0)
		end
		for _, button in ipairs({ starButton, runButton }) do
			local buttonFrame = button.ElementFrame
			if buttonFrame then
				buttonFrame.AutomaticSize = Enum.AutomaticSize.None
				buttonFrame.Size = UDim2.new(0, 46, 0, 38)
			end
		end
		local layout = stack.ElementFrame and stack.ElementFrame:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
		end
	end)
	scriptRows[name] = { stack = stack, paragraph = paragraph }
	table.insert(scriptTabElements, stack)
end

-- (Re)builds the Scripts tab in a fixed order: section header, recent
-- selection, page bar, search, one run row per script. Runs at startup and
-- whenever a script is added or removed, so nothing jumps to the bottom.
local function buildScriptTabContent()
	destroyScriptTabContent()
	table.insert(scriptTabElements, ScriptsTab:Section({ Title = "Script library", Icon = "boxes", Opened = true }))
	local pageStack = ScriptsTab:HStack({})
	local prevPageButton = elementFrom(pageStack:Button({
		Title = "",
		Icon = "chevron-left",
		Callback = function()
			if scriptsCurrentPage > 1 then
				scriptsCurrentPage -= 1
				applyScriptsView()
			end
		end,
	}))
	scriptsIndicatorRef = elementFrom(pageStack:Paragraph({
		Title = "Page 1 / 1",
		Desc = "",
	}))
	local nextPageButton = elementFrom(pageStack:Button({
		Title = "",
		Icon = "chevron-right",
		Callback = function()
			scriptsCurrentPage += 1
			applyScriptsView()
		end,
	}))
	pcall(function()
		if scriptsIndicatorRef.ElementFrame then
			scriptsIndicatorRef.ElementFrame.Size = UDim2.new(1, -116, 0, 0)
		end
		for _, button in ipairs({ prevPageButton, nextPageButton }) do
			local buttonFrame = button.ElementFrame
			if buttonFrame then
				buttonFrame.AutomaticSize = Enum.AutomaticSize.None
				buttonFrame.Size = UDim2.new(0, 46, 0, 38)
			end
		end
		local layout = pageStack.ElementFrame and pageStack.ElementFrame:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
		end
	end)
	table.insert(scriptTabElements, pageStack)
	local searchInput = elementFrom(ScriptsTab:Input({
		Title = "Search scripts",
		Desc = "Filters instantly while you type — no enter needed.",
		Placeholder = "Type a name…",
		Value = scriptsSearchQuery,
		Callback = function(value)
			local query = tostring(value or "")
			if query == scriptsSearchQuery then return end
			scriptsSearchQuery = query
			scriptsCurrentPage = 1
			applyScriptsView()
		end,
	}))
	table.insert(scriptTabElements, searchInput)
	-- The stock Input element only fires its callback on FocusLost, so hook
	-- the TextBox directly to filter on every single keystroke.
	pcall(function()
		local container = searchInput.InputFrame and searchInput.InputFrame.UIElements.Main
		if not container then return end
		for _, descendant in ipairs(container:GetDescendants()) do
			if descendant:IsA("TextBox") then
				descendant:GetPropertyChangedSignal("Text"):Connect(function()
					local query = descendant.Text or ""
					if query == scriptsSearchQuery then return end
					scriptsSearchQuery = query
					scriptsCurrentPage = 1
					applyScriptsView()
				end)
				break
			end
		end
	end)
	for _, scriptName in ipairs(scriptNames) do
		buildScriptRow(scriptName)
	end
	applyScriptsView()
end
buildScriptTabContent()

-- ---------------------------------------------------------------------------
-- Downloads tab: status overview, one compact row per script, options and an
-- add-script form. The whole tab is rebuilt in a fixed order whenever a
-- script is added or removed, so nothing ever jumps to the bottom.
-- ---------------------------------------------------------------------------
local downloadTabElements = {}
local removeCustomScript
local newScriptName = ""
local newScriptUrl = ""
-- The downloads library is paginated so huge libraries stay usable; pages
-- grow automatically as scripts are added, up to MAX_PAGES.
currentPage = 1
local searchQuery = ""
local pageIndicatorRef = nil

local destroyDownloadTabContent
local buildDownloadTabContent

-- Refreshes both library tabs after a script is added or removed: rebuilds
-- each tab's content in order and updates the Home script counter.
rebuildLibraryTabs = function()
	destroyDownloadTabContent()
	buildDownloadTabContent()
	destroyScriptTabContent()
	buildScriptTabContent()
	if homeRefs.welcome then
		pcall(function()
			homeRefs.welcome:SetDesc("Your client dashboard · " .. tostring(#scriptNames) .. " scripts available.")
		end)
	end
end

-- One compact row per script: name + live status on the left, three small
-- icon-only buttons (download / refresh / delete) on the right.
local function buildDownloadRow(scriptName)
	local name = scriptName
	local stack = DownloadsTab:HStack({})
	local paragraph = elementFrom(stack:Paragraph({
		Title = name,
		Desc = describeStatus(name),
	}))
	local downloadButton = elementFrom(stack:Button({
		Title = "",
		Icon = "download",
		Callback = function()
			task.spawn(function()
				local wasCached = scriptStore[name] and scriptStore[name].state == "cached"
				local source, downloadError = downloadScript(name, false)
				if source then
					if wasCached then
						WindUI:Notify({
							Title = "Already downloaded",
							Content = name .. " was already cached. Use the refresh button for a newer version.",
							Duration = 4,
						})
					else
						WindUI:Notify({ Title = "Downloaded", Content = name .. " is cached and ready to run.", Duration = 4 })
					end
				else
					WindUI:Notify({ Title = "Download failed", Content = tostring(downloadError):sub(1, 140), Duration = 5 })
				end
			end)
		end,
	}))
	local refreshButton = elementFrom(stack:Button({
		Title = "",
		Icon = "refresh-cw",
		Callback = function()
			task.spawn(function()
				local source, downloadError = downloadScript(name, true)
				if source then
					WindUI:Notify({ Title = "Script refreshed", Content = name .. " was re-downloaded (newest version).", Duration = 4 })
				else
					WindUI:Notify({ Title = "Redownload failed", Content = tostring(downloadError):sub(1, 140), Duration = 5 })
				end
			end)
		end,
	}))
	local deleteButton = elementFrom(stack:Button({
		Title = "",
		Icon = "trash-2",
		Callback = function()
			if customSources[name] then
				WindUI:Popup({
					Title = "Remove " .. name .. "?",
					Icon = "trash-2",
					Content = "Choose whether to only clear the downloaded cache, or remove the script from your library entirely.",
					Buttons = {
						{ Title = "Cancel", Variant = "Tertiary", Callback = function() end },
						{
							Title = "Clear cache",
							Callback = function()
								clearScriptCache(name)
							end,
						},
						{
							Title = "Remove script",
							Icon = "trash-2",
							Variant = "Primary",
							Callback = function()
								removeCustomScript(name)
							end,
						},
					},
				})
			else
				clearScriptCache(name)
				WindUI:Notify({ Title = "Cache cleared", Content = name .. " was removed from the local cache.", Duration = 3 })
			end
		end,
	}))
	-- Compact layout: the paragraph stretches, the three buttons become small
	-- fixed-size icon chips on the right.
	pcall(function()
		if paragraph.ElementFrame then
			paragraph.ElementFrame.Size = UDim2.new(1, -180, 0, 0)
		end
		for _, button in ipairs({ downloadButton, refreshButton, deleteButton }) do
			local buttonFrame = button.ElementFrame
			if buttonFrame then
				buttonFrame.AutomaticSize = Enum.AutomaticSize.None
				buttonFrame.Size = UDim2.new(0, 46, 0, 38)
			end
		end
		local layout = stack.ElementFrame and stack.ElementFrame:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
		end
	end)
	downloadRows[name] = { stack = stack, paragraph = paragraph }
	table.insert(downloadTabElements, stack)
end

-- Clears everything this script built on the Downloads tab. Newest first, so
-- WindUI's internal element indexes stay valid while they are removed.
destroyDownloadTabContent = function()
	for index = #downloadTabElements, 1, -1 do
		destroyTrackedElement(downloadTabElements[index])
		downloadTabElements[index] = nil
	end
	downloadSummary = nil
	pageIndicatorRef = nil
	table.clear(downloadRows)
	newScriptName = ""
	newScriptUrl = ""
end

-- Instantly reshapes the library view: filters rows by the search query and
-- shows only the current page's slice by toggling visibility. No elements are
-- created or destroyed, so typing in the search box never loses focus.
local function applyLibraryView()
	local filtered = {}
	local loweredQuery = string.lower(searchQuery)
	for _, scriptName in ipairs(scriptNames) do
		local row = downloadRows[scriptName]
		if row then
			if searchQuery == "" or string.find(string.lower(scriptName), loweredQuery, 1, true) == 1 then
				table.insert(filtered, scriptName)
			end
		end
	end
	local pageCount = math.max(1, math.ceil(#filtered / SCRIPTS_PER_PAGE))
	currentPage = math.clamp(currentPage, 1, pageCount)
	local firstIndex = (currentPage - 1) * SCRIPTS_PER_PAGE + 1
	local lastIndex = math.min(#filtered, currentPage * SCRIPTS_PER_PAGE)
	local visibleSet = {}
	for index = firstIndex, lastIndex do
		visibleSet[filtered[index]] = true
	end
	for _, scriptName in ipairs(scriptNames) do
		local row = downloadRows[scriptName]
		if row and row.stack and row.stack.ElementFrame then
			row.stack.ElementFrame.Visible = visibleSet[scriptName] == true
		end
	end
	if pageIndicatorRef then
		local title = "Page " .. tostring(currentPage) .. " / " .. tostring(pageCount)
		local desc
		if searchQuery ~= "" then
			if #filtered == 0 then
				desc = "No scripts match your search."
			else
				desc = "Matches " .. tostring(firstIndex) .. "–" .. tostring(lastIndex)
					.. " of " .. tostring(#filtered) .. " · " .. tostring(#scriptNames) .. " total"
			end
		else
			desc = "Scripts " .. tostring(firstIndex) .. "–" .. tostring(lastIndex) .. " of " .. tostring(#scriptNames)
		end
		pcall(function()
			pageIndicatorRef:SetTitle(title)
			pageIndicatorRef:SetDesc(desc)
		end)
	end
end

buildDownloadTabContent = function()
	table.insert(downloadTabElements, DownloadsTab:Section({ Title = "Download status", Icon = "cloud-download", Opened = true }))
	downloadSummary = elementFrom(DownloadsTab:Paragraph({
		Title = "Overview",
		Desc = "Checking script cache…",
	}))
	table.insert(downloadTabElements, downloadSummary)
	-- Paginated script library. Every row is created once; searching and page
	-- flips only toggle row visibility through applyLibraryView, so they are
	-- instant and the search box never loses focus.
	table.insert(downloadTabElements, DownloadsTab:Section({ Title = "Script library", Icon = "list", Opened = true }))
	local pageStack = DownloadsTab:HStack({})
	local prevPageButton = elementFrom(pageStack:Button({
		Title = "",
		Icon = "chevron-left",
		Callback = function()
			if currentPage > 1 then
				currentPage -= 1
				applyLibraryView()
			end
		end,
	}))
	pageIndicatorRef = elementFrom(pageStack:Paragraph({
		Title = "Page 1 / 1",
		Desc = "",
	}))
	local nextPageButton = elementFrom(pageStack:Button({
		Title = "",
		Icon = "chevron-right",
		Callback = function()
			currentPage += 1
			applyLibraryView()
		end,
	}))
	pcall(function()
		if pageIndicatorRef.ElementFrame then
			pageIndicatorRef.ElementFrame.Size = UDim2.new(1, -116, 0, 0)
		end
		for _, button in ipairs({ prevPageButton, nextPageButton }) do
			local buttonFrame = button.ElementFrame
			if buttonFrame then
				buttonFrame.AutomaticSize = Enum.AutomaticSize.None
				buttonFrame.Size = UDim2.new(0, 46, 0, 38)
			end
		end
		local layout = pageStack.ElementFrame and pageStack.ElementFrame:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
		end
	end)
	table.insert(downloadTabElements, pageStack)
	local searchInput = elementFrom(DownloadsTab:Input({
		Title = "Search scripts",
		Desc = "Filters instantly while you type — no enter needed.",
		Placeholder = "Type a name…",
		Value = searchQuery,
		Callback = function(value)
			-- WindUI inputs fire this on FocusLost; the TextBox hook below
			-- already handled every keystroke, so skip unchanged values.
			local query = tostring(value or "")
			if query == searchQuery then return end
			searchQuery = query
			currentPage = 1
			applyLibraryView()
		end,
	}))
	table.insert(downloadTabElements, searchInput)
	-- The stock Input element only fires its callback on FocusLost, so hook
	-- the TextBox directly to filter on every single keystroke. The TextBox
	-- sits a few frames deep, so search all descendants for it.
	pcall(function()
		local container = searchInput.InputFrame and searchInput.InputFrame.UIElements.Main
		if not container then return end
		for _, descendant in ipairs(container:GetDescendants()) do
			if descendant:IsA("TextBox") then
				descendant:GetPropertyChangedSignal("Text"):Connect(function()
					local query = descendant.Text or ""
					if query == searchQuery then return end
					searchQuery = query
					currentPage = 1
					applyLibraryView()
				end)
				break
			end
		end
	end)
	for _, scriptName in ipairs(scriptNames) do
		buildDownloadRow(scriptName)
	end
	applyLibraryView()
	table.insert(downloadTabElements, DownloadsTab:Section({ Title = "Options", Icon = "settings-2", Opened = true }))
	table.insert(downloadTabElements, DownloadsTab:Toggle({
		Title = "Auto-update scripts",
		Desc = "When on, Run always downloads the newest version of the script before launching it.",
		Value = autoUpdate,
		Callback = function(value)
			autoUpdate = value == true
			saveSetting("AutoUpdate", autoUpdate)
			refreshDownloadSummary()
			WindUI:Notify({
				Title = autoUpdate and "Auto-update enabled" or "Auto-update disabled",
				Content = autoUpdate and "Scripts are re-fetched before every run." or "Scripts run from the cached copy.",
				Duration = 3,
			})
		end,
	}))
	table.insert(downloadTabElements, DownloadsTab:Button({
		Title = "Redownload all scripts",
		Desc = "Fetch a fresh copy of every script in the library.",
		Icon = "refresh-cw",
		Callback = function()
			task.spawn(function()
				for _, scriptName in ipairs(scriptNames) do
					if isExiting then return end
					downloadScript(scriptName, true)
				end
				if not isExiting then
					WindUI:Notify({ Title = "Library refreshed", Content = "All scripts were re-downloaded.", Duration = 4 })
				end
			end)
		end,
	}))
	table.insert(downloadTabElements, DownloadsTab:Button({
		Title = "Clear all cached scripts",
		Desc = "Remove every downloaded source from the cache. Nothing is run.",
		Icon = "trash-2",
		Callback = function()
			for _, scriptName in ipairs(scriptNames) do
				clearScriptCache(scriptName)
			end
			WindUI:Notify({ Title = "Cache cleared", Content = "All downloaded sources were removed.", Duration = 3 })
		end,
	}))
	table.insert(downloadTabElements, DownloadsTab:Section({ Title = "Add a script", Icon = "plus", Opened = true }))
	table.insert(downloadTabElements, DownloadsTab:Input({
		Title = "Script name",
		Desc = "Shown in Scripts and Downloads.",
		Placeholder = "My script",
		Callback = function(value)
			newScriptName = tostring(value or "")
		end,
	}))
	table.insert(downloadTabElements, DownloadsTab:Input({
		Title = "Source URL",
		Desc = "Direct link to a raw .lua/.luau file.",
		Placeholder = "https://raw.githubusercontent.com/...",
		Callback = function(value)
			newScriptUrl = tostring(value or "")
		end,
	}))
	table.insert(downloadTabElements, DownloadsTab:Button({
		Title = "Add script",
		Desc = "Adds it to the library, starts the download and shows it in both tabs.",
		Icon = "plus",
		Callback = function()
			local name = newScriptName:match("^%s*(.-)%s*$")
			local url = newScriptUrl:match("^%s*(.-)%s*$")
			if name == "" then
				WindUI:Notify({ Title = "Name needed", Content = "Enter a name for the script first.", Duration = 4 })
				return
			end
			if SOURCES[name] then
				WindUI:Notify({ Title = "Name already used", Content = "A script called " .. name .. " already exists.", Duration = 4 })
				return
			end
			if url ~= "" and not url:match("^https?://") and url:match("^[%w%.%-]+%.") then
				url = "https://" .. url
			end
			if not url:match("^https?://") then
				WindUI:Notify({ Title = "URL needed", Content = "Enter a direct http(s) link to the script source.", Duration = 4 })
				return
			end
			if #scriptNames >= SCRIPTS_PER_PAGE * MAX_PAGES then
				WindUI:Notify({
					Title = "Library is full",
					Content = "The limit is " .. tostring(SCRIPTS_PER_PAGE * MAX_PAGES) .. " scripts (1000 pages).",
					Duration = 5,
				})
				return
			end
			SOURCES[name] = url
			customSources[name] = true
			saveCustomSources()
			table.insert(scriptNames, name)
			table.sort(scriptNames, compareNames)
			local newIndex = table.find(scriptNames, name)
			if newIndex then
				currentPage = math.ceil(newIndex / SCRIPTS_PER_PAGE)
				scriptsCurrentPage = math.ceil(newIndex / SCRIPTS_PER_PAGE)
			end
			rebuildLibraryTabs()
			WindUI:Notify({ Title = "Script added", Content = name .. " was added — downloading it now.", Duration = 4 })
			task.spawn(function()
				local source, downloadError = downloadScript(name, false)
				if source then
					WindUI:Notify({ Title = "Downloaded", Content = name .. " is cached and ready to run.", Duration = 4 })
				else
					WindUI:Notify({ Title = "Download failed", Content = tostring(downloadError):sub(1, 140), Duration = 5 })
				end
			end)
		end,
	}))
	refreshDownloadSummary()
end

-- Removes a user-added script from the library, its row and the dropdown.
removeCustomScript = function(scriptName)
	clearScriptCache(scriptName)
	SOURCES[scriptName] = nil
	customSources[scriptName] = nil
	saveCustomSources()
	local nameIndex = table.find(scriptNames, scriptName)
	if nameIndex then table.remove(scriptNames, nameIndex) end
	if selectedScript == scriptName then
		selectedScript = scriptNames[1] or ""
		saveSetting("LastScript", selectedScript)
	end
	rebuildLibraryTabs()
	WindUI:Notify({ Title = "Script removed", Content = scriptName .. " was removed from your library.", Duration = 3 })
end

buildDownloadTabContent()

-- ---------------------------------------------------------------------------
-- Server Hop: leave the current server by strategy. The public games API
-- exposes ping, fps and player counts per server, so every mode is real data.
-- ---------------------------------------------------------------------------
local hopBusy = false
local TeleportService = game:GetService("TeleportService")

local function hopNow()
	if hopBusy then
		WindUI:Notify({ Title = "Already hopping", Content = "A server hop is already in progress.", Duration = 3 })
		return
	end
	hopBusy = true
	task.spawn(function()
		local ok, hopError = pcall(function()
			local mode = SETTINGS.HopMode or "Lowest ping"
			local excludeFull = SETTINGS.ExcludeFullServers ~= false
			local servers = {}
			local cursor = nil
			for _ = 1, 3 do
				local url = "https://games.roblox.com/v1/games/" .. tostring(game.PlaceId)
					.. "/servers/Public?limit=100"
					.. (excludeFull and "&excludeFullGames=true" or "")
					.. (cursor and ("&cursor=" .. cursor) or "")
				local body = requestHttpGet(url)
				local decoded = HttpService:JSONDecode(body)
				for _, entry in ipairs(decoded.data or {}) do
					table.insert(servers, entry)
				end
				cursor = decoded.nextPageCursor
				if not cursor then break end
			end
			local candidates = {}
			for _, entry in ipairs(servers) do
				if entry.id ~= game.JobId
					and (not excludeFull or (entry.playing or 0) < (entry.maxPlayers or 0)) then
					table.insert(candidates, entry)
				end
			end
			if #candidates == 0 then
				WindUI:Notify({
					Title = "No servers found",
					Content = "Nothing to hop to — try allowing full servers.",
					Duration = 5,
				})
				return
			end
			local chosen
			if mode == "Highest players" then
				table.sort(candidates, function(a, b)
					return (a.playing or 0) > (b.playing or 0)
				end)
				chosen = candidates[1]
			elseif mode == "Lowest players" then
				table.sort(candidates, function(a, b)
					return (a.playing or 0) < (b.playing or 0)
				end)
				chosen = candidates[1]
			elseif mode == "Random" then
				chosen = candidates[math.random(#candidates)]
			else
				table.sort(candidates, function(a, b)
					return (a.ping or math.huge) < (b.ping or math.huge)
				end)
				chosen = candidates[1]
			end
			local summary = string.format("%d/%d players · %dms ping · chosen from %d servers",
				chosen.playing or 0, chosen.maxPlayers or 0, chosen.ping or 0, #candidates)
			WindUI:Notify({ Title = "Server hopping", Content = summary, Icon = "globe", Duration = 4 })
			TeleportService:TeleportToPlaceInstance(game.PlaceId, chosen.id, player)
		end)
		hopBusy = false
		if not ok then
			WindUI:Notify({ Title = "Server hop failed", Content = tostring(hopError):sub(1, 140), Duration = 5 })
		end
	end)
end

ServerTab:Section({ Title = "Server hopper", Icon = "globe", Opened = true })

-- WindUI's dropdown trigger calls Open on every click instead of toggling,
-- so a second click never closes the list. Wrap Open/Close the same way the
-- old script dropdown was fixed: the trigger now toggles, and picking a
-- value closes the list through the wrapper to keep the state in sync.
local function applyDropdownToggleFix(dropdown)
	local dropdownModule = dropdown and dropdown.DropdownMenu
	local originalOpen = dropdownModule and dropdownModule.Open
	local originalClose = dropdownModule and dropdownModule.Close
	if dropdownModule and type(originalOpen) == "function" and type(originalClose) == "function" then
		local isOpen = false
		local function closeDropdown()
			isOpen = false
			originalClose(dropdownModule)
		end
		local function toggleDropdown()
			if isOpen then
				closeDropdown()
			else
				isOpen = true
				originalOpen(dropdownModule)
			end
		end
		dropdownModule.Open = toggleDropdown
		dropdownModule.Close = closeDropdown
		dropdown.Open = toggleDropdown
		dropdown.Close = closeDropdown
	end
	return dropdown
end

local hopModeDropdown
hopModeDropdown = ServerTab:Dropdown({
	Title = "Hop strategy",
	Desc = "How the next server is chosen.",
	Values = { "Lowest ping", "Highest players", "Lowest players", "Random" },
	Value = SETTINGS.HopMode or "Lowest ping",
	Callback = function(value)
		saveSetting("HopMode", value)
		if hopModeDropdown and hopModeDropdown.Close then
			pcall(function() hopModeDropdown:Close() end)
		end
	end,
})
applyDropdownToggleFix(hopModeDropdown)
ServerTab:Toggle({
	Title = "Exclude full servers",
	Desc = "Never hop into a server that is already at max capacity.",
	Value = SETTINGS.ExcludeFullServers ~= false,
	Callback = function(value)
		saveSetting("ExcludeFullServers", value == true)
	end,
})
ServerTab:Button({
	Title = "Hop now",
	Desc = "Leave this server using the strategy above. The teleport takes a few seconds.",
	Icon = "arrow-right-left",
	Callback = function()
		hopNow()
	end,
})
ServerTab:Button({
	Title = "Rejoin this server",
	Desc = "Teleport straight back into the exact server you are in right now.",
	Icon = "rotate-cw",
	Callback = function()
		if hopBusy then
			WindUI:Notify({ Title = "Already hopping", Content = "A server hop is already in progress.", Duration = 3 })
			return
		end
		if game.JobId == "" then
			WindUI:Notify({ Title = "No server", Content = "You are not in a live server (Studio session).", Duration = 4 })
			return
		end
		hopBusy = true
		task.spawn(function()
			WindUI:Notify({ Title = "Rejoining", Content = "Teleporting back into this server…", Icon = "rotate-cw", Duration = 4 })
			local ok, rejoinError = pcall(function()
				TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, player)
			end)
			hopBusy = false
			if not ok then
				WindUI:Notify({ Title = "Rejoin failed", Content = tostring(rejoinError):sub(1, 140), Duration = 5 })
			end
		end)
	end,
})

-- ---------------------------------------------------------------------------
-- Share: export/import the whole library (custom scripts, pins, preferences)
-- as a single portable code string a friend can paste into their menu.
-- ---------------------------------------------------------------------------
local LIBRARY_CODE_PREFIX = "GHOSTSLIB1:"
local importedLibraryCode = ""

local function buildLibraryPayload()
	local scriptsTable = {}
	for customName in pairs(customSources) do
		scriptsTable[customName] = SOURCES[customName]
	end
	local pinsTable = {}
	for _, scriptName in ipairs(scriptNames) do
		if favoriteSet[scriptName] then
			table.insert(pinsTable, scriptName)
		end
	end
	-- Every persisted preference travels — defaults fill in for anything the
	-- user never changed, and unknown future keys from SETTINGS ride along.
	-- The cache and the built-in scripts never do. CustomSources and Favorites
	-- ride separately as scripts/pins.
	local settingsTable = {}
	for settingKey, defaultValue in pairs(SETTING_DEFAULTS) do
		local value = SETTINGS[settingKey]
		if value == nil then
			value = defaultValue
		end
		settingsTable[settingKey] = value
	end
	for settingKey, settingValue in pairs(SETTINGS) do
		if settingKey ~= "CustomSources" and settingKey ~= "Favorites" and settingsTable[settingKey] == nil then
			settingsTable[settingKey] = settingValue
		end
	end
	return {
		v = 1,
		scripts = scriptsTable,
		pins = pinsTable,
		settings = settingsTable,
	}
end

-- Base64: prefer the executor's own functions (Roblox's HttpService variants
-- are unavailable in some environments), with HttpService as last resort.
local base64Encode, base64Decode
do
	pcall(function()
		local executorEnv = getgenv and getgenv()
		if type(executorEnv) == "table" then
			base64Encode = rawget(executorEnv, "base64encode") or rawget(executorEnv, "base64_encode")
			base64Decode = rawget(executorEnv, "base64decode") or rawget(executorEnv, "base64_decode")
		end
	end)
	if not (base64Encode and base64Decode) then
		pcall(function()
			local cryptEnv = (getgenv and getgenv().crypt) or (type(_G) == "table" and rawget(_G, "crypt"))
			if type(cryptEnv) == "table" then
				base64Encode = base64Encode or rawget(cryptEnv, "base64encode")
				base64Decode = base64Decode or rawget(cryptEnv, "base64decode")
			end
		end)
	end
	if not (base64Encode and base64Decode) then
		base64Encode = base64Encode or function(value) return HttpService:EncodeBase64(value) end
		base64Decode = base64Decode or function(value) return HttpService:DecodeBase64(value) end
	end
end

local function encodeLibraryPayload(payload)
	return LIBRARY_CODE_PREFIX .. base64Encode(HttpService:JSONEncode(payload))
end

local function decodeLibraryPayload(code)
	local cleaned = tostring(code or ""):match("^%s*(.-)%s*$")
	if cleaned:sub(1, #LIBRARY_CODE_PREFIX) ~= LIBRARY_CODE_PREFIX then
		return nil, "that does not look like a Ghost's Scripts library code"
	end
	local decodeOk, json = pcall(function()
		return base64Decode(cleaned:sub(#LIBRARY_CODE_PREFIX + 1))
	end)
	if not decodeOk or type(json) ~= "string" then
		return nil, "the library code is damaged"
	end
	local jsonOk, payload = pcall(function() return HttpService:JSONDecode(json) end)
	if not jsonOk or type(payload) ~= "table" or payload.v ~= 1 or type(payload.scripts) ~= "table" then
		return nil, "the library code is damaged"
	end
	return payload
end

-- Clipboard functions are executor globals; resolve them the lazy way so the
-- analyzer stays clean and a missing clipboard never errors.
local function getClipboardFunction()
	local clipboardFn = nil
	pcall(function()
		local executorEnv = getgenv and getgenv()
		if type(executorEnv) == "table" then
			clipboardFn = rawget(executorEnv, "setclipboard") or rawget(executorEnv, "toclipboard")
		end
		if not clipboardFn and type(_G) == "table" then
			clipboardFn = rawget(_G, "setclipboard") or rawget(_G, "toclipboard")
		end
	end)
	return clipboardFn
end

ShareTab:Section({ Title = "Export", Icon = "upload", Opened = true })
ShareTab:Paragraph({
	Title = "What gets shared",
	Desc = "Every preference (menu shortcut, font, auto-update, hop strategy, guardian — complete, even untouched defaults), plus your custom scripts and pins. The downloaded cache and built-in scripts are never included.",
})
ShareTab:Button({
	Title = "Copy library code",
	Desc = "Copies a portable code string — send it to a friend.",
	Icon = "copy",
	Callback = function()
		local code = encodeLibraryPayload(buildLibraryPayload())
		local clipboardFn = getClipboardFunction()
		local copied = clipboardFn and pcall(clipboardFn, code)
		if copied then
			WindUI:Notify({
				Title = "Library copied",
				Content = "The code is on your clipboard — paste it to a friend.",
				Icon = "copy",
				Duration = 4,
			})
		elseif type(writefile) == "function" then
			pcall(function() writefile("GhostsScripts/library_export.txt", code) end)
			WindUI:Notify({
				Title = "Clipboard unavailable",
				Content = "The code was saved to GhostsScripts/library_export.txt instead.",
				Duration = 5,
			})
		else
			WindUI:Notify({ Title = "Export failed", Content = "No clipboard or file access available.", Duration = 5 })
		end
	end,
})

ShareTab:Section({ Title = "Import", Icon = "download", Opened = true })
ShareTab:Input({
	Title = "Library code",
	Desc = "Paste a code string from a friend here.",
	Placeholder = "GHOSTSLIB1:…",
	Callback = function(value)
		importedLibraryCode = tostring(value or "")
	end,
})
ShareTab:Button({
	Title = "Import library",
	Desc = "Adds the shared scripts, pins and preferences after you confirm.",
	Icon = "check-check",
	Callback = function()
		local payload, decodeError = decodeLibraryPayload(importedLibraryCode)
		if not payload then
			WindUI:Notify({ Title = "Import failed", Content = tostring(decodeError), Duration = 5 })
			return
		end
		local newScripts, skippedCount, newCount = {}, 0, 0
		for importName, importUrl in pairs(payload.scripts) do
			if type(importName) == "string" and #importName > 0
				and type(importUrl) == "string" and importUrl:match("^https?://") then
				if SOURCES[importName] then
					skippedCount += 1
				else
					newScripts[importName] = importUrl
					newCount += 1
				end
			end
		end
		local pinCount = 0
		for _, pinName in ipairs(payload.pins or {}) do
			if SOURCES[pinName] or newScripts[pinName] then
				pinCount += 1
			end
		end
		WindUI:Popup({
			Title = "Import library?",
			Icon = "download",
			Content = "Adds " .. tostring(newCount) .. " new scripts ("
				.. tostring(skippedCount) .. " skipped as duplicates) and applies "
				.. tostring(pinCount) .. " pins plus the shared preferences.",
			Buttons = {
				{ Title = "Cancel", Variant = "Tertiary", Callback = function() end },
				{
					Title = "Import",
					Icon = "check-check",
					Variant = "Primary",
					Callback = function()
						for importName, importUrl in pairs(newScripts) do
							SOURCES[importName] = importUrl
							customSources[importName] = true
							table.insert(scriptNames, importName)
						end
						table.sort(scriptNames, compareNames)
						saveCustomSources()
						local appliedPins = 0
						for _, pinName in ipairs(payload.pins or {}) do
							if SOURCES[pinName] then
								favoriteSet[pinName] = true
								appliedPins += 1
							end
						end
						saveFavorites()
						local imported = payload.settings or {}
						local appliedSettings = 0
						for settingKey, settingValue in pairs(imported) do
							saveSetting(settingKey, settingValue)
							appliedSettings += 1
						end
						-- Sync the live state that persisted keys control.
						if imported.AutoUpdate ~= nil then
							autoUpdate = imported.AutoUpdate == true
						end
						if type(imported.ToggleKey) == "string" and Enum.KeyCode[imported.ToggleKey] then
							pcall(function() Window:SetToggleKey(Enum.KeyCode[imported.ToggleKey]) end)
						end
						if type(imported.FontAsset) == "string" then
							pcall(function() WindUI:SetFont(imported.FontAsset) end)
						end
						if homeRefs.welcome then
							pcall(function()
								homeRefs.welcome:SetDesc("Your client dashboard · " .. tostring(#scriptNames) .. " scripts available.")
							end)
						end
						refreshDownloadSummary()
						rebuildLibraryTabs()
						WindUI:Notify({
							Title = "Library imported",
							Content = tostring(newCount) .. " scripts added · "
								.. tostring(skippedCount) .. " skipped (already exist) · "
								.. tostring(appliedPins) .. " pins · "
								.. tostring(appliedSettings) .. " preferences applied",
							Icon = "check-check",
							Duration = 5,
						})
					end,
				},
			},
		})
	end,
})

SettingsTab:Section({ Title = "Menu shortcut", Icon = "keyboard", Opened = true })
local toggleKeyControl
local function readableKey(name)
	return name:gsub("([a-z])([A-Z])", "%1 %2")
end
toggleKeyControl = SettingsTab:Keybind({
	Title = "Menu shortcut",
	Desc = "Current key: " .. readableKey(savedKey) .. " · click the key chip to change it.",
	Value = savedKey,
	Callback = function(value)
		local keyCode = Enum.KeyCode[value]
		if not keyCode then return end
		savedKey = value
		saveSetting("ToggleKey", value)
		Window:SetToggleKey(keyCode)
		if toggleKeyControl then
			pcall(function()
				toggleKeyControl:SetDesc("Current key: " .. readableKey(value) .. " · click the key chip to change it.")
			end)
		end
	end,
})
SettingsTab:Paragraph({
	Title = "Input",
	Desc = "The mouse cursor is unlocked while this menu is open and restored when it closes.",
})

SettingsTab:Section({ Title = "Appearance", Icon = "type", Opened = true })
local customFontAsset = ""
local customFontInput
customFontInput = SettingsTab:Input({
	Title = "Custom font asset",
	Desc = "Enter a Roblox font family asset ID or rbxassetid:// URL.",
	Placeholder = "rbxassetid://123456789",
	Callback = function(value)
		customFontAsset = tostring(value or "")
	end,
})
local function normalizeFontAsset(value)
	local asset = tostring(value or ""):match("^%s*(.-)%s*$")
	if asset:match("^%d+$") then asset = "rbxassetid://" .. asset end
	if asset:match("^rbxassetid://%d+$") then return asset end
	return nil
end
SettingsTab:Button({
	Title = "Apply custom font",
	Desc = "Use the font asset entered above.",
	Icon = "type",
	Callback = function()
		local fontAsset = normalizeFontAsset(customFontAsset)
		if not fontAsset then
			WindUI:Notify({ Title = "Font asset needed", Content = "Enter a numeric font asset ID or rbxassetid:// URL.", Duration = 4 })
			return
		end
		local ok, err = pcall(function() WindUI:SetFont(fontAsset) end)
		if not ok then
			WindUI:Notify({ Title = "Font could not be applied", Content = tostring(err):sub(1, 140), Duration = 5 })
			return
		end
		savedFontAsset = fontAsset
		saveSetting("FontAsset", fontAsset)
		WindUI:Notify({ Title = "Custom font applied", Content = "The interface font has been updated.", Duration = 3 })
	end,
})
SettingsTab:Button({
	Title = "Use Inter default",
	Desc = "Restore the default Inter font.",
	Icon = "rotate-ccw",
	Callback = function()
		WindUI:SetFont(DEFAULT_FONT_ASSET)
		savedFontAsset = DEFAULT_FONT_ASSET
		pcall(function() customFontInput:Set(DEFAULT_FONT_ASSET) end)
		saveSetting("FontAsset", DEFAULT_FONT_ASSET)
		WindUI:Notify({ Title = "Inter font restored", Content = "The default font is active.", Duration = 3 })
	end,
})

local windowFrame
local resetWindowSize
local centerWindow
SettingsTab:Section({ Title = "Window layout", Icon = "panels-top-left", Opened = true })
SettingsTab:Button({
	Title = "Reset size to default",
	Desc = "Restore the window to 700 × 500.",
	Icon = "rotate-ccw",
	Callback = function()
		if resetWindowSize then resetWindowSize() end
	end,
})
SettingsTab:Button({
	Title = "Center window",
	Desc = "Smoothly move the window back to the middle of the screen.",
	Icon = "move",
	Callback = function()
		if centerWindow then centerWindow() end
	end,
})

local exitScript
SettingsTab:Section({ Title = "Session guardian", Icon = "shield-check", Opened = true })
SettingsTab:Toggle({
	Title = "Anti-AFK",
	Desc = "Silently pulses the controller when you idle so the 20 minute kick never happens.",
	Value = SETTINGS.AntiAFK ~= false,
	Callback = function(value)
		saveSetting("AntiAFK", value == true)
	end,
})
SettingsTab:Toggle({
	Title = "Auto rejoin on disconnect",
	Desc = "When a teleport fails or you get kicked while the client is still alive, rejoin the same place after 3 seconds. A full client crash cannot be caught from inside.",
	Value = SETTINGS.AutoRejoin ~= false,
	Callback = function(value)
		saveSetting("AutoRejoin", value == true)
	end,
})
SettingsTab:Section({ Title = "Session", Icon = "power", Opened = true })
SettingsTab:Button({
	Title = "Exit script",
	Desc = "Fully close Ghost's Scripts and remove its interface.",
	Icon = "log-out",
	Callback = function()
		if exitScript then exitScript() end
	end,
})

local savedMouseState
local MOUSE_FREE_BIND = "GhostScriptsMouseFree"
local mouseGuardBound = false

local function holdMouseFree()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function unlockMouse()
	if not savedMouseState then
		savedMouseState = {
			Behavior = UserInputService.MouseBehavior,
			IconEnabled = UserInputService.MouseIconEnabled,
		}
	end
	holdMouseFree()
	-- First-person games re-lock the cursor on their own: CameraMode
	-- LockFirstPerson, or a zoom of 0.5 in Classic mode, makes the engine put
	-- MouseBehavior back to LockCenter within about a second (measured).
	-- Re-asserting it as the very last render step frees the cursor without
	-- touching the camera, its mode or the zoom range, so the view stays first
	-- person and nothing zooms out.
	if not mouseGuardBound then
		mouseGuardBound = true
		pcall(function()
			RunService:BindToRenderStep(MOUSE_FREE_BIND, Enum.RenderPriority.Last.Value, holdMouseFree)
		end)
	end
end

local function restoreMouse()
	if mouseGuardBound then
		mouseGuardBound = false
		pcall(function() RunService:UnbindFromRenderStep(MOUSE_FREE_BIND) end)
	end
	if not savedMouseState then return end
	UserInputService.MouseBehavior = savedMouseState.Behavior
	UserInputService.MouseIconEnabled = savedMouseState.IconEnabled
	savedMouseState = nil
end

local interfaceConnections = {}
local function disconnectInterfaceConnections()
	for _, connection in ipairs(interfaceConnections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(interfaceConnections)
end

-- While exiting, every mouse click reports KeyCode.Unknown, and WindUI's
-- toggle-key handler treats a matching key as a toggle — which made the
-- half-destroyed window flash open and closed on mouse clicks. Block
-- toggling outright until the interface is fully gone.
local originalWindowToggle = Window.Toggle
Window.Toggle = function(self, ...)
	if isExiting then
		return nil
	end
	return originalWindowToggle(self, ...)
end

local originalWindowDestroy = Window.Destroy
Window.Destroy = function(self)
	if isExiting then
		return originalWindowDestroy(self)
	end

	isExiting = true
	WindUI:Notify({
		Title = "Script exited",
		Content = "Ghost's Scripts is fully closing.",
		Icon = "log-out",
		Duration = 3,
	})
	-- Close() plays the exit animation and returns WindUI's internal destroy
	-- handle. Tearing down through it (instead of calling Window:Destroy()
	-- again) avoids running the whole close sequence twice, which made the
	-- window flash open for a moment before everything was removed.
	local closeHandle = nil
	pcall(function()
		closeHandle = self:Close()
	end)
	-- WindUI destroys its notification container as part of Destroy, so let
	-- the exit toast finish before tearing the interface down.
	task.delay(3.1, function()
		disconnectInterfaceConnections()
		restoreMouse()
		if closeHandle and closeHandle.Destroy then
			pcall(function() closeHandle:Destroy() end)
		else
			pcall(function() originalWindowDestroy(self) end)
		end
	end)
	return nil
end

exitScript = function()
	Window:Destroy()
end

Window:OnOpen(unlockMouse)
Window:OnClose(function()
	restoreMouse()
	if isExiting then return end
	task.delay(0.08, function()
		if isExiting then return end
		WindUI:Notify({
			Title = "Menu minimized",
			Content = "Press " .. readableKey(savedKey) .. " to reopen.",
			Icon = "keyboard",
			Duration = 3,
		})
	end)
end)
Window:OnDestroy(function()
	restoreMouse()
	disconnectInterfaceConnections()
	if not isExiting then
		isExiting = true
		WindUI:Notify({
			Title = "Script exited",
			Content = "Ghost's Scripts was fully closed.",
			Icon = "log-out",
			Duration = 3,
		})
	end
end)
unlockMouse()

-- ---------------------------------------------------------------------------
-- Session guardian: anti-AFK + auto rejoin. Both default ON and are toggleable
-- in Settings; state persists through the settings file. Resolved lazily so a
-- missing VirtualUser never errors.
-- ---------------------------------------------------------------------------
do
	local TeleportService = game:GetService("TeleportService")
	local VirtualUser = nil
	pcall(function()
		local executorEnv = getgenv and getgenv()
		if type(executorEnv) == "table" then
			VirtualUser = rawget(executorEnv, "VirtualUser")
		end
		if not VirtualUser and type(_G) == "table" then
			VirtualUser = rawget(_G, "VirtualUser")
		end
	end)
	local function guardianEnabled(key)
		local value = SETTINGS[key]
		if value == nil then return true end
		return value == true
	end
	if VirtualUser then
		player.Idled:Connect(function()
			if not guardianEnabled("AntiAFK") then return end
			pcall(function()
				VirtualUser:CaptureController()
				VirtualUser:ClickButton2(Vector2.new())
			end)
		end)
	end
	player.OnTeleport:Connect(function(teleportState)
		if teleportState ~= Enum.TeleportState.Failed then return end
		if not guardianEnabled("AutoRejoin") then return end
		task.delay(3, function()
			pcall(function()
				WindUI:Notify({
					Title = "Disconnected",
					Content = "Attempting to rejoin the same place…",
					Icon = "refresh-cw",
					Duration = 4,
				})
			end)
			pcall(function()
				TeleportService:Teleport(game.PlaceId, player)
			end)
		end)
	end)
end

local function findWindowFrame()
	local roots = {
		(gethui and gethui()) or nil,
		player:FindFirstChildOfClass("PlayerGui"),
		game:GetService("CoreGui"),
	}
	local seen = {}
	for _, root in ipairs(roots) do
		if root then
			for _, screen in ipairs(root:GetChildren()) do
				if not seen[screen] and screen:IsA("ScreenGui") and screen.Name == "WindUI" then
					seen[screen] = true
					local windowFolder = screen:FindFirstChild("Window")
					if windowFolder then
						for _, object in ipairs(windowFolder:GetChildren()) do
							if object:IsA("GuiObject") and object.AnchorPoint == Vector2.new(0.5, 0.5)
								and object.AbsoluteSize.X >= 500 and object.AbsoluteSize.Y >= 350 then
								return object
							end
						end
					end
				end
			end
		end
	end
	return nil
end

for _ = 1, 30 do
	windowFrame = findWindowFrame()
	if windowFrame then break end
	task.wait(0.1)
end

local TweenService = game:GetService("TweenService")
local sizeResetTween
local sizeResetCompletedConnection
resetWindowSize = function()
	if sizeResetCompletedConnection then
		sizeResetCompletedConnection:Disconnect()
		sizeResetCompletedConnection = nil
	end
	if sizeResetTween then
		sizeResetTween:Cancel()
		sizeResetTween = nil
	end

	if not windowFrame or not windowFrame.Parent then
		Window:SetSize(DEFAULT_WINDOW_SIZE)
		return
	end

	-- Match the center-window animation, then sync WindUI's stored size once the
	-- visible frame has reached the target so SetSize cannot snap it mid-tween.
	sizeResetTween = TweenService:Create(
		windowFrame,
		TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Size = DEFAULT_WINDOW_SIZE }
	)
	sizeResetCompletedConnection = sizeResetTween.Completed:Connect(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed and windowFrame and windowFrame.Parent then
			Window:SetSize(DEFAULT_WINDOW_SIZE)
		end
	end)
	sizeResetTween:Play()
end

local centerTween
centerWindow = function()
	if not windowFrame or not windowFrame.Parent then return end
	if centerTween then centerTween:Cancel() end
	centerTween = TweenService:Create(
		windowFrame,
		TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.fromScale(0.5, 0.5) }
	)
	centerTween:Play()
end

if windowFrame then
	-- Reuse WindUI's built-in bottom gesture handle. WindUI keeps the native
	-- bottom-right resize grip; the window body remains available for clicks.
	local background = windowFrame:FindFirstChild("Background")
	local bottomLine = background and background:FindFirstChild("ImageLabel")
	local gestureHandle = bottomLine and bottomLine:FindFirstChild("Frame")
	local dragStart, positionStart

	if gestureHandle and gestureHandle:IsA("GuiButton") then
		table.insert(interfaceConnections, gestureHandle.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragStart = input.Position
				positionStart = windowFrame.Position
			end
		end))

		table.insert(interfaceConnections, UserInputService.InputChanged:Connect(function(input)
			if not dragStart or not positionStart then return end
			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
			local delta = input.Position - dragStart
			windowFrame.Position = UDim2.new(
				positionStart.X.Scale, positionStart.X.Offset + delta.X,
				positionStart.Y.Scale, positionStart.Y.Offset + delta.Y
			)
		end))

		table.insert(interfaceConnections, UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragStart, positionStart = nil, nil
			end
		end))
	end
end
-- WindUI exposes tab selection on the tab object itself. Select only after
-- all tab content has been created so startup always lands on a populated Home.
task.defer(function()
	task.wait(0.15)
	pcall(function() HomeTab:Select() end)
end)

-- Refresh the dashboard and the downloads statuses every 5 seconds. Text is
-- only rewritten through SetTitle/SetDesc, so no elements are recreated.
task.spawn(function()
	while not isExiting do
		task.wait(5)
		if isExiting then break end
		refreshHome()
		refreshDownloadSummary()
		for _, scriptName in ipairs(scriptNames) do
			if isExiting then return end
			refreshDownloadRow(scriptName)
			local scriptRow = scriptRows[scriptName]
			if scriptRow and scriptRow.paragraph then
				pcall(function() scriptRow.paragraph:SetDesc(describeStatus(scriptName)) end)
			end
		end
	end
end)

-- Download and cache every source in the background. Downloading does not compile or run it.
task.spawn(function()
	local cachedCount = 0
	local failedScripts = {}
	for _, scriptName in ipairs(scriptNames) do
		if isExiting then return end
		local source = downloadScript(scriptName, false)
		if source then
			cachedCount += 1
		else
			table.insert(failedScripts, scriptName)
		end
	end
	if isExiting then return end
	if #failedScripts == 0 then
		pcall(function()
			WindUI:Notify({
				Title = "Script cache ready",
				Content = "All " .. tostring(cachedCount) .. " sources are downloaded. None have been run.",
				Duration = 4,
			})
		end)
	else
		pcall(function()
			WindUI:Notify({
				Title = "Script cache partially ready",
				Content = tostring(cachedCount) .. "/" .. tostring(#scriptNames)
					.. " downloaded. Run will retry: " .. table.concat(failedScripts, ", "),
				Duration = 5,
			})
		end)
	end
end)

-- ---------------------------------------------------------------------------
-- Sidebar polish: WindUI's tab hover only brightens the tab's background,
-- leaving the icon dim. Tween the icon's transparency and color on hover so
-- it brightens together with the button.
-- ---------------------------------------------------------------------------
task.spawn(function()
	task.wait(1)
	local guiRoot = (gethui and gethui()) or game:GetService("CoreGui")
	local winduiGui = guiRoot and guiRoot:FindFirstChild("WindUI")
	if not winduiGui then return end
	local tabScrollFrame = nil
	for _, label in ipairs(winduiGui:GetDescendants()) do
		if label:IsA("TextLabel") and label.Text == "Home" then
			local tabButton = label.Parent and label.Parent:FindFirstChildOfClass("ImageButton")
			if tabButton and tabButton.Parent and tabButton.Parent.Parent then
				tabScrollFrame = tabButton.Parent.Parent
			end
			break
		end
	end
	if not tabScrollFrame then return end
	for _, tabButton in ipairs(tabScrollFrame:GetChildren()) do
		if tabButton:IsA("ImageButton") then
			local icon = tabButton:FindFirstChildWhichIsA("ImageLabel", true)
			if icon then
				local originalColor = icon.ImageColor3
				local tweenIn = TweenService:Create(icon, TweenInfo.new(0.12), {
					ImageTransparency = 0.05,
					ImageColor3 = Color3.fromRGB(255, 255, 255),
				})
				local tweenOut = TweenService:Create(icon, TweenInfo.new(0.2), {
					ImageTransparency = 0.4,
					ImageColor3 = originalColor,
				})
				tabButton.MouseEnter:Connect(function()
					tweenIn:Play()
				end)
				tabButton.MouseLeave:Connect(function()
					tweenOut:Play()
				end)
			end
		end
	end
end)
