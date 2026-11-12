local SRC = [=====[
local env = (getgenv and getgenv()) or _G
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local player = Players.LocalPlayer

local ASSET_ID = 139607718
local Y_OFFSET_IDLE = 0.2   -- studs; height when standing still
local Y_OFFSET_MOVING = 0.5 -- studs; height while walking/running
local KILL_KEY = Enum.KeyCode.F6

-- Auto-run handling: a manual run clears the disabled flag,
-- a run queued from a previous game exits if you killed it with F6.
if env.KorbloxAuto then
	env.KorbloxAuto = nil
	if env.KorbloxDisabled then return end
else
	env.KorbloxDisabled = false
end

-- Remove any previous instance so runs never stack
if env.KorbloxUnload then pcall(env.KorbloxUnload) end

local cleanups = {}
local function track(f) table.insert(cleanups, f) end
local unloaded = false

local function unload(disable)
	if unloaded then return end
	unloaded = true
	if disable then env.KorbloxDisabled = true end
	for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
	if env.KorbloxUnload == env.KorbloxUnloadSelf then env.KorbloxUnload = nil end
end
env.KorbloxUnloadSelf = function() unload(false) end
env.KorbloxUnload = env.KorbloxUnloadSelf

-- Re-run automatically after teleporting to another game
local q = queue_on_teleport
	or (syn and syn.queue_on_teleport)
	or (fluxus and fluxus.queue_on_teleport)
if q then
	q("local e=(getgenv and getgenv()) or _G e.KorbloxAuto=true e.KorbloxSource="
		.. string.format("%q", env.KorbloxSource)
		.. " loadstring(e.KorbloxSource)()")
else
	warn("queue_on_teleport not supported by this executor; auto-execute is off.")
end

-- Kill switch
local inputConn = UIS.InputBegan:Connect(function(input)
	if input.KeyCode == KILL_KEY then
		unload(true)
		print("Korblox/Headless unloaded. Auto-execute disabled until you run it manually again.")
	end
end)
track(function() inputConn:Disconnect() end)

-- Load the asset and grab the three leg pieces
local pieces = {}
local ok, objs = pcall(function()
	return game:GetObjects("rbxassetid://" .. ASSET_ID)
end)

if not ok or not objs then
	warn("GetObjects failed: " .. tostring(objs))
	unload(false)
	return
end

for _, obj in ipairs(objs) do
	local list = { obj }
	for _, d in ipairs(obj:GetDescendants()) do table.insert(list, d) end
	for _, d in ipairs(list) do
		if d:IsA("MeshPart") and (d.Name == "RightUpperLeg" or d.Name == "RightLowerLeg" or d.Name == "RightFoot") then
			pieces[d.Name] = d
		end
	end
end

if not (pieces.RightUpperLeg and pieces.RightLowerLeg and pieces.RightFoot) then
	warn("Missing one of the three leg parts.")
	unload(false)
	return
end

local function applyR6(char)
	local leg = char:WaitForChild("Right Leg", 10)
	local hum = char:WaitForChild("Humanoid", 10)
	if not leg or not hum or unloaded then return end

	local oldTransparency = leg.Transparency
	track(function() leg.Transparency = oldTransparency end)
	leg.Transparency = 1

	local order = { pieces.RightUpperLeg, pieces.RightLowerLeg, pieces.RightFoot }
	local total = 0
	for _, p in ipairs(order) do total += p.Size.Y end
	local factor = 2 / total

	local clones = {}
	local y = 1
	for _, p in ipairs(order) do
		local c = p:Clone()
		c.Size = p.Size * factor
		c.Anchored = true
		c.CanCollide = false
		c.CanQuery = false
		c.CanTouch = false
		c.Massless = true
		c.Parent = char
		track(function() c:Destroy() end)
		table.insert(clones, { part = c, offset = CFrame.new(0, y - c.Size.Y / 2, 0) })
		y -= c.Size.Y
	end

	local lift = Y_OFFSET_IDLE
	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		if not leg.Parent then
			conn:Disconnect()
			return
		end
		leg.Transparency = 1
		local target = (hum.MoveDirection.Magnitude > 0.1) and Y_OFFSET_MOVING or Y_OFFSET_IDLE
		lift += (target - lift) * math.min(1, dt * 12)
		for _, e in ipairs(clones) do
			e.part.CFrame = (leg.CFrame * e.offset) + Vector3.new(0, lift, 0)
		end
	end)
	track(function() conn:Disconnect() end)
end

local function applyR15(char)
	for name, src in pairs(pieces) do
		local part = char:WaitForChild(name, 10)
		if part and not unloaded then
			local oldMesh, oldTex = part.MeshId, part.TextureID
			track(function()
				part.MeshId = oldMesh
				part.TextureID = oldTex
			end)
			part.MeshId = src.MeshId
			part.TextureID = src.TextureID
		end
	end
end

local function apply(char)
	local head = char:WaitForChild("Head", 10)
	if head and not unloaded then
		local oldT = head.Transparency
		local decals = {}
		for _, v in ipairs(head:GetChildren()) do
			if v:IsA("Decal") then
				decals[v] = v.Transparency
				v.Transparency = 1
			end
		end
		head.Transparency = 1
		track(function()
			head.Transparency = oldT
			for d, t in pairs(decals) do d.Transparency = t end
		end)
	end

	if unloaded then return end
	if char:FindFirstChild("Right Leg") then
		applyR6(char)
	elseif char:FindFirstChild("RightUpperLeg") then
		applyR15(char)
	else
		warn("Unrecognized rig.")
	end
end

if player.Character then task.spawn(apply, player.Character) end
local charConn = player.CharacterAdded:Connect(function(c) task.spawn(apply, c) end)
track(function() charConn:Disconnect() end)
]=====]

local env = (getgenv and getgenv()) or _G
env.KorbloxSource = SRC
loadstring(SRC)()