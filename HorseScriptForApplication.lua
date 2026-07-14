-- Connected Discord-GitHub | Roblox username: dragonstarkills
-- handles the race sequence client side: mount cutscene, screen flash transitions,
-- speedline vfx, chase camera, HUD updates and horse outline highlighting

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

local gui = plr.PlayerGui

local letterbox = gui.RaceLetterbox
local barTop = letterbox.TopBar
local barBot = letterbox.BottomBar

local function letterboxToggle(state)
	local sz = state and UDim2.new(1, 0, 0.12, 0) or UDim2.new(1, 0, 0, 0)
	TS:Create(barTop, TweenInfo.new(0.35), {Size = sz}):Play()
	TS:Create(barBot, TweenInfo.new(0.35), {Size = sz}):Play()
end

local flashFrame = gui.RaceFlash.Flash
local fadeTween

local function doFlash(col, a, t)
	if fadeTween then fadeTween:Cancel() end
	flashFrame.BackgroundColor3 = col
	flashFrame.BackgroundTransparency = 1 - a
	fadeTween = TS:Create(flashFrame, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 1})
	fadeTween:Play()
end

local speedHud = gui:FindFirstChild("RaceHud") and gui.RaceHud:FindFirstChild("SpeedLabel")

local function updateSpeedHud(ratio)
	if not speedHud then return end
	local pct = math.floor(ratio * 100)
	speedHud.Text = pct .. "%"

	if pct >= 90 then
		speedHud.TextColor3 = Color3.fromRGB(255, 90, 90)
	elseif pct >= 50 then
		speedHud.TextColor3 = Color3.fromRGB(255, 210, 80)
	else
		speedHud.TextColor3 = Color3.fromRGB(220, 220, 220)
	end
end

local linesRig = RS.Speedlines:Clone()
linesRig.Parent = workspace

local rigIsPart = linesRig:IsA("BasePart")
local linesFX = linesRig.Attachment.ParticleEmitter
linesFX.Enabled = false
linesFX.Rate = 0

local MAXRATE = Config.SPEEDLINE_MAX_RATE
local OFF_WIDE = Config.SPEEDLINE_OFFSET_WIDE
local OFF_NARROW = Config.SPEEDLINE_OFFSET_NARROW
local WIDE_ASPECT = Config.SPEEDLINE_WIDE_ASPECT

local linesHeartbeat

local function placeLines(cf)
	if rigIsPart then
		linesRig.CFrame = cf
	else
		linesRig:PivotTo(cf)
	end
end

-- keeps the rig infront of the cam every frame, offset scales w fov
local function linesTick()
	local vp = cam.ViewportSize
	local ar = vp.X / vp.Y
	local off = ar > WIDE_ASPECT and OFF_WIDE or OFF_NARROW

	placeLines(cam.CFrame * CFrame.new(0, 0, -off / (cam.FieldOfView / 70)))

	local ratio = plr:GetAttribute("RaceSpeedRatio") or 0
	local minR = Config.SPEEDLINE_MIN_RATIO
	local pow = 0

	if ratio > minR then
		pow = math.clamp((ratio - minR) / (1 - minR), 0, 1)
	end

	linesFX.Rate = pow * MAXRATE
	updateSpeedHud(ratio)
end

local function linesOn()
	linesFX.Enabled = true
	linesHeartbeat = RunService.RenderStepped:Connect(linesTick)
end

local function linesOff()
	if linesHeartbeat then
		linesHeartbeat:Disconnect()
		linesHeartbeat = nil
	end
	linesFX.Enabled = false
	linesFX.Rate = 0
end

local activeOutline

local function clearOutline()
	if activeOutline then
		activeOutline:Destroy()
		activeOutline = nil
	end
end

-- adds a highlight (USING NEW INSTANC3 CUZ I HAVE A STUDIO GLITCH AND CANT IMPORT)
local function setOutline(model)
	clearOutline()
	if not model then return end

	local hl = Instance.new("Highlight")
	hl.Name = "horseputputline"
	hl.FillTransparency = 1
	hl.OutlineTransparency = 0
	hl.OutlineColor = Config.HORSE_OUTLINE_COLOR or Color3.fromRGB(255, 210, 80)
	hl.Parent = model

	activeOutline = hl
end

local isRacing = false
local activeHorse
local steer = 0
local heldL, heldR = false, false
local camHeartbeat
local camShakeOffset = Vector3.new()
local shakeTimeLeft = 0

local function horseRoot(m)
	return m.PrimaryPart or m:FindFirstChild(Config.HORSE_ROOT_NAME)
end

-- horse mesh faces backwards so we gotta flip it back to get real heading
local function travelCF(m)
	return horseRoot(m).CFrame * Config.HORSE_FACING_OFFSET
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

-- brief camera shake, used on race start impact
local function triggerCamShake(duration, magnitude)
	shakeTimeLeft = duration
	camShakeOffset = Vector3.new(
		math.random(-100, 100) / 100 * magnitude,
		math.random(-100, 100) / 100 * magnitude,
		0
	)
end

local function updateCamShake(dt)
	if shakeTimeLeft <= 0 then
		camShakeOffset = Vector3.new()
		return Vector3.new()
	end

	shakeTimeLeft -= dt
	local falloff = math.clamp(shakeTimeLeft / Config.CAM_SHAKE_DURATION, 0, 1)
	return camShakeOffset * falloff
end

local BOB_AMP = Config.CAM_BOB_AMPLITUDE
local BOB_FREQ = Config.CAM_BOB_FREQUENCY
local SWAY_AMP = Config.CAM_SWAY_AMPLITUDE
local SWAY_FREQ = Config.CAM_SWAY_FREQUENCY
local SWAY_ROLL = Config.CAM_SWAY_ROLL

-- locks cam behind horse, bob/sway ramps
local function camOn()
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = Config.CAM_FOV

	camHeartbeat = RunService.RenderStepped:Connect(function(dt)
		local tcf = travelCF(activeHorse)

		local ratio = math.clamp(plr:GetAttribute("RaceSpeedRatio") or 0, 0, 1)
		local now = os.clock()

		local bob = math.sin(now * BOB_FREQ) * BOB_AMP * ratio
		local sway = math.sin(now * SWAY_FREQ) * SWAY_AMP * ratio
		local roll = math.sin(now * SWAY_FREQ) * SWAY_ROLL * ratio
		local shake = updateCamShake(dt)

		local behindCF = CFrame.new(
			steer * Config.CAM_STEER_SHIFT + sway + shake.X,
			Config.CAM_HEIGHT + bob + shake.Y,
			Config.CAM_BACK_DISTANCE
		)

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

-- quick pan to the horse before handing off to the chase cam
local function mountCutscene(cb)
	local tcf = travelCF(activeHorse)

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

local function bindCharacter(char)
	if not char then return end

	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Died:Connect(function()
			if isRacing then
				EndRaceRemote:FireServer()
			end
		end)
	end
end

if plr.Character then
	bindCharacter(plr.Character)
end
plr.CharacterAdded:Connect(bindCharacter)

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
	setOutline(horseModel)
	triggerCamShake(Config.CAM_SHAKE_DURATION, Config.CAM_SHAKE_MAGNITUDE)

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
	clearOutline()
end)
