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

-- using scale (0.12) not offset for the bar height so it stays scaled
-- no matter what resolution the screen is (my properties bar wont open)
local function letterboxToggle(state)
	local sz = state and UDim2.new(1, 0, 0.12, 0) or UDim2.new(1, 0, 0, 0)
	TS:Create(barTop, TweenInfo.new(0.35), {Size = sz}):Play()
	TS:Create(barBot, TweenInfo.new(0.35), {Size = sz}):Play()
end

local flashFrame = gui.RaceFlash.Flash
local fadeTween

-- tween function just do do a lil flash 
local function doFlash(col, a, t)
	if fadeTween then fadeTween:Cancel() end
	flashFrame.BackgroundColor3 = col
	flashFrame.BackgroundTransparency = 1 - a
	fadeTween = TS:Create(flashFrame, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 1})
	fadeTween:Play()
end
-- finds the hud for the race 
 :FindFirstChild("RaceHud") and gui.RaceHud:FindFirstChild("SpeedLabel")

-- 3 colour tiers based on % so its readable at a glance instead of havin to actually see it so like when low speed test colour changes
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

-- this is a line script for a quick vfx in the screen like wind vfx 
local linesRig = RS.Speedlines:Clone()
linesRig.Parent = workspace

-- checkin this once up front so linesTick and are enabled i dont enable them rn cuz it lag me 
local rigIsPart = linesRig:IsA("BasePart")
local linesFX = linesRig.Attachment.ParticleEmitter
linesFX.Enabled = false
linesFX.Rate = 0

local MAXRATE = Config.SPEEDLINE_MAX_RATE
local OFF_WIDE = Config.SPEEDLINE_OFFSET_WIDE
local OFF_NARROW = Config.SPEEDLINE_OFFSET_NARROW
local WIDE_ASPECT = Config.SPEEDLINE_WIDE_ASPECT

local linesHeartbeat

-- parts use .CFrame directly but models need PivotTo, so branchin here keeps that
-- difference is ind to one function
local function placeLines(cf)
	if rigIsPart then
		linesRig.CFrame = cf
	else
		linesRig:PivotTo(cf)
	end
end

-- keeps the rig infront of the cam every frame, offset scales w fov it font go out of the screen
local function linesTick()
	local vp = cam.ViewportSize
	local ar = vp.X / vp.Y
	-- pickin wide vs narrow offset based on current aspect ratio so the rig distance
	-- adapts if the player resizes their window or is on a diff device
	local off = ar > WIDE_ASPECT and OFF_WIDE or OFF_NARROW

	-- dividing offset by fov/70 so when fov changes (like durin the cutscene which uses
	-- a diff fov than the race cam) the apparent distance of the lines stays consistent
	placeLines(cam.CFrame * CFrame.new(0, 0, -off / (cam.FieldOfView / 70)))

	local ratio = plr:GetAttribute("RaceSpeedRatio") or 0
	local minR = Config.SPEEDLINE_MIN_RATIO
	local pow = 0

	-- remapping ratio from [minR, 1] to [0, 1] so the particle rate ramps up smoothly
	-- once past the threshold instead of just switchin on/off at minR
	if ratio > minR then
		pow = math.clamp((ratio - minR) / (1 - minR), 0, 1)
	end

	linesFX.Rate = pow * MAXRATE
	updateSpeedHud(ratio)
end

-- only connecting to renderstepped while this is actually on, so the tick function
-- isnt runnin every frame of the whole game session for no reason
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
-- parented straight to the horse model so if that model ever gets removed the
-- highlight goes with it automatically, dont gotta clean it up separately for that case
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

-- falling back to a named part lookup if PrimaryPart isnt set, so this doesnt just
-- error out on a model that wasnt configured w a primary part and it will not play a anims 
local function horseRoot(m)
	return m.PrimaryPart or m:FindFirstChild(Config.HORSE_ROOT_NAME)
end

-- horse mesh faces backwards because mesh is liek that I guess so we gotta flip it back to get real heading
local function travelCF(m)
	return horseRoot(m).CFrame * Config.HORSE_FACING_OFFSET
end

-- early return if steer didnt actually change so we're not firing a remote every
-- frame while a key is held, only fires on an actual value change optimization baby
local function pushSteer(v)
	if v == steer then return end
	steer = v
	SteerRemote:FireServer(steer)
end

-- recomputing from both held states instead of just incrementing/decrementing on
-- keydown/keyup, that way if both L and R are held (or released in domr other way order)
-- steer always resolves to the correct net value instead of driftin off
local function recalcSteer()
	local v = 0
	if heldR then v += 1 end
	if heldL then v -= 1 end
	pushSteer(v)
end

-- brief camera shake, used on race start impact
-- offset is rolled once when triggered, not every fraume, so the shake decays from
-- a fixed dir
local function triggerCamShake(duration, magnitude)
	shakeTimeLeft = duration
	camShakeOffset = Vector3.new(
		math.random(-100, 100) / 100 * magnitude,
		math.random(-100, 100) / 100 * magnitude,
		0
	)
end

-- falloff is just remaining time over total duration, clamped 0-1, so the shake
-- linearly shrinks to nothin by the time shakeTimeLeft hits 0
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

-- locks cam behind horse, bob/sway ramps for the cam
local function camOn()
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = Config.CAM_FOV

	camHeartbeat = RunService.RenderStepped:Connect(function(dt)
		local tcf = travelCF(activeHorse)

		local ratio = math.clamp(plr:GetAttribute("RaceSpeedRatio") or 0, 0, 1)
		local now = os.clock()

		-- multiplying bob/sway/roll by ratio means at 0 speed theres no wobble at all,
		-- and it scales up the faster the horse is goin so its dunamic
		local bob = math.sin(now * BOB_FREQ) * BOB_AMP * ratio
		local sway = math.sin(now * SWAY_FREQ) * SWAY_AMP * ratio
		local roll = math.sin(now * SWAY_FREQ) * SWAY_ROLL * ratio
		local shake = updateCamShake(dt)

		-- this CFrame is built relative to the horse's travelCF, so x/y/z here are
		-- local offsets (steer shift sideways, height up, back distance behind)
		-- before gettin multiplied into world space below
		local behindCF = CFrame.new(
			steer * Config.CAM_STEER_SHIFT + sway + shake.X,
			Config.CAM_HEIGHT + bob + shake.Y,
			Config.CAM_BACK_DISTANCE
		)

		local targetPos = (tcf * behindCF).Position
		-- lookPos is offset up from the horse's actual position so the cam isnt
		-- pointed straight down at it, aims a bit higher toward where its headed
		local lookPos = tcf.Position + Vector3.new(0, Config.CAM_HEIGHT * 0.4, 0)

		-- angling the cam based on steer so turnin also tilts the view, using
		-- -steer so it tilts the opposite direction of the shift above (into the turn)
		local goalCF = CFrame.new(targetPos, lookPos) * CFrame.Angles(0, 0, math.rad(-steer * Config.CAM_STEER_TILT - roll))

		-- lerping toward goalCF instead of settin it directly, so frame to frame
		-- movement stays smooth instead of snappin straight to a new position
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

	-- rechecking isRacing after the delay bc the race could've ended (EndRace fired)
	-- while this delay was still runnin, dont wanna call cb() and turn the chase cam
	-- on for a race that already ended
	task.delay(Config.CUTSCENE_DURATION, function()
		if not isRacing then return end
		letterboxToggle(false)
		cb()
	end)
end

-- rebinding on every CharacterAdded bc humanoid is a new instance each respawn,
-- a connection made on the old humanoid wouldnt fire for the new one
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

-- covering both cases: character already loaded when this script runs, and
-- character loading later, so bindCharacter always gets called exactly once per spawn
if plr.Character then
	bindCharacter(plr.Character)
end
plr.CharacterAdded:Connect(bindCharacter)

UIS.InputBegan:Connect(function(inp, sunk)
	-- sunk = true means a ui element already consumed this input, so returnin here
	-- stops keybinds from firing while ur typin in a textbox or similar
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

-- server fires this w the horse model when a race starts, resetin steer state first
-- so nothin carries over from a previous race before settin up the new one
RaceStarted.OnClientEvent:Connect(function(horseModel)
	activeHorse = horseModel
	isRacing = true
	heldL, heldR, steer = false, false, 0

	doFlash(Config.SCREEN_FLASH_COLOR, Config.START_FLASH_ALPHA, Config.START_FLASH_FADE_TIME)
	linesOn()
	setOutline(horseModel)
	triggerCamShake(Config.CAM_SHAKE_DURATION, Config.CAM_SHAKE_MAGNITUDE)

	-- camOn only gets called once the cutscene finishes (via this callback), so the
	-- chase cam doesnt kick in mid-pan, see the isRacing guard inside mountCutscene
	-- for what happens if the race ends before the cutscene is done
	mountCutscene(function()
		camOn()
	end)
end)

-- turns everything back off in the same order it got turned on, nothin here
-- depends on order relative to each other, theyre all independent systems
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
