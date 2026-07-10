local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TS = game:GetService("TweenService")

local plr = Players.LocalPlayer
local cam = workspace.CurrentCamera

local Config = require(RS:WaitForChild("RaceSystem"):WaitForChild("RaceConfig"))

local Remotes = RS:WaitForChild("RaceRemotes")
local SteerRemote = Remotes:WaitForChild("Steer")
local EndRaceRemote = Remotes:WaitForChild("EndRace")
local RaceStarted = Remotes:WaitForChild("RaceStarted")
local RaceEnded = Remotes:WaitForChild("RaceEnded")

local gui = plr:WaitForChild("PlayerGui")

local letterbox = gui:WaitForChild("RaceLetterbox")
local barTop = letterbox:WaitForChild("TopBar")
local barBot = letterbox:WaitForChild("BottomBar")

local function letterboxToggle(state)
	local sz = state and UDim2.new(1, 0, 0.12, 0) or UDim2.new(1, 0, 0, 0)
	TS:Create(barTop, TweenInfo.new(0.35), {Size = sz}):Play()
	TS:Create(barBot, TweenInfo.new(0.35), {Size = sz}):Play()
end

local flashGui = gui:WaitForChild("RaceFlash")
local flashFrame = flashGui:WaitForChild("Flash")
local fadeTween = nil

local function doFlash(col, a, t)
	if fadeTween then fadeTween:Cancel() end
	flashFrame.BackgroundColor3 = col
	flashFrame.BackgroundTransparency = 1 - a
	fadeTween = TS:Create(flashFrame, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 1})
	fadeTween:Play()
end

local linesTemplate = RS:WaitForChild("Speedlines")
local linesRig = linesTemplate:Clone()
linesRig.Parent = workspace

local rigIsPart = linesRig:IsA("BasePart")

if rigIsPart then
	linesRig.Anchored = true
	linesRig.CanCollide = false
	linesRig.CanQuery = false
	linesRig.Transparency = 1
elseif linesRig:IsA("Model") then
	if not linesRig.PrimaryPart then
		linesRig.PrimaryPart = linesRig:FindFirstChildWhichIsA("BasePart", true)
	end
	for _, p in ipairs(linesRig:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.Transparency = 1
		end
	end
end

local linesAttach = linesRig:FindFirstChild("Attachment", true)
local linesFX = linesAttach and linesAttach:FindFirstChild("ParticleEmitter")

if linesFX then
	linesFX.Enabled = false
	linesFX.Rate = 0
end

local MAXRATE = Config.SPEEDLINE_MAX_RATE or 1500
local OFF_WIDE = Config.SPEEDLINE_OFFSET_WIDE or 10
local OFF_NARROW = Config.SPEEDLINE_OFFSET_NARROW or 13
local WIDE_ASPECT = Config.SPEEDLINE_WIDE_ASPECT or 1.5

local linesHeartbeat

local function placeLines(cf)
	if rigIsPart then
		linesRig.CFrame = cf
	else
		linesRig:PivotTo(cf)
	end
end

local function linesTick()
	local vp = cam.ViewportSize
	local ar = vp.X / math.max(vp.Y, 1)
	local off = ar > WIDE_ASPECT and OFF_WIDE or OFF_NARROW

	placeLines(cam.CFrame * CFrame.new(0, 0, -off / (cam.FieldOfView / 70)))

	if not linesFX then return end

	local ratio = plr:GetAttribute("RaceSpeedRatio") or 0
	local minR = Config.SPEEDLINE_MIN_RATIO
	local pow = 0

	if ratio > minR then
		pow = math.clamp((ratio - minR) / math.max(0.0001, 1 - minR), 0, 1)
	end

	linesFX.Rate = pow * MAXRATE
end

local function linesOn()
	if linesFX then linesFX.Enabled = true end
	if not linesHeartbeat then
		linesHeartbeat = RunService.RenderStepped:Connect(linesTick)
	end
end

local function linesOff()
	if linesHeartbeat then
		linesHeartbeat:Disconnect()
		linesHeartbeat = nil
	end
	if linesFX then
		linesFX.Enabled = false
		linesFX.Rate = 0
	end
end

local function getOutline(char)
	return char:WaitForChild("RaceOutlineHighlight")
end

if plr.Character then
	getOutline(plr.Character)
end
plr.CharacterAdded:Connect(getOutline)

local isRacing = false
local activeHorse
local steer = 0
local heldL, heldR = false, false
local camHeartbeat

local function horseRoot(m)
	if not m then return nil end
	return m.PrimaryPart or m:FindFirstChild(Config.HORSE_ROOT_NAME)
end

local function travelCF(m)
	local root = horseRoot(m)
	if not root then return nil end
	return root.CFrame * Config.HORSE_FACING_OFFSET
end

local function pushSteer(v)
	if v == steer then return end
	steer = v
	SteerRemote:FireServer(steer)
end

local function recalcSteer()
	local v = 0
	if heldR then v += 1 end
	if heldL then v -= 1 end
	pushSteer(v)
end

local BOB_AMP = Config.CAM_BOB_AMPLITUDE or 0.18
local BOB_FREQ = Config.CAM_BOB_FREQUENCY or 8
local SWAY_AMP = Config.CAM_SWAY_AMPLITUDE or 0.12
local SWAY_FREQ = Config.CAM_SWAY_FREQUENCY or 3
local SWAY_ROLL = Config.CAM_SWAY_ROLL or 1.2

local function camOn()
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = Config.CAM_FOV

	camHeartbeat = RunService.RenderStepped:Connect(function()
		local tcf = travelCF(activeHorse)
		if not tcf then return end

		local ratio = math.clamp(plr:GetAttribute("RaceSpeedRatio") or 0, 0, 1)
		local now = os.clock()

		local bob = math.sin(now * BOB_FREQ) * BOB_AMP * ratio
		local sway = math.sin(now * SWAY_FREQ) * SWAY_AMP * ratio
		local roll = math.sin(now * SWAY_FREQ) * SWAY_ROLL * ratio

		local behindCF = CFrame.new(steer * Config.CAM_STEER_SHIFT + sway, Config.CAM_HEIGHT + bob, Config.CAM_BACK_DISTANCE)

		local targetPos = (tcf * behindCF).Position
		local lookPos = tcf.Position + Vector3.new(0, Config.CAM_HEIGHT * 0.4, 0)

		local goalCF = CFrame.new(targetPos, lookPos) * CFrame.Angles(0, 0, math.rad(-steer * Config.CAM_STEER_TILT - roll))

		cam.CFrame = cam.CFrame:Lerp(goalCF, Config.CAM_LERP_ALPHA)
	end)
end

local function camOff()
	if camHeartbeat then
		camHeartbeat:Disconnect()
		camHeartbeat = nil
	end
	cam.CameraType = Enum.CameraType.Custom
	cam.FieldOfView = Config.CAM_DEFAULT_FOV
end

local function mountCutscene(cb)
	local tcf = travelCF(activeHorse)
	if not tcf then
		cb()
		return
	end

	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = Config.CUTSCENE_FOV
	letterboxToggle(true)

	cam.CFrame = tcf * CFrame.new(8, 5, 8) * CFrame.Angles(0, math.rad(135), 0)

	task.delay(Config.CUTSCENE_DURATION, function()
		if not isRacing then return end
		letterboxToggle(false)
		cb()
	end)
end

UIS.InputBegan:Connect(function(inp, sunk)
	if sunk then return end
	local k = inp.KeyCode

	if k == Enum.KeyCode.A or k == Enum.KeyCode.Left then
		heldL = true
		recalcSteer()
	elseif k == Enum.KeyCode.D or k == Enum.KeyCode.Right then
		heldR = true
		recalcSteer()
	elseif k == Enum.KeyCode.E and isRacing then
		EndRaceRemote:FireServer()
	end
end)

UIS.InputEnded:Connect(function(inp)
	local k = inp.KeyCode
	if k == Enum.KeyCode.A or k == Enum.KeyCode.Left then
		heldL = false
		recalcSteer()
	elseif k == Enum.KeyCode.D or k == Enum.KeyCode.Right then
		heldR = false
		recalcSteer()
	end
end)

RaceStarted.OnClientEvent:Connect(function(horseModel)
	activeHorse = horseModel
	isRacing = true
	heldL, heldR, steer = false, false, 0

	doFlash(Config.SCREEN_FLASH_COLOR, Config.START_FLASH_ALPHA, Config.START_FLASH_FADE_TIME)
	linesOn()

	mountCutscene(function()
		camOn()
	end)
end)

RaceEnded.OnClientEvent:Connect(function()
	isRacing = false
	activeHorse = nil
	heldL, heldR, steer = false, false, 0

	letterboxToggle(false)
	doFlash(Config.SCREEN_FLASH_COLOR, Config.RESPAWN_FLASH_ALPHA, Config.RESPAWN_FLASH_FADE_TIME)
	camOff()
	linesOff()
end)
