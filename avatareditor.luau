--[[
	Avatar Studio - client-side avatar editor
	* Full catalog + Roblox-recommended outfits (via AvatarEditorService, no HTTP needed)
	* Fresh Avatar, Restore Original, Wardrobe (see/remove what you're wearing)
	* Save / load avatars (executor file system, memory fallback)
	* Settings (top right): change the UI keybind, respawn re-apply, unload
	Everything is client-side: only you see it.
]]

local env = (getgenv and getgenv()) or _G
if env.AvatarStudioUnload then pcall(env.AvatarStudioUnload) end

if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local AES = game:GetService("AvatarEditorService")
local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do task.wait() LocalPlayer = Players.LocalPlayer end

local conns = {}
local function bind(signal, fn)
	local c = signal:Connect(fn)
	conns[#conns + 1] = c
	return c
end

local function enumItem(enum, name)
	local ok, v = pcall(function() return enum[name] end)
	if ok and typeof(v) == "EnumItem" then return v end
	return nil
end

--------------------------------------------------------------------------------
-- Storage / config
--------------------------------------------------------------------------------
local ROOT = "AvatarStudio"
local hasFS = type(writefile) == "function" and type(readfile) == "function"
	and type(isfolder) == "function" and type(makefolder) == "function"
	and type(listfiles) == "function"

if hasFS then
	pcall(function()
		if not isfolder(ROOT) then makefolder(ROOT) end
		if not isfolder(ROOT .. "/saves") then makefolder(ROOT .. "/saves") end
	end)
end
env.AvatarStudioMem = env.AvatarStudioMem or {}

local config = { key = "RightShift", respawn = true }
if hasFS and type(isfile) == "function" then
	pcall(function()
		if isfile(ROOT .. "/config.json") then
			local d = HttpService:JSONDecode(readfile(ROOT .. "/config.json"))
			if type(d.key) == "string" and enumItem(Enum.KeyCode, d.key) then config.key = d.key end
			if type(d.respawn) == "boolean" then config.respawn = d.respawn end
		end
	end)
end
local function saveConfig()
	if hasFS then pcall(writefile, ROOT .. "/config.json", HttpService:JSONEncode(config)) end
end

local function httpJson(url)
	local req = (syn and syn.request) or http_request or request
	if type(req) ~= "function" then return nil end
	local ok, res = pcall(req, { Url = url, Method = "GET" })
	if ok and res and res.Body then
		local ok2, d = pcall(function() return HttpService:JSONDecode(res.Body) end)
		if ok2 then return d end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Avatar data model (HumanoidDescription)
--------------------------------------------------------------------------------
local NUM_PROPS = {
	"Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg",
	"Shirt", "Pants", "GraphicTShirt", "Face",
	"ClimbAnimation", "FallAnimation", "IdleAnimation", "JumpAnimation",
	"RunAnimation", "SwimAnimation", "WalkAnimation", "MoodAnimation",
	"HeightScale", "WidthScale", "DepthScale", "HeadScale", "BodyTypeScale", "ProportionScale",
}
local COLOR_PROPS = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }
-- props that show up in the Wardrobe (ids), in display order
local WARDROBE_PROPS = {
	"Head", "Face", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg",
	"GraphicTShirt", "Shirt", "Pants",
	"IdleAnimation", "WalkAnimation", "RunAnimation", "JumpAnimation",
	"FallAnimation", "ClimbAnimation", "SwimAnimation", "MoodAnimation",
}

-- AvatarAssetType name -> HumanoidDescription property
local PROP_FOR = {
	TShirt = "GraphicTShirt", Shirt = "Shirt", Pants = "Pants", Face = "Face",
	Head = "Head", DynamicHead = "Head", Torso = "Torso",
	LeftArm = "LeftArm", RightArm = "RightArm", LeftLeg = "LeftLeg", RightLeg = "RightLeg",
	ClimbAnimation = "ClimbAnimation", FallAnimation = "FallAnimation", IdleAnimation = "IdleAnimation",
	JumpAnimation = "JumpAnimation", RunAnimation = "RunAnimation", SwimAnimation = "SwimAnimation",
	WalkAnimation = "WalkAnimation", MoodAnimation = "MoodAnimation",
}
-- AvatarAssetType name -> AccessoryType name
local ACC_FOR = {
	Hat = "Hat", HairAccessory = "Hair", FaceAccessory = "Face", NeckAccessory = "Neck",
	ShoulderAccessory = "Shoulder", FrontAccessory = "Front", BackAccessory = "Back",
	WaistAccessory = "Waist", TShirtAccessory = "TShirt", ShirtAccessory = "Shirt",
	PantsAccessory = "Pants", JacketAccessory = "Jacket", SweaterAccessory = "Sweater",
	ShortsAccessory = "Shorts", LeftShoeAccessory = "LeftShoe", RightShoeAccessory = "RightShoe",
	DressSkirtAccessory = "DressSkirt", EyebrowAccessory = "Eyebrow", EyelashAccessory = "Eyelash",
}
local LAYERED = {
	TShirtAccessory = true, ShirtAccessory = true, PantsAccessory = true, JacketAccessory = true,
	SweaterAccessory = true, ShortsAccessory = true, LeftShoeAccessory = true, RightShoeAccessory = true,
	DressSkirtAccessory = true, EyebrowAccessory = true, EyelashAccessory = true,
}

local function readProp(desc, p)
	local ok, v = pcall(function() return desc[p] end)
	if ok then return v end
	return nil
end

local function accList(desc)
	local ok, l = pcall(function() return desc:GetAccessories(true) end)
	if ok and type(l) == "table" then return l end
	return {}
end

local function accTypeName(a)
	if typeof(a.AccessoryType) == "EnumItem" then return a.AccessoryType.Name end
	return tostring(a.AccessoryType)
end

local function serialize(desc)
	local t = { n = {}, c = {}, a = {} }
	for _, p in ipairs(NUM_PROPS) do
		local v = readProp(desc, p)
		if type(v) == "number" then t.n[p] = v end
	end
	for _, p in ipairs(COLOR_PROPS) do
		local v = readProp(desc, p)
		if typeof(v) == "Color3" then t.c[p] = v:ToHex() end
	end
	for _, a in ipairs(accList(desc)) do
		t.a[#t.a + 1] = {
			id = a.AssetId, ty = accTypeName(a), l = a.IsLayered and true or false,
			o = a.Order, p = a.Puffiness,
		}
	end
	return t
end

local function deserialize(t)
	local d = Instance.new("HumanoidDescription")
	for p, v in pairs(t.n or {}) do pcall(function() d[p] = v end) end
	for p, h in pairs(t.c or {}) do pcall(function() d[p] = Color3.fromHex(h) end) end
	local list = {}
	for i, a in ipairs(t.a or {}) do
		local ty = enumItem(Enum.AccessoryType, a.ty)
		if ty then
			local e = { AssetId = a.id, AccessoryType = ty, IsLayered = a.l and true or false }
			if a.l then e.Order = a.o or i e.Puffiness = a.p or 1 end
			list[#list + 1] = e
		end
	end
	pcall(function() d:SetAccessories(list, true) end)
	return d
end

local function blankDesc()
	local d = Instance.new("HumanoidDescription")
	pcall(function()
		d.HeightScale = 1 d.WidthScale = 1 d.DepthScale = 1 d.HeadScale = 1
		d.BodyTypeScale = 0 d.ProportionScale = 0
	end)
	local grey = Color3.fromRGB(163, 162, 165)
	for _, p in ipairs(COLOR_PROPS) do pcall(function() d[p] = grey end) end
	return d
end

local function getHum()
	local c = LocalPlayer.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function captureCurrent()
	local hum = getHum()
	if hum then
		local ok, d = pcall(function() return hum:GetAppliedDescription() end)
		if ok and d then return d end
	end
	local ok, d = pcall(function() return Players:GetHumanoidDescriptionFromUserId(LocalPlayer.UserId) end)
	if ok and d then return d end
	return blankDesc()
end

local State, Original, dirty = nil, nil, false
local function ensureState()
	if State then return end
	State = captureCurrent()
	Original = serialize(State)
end

--------------------------------------------------------------------------------
-- UI helpers + theme
--------------------------------------------------------------------------------
local C = {
	bg = Color3.fromRGB(16, 16, 20),
	panel = Color3.fromRGB(22, 22, 28),
	item = Color3.fromRGB(32, 32, 40),
	itemHover = Color3.fromRGB(42, 42, 52),
	line = Color3.fromRGB(44, 44, 54),
	text = Color3.fromRGB(236, 236, 242),
	muted = Color3.fromRGB(145, 145, 162),
	accent = Color3.fromRGB(104, 110, 255),
	danger = Color3.fromRGB(224, 78, 90),
	dangerDim = Color3.fromRGB(70, 30, 36),
}

local function new(class, props, parent)
	local i = Instance.new(class)
	for k, v in pairs(props) do i[k] = v end
	if parent then i.Parent = parent end
	return i
end
local function corner(inst, r) return new("UICorner", { CornerRadius = UDim.new(0, r or 8) }, inst) end
local function stroke(inst, col, th)
	return new("UIStroke", { Color = col, Thickness = th or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, inst)
end
local function hover(b, base, over)
	bind(b.MouseEnter, function() b.BackgroundColor3 = over end)
	bind(b.MouseLeave, function() b.BackgroundColor3 = base end)
end
local function mkButton(parent, text, pos, size, base, over)
	base = base or C.item
	over = over or C.itemHover
	local b = new("TextButton", {
		Text = text, Position = pos, Size = size, BackgroundColor3 = base, TextColor3 = C.text,
		Font = Enum.Font.GothamMedium, TextSize = 13, AutoButtonColor = false, BorderSizePixel = 0,
	}, parent)
	corner(b, 8)
	hover(b, base, over)
	return b
end
local function mkBox(parent, placeholder, pos, size)
	local t = new("TextBox", {
		Position = pos, Size = size, BackgroundColor3 = C.item, TextColor3 = C.text,
		PlaceholderText = placeholder, PlaceholderColor3 = C.muted, Text = "",
		Font = Enum.Font.Gotham, TextSize = 13, ClearTextOnFocus = false, BorderSizePixel = 0,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, parent)
	corner(t, 8)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, t)
	return t
end

local function guiParent()
	local ok, h = pcall(function() return gethui and gethui() end)
	if ok and h then return h end
	ok, h = pcall(function() return game:GetService("CoreGui") end)
	if ok and h then return h end
	return LocalPlayer:WaitForChild("PlayerGui")
end

local gui = new("ScreenGui", {
	Name = "AvatarStudio", ResetOnSpawn = false, DisplayOrder = 100,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = true,
}, guiParent())

local main = new("Frame", {
	Size = UDim2.fromOffset(780, 500), Position = UDim2.fromScale(0.5, 0.5),
	AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.bg, BorderSizePixel = 0,
	ClipsDescendants = true,
}, gui)
corner(main, 12)
stroke(main, C.line)

-- Toast
local toastLbl = new("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 80, 1, -14),
	AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.fromOffset(0, 0),
	BackgroundColor3 = C.panel, TextColor3 = C.text, Font = Enum.Font.GothamMedium,
	TextSize = 13, Visible = false, ZIndex = 50, BorderSizePixel = 0, Text = "",
}, main)
corner(toastLbl, 8)
stroke(toastLbl, C.line)
new("UIPadding", {
	PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14),
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
}, toastLbl)
local toastId = 0
local function toast(msg, bad)
	toastId = toastId + 1
	local id = toastId
	toastLbl.Text = msg
	toastLbl.TextColor3 = bad and C.danger or C.text
	toastLbl.Visible = true
	task.delay(2.6, function()
		if id == toastId then toastLbl.Visible = false end
	end)
end

-- Top bar
local top = new("Frame", { Size = UDim2.new(1, 0, 0, 42), BackgroundColor3 = C.panel, BorderSizePixel = 0 }, main)
new("Frame", { Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(16, 17), BackgroundColor3 = C.accent, BorderSizePixel = 0 }, top)
corner(top:FindFirstChildOfClass("Frame"), 4)
new("TextLabel", {
	Position = UDim2.fromOffset(32, 0), Size = UDim2.new(0, 220, 1, 0), BackgroundTransparency = 1,
	Text = "Avatar Studio", TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left,
}, top)
local gear = new("TextButton", {
	Size = UDim2.fromOffset(32, 32), Position = UDim2.new(1, -40, 0, 5), BackgroundColor3 = C.panel,
	Text = "\u{2699}", TextColor3 = C.muted, Font = Enum.Font.GothamBold, TextSize = 20,
	AutoButtonColor = false, BorderSizePixel = 0,
}, top)
corner(gear, 8)
hover(gear, C.panel, C.item)

-- Dragging
do
	local dragging, dragStart, startPos = false, nil, nil
	bind(top.InputBegan, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true dragStart = i.Position startPos = main.Position
		end
	end)
	bind(UIS.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	bind(UIS.InputEnded, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

-- Sidebar + page container
local side = new("Frame", {
	Position = UDim2.fromOffset(0, 42), Size = UDim2.new(0, 160, 1, -42),
	BackgroundColor3 = C.panel, BorderSizePixel = 0,
}, main)
local pageHost = new("Frame", {
	Position = UDim2.fromOffset(160, 42), Size = UDim2.new(1, -160, 1, -42),
	BackgroundTransparency = 1,
}, main)

local pages, tabButtons = {}, {}
local function newPage(name)
	local p = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, pageHost)
	pages[name] = p
	return p
end

--------------------------------------------------------------------------------
-- Grid (shared by Catalog / Outfits / Wardrobe)
--------------------------------------------------------------------------------
local grids = {}
local function makeGrid(parent, pos, size)
	local sf = new("ScrollingFrame", {
		Position = pos, Size = size, BackgroundTransparency = 1, BorderSizePixel = 0,
		ScrollBarThickness = 4, ScrollBarImageColor3 = C.muted,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, parent)
	new("UIGridLayout", {
		CellSize = UDim2.fromOffset(112, 150), CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, sf)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, 12), PaddingTop = UDim.new(0, 4),
		PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 10),
	}, sf)
	local status = new("TextLabel", {
		Position = pos, Size = size, BackgroundTransparency = 1, Text = "", TextColor3 = C.muted,
		Font = Enum.Font.GothamMedium, TextSize = 14, Visible = false, TextWrapped = true,
	}, parent)
	local g = { sf = sf, status = status, tiles = {}, count = 0, token = 0, loading = false, pages = nil }
	grids[#grids + 1] = g
	return g
end

local function clearGrid(g)
	for _, c in ipairs(g.sf:GetChildren()) do
		if c:IsA("GuiButton") then c:Destroy() end
	end
	g.tiles = {}
	g.count = 0
	g.pages = nil
	g.sf.CanvasPosition = Vector2.new(0, 0)
end

local function setStatus(g, text)
	g.status.Text = text or ""
	g.status.Visible = text ~= nil and text ~= ""
end

local function makeTile(g, id, name, thumbType, onClick, isBundle)
	g.count = g.count + 1
	local t = new("TextButton", {
		Text = "", AutoButtonColor = false, BackgroundColor3 = C.item, BorderSizePixel = 0,
		LayoutOrder = g.count,
	}, g.sf)
	corner(t, 10)
	local st = stroke(t, C.accent, 2)
	st.Enabled = false
	local img = new("ImageLabel", {
		Size = UDim2.new(1, -12, 0, 100), Position = UDim2.fromOffset(6, 6), BackgroundColor3 = C.bg,
		BorderSizePixel = 0, ScaleType = Enum.ScaleType.Fit,
		Image = string.format("rbxthumb://type=%s&id=%d&w=150&h=150", thumbType, id),
	}, t)
	corner(img, 8)
	new("TextLabel", {
		Position = UDim2.fromOffset(6, 110), Size = UDim2.new(1, -12, 0, 34), BackgroundTransparency = 1,
		Text = name, TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 11, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, t)
	hover(t, C.item, C.itemHover)
	bind(t.MouseButton1Click, onClick)
	g.tiles[#g.tiles + 1] = { id = id, stroke = st, bundle = isBundle }
end

--------------------------------------------------------------------------------
-- Equipping logic
--------------------------------------------------------------------------------
local typeCache = {}
local function assetTypeName(id)
	if typeCache[id] then return typeCache[id] end
	local ok, d = pcall(function() return AES:GetItemDetails(id, Enum.AvatarItemType.Asset) end)
	if not ok or type(d) ~= "table" then return nil end
	local at, name = d.AssetType, nil
	if typeof(at) == "EnumItem" then
		name = at.Name
	elseif type(at) == "number" then
		for _, e in ipairs(Enum.AvatarAssetType:GetEnumItems()) do
			if e.Value == at then name = e.Name break end
		end
	elseif type(at) == "string" then
		name = at:gsub("^Enum%.AvatarAssetType%.", "")
	end
	typeCache[id] = name
	return name
end

-- returns "added" / "removed" / nil (unsupported)
local function toggleAsset(desc, id, typeName, force)
	local prop = PROP_FOR[typeName]
	if prop then
		local cur = readProp(desc, prop)
		if cur == id and not force then
			desc[prop] = 0
			return "removed"
		end
		desc[prop] = id
		return "added"
	end
	local accName = ACC_FOR[typeName]
	if accName then
		local list = accList(desc)
		for i, a in ipairs(list) do
			if a.AssetId == id then
				if force then return "added" end
				table.remove(list, i)
				desc:SetAccessories(list, true)
				return "removed"
			end
		end
		local aty = enumItem(Enum.AccessoryType, accName)
		if not aty then return nil end
		local entry = { AssetId = id, AccessoryType = aty, IsLayered = false }
		if LAYERED[typeName] then
			entry.IsLayered = true
			entry.Puffiness = 1
			for i = #list, 1, -1 do
				if list[i].AccessoryType == aty then table.remove(list, i) end
			end
			local maxOrder = 0
			for _, a in ipairs(list) do
				if a.IsLayered and (a.Order or 0) > maxOrder then maxOrder = a.Order end
			end
			entry.Order = maxOrder + 1
		end
		list[#list + 1] = entry
		desc:SetAccessories(list, true)
		return "added"
	end
	return nil
end

local function applyState()
	local hum = getHum()
	if not hum then toast("No character found", true) return false end
	local ok, err = pcall(function() hum:ApplyDescriptionClientServer(State) end)
	if not ok then ok, err = pcall(function() hum:ApplyDescription(State) end) end
	if not ok then
		toast("Apply failed: " .. string.sub(tostring(err), 1, 70), true)
	end
	return ok
end

local refreshAll
local busy = false
local function edit(fn)
	if busy then toast("Working...") return end
	busy = true
	task.spawn(function()
		local ok, err = pcall(function() ensureState() fn() end)
		if ok then
			dirty = true
			applyState()
			if refreshAll then refreshAll() end
		else
			local msg = tostring(err):gsub("^.-:%d+: ", "")
			toast(string.sub(msg, 1, 80), true)
		end
		busy = false
	end)
end

local function equipAsset(id)
	edit(function()
		local tn = assetTypeName(id)
		if not tn then error("couldn't read that item's type") end
		local r = toggleAsset(State, id, tn, false)
		if not r then error("unsupported item type: " .. tn) end
		toast(r == "added" and "Equipped" or "Removed")
	end)
end

local function bundleItems(id)
	local out = {}
	local ok, d = pcall(function() return AES:GetItemDetails(id, Enum.AvatarItemType.Bundle) end)
	local items = ok and type(d) == "table" and (d.Items or d.items) or nil
	if type(items) == "table" then
		for _, it in ipairs(items) do
			out[#out + 1] = { id = it.Id or it.id, ty = tostring(it.Type or it.type or "") }
		end
	end
	if #out == 0 then
		local j = httpJson("https://catalog.roblox.com/v1/bundles/details?bundleIds=" .. tostring(id))
		local b = type(j) == "table" and j[1] or nil
		if b and type(b.items) == "table" then
			for _, it in ipairs(b.items) do
				out[#out + 1] = { id = it.id, ty = tostring(it.type or "") }
			end
		end
	end
	return out
end

local function equipBundle(id)
	edit(function()
		local items = bundleItems(id)
		if #items == 0 then error("couldn't read that bundle") end
		local outfitId
		for _, it in ipairs(items) do
			if it.ty:lower():find("outfit") then outfitId = it.id break end
		end
		if outfitId then
			State = Players:GetHumanoidDescriptionFromOutfitId(outfitId)
			toast("Outfit applied")
		else
			local n = 0
			for _, it in ipairs(items) do
				local tn = assetTypeName(it.id)
				if tn and toggleAsset(State, it.id, tn, true) then n = n + 1 end
			end
			if n == 0 then error("nothing in that bundle could be equipped") end
			toast("Bundle equipped")
		end
	end)
end

local function copyUser(text)
	text = (text or ""):match("^%s*(.-)%s*$")
	if text == "" then toast("Enter a username or user ID", true) return end
	edit(function()
		local uid = tonumber(text)
		if not uid then uid = Players:GetUserIdFromNameAsync(text) end
		State = Players:GetHumanoidDescriptionFromUserId(uid)
		toast("Avatar copied")
	end)
end

local function loadOutfitId(text)
	local n = tonumber((text or ""):match("^%s*(.-)%s*$"))
	if not n then toast("Enter an outfit ID", true) return end
	edit(function()
		State = Players:GetHumanoidDescriptionFromOutfitId(n)
		toast("Outfit applied")
	end)
end

local function freshAvatar()
	edit(function()
		State = blankDesc()
		-- stop whatever animations are currently playing
		local hum = getHum()
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		if animator then
			for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do pcall(function() tr:Stop(0) end) end
		end
	end)
	-- remove leftovers the description doesn't manage (game-given hats, clothes, etc.)
	task.spawn(function()
		repeat task.wait(0.2) until not busy
		local char = LocalPlayer.Character
		if char then
			for _, c in ipairs(char:GetChildren()) do
				if c:IsA("Accessory") or c:IsA("Clothing") or c:IsA("ShirtGraphic") or c:IsA("CharacterMesh") then
					pcall(function() c:Destroy() end)
				end
			end
		end
		toast("Fresh avatar ready")
	end)
end

local function restoreOriginal()
	edit(function()
		if not Original then error("nothing to restore") end
		State = deserialize(Original)
		toast("Original avatar restored")
	end)
end

--------------------------------------------------------------------------------
-- Catalog search
--------------------------------------------------------------------------------
local SORTS = {
	{ "Relevance", "Relevance" }, { "Best selling", "Bestselling" }, { "Most favorited", "MostFavorited" },
	{ "Newest", "RecentlyCreated" }, { "Price: low", "PriceLowToHigh" }, { "Price: high", "PriceHighToLow" },
}

local function buildParams(cfg)
	local p = CatalogSearchParams.new()
	p.SearchKeyword = cfg.keyword or ""
	if cfg.category then
		local e = enumItem(Enum.CatalogCategoryFilter, cfg.category)
		if e then p.CategoryFilter = e end
	end
	if cfg.assets then
		local l = {}
		for _, n in ipairs(cfg.assets) do
			local e = enumItem(Enum.AvatarAssetType, n)
			if e then l[#l + 1] = e end
		end
		if #l > 0 then p.AssetTypes = l end
	end
	if cfg.bundles then
		local l = {}
		for _, n in ipairs(cfg.bundles) do
			local e = enumItem(Enum.BundleType, n)
			if e then l[#l + 1] = e end
		end
		if #l > 0 then p.BundleTypes = l end
	end
	local s = enumItem(Enum.CatalogSortType, cfg.sort or "Relevance")
	if s then p.SortType = s end
	return p
end

local function fillGrid(g, items)
	for _, it in ipairs(items) do
		local id = tonumber(it.Id)
		if id then
			local isBundle = tostring(it.ItemType):find("Bundle") ~= nil
			makeTile(g, id, tostring(it.Name or "?"), isBundle and "BundleThumbnail" or "Asset", function()
				if isBundle then equipBundle(id) else equipAsset(id) end
			end, isBundle)
		end
	end
end

local checkMore
local function loadMore(g)
	if g.loading or not g.pages or g.pages.IsFinished then return end
	g.loading = true
	local token = g.token
	task.spawn(function()
		local ok = pcall(function() g.pages:AdvanceToNextPageAsync() end)
		if ok and token == g.token then
			local ok2, items = pcall(function() return g.pages:GetCurrentPage() end)
			if ok2 and type(items) == "table" then fillGrid(g, items) refreshAll() end
		end
		g.loading = false
		if token == g.token then checkMore(g) end
	end)
end
checkMore = function(g)
	local sf = g.sf
	if sf.AbsoluteCanvasSize.Y <= sf.AbsoluteWindowSize.Y + 1
		or sf.CanvasPosition.Y + sf.AbsoluteWindowSize.Y > sf.AbsoluteCanvasSize.Y - 320 then
		loadMore(g)
	end
end

local function runSearch(g, cfg)
	g.token = g.token + 1
	local token = g.token
	clearGrid(g)
	setStatus(g, "Loading...")
	task.spawn(function()
		local ok, pg = pcall(function() return AES:SearchCatalog(buildParams(cfg)) end)
		if token ~= g.token then return end
		if not ok then
			setStatus(g, "Catalog request failed:\n" .. string.sub(tostring(pg), 1, 120))
			return
		end
		g.pages = pg
		local ok2, items = pcall(function() return pg:GetCurrentPage() end)
		if not ok2 or type(items) ~= "table" or #items == 0 then
			setStatus(g, "No results")
			return
		end
		setStatus(g, nil)
		fillGrid(g, items)
		refreshAll()
		task.defer(function() if token == g.token then checkMore(g) end end)
	end)
end

local function hookScroll(g)
	bind(g.sf:GetPropertyChangedSignal("CanvasPosition"), function() checkMore(g) end)
end

local function makeChips(parent, pos, size, defs, onPick)
	local sf = new("ScrollingFrame", {
		Position = pos, Size = size, BackgroundTransparency = 1, BorderSizePixel = 0,
		ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.X,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.X,
	}, parent)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center,
	}, sf)
	new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, sf)
	local chips = {}
	local function pick(i)
		for j, c in ipairs(chips) do
			c.BackgroundColor3 = (j == i) and C.accent or C.item
			c.TextColor3 = (j == i) and Color3.new(1, 1, 1) or C.muted
		end
		onPick(defs[i], i)
	end
	for i, d in ipairs(defs) do
		local b = new("TextButton", {
			AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 0, 26), Text = d.name,
			Font = Enum.Font.GothamMedium, TextSize = 12, BackgroundColor3 = C.item,
			TextColor3 = C.muted, AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = i,
		}, sf)
		corner(b, 13)
		new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, b)
		chips[i] = b
		bind(b.MouseButton1Click, function() pick(i) end)
	end
	return pick
end

--------------------------------------------------------------------------------
-- Page: Catalog
--------------------------------------------------------------------------------
local pCatalog = newPage("Catalog")
local CATS = {
	{ name = "All" },
	{ name = "Recommended", category = "Recommended" },
	{ name = "Featured", category = "Featured" },
	{ name = "Limiteds", category = "Collectibles" },
	{ name = "Hats", assets = { "Hat" } },
	{ name = "Hair", assets = { "HairAccessory" } },
	{ name = "Face acc.", assets = { "FaceAccessory" } },
	{ name = "Neck", assets = { "NeckAccessory" } },
	{ name = "Shoulder", assets = { "ShoulderAccessory" } },
	{ name = "Front", assets = { "FrontAccessory" } },
	{ name = "Back", assets = { "BackAccessory" } },
	{ name = "Waist", assets = { "WaistAccessory" } },
	{ name = "T-Shirts", assets = { "TShirt" } },
	{ name = "Shirts", assets = { "Shirt" } },
	{ name = "Pants", assets = { "Pants" } },
	{ name = "Layered tops", assets = { "TShirtAccessory", "ShirtAccessory", "JacketAccessory", "SweaterAccessory" } },
	{ name = "Layered bottoms", assets = { "PantsAccessory", "ShortsAccessory", "DressSkirtAccessory" } },
	{ name = "Shoes", assets = { "LeftShoeAccessory", "RightShoeAccessory" } },
	{ name = "Faces", assets = { "Face" } },
	{ name = "Heads", assets = { "Head", "DynamicHead" } },
	{ name = "Eyebrows", assets = { "EyebrowAccessory" } },
	{ name = "Eyelashes", assets = { "EyelashAccessory" } },
	{ name = "Torsos", assets = { "Torso" } },
	{ name = "Arms & legs", assets = { "LeftArm", "RightArm", "LeftLeg", "RightLeg" } },
	{ name = "Idle", assets = { "IdleAnimation" } },
	{ name = "Walk", assets = { "WalkAnimation" } },
	{ name = "Run", assets = { "RunAnimation" } },
	{ name = "Jump", assets = { "JumpAnimation" } },
	{ name = "Fall", assets = { "FallAnimation" } },
	{ name = "Climb", assets = { "ClimbAnimation" } },
	{ name = "Swim", assets = { "SwimAnimation" } },
	{ name = "Mood", assets = { "MoodAnimation" } },
	{ name = "Bundles", bundles = { "BodyParts", "Animations", "Shoes" } },
}

local cState = { cat = CATS[1], sort = 1 }
local catalogGrid
local searchBox = mkBox(pCatalog, "Search the catalog...", UDim2.fromOffset(12, 10), UDim2.new(1, -240, 0, 34))
local sortBtn = mkButton(pCatalog, "Sort: " .. SORTS[1][1], UDim2.new(1, -218, 0, 10), UDim2.fromOffset(130, 34))
local goBtn = mkButton(pCatalog, "Search", UDim2.new(1, -82, 0, 10), UDim2.fromOffset(70, 34), C.accent, Color3.fromRGB(124, 130, 255))
catalogGrid = makeGrid(pCatalog, UDim2.fromOffset(0, 92), UDim2.new(1, 0, 1, -92))
hookScroll(catalogGrid)

local function doCatalog()
	runSearch(catalogGrid, {
		keyword = searchBox.Text, category = cState.cat.category,
		assets = cState.cat.assets, bundles = cState.cat.bundles, sort = SORTS[cState.sort][2],
	})
end
local pickCat = makeChips(pCatalog, UDim2.fromOffset(0, 52), UDim2.new(1, 0, 0, 34), CATS, function(def)
	cState.cat = def
	doCatalog()
end)
bind(sortBtn.MouseButton1Click, function()
	cState.sort = cState.sort % #SORTS + 1
	sortBtn.Text = "Sort: " .. SORTS[cState.sort][1]
	doCatalog()
end)
bind(goBtn.MouseButton1Click, doCatalog)
bind(searchBox.FocusLost, function(enter) if enter then doCatalog() end end)

--------------------------------------------------------------------------------
-- Page: Outfits
--------------------------------------------------------------------------------
local pOutfits = newPage("Outfits")
local userBox = mkBox(pOutfits, "Username, user ID or outfit ID...", UDim2.fromOffset(12, 10), UDim2.new(1, -248, 0, 34))
local copyBtn = mkButton(pOutfits, "Copy user", UDim2.new(1, -228, 0, 10), UDim2.fromOffset(104, 34))
local idBtn = mkButton(pOutfits, "Outfit ID", UDim2.new(1, -116, 0, 10), UDim2.fromOffset(104, 34))
bind(copyBtn.MouseButton1Click, function() copyUser(userBox.Text) end)
bind(idBtn.MouseButton1Click, function() loadOutfitId(userBox.Text) end)
local outfitGrid = makeGrid(pOutfits, UDim2.fromOffset(0, 92), UDim2.new(1, 0, 1, -92))
hookScroll(outfitGrid)
local OUTFIT_SRC = {
	{ name = "Recommended", cfg = { category = "Recommended", bundles = { "BodyParts" } } },
	{ name = "Featured", cfg = { category = "Featured", bundles = { "BodyParts" } } },
	{ name = "Best selling", cfg = { bundles = { "BodyParts" }, sort = "Bestselling" } },
	{ name = "Newest", cfg = { bundles = { "BodyParts" }, sort = "RecentlyCreated" } },
	{ name = "Most favorited", cfg = { bundles = { "BodyParts" }, sort = "MostFavorited" } },
	{ name = "Animation packs", cfg = { bundles = { "Animations" }, sort = "Bestselling" } },
}
local pickOutfit = makeChips(pOutfits, UDim2.fromOffset(0, 52), UDim2.new(1, 0, 0, 34), OUTFIT_SRC, function(def)
	runSearch(outfitGrid, def.cfg)
end)

--------------------------------------------------------------------------------
-- Page: Wardrobe (what you're wearing)
--------------------------------------------------------------------------------
local pWardrobe = newPage("Wardrobe")
new("TextLabel", {
	Position = UDim2.fromOffset(12, 10), Size = UDim2.new(1, -24, 0, 34), BackgroundTransparency = 1,
	Text = "Currently equipped. Click an item to remove it.", TextColor3 = C.muted,
	Font = Enum.Font.GothamMedium, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
}, pWardrobe)
local wardrobeGrid = makeGrid(pWardrobe, UDim2.fromOffset(0, 52), UDim2.new(1, 0, 1, -52))

local function equippedList()
	local list = {}
	if not State then return list end
	for _, p in ipairs(WARDROBE_PROPS) do
		local v = readProp(State, p)
		if type(v) == "number" and v ~= 0 then list[#list + 1] = { kind = "prop", slot = p, id = v } end
	end
	for _, a in ipairs(accList(State)) do
		list[#list + 1] = { kind = "acc", slot = accTypeName(a), id = a.AssetId }
	end
	return list
end

local function removeEquipped(e)
	edit(function()
		if e.kind == "prop" then
			State[e.slot] = 0
		else
			local list = accList(State)
			for i, a in ipairs(list) do
				if a.AssetId == e.id then table.remove(list, i) break end
			end
			State:SetAccessories(list, true)
		end
		toast("Removed")
	end)
end

local function rebuildWardrobe()
	clearGrid(wardrobeGrid)
	local list = equippedList()
	if #list == 0 then setStatus(wardrobeGrid, "Nothing equipped") return end
	setStatus(wardrobeGrid, nil)
	for _, e in ipairs(list) do
		makeTile(wardrobeGrid, e.id, e.slot, "Asset", function() removeEquipped(e) end, false)
	end
end

--------------------------------------------------------------------------------
-- Page: Saved avatars
--------------------------------------------------------------------------------
local pSaves = newPage("Saved")
local nameBox = mkBox(pSaves, "Name this avatar...", UDim2.fromOffset(12, 10), UDim2.new(1, -112, 0, 34))
local saveBtn = mkButton(pSaves, "Save", UDim2.new(1, -92, 0, 10), UDim2.fromOffset(80, 34), C.accent, Color3.fromRGB(124, 130, 255))
new("TextLabel", {
	Position = UDim2.fromOffset(12, 50), Size = UDim2.new(1, -24, 0, 18), BackgroundTransparency = 1,
	Text = hasFS and "Saved to your executor's workspace folder: AvatarStudio/saves"
		or "Your executor has no file access: saves last until you rejoin or unload.",
	TextColor3 = C.muted, Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
}, pSaves)
local saveList = new("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 76), Size = UDim2.new(1, 0, 1, -76), BackgroundTransparency = 1,
	BorderSizePixel = 0, ScrollBarThickness = 4, ScrollBarImageColor3 = C.muted,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, pSaves)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, saveList)
new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingBottom = UDim.new(0, 10) }, saveList)

local function cleanName(s)
	local c = (s or ""):gsub("[^%w _%-]", "")
	return c:match("^%s*(.-)%s*$")
end
local function listSaves()
	local out = {}
	if hasFS then
		local ok, files = pcall(listfiles, ROOT .. "/saves")
		if ok and type(files) == "table" then
			for _, f in ipairs(files) do
				local n = tostring(f):match("([^/\\]+)%.json$")
				if n then out[#out + 1] = n end
			end
		end
	else
		for n in pairs(env.AvatarStudioMem) do out[#out + 1] = n end
	end
	table.sort(out, function(a, b) return a:lower() < b:lower() end)
	return out
end
local function readSave(name)
	local json
	if hasFS then
		local ok, r = pcall(readfile, ROOT .. "/saves/" .. name .. ".json")
		if ok then json = r end
	else
		json = env.AvatarStudioMem[name]
	end
	if not json then return nil end
	local ok, t = pcall(function() return HttpService:JSONDecode(json) end)
	if ok and type(t) == "table" then return t end
	return nil
end

local rebuildSaves
local function deleteSave(name)
	if hasFS then
		if type(delfile) == "function" then pcall(delfile, ROOT .. "/saves/" .. name .. ".json") end
	else
		env.AvatarStudioMem[name] = nil
	end
	rebuildSaves()
end

rebuildSaves = function()
	for _, c in ipairs(saveList:GetChildren()) do
		if c:IsA("Frame") then c:Destroy() end
	end
	local names = listSaves()
	for i, name in ipairs(names) do
		local row = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = C.item, BorderSizePixel = 0, LayoutOrder = i }, saveList)
		corner(row, 8)
		new("TextLabel", {
			Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -170, 1, 0), BackgroundTransparency = 1,
			Text = name, TextColor3 = C.text, Font = Enum.Font.GothamMedium, TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		}, row)
		local load = mkButton(row, "Load", UDim2.new(1, -150, 0, 6), UDim2.fromOffset(70, 28), C.accent, Color3.fromRGB(124, 130, 255))
		local del = mkButton(row, "Delete", UDim2.new(1, -74, 0, 6), UDim2.fromOffset(66, 28), C.dangerDim, C.danger)
		bind(load.MouseButton1Click, function()
			edit(function()
				local t = readSave(name)
				if not t then error("couldn't read that save") end
				State = deserialize(t)
				toast("Loaded \"" .. name .. "\"")
			end)
		end)
		bind(del.MouseButton1Click, function() deleteSave(name) end)
	end
	if #names == 0 then
		new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundTransparency = 1, LayoutOrder = 1 }, saveList)
	end
end

local function doSave()
	local name = cleanName(nameBox.Text)
	if name == "" then toast("Give it a name first", true) return end
	task.spawn(function()
		ensureState()
		local json = HttpService:JSONEncode(serialize(State))
		if hasFS then
			local ok, err = pcall(writefile, ROOT .. "/saves/" .. name .. ".json", json)
			if not ok then toast("Save failed: " .. string.sub(tostring(err), 1, 60), true) return end
		else
			env.AvatarStudioMem[name] = json
		end
		nameBox.Text = ""
		toast("Saved \"" .. name .. "\"")
		rebuildSaves()
	end)
end
bind(saveBtn.MouseButton1Click, doSave)
bind(nameBox.FocusLost, function(enter) if enter then doSave() end end)

--------------------------------------------------------------------------------
-- Sidebar: tabs + actions
--------------------------------------------------------------------------------
local TABS = { "Catalog", "Outfits", "Wardrobe", "Saved" }
local outfitsLoaded = false
local function showTab(name)
	for n, p in pairs(pages) do p.Visible = (n == name) end
	for n, b in pairs(tabButtons) do
		b.BackgroundColor3 = (n == name) and C.item or C.panel
		b.TextColor3 = (n == name) and C.text or C.muted
	end
	if name == "Outfits" and not outfitsLoaded then
		outfitsLoaded = true
		pickOutfit(1)
	elseif name == "Wardrobe" then
		task.spawn(function() ensureState() rebuildWardrobe() end)
	elseif name == "Saved" then
		rebuildSaves()
	end
end
for i, name in ipairs(TABS) do
	local b = mkButton(side, name, UDim2.fromOffset(12, 12 + (i - 1) * 40), UDim2.new(1, -24, 0, 34), C.panel, C.item)
	b.TextXAlignment = Enum.TextXAlignment.Left
	new("UIPadding", { PaddingLeft = UDim.new(0, 12) }, b)
	b.TextColor3 = C.muted
	tabButtons[name] = b
	bind(b.MouseButton1Click, function() showTab(name) end)
end

local restoreBtn = mkButton(side, "Restore Original", UDim2.new(0, 12, 1, -52), UDim2.new(1, -24, 0, 36))
bind(restoreBtn.MouseButton1Click, restoreOriginal)
local freshBtn = mkButton(side, "Fresh Avatar", UDim2.new(0, 12, 1, -96), UDim2.new(1, -24, 0, 36), C.dangerDim, C.danger)
local freshArmed = 0
bind(freshBtn.MouseButton1Click, function()
	if freshArmed > 0 then
		freshArmed = 0
		freshBtn.Text = "Fresh Avatar"
		freshAvatar()
		return
	end
	freshArmed = 1
	freshBtn.Text = "Click again to confirm"
	task.delay(3, function()
		if freshArmed == 1 then freshArmed = 0 freshBtn.Text = "Fresh Avatar" end
	end)
end)

--------------------------------------------------------------------------------
-- Highlights / refresh
--------------------------------------------------------------------------------
refreshAll = function()
	local set = {}
	for _, e in ipairs(equippedList()) do set[e.id] = true end
	for _, g in ipairs({ catalogGrid, outfitGrid }) do
		for _, t in ipairs(g.tiles) do
			if t.stroke and t.stroke.Parent then t.stroke.Enabled = (not t.bundle) and set[t.id] == true end
		end
	end
	if pages.Wardrobe.Visible then rebuildWardrobe() end
end

--------------------------------------------------------------------------------
-- Settings popup (keybind, respawn re-apply, unload)
--------------------------------------------------------------------------------
local pop = new("Frame", {
	Position = UDim2.new(1, -276, 0, 48), Size = UDim2.fromOffset(264, 176),
	BackgroundColor3 = C.panel, Visible = false, ZIndex = 30, BorderSizePixel = 0,
}, main)
corner(pop, 10)
stroke(pop, C.line)
local function popLabel(text, y)
	return new("TextLabel", {
		Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 20), BackgroundTransparency = 1,
		Text = text, TextColor3 = C.muted, Font = Enum.Font.GothamMedium, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 31,
	}, pop)
end
popLabel("UI keybind", 12)
local keyBtn = mkButton(pop, config.key, UDim2.fromOffset(14, 34), UDim2.new(1, -28, 0, 32))
keyBtn.ZIndex = 31
popLabel("Re-apply avatar after respawn", 76)
local respawnBtn = mkButton(pop, config.respawn and "On" or "Off", UDim2.fromOffset(14, 98), UDim2.new(1, -28, 0, 32))
respawnBtn.ZIndex = 31
local unloadBtn = mkButton(pop, "Unload Avatar Studio", UDim2.new(0, 14, 1, -42), UDim2.new(1, -28, 0, 32), C.dangerDim, C.danger)
unloadBtn.ZIndex = 31

local capturing = false
bind(gear.MouseButton1Click, function() pop.Visible = not pop.Visible end)
bind(keyBtn.MouseButton1Click, function()
	capturing = true
	keyBtn.Text = "Press a key... (Esc to cancel)"
end)
bind(respawnBtn.MouseButton1Click, function()
	config.respawn = not config.respawn
	respawnBtn.Text = config.respawn and "On" or "Off"
	saveConfig()
end)

local function unload()
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	pcall(function() gui:Destroy() end)
	env.AvatarStudioUnload = nil
end
env.AvatarStudioUnload = unload
bind(unloadBtn.MouseButton1Click, unload)

bind(UIS.InputBegan, function(input)
	if capturing then
		if input.UserInputType == Enum.UserInputType.Keyboard then
			if input.KeyCode ~= Enum.KeyCode.Escape then
				config.key = input.KeyCode.Name
				saveConfig()
				toast("Keybind set to " .. config.key)
			end
			keyBtn.Text = config.key
			capturing = false
		end
		return
	end
	if UIS:GetFocusedTextBox() then return end
	if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode.Name == config.key then
		main.Visible = not main.Visible
		if not main.Visible then pop.Visible = false end
	end
end)

--------------------------------------------------------------------------------
-- Respawn handling
--------------------------------------------------------------------------------
bind(LocalPlayer.CharacterAdded, function(char)
	if not (config.respawn and dirty and State) then return end
	char:WaitForChild("Humanoid", 10)
	task.wait(0.6)
	if busy then return end
	busy = true
	task.spawn(function()
		applyState()
		busy = false
	end)
end)

--------------------------------------------------------------------------------
-- Go
--------------------------------------------------------------------------------
showTab("Catalog")
pickCat(1)
task.spawn(function() ensureState() end)
toast("Avatar Studio loaded - " .. config.key .. " toggles the UI")
