local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = pcall(function() return game:GetService("VirtualInputManager") end) and game:GetService("VirtualInputManager") or nil
local CoreGui = game:GetService("CoreGui")

local localPlayer = Players.LocalPlayer
if not localPlayer then
	return
end

local env = (typeof(getgenv) == "function" and getgenv()) or _G
local SUITE_KEY = "GakuranVolleyballLegends_v2"

if env[SUITE_KEY] and typeof(env[SUITE_KEY].Cleanup) == "function" then
	pcall(env[SUITE_KEY].Cleanup)
end

local isTouchDevice = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local CONFIG = {
	AutoReceiveEnabled = true,
	AreaExpandEnabled = true,
	AutoJumpEnabled = true,
	BallEspEnabled = true,
	ShowAreaRing = true,
	FaceBallEnabled = true,

	-- "AUTO" | "BUMP" (COLISION) | "SET" (ESTABLECER) | "DIVE" (ZAMBULLA)
	ActionMode = "AUTO",

	-- Alcance de recepcion ampliado (en studs)
	AreaRadius = 30,
	MinRadius = 10,
	MaxRadius = 60,
	RadiusStep = 4,

	-- Prediccion de trayectoria y tiempos
	PredictionTime = 0.24,
	ActionCooldown = 0.16,
	JumpCooldown = 0.42,

	-- Nombres opcionales si el juego cambia algun GuiButton en PlayerGui
	BumpGuiName = "",
	SetGuiName = "",
	DiveGuiName = "",

	ScanInterval = 0.015,
	HudInterval = 0.06,
	DragDeadzone = 6
}

local BALL_KEYWORDS = { "ball", "volleyball", "vball", "pelota", "balon", "sphere" }
local BALL_EXCLUDE = { "effect", "trail", "shadow", "indicator", "ring", "hitbox_visual" }

local suite = {
	AutoReceiveEnabled = CONFIG.AutoReceiveEnabled,
	AreaExpandEnabled = CONFIG.AreaExpandEnabled,
	AutoJumpEnabled = CONFIG.AutoJumpEnabled,
	BallEspEnabled = CONFIG.BallEspEnabled,
	ShowAreaRing = CONFIG.ShowAreaRing,
	FaceBallEnabled = CONFIG.FaceBallEnabled,
	ActionMode = CONFIG.ActionMode,
	AreaRadius = CONFIG.AreaRadius,
	Minimized = false,

	ActionCount = 0,
	LastActionClock = 0,
	LastJumpClock = 0,
	LastDetectedBtn = "Auto",
	LastEvent = isTouchDevice and "Volleyball Legends Movil Listo" or "Volleyball Legends Listo",

	AreaPart = nil :: Part?,
	BallGui = nil :: BillboardGui?,
	Gui = nil :: ScreenGui?,
	HudRefs = {} :: { [string]: GuiObject },
	Connections = {} :: { RBXScriptConnection },
	Cleanup = nil :: (() -> ())?
}

local function track(conn: RBXScriptConnection): RBXScriptConnection
	table.insert(suite.Connections, conn)
	return conn
end

local function getUiRoot(): Instance
	local root: Instance = CoreGui
	pcall(function()
		if typeof(gethui) == "function" then
			local custom = gethui()
			if typeof(custom) == "Instance" then
				root = custom
			end
		end
	end)
	return root
end

local function getMyRig()
	local char = localPlayer.Character
	if not char then
		return nil, nil, nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = (char:FindFirstChild("HumanoidRootPart") :: BasePart?) or (char.PrimaryPart :: BasePart?)
	if not hum or not root or hum.Health <= 0 then
		return nil, nil, nil
	end
	return char, hum, root
end

local function isExcludedName(nameLower: string): boolean
	for _, ex in ipairs(BALL_EXCLUDE) do
		if string.find(nameLower, ex, 1, true) then
			return true
		end
	end
	return false
end

local function findBallPart(): BasePart?
	local bestPart: BasePart? = nil
	local bestScore = -math.huge

	for _, desc in ipairs(workspace:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Transparency < 0.95 then
			local nLower = string.lower(desc.Name)
			local pLower = desc.Parent and string.lower(desc.Parent.Name) or ""
			if not isExcludedName(nLower) and not isExcludedName(pLower) then
				local matchesKeyword = false
				for _, kw in ipairs(BALL_KEYWORDS) do
					if string.find(nLower, kw, 1, true) or string.find(pLower, kw, 1, true) then
						matchesKeyword = true
						break
					end
				end

				if matchesKeyword and desc.Size.Magnitude < 25 then
					local score = 0
					if desc.Shape == Enum.PartType.Ball then
						score += 60
					end
					if desc:FindFirstChildWhichIsA("BodyMover") or desc:FindFirstChildWhichIsA("Constraint") then
						score += 12
					end
					local speed = desc.AssemblyLinearVelocity.Magnitude
					if speed > 0.25 then
						score += math.min(20, speed * 0.5)
					end
					if score > bestScore then
						bestScore = score
						bestPart = desc
					end
				end
			end
		end
	end

	return bestPart
end

local function findGameButton(kind: string): GuiButton?
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end

	local explicit = ""
	if kind == "BUMP" then
		explicit = CONFIG.BumpGuiName
	elseif kind == "SET" then
		explicit = CONFIG.SetGuiName
	elseif kind == "DIVE" then
		explicit = CONFIG.DiveGuiName
	end

	if explicit ~= "" then
		local exact = playerGui:FindFirstChild(explicit, true)
		if exact and exact:IsA("GuiButton") then
			return exact
		end
	end

	local matchers = {
		BUMP = { "colision", "collision", "bump", "recib", "receive" },
		SET = { "establecer", "set", "armar", "levant" },
		DIVE = { "zambull", "dive", "salv", "save", "lanz" }
	}
	local keys = matchers[kind] or {}

	for _, desc in ipairs(playerGui:GetDescendants()) do
		if desc:IsA("GuiButton") and desc.Visible then
			local n = string.lower(desc.Name)
			local t = desc:IsA("TextButton") and string.lower(desc.Text) or ""
			for _, kw in ipairs(keys) do
				if string.find(n, kw, 1, true) or string.find(t, kw, 1, true) then
					return desc
				end
			end
		end
	end

	return nil
end

local function triggerGuiButton(btn: GuiButton)
	suite.LastDetectedBtn = btn.Name
	pcall(function()
		if typeof(getconnections) == "function" then
			for _, conn in ipairs(getconnections(btn.MouseButton1Down)) do
				conn:Fire()
			end
			for _, conn in ipairs(getconnections(btn.MouseButton1Click)) do
				conn:Fire()
			end
			for _, conn in ipairs(getconnections(btn.Activated)) do
				conn:Fire()
			end
		end
	end)
end

local function pressJump()
	local _, hum = getMyRig()
	if hum and hum.FloorMaterial ~= Enum.Material.Air then
		hum.Jump = true
	end
	if VirtualInputManager then
		pcall(function()
			VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
			task.delay(0.05, function()
				VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
			end)
		end)
	end
end

local function predictBallPosition(ball: BasePart): Vector3
	local pos = ball.Position
	local vel = ball.AssemblyLinearVelocity
	-- Incluye leve correccion por gravedad en prediccion corta
	local g = workspace.Gravity
	local t = CONFIG.PredictionTime
	return Vector3.new(
		pos.X + vel.X * t,
		pos.Y + vel.Y * t - 0.5 * g * (t * t) * 0.25,
		pos.Z + vel.Z * t
	)
end

local function chooseAction(predictedPos: Vector3, root: BasePart): string
	if suite.ActionMode ~= "AUTO" then
		return suite.ActionMode
	end
	local dy = predictedPos.Y - root.Position.Y
	local flatDist = Vector3.new(predictedPos.X - root.Position.X, 0, predictedPos.Z - root.Position.Z).Magnitude
	if dy < -2.4 and flatDist > 8.5 then
		return "DIVE"
	elseif dy > 2.4 then
		return "SET"
	else
		return "BUMP"
	end
end

local function removeAreaRing()
	if suite.AreaPart then
		pcall(function()
			suite.AreaPart:Destroy()
		end)
		suite.AreaPart = nil
	end
end

local function updateAreaRing(root: BasePart?)
	if not suite.AreaExpandEnabled or not suite.ShowAreaRing or not root then
		removeAreaRing()
		return
	end

	local part = suite.AreaPart
	if not part or not part.Parent then
		part = Instance.new("Part")
		part.Name = "GakuranVLAreaRing"
		part.Shape = Enum.PartType.Cylinder
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(95, 225, 255)
		part.Transparency = 0.78
		part.Parent = workspace
		suite.AreaPart = part
	end

	local diameter = suite.AreaRadius * 2
	part.Size = Vector3.new(0.18, diameter, diameter)
	part.CFrame = CFrame.new(root.Position.X, root.Position.Y - 2.6, root.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
end

local function updateBallEsp(ball: BasePart?, predictedPos: Vector3?, root: BasePart?)
	if not suite.BallEspEnabled or not ball then
		if suite.BallGui then
			pcall(function()
				suite.BallGui:Destroy()
			end)
			suite.BallGui = nil
		end
		return
	end

	if not suite.BallGui or not suite.BallGui.Parent then
		local bg = Instance.new("BillboardGui")
		bg.Name = "GakuranVLBallEsp"
		bg.Adornee = ball
		bg.Size = UDim2.fromOffset(146, 28)
		bg.StudsOffset = Vector3.new(0, 1.9, 0)
		bg.AlwaysOnTop = true
		bg.Parent = getUiRoot()

		local lbl = Instance.new("TextLabel")
		lbl.Name = "InfoLabel"
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundColor3 = Color3.fromRGB(16, 22, 34)
		lbl.BackgroundTransparency = 0.22
		lbl.BorderSizePixel = 0
		lbl.Font = Enum.Font.GothamBold
		lbl.TextSize = 10.5
		lbl.TextColor3 = Color3.fromRGB(120, 235, 255)
		lbl.Text = "BALON"
		lbl.Parent = bg

		Instance.new("UICorner", lbl).CornerRadius = UDim.new(0, 6)
		suite.BallGui = bg
	else
		suite.BallGui.Adornee = ball
	end

	local lbl = suite.BallGui:FindFirstChild("InfoLabel") :: TextLabel?
	if lbl and root and predictedPos then
		local dist = (predictedPos - root.Position).Magnitude
		local speed = ball.AssemblyLinearVelocity.Magnitude
		lbl.Text = string.format("BALON %.1fm | %.0f u/s", dist, speed)
	end
end

local function executeReceiveAction(kind: string, targetPos: Vector3, root: BasePart)
	local now = os.clock()
	if now - suite.LastActionClock < CONFIG.ActionCooldown then
		return
	end
	suite.LastActionClock = now

	if suite.FaceBallEnabled then
		local flat = Vector3.new(targetPos.X - root.Position.X, 0, targetPos.Z - root.Position.Z)
		if flat.Magnitude > 0.05 then
			pcall(function()
				root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
			end)
		end
	end

	local btn = findGameButton(kind) or findGameButton("BUMP") or findGameButton("SET") or findGameButton("DIVE")
	if btn then
		triggerGuiButton(btn)
	end

	if suite.AutoJumpEnabled and (kind == "SET" or targetPos.Y - root.Position.Y > 3.2) and (now - suite.LastJumpClock > CONFIG.JumpCooldown) then
		suite.LastJumpClock = now
		pressJump()
	end

	suite.ActionCount += 1
	local labelMap = {
		BUMP = "COLISION",
		SET = "ESTABLECER",
		DIVE = "ZAMBULLA"
	}
	suite.LastEvent = string.format("%s %.0fm (#%d)", labelMap[kind] or kind, suite.AreaRadius, suite.ActionCount)
end

local function scanMatch()
	local _, _, root = getMyRig()
	updateAreaRing(root)

	local ball = findBallPart()
	if not ball then
		updateBallEsp(nil, nil, nil)
		return
	end

	local predPos = predictBallPosition(ball)
	updateBallEsp(ball, predPos, root)

	if not suite.AutoReceiveEnabled or not root then
		return
	end

	local effectiveRadius = suite.AreaExpandEnabled and suite.AreaRadius or 14
	local toPlayer = root.Position - predPos
	local dist = toPlayer.Magnitude

	if dist <= effectiveRadius and dist > 0.05 then
		local dirToPlayer = toPlayer.Unit
		local speedTowardPlayer = ball.AssemblyLinearVelocity:Dot(dirToPlayer)
		local isThreatening = (speedTowardPlayer > 1.5) or (dist <= effectiveRadius * 0.72)
		if isThreatening then
			local kind = chooseAction(predPos, root)
			executeReceiveAction(kind, predPos, root)
		end
	end
end

local function makeDraggable(targetGui: GuiObject, onClick: (() -> ())?)
	local dragging = false
	local movedEnough = false
	local dragStart = Vector2.zero
	local startPos = targetGui.Position

	track(targetGui.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			movedEnough = false
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			startPos = targetGui.Position
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local current = Vector2.new(input.Position.X, input.Position.Y)
			local delta = current - dragStart
			if delta.Magnitude >= CONFIG.DragDeadzone then
				movedEnough = true
			end
			if movedEnough then
				targetGui.Position = UDim2.new(
					startPos.X.Scale,
					startPos.X.Offset + delta.X,
					startPos.Y.Scale,
					startPos.Y.Offset + delta.Y
				)
			end
		end
	end))

	track(UserInputService.InputEnded:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			local wasTap = not movedEnough
			dragging = false
			movedEnough = false
			if wasTap and onClick then
				onClick()
			end
		end
	end))
end

local function getPanelSize(): UDim2
	local w = isTouchDevice and 246 or 260
	if suite.Minimized then
		return UDim2.fromOffset(w, 34)
	end
	return UDim2.fromOffset(w, isTouchDevice and 226 or 214)
end

local refreshHud: () -> ()

local function toggleReceive()
	suite.AutoReceiveEnabled = not suite.AutoReceiveEnabled
	suite.LastEvent = suite.AutoReceiveEnabled and "Auto Recibir ON" or "Auto Recibir OFF"
	if refreshHud then refreshHud() end
end

local function toggleArea()
	suite.AreaExpandEnabled = not suite.AreaExpandEnabled
	suite.LastEvent = suite.AreaExpandEnabled and string.format("Area ON (%.0f)", suite.AreaRadius) or "Area OFF"
	if refreshHud then refreshHud() end
end

local function toggleJump()
	suite.AutoJumpEnabled = not suite.AutoJumpEnabled
	suite.LastEvent = suite.AutoJumpEnabled and "Auto Salto ON" or "Auto Salto OFF"
	if refreshHud then refreshHud() end
end

local function toggleEsp()
	suite.BallEspEnabled = not suite.BallEspEnabled
	suite.LastEvent = suite.BallEspEnabled and "ESP ON" or "ESP OFF"
	if refreshHud then refreshHud() end
end

local function changeRadius(delta: number)
	suite.AreaRadius = math.clamp(suite.AreaRadius + delta, CONFIG.MinRadius, CONFIG.MaxRadius)
	suite.LastEvent = string.format("Area: %.0f studs", suite.AreaRadius)
	if refreshHud then refreshHud() end
end

local function cycleMode()
	local order = { "AUTO", "BUMP", "SET", "DIVE" }
	local idx = 1
	for i, m in ipairs(order) do
		if m == suite.ActionMode then
			idx = i
			break
		end
	end
	suite.ActionMode = order[(idx % #order) + 1]
	suite.LastEvent = "Modo: " .. suite.ActionMode
	if refreshHud then refreshHud() end
end

local function toggleMinimize()
	suite.Minimized = not suite.Minimized
	local body = suite.HudRefs.BodyFrame
	local panel = suite.HudRefs.MainPanel
	local minBtn = suite.HudRefs.MinBtn :: TextButton?
	if body and panel then
		body.Visible = not suite.Minimized
		panel.Size = getPanelSize()
	end
	if minBtn then
		minBtn.Text = suite.Minimized and "+" or "-"
	end
end

refreshHud = function()
	local refs = suite.HudRefs
	local statusLbl = refs.StatusLabel :: TextLabel?
	local statsLbl = refs.StatsLabel :: TextLabel?
	local eventLbl = refs.EventLabel :: TextLabel?
	local recBtn = refs.RecBtn :: TextButton?
	local areaBtn = refs.AreaBtn :: TextButton?
	local jumpBtn = refs.JumpBtn :: TextButton?
	local espBtn = refs.EspBtn :: TextButton?
	local modeBtn = refs.ModeBtn :: TextButton?

	if statusLbl then
		statusLbl.Text = suite.AutoReceiveEnabled and "VOLLEYBALL LEGENDS: ON" or "VOLLEYBALL LEGENDS: PAUSA"
		statusLbl.TextColor3 = suite.AutoReceiveEnabled and Color3.fromRGB(115, 255, 185) or Color3.fromRGB(255, 110, 110)
	end
	if statsLbl then
		statsLbl.Text = string.format("Area: %.0f | Acciones: %d | %s", suite.AreaRadius, suite.ActionCount, suite.ActionMode)
	end
	if eventLbl then
		eventLbl.Text = suite.LastEvent
	end
	if recBtn then
		recBtn.Text = suite.AutoReceiveEnabled and "RECIBIR: ON" or "RECIBIR: OFF"
	end
	if areaBtn then
		areaBtn.Text = suite.AreaExpandEnabled and "AREA: ON" or "AREA: OFF"
	end
	if jumpBtn then
		jumpBtn.Text = suite.AutoJumpEnabled and "SALTO: ON" or "SALTO: OFF"
	end
	if espBtn then
		espBtn.Text = suite.BallEspEnabled and "ESP: ON" or "ESP: OFF"
	end
	if modeBtn then
		modeBtn.Text = "MODO: " .. suite.ActionMode
	end
end

local function buildMenu()
	local root = getUiRoot()
	local prev = root:FindFirstChild("GakuranVolleyballLegends_Gui")
	if prev then
		prev:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "GakuranVolleyballLegends_Gui"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = root
	suite.Gui = gui

	local panel = Instance.new("Frame")
	panel.Name = "MainPanel"
	panel.Size = getPanelSize()
	panel.Position = isTouchDevice and UDim2.new(0, 10, 0.18, 0) or UDim2.new(0, 16, 0.25, 0)
	panel.BackgroundColor3 = Color3.fromRGB(14, 19, 30)
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.Parent = gui

	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)
	local stroke = Instance.new("UIStroke", panel)
	stroke.Color = Color3.fromRGB(105, 215, 255)
	stroke.Thickness = 1.3
	stroke.Transparency = 0.3

	local titleBar = Instance.new("Frame")
	titleBar.Size = UDim2.new(1, 0, 0, 34)
	titleBar.BackgroundColor3 = Color3.fromRGB(20, 29, 45)
	titleBar.BackgroundTransparency = 0.1
	titleBar.BorderSizePixel = 0
	titleBar.Active = true
	titleBar.Parent = panel
	Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 12)

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Size = UDim2.new(1, -42, 1, 0)
	titleLbl.Position = UDim2.fromOffset(10, 0)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 11.5
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.TextColor3 = Color3.fromRGB(130, 225, 255)
	titleLbl.Text = "VOLLEYBALL LEGENDS (MOVIL)"
	titleLbl.Parent = titleBar

	local minBtn = Instance.new("TextButton")
	minBtn.Size = isTouchDevice and UDim2.fromOffset(28, 28) or UDim2.fromOffset(24, 24)
	minBtn.Position = isTouchDevice and UDim2.new(1, -32, 0.5, -14) or UDim2.new(1, -30, 0.5, -12)
	minBtn.BackgroundColor3 = Color3.fromRGB(36, 52, 78)
	minBtn.BorderSizePixel = 0
	minBtn.Font = Enum.Font.GothamBold
	minBtn.TextSize = 14
	minBtn.TextColor3 = Color3.fromRGB(240, 248, 255)
	minBtn.Text = "-"
	minBtn.Parent = titleBar
	Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

	minBtn.MouseButton1Click:Connect(toggleMinimize)
	makeDraggable(panel, nil)

	local body = Instance.new("Frame")
	body.Name = "BodyFrame"
	body.Size = UDim2.new(1, -16, 1, -42)
	body.Position = UDim2.fromOffset(8, 38)
	body.BackgroundTransparency = 1
	body.Parent = panel

	local statusLbl = Instance.new("TextLabel")
	statusLbl.Size = UDim2.new(1, 0, 0, 18)
	statusLbl.BackgroundTransparency = 1
	statusLbl.Font = Enum.Font.GothamBold
	statusLbl.TextSize = 11
	statusLbl.TextXAlignment = Enum.TextXAlignment.Left
	statusLbl.TextColor3 = Color3.fromRGB(115, 255, 185)
	statusLbl.Text = "VOLLEYBALL LEGENDS: ON"
	statusLbl.Parent = body

	local statsLbl = Instance.new("TextLabel")
	statsLbl.Size = UDim2.new(1, 0, 0, 16)
	statsLbl.Position = UDim2.fromOffset(0, 18)
	statsLbl.BackgroundTransparency = 1
	statsLbl.Font = Enum.Font.GothamSemibold
	statsLbl.TextSize = 10.5
	statsLbl.TextXAlignment = Enum.TextXAlignment.Left
	statsLbl.TextColor3 = Color3.fromRGB(220, 234, 248)
	statsLbl.Text = string.format("Area: %.0f | Acciones: 0 | %s", suite.AreaRadius, suite.ActionMode)
	statsLbl.Parent = body

	local eventLbl = Instance.new("TextLabel")
	eventLbl.Size = UDim2.new(1, 0, 0, 16)
	eventLbl.Position = UDim2.fromOffset(0, 36)
	eventLbl.BackgroundTransparency = 1
	eventLbl.Font = Enum.Font.Gotham
	eventLbl.TextSize = 10
	eventLbl.TextXAlignment = Enum.TextXAlignment.Left
	eventLbl.TextColor3 = Color3.fromRGB(180, 206, 230)
	eventLbl.Text = suite.LastEvent
	eventLbl.Parent = body

	local function makeBtn(name: string, pos: UDim2, size: UDim2, text: string, color: Color3, cb: () -> ())
		local b = Instance.new("TextButton")
		b.Name = name
		b.Position = pos
		b.Size = size
		b.BackgroundColor3 = color
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = isTouchDevice and 10.5 or 10
		b.TextColor3 = Color3.fromRGB(244, 250, 255)
		b.Text = text
		b.Parent = body
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
		b.MouseButton1Click:Connect(cb)
		return b
	end

	local h = isTouchDevice and 28 or 24
	suite.HudRefs.MainPanel = panel
	suite.HudRefs.BodyFrame = body
	suite.HudRefs.MinBtn = minBtn
	suite.HudRefs.StatusLabel = statusLbl
	suite.HudRefs.StatsLabel = statsLbl
	suite.HudRefs.EventLabel = eventLbl

	-- Fila 1: Recibir y Area
	suite.HudRefs.RecBtn = makeBtn("RecBtn", UDim2.fromOffset(0, 56), UDim2.new(0.485, 0, 0, h), "RECIBIR: ON", Color3.fromRGB(28, 70, 56), toggleReceive)
	suite.HudRefs.AreaBtn = makeBtn("AreaBtn", UDim2.new(0.515, 0, 0, 56), UDim2.new(0.485, 0, 0, h), "AREA: ON", Color3.fromRGB(28, 58, 92), toggleArea)

	-- Fila 2: Salto y ESP
	suite.HudRefs.JumpBtn = makeBtn("JumpBtn", UDim2.fromOffset(0, 88), UDim2.new(0.485, 0, 0, h), "SALTO: ON", Color3.fromRGB(36, 62, 88), toggleJump)
	suite.HudRefs.EspBtn = makeBtn("EspBtn", UDim2.new(0.515, 0, 0, 88), UDim2.new(0.485, 0, 0, h), "ESP: ON", Color3.fromRGB(48, 38, 76), toggleEsp)

	-- Fila 3: - AREA, + AREA y MODO
	makeBtn("MinusBtn", UDim2.fromOffset(0, 120), UDim2.new(0.22, 0, 0, h), "- AREA", Color3.fromRGB(58, 42, 46), function()
		changeRadius(-CONFIG.RadiusStep)
	end)
	makeBtn("PlusBtn", UDim2.new(0.24, 0, 0, 120), UDim2.new(0.22, 0, 0, h), "+ AREA", Color3.fromRGB(36, 62, 88), function()
		changeRadius(CONFIG.RadiusStep)
	end)
	suite.HudRefs.ModeBtn = makeBtn("ModeBtn", UDim2.new(0.48, 0, 0, 120), UDim2.new(0.52, 0, 0, h), "MODO: " .. suite.ActionMode, Color3.fromRGB(48, 38, 76), cycleMode)
end

local lastScan, lastHud = 0, 0
track(RunService.RenderStepped:Connect(function()
	local now = os.clock()
	if now - lastScan >= CONFIG.ScanInterval then
		lastScan = now
		scanMatch()
	end
	if now - lastHud >= CONFIG.HudInterval then
		lastHud = now
		refreshHud()
	end
end))

suite.Cleanup = function()
	removeAreaRing()
	for _, c in ipairs(suite.Connections) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(suite.Connections)
	if suite.BallGui then
		pcall(function()
			suite.BallGui:Destroy()
		end)
		suite.BallGui = nil
	end
	if suite.Gui then
		pcall(function()
			suite.Gui:Destroy()
		end)
		suite.Gui = nil
	end
end

env[SUITE_KEY] = suite
buildMenu()
refreshHud()
