--!strict
--[[
	MineRewardController (ModuleScript) — put it next to MiningController

	What happens on every rock hit that does damage:
	  1. the screen shakes (uses the ScreenShake module in ReplicatedStorage)
	  2. the server (ShopServer) rolls a random 0-100 Stars reward and adds it
	  3. the client gets the amount back and, if it's more than 0, an invisible,
	     uncollidable star drop pops out of the rock, falls until it touches
	     collidable ground, then glides into you with a yellow -> light yellow trail

	MiningController calls Start() once and OnHit(Rock) on every hit.
]]

const Debris = game:GetService("Debris")
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const TweenService = game:GetService("TweenService")
const Workspace = game:GetService("Workspace")

const REMOTE_NAME = "MineReward" -- created by ShopServer

const Settings = table.freeze({
	-- screen shake on every hit (presets are in the ScreenShake module)
	ShakePreset = "Impact",
	ShakeMagnitude = 0.6,

	-- popping out of the rock
	PopUpSpeed = NumberRange.new(18, 26), -- studs/s upwards
	PopOutSpeed = NumberRange.new(6, 12), -- studs/s sideways
	PopSpread = 70, -- degrees either side of "towards you"
	MaxFallTime = 2, -- seconds: if it never lands (falls off the map), it flies to you anyway

	-- flying to you once it lands
	GroundDelay = 0.08, -- seconds it sits on the ground first
	FlyTime = 0.45,
	FlyArc = 2.5, -- studs it curves upwards on the way
	FlyStyle = Enum.EasingStyle.Quad,
	FlyDirection = Enum.EasingDirection.In, -- starts slow, speeds up into you like a magnet

	-- the trail (the drop itself is invisible)
	TrailColor = Color3.fromRGB(255, 208, 0), -- yellow, at the drop
	TrailFadeColor = Color3.fromRGB(255, 244, 158), -- light yellow, at the tail
	TrailWidth = 0.6,
	TrailLifetime = 0.35,
})

const Rng = Random.new()

local Started = false
local Remote: RemoteEvent? = nil
local ScreenShake: any = nil

const function GetRoot(): BasePart?
	const Character = Players.LocalPlayer.Character
	const Root = if Character then Character:FindFirstChild("HumanoidRootPart") else nil

	return if Root and Root:IsA("BasePart") then Root else nil
end

const function LoadScreenShake()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end

	-- works whether it's in ReplicatedStorage or ReplicatedStorage.Modules
	const Module = ReplicatedStorage:FindFirstChild("ScreenShake", true)

	if Module == nil or not Module:IsA("ModuleScript") then
		warn("[mining] ScreenShake module not found in ReplicatedStorage, hits won't shake the screen")
		return
	end

	ScreenShake = require(Module :: ModuleScript)
end

const function ShakeScreen()
	if ScreenShake then
		ScreenShake.Shake(Settings.ShakePreset, { Magnitude = Settings.ShakeMagnitude })
	end
end

-- the side of the rock that faces you, at half its height
const function SpawnPoint(Rock: Model, Toward: Vector3): Vector3
	const BoxCFrame, BoxSize = Rock:GetBoundingBox()
	const Half = BoxSize / 2
	const Point = BoxCFrame:PointToObjectSpace(Vector3.new(Toward.X, BoxCFrame.Position.Y, Toward.Z))

	return BoxCFrame:PointToWorldSpace(Vector3.new(
		math.clamp(Point.X, -Half.X, Half.X),
		math.clamp(Point.Y, -Half.Y, Half.Y),
		math.clamp(Point.Z, -Half.Z, Half.Z)
	))
end

const function CreateDrop(Origin: Vector3): (Part, Trail)
	const Drop = Instance.new("Part")
	Drop.Name = "StarDrop"
	Drop.Anchored = true
	Drop.CanCollide = false
	Drop.CanQuery = false
	Drop.CanTouch = false
	Drop.CastShadow = false
	Drop.Transparency = 1
	Drop.Size = Vector3.one * 0.2
	Drop.CFrame = CFrame.new(Origin)

	const Left = Instance.new("Attachment")
	Left.Position = Vector3.new(-Settings.TrailWidth / 2, 0, 0)
	Left.Parent = Drop

	const Right = Instance.new("Attachment")
	Right.Position = Vector3.new(Settings.TrailWidth / 2, 0, 0)
	Right.Parent = Drop

	const Trail = Instance.new("Trail")
	Trail.Attachment0 = Left
	Trail.Attachment1 = Right
	Trail.Color = ColorSequence.new(Settings.TrailColor, Settings.TrailFadeColor)
	Trail.Transparency = NumberSequence.new(0, 1)
	Trail.WidthScale = NumberSequence.new(1, 0)
	Trail.Lifetime = Settings.TrailLifetime
	Trail.MinLength = 0
	Trail.FaceCamera = true
	Trail.LightEmission = 1
	Trail.LightInfluence = 0
	Trail.Parent = Drop

	Drop.Parent = Workspace

	return Drop, Trail
end

const function SpawnDrop(Rock: Model?, Fallback: Vector3)
	const Root = GetRoot()

	if Root == nil then
		return
	end

	const Origin = if Rock and Rock.Parent then SpawnPoint(Rock, Root.Position) else Fallback

	-- pop out roughly towards you, spread a bit to the sides
	local Flat = (Root.Position - Origin) * Vector3.new(1, 0, 1)

	if Flat.Magnitude < 1e-3 then
		Flat = Vector3.new(0, 0, -1)
	end

	const Turn = CFrame.Angles(0, math.rad(Rng:NextNumber(-Settings.PopSpread, Settings.PopSpread)), 0)
	const Outward = Turn:VectorToWorldSpace(Flat.Unit)

	local Velocity = Outward * Rng:NextNumber(Settings.PopOutSpeed.Min, Settings.PopOutSpeed.Max)
		+ Vector3.yAxis * Rng:NextNumber(Settings.PopUpSpeed.Min, Settings.PopUpSpeed.Max)

	-- "ground" is anything collidable except the rock itself and characters
	const Ignore: { Instance } = {}

	if Rock then
		table.insert(Ignore, Rock)
	end

	for _, Player in Players:GetPlayers() do
		if Player.Character then
			table.insert(Ignore, Player.Character)
		end
	end

	const Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.FilterDescendantsInstances = Ignore
	Params.RespectCanCollide = true
	Params.IgnoreWater = true

	const Drop, Trail = CreateDrop(Origin)

	local Position = Origin
	local Facing = CFrame.identity
	local Phase: "Fall" | "Rest" | "Fly" = "Fall"
	local Timer = 0
	local FlyFrom = Origin
	local Target = Root.Position
	local Connection: RBXScriptConnection? = nil

	-- keeps the trail attachments sideways to the movement so the trail is always wide
	const function Place(NewPosition: Vector3)
		const Moved = NewPosition - Position

		if Moved.Magnitude > 1e-4 then
			const Up = if math.abs(Moved.Unit.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
			Facing = CFrame.lookAt(Vector3.zero, Moved, Up)
		end

		Position = NewPosition
		Drop.CFrame = Facing + Position
	end

	const function StartFlying()
		Phase = "Fly"
		Timer = 0
		FlyFrom = Position
	end

	const function Finish()
		if Connection then
			Connection:Disconnect()
		end

		-- stop emitting so the trail fades out instead of vanishing
		Trail.Enabled = false
		Debris:AddItem(Drop, Settings.TrailLifetime)
	end

	Connection = RunService.Heartbeat:Connect(function(DeltaTime: number)
		if Drop.Parent == nil then
			Finish()
			return
		end

		Timer += DeltaTime

		if Phase == "Fall" then
			Velocity -= Vector3.yAxis * Workspace.Gravity * DeltaTime

			const Step = Velocity * DeltaTime
			const Landed = Workspace:Raycast(Position, Step, Params)

			if Landed then
				Place(Landed.Position + Landed.Normal * 0.1)
				Phase = "Rest"
				Timer = 0
			else
				Place(Position + Step)

				if Timer >= Settings.MaxFallTime then
					StartFlying()
				end
			end
		elseif Phase == "Rest" then
			if Timer >= Settings.GroundDelay then
				StartFlying()
			end
		else
			-- follows you if you move while it's flying
			const Current = GetRoot()

			if Current then
				Target = Current.Position
			end

			const Alpha = math.min(Timer / Settings.FlyTime, 1)
			const Eased = TweenService:GetValue(Alpha, Settings.FlyStyle, Settings.FlyDirection)

			Place(FlyFrom:Lerp(Target, Eased) + Vector3.yAxis * math.sin(Alpha * math.pi) * Settings.FlyArc)

			if Alpha >= 1 then
				Finish()
			end
		end
	end)
end

const function OnHit(Rock: Model)
	ShakeScreen()

	if Remote then
		Remote:FireServer(Rock)
	end
end

-- safe to call more than once (only the first call does anything)
const function Start()
	if Started then
		return
	end

	Started = true
	task.spawn(LoadScreenShake)

	task.spawn(function()
		const Found = ReplicatedStorage:WaitForChild(REMOTE_NAME)

		if not Found:IsA("RemoteEvent") then
			warn(`[mining] ReplicatedStorage.{REMOTE_NAME} isn't a RemoteEvent, hits won't give Stars`)
			return
		end

		const Event = Found :: RemoteEvent
		Remote = Event

		-- the server answers every rewarded hit with: Stars given, the rock, the rock's center
		Event.OnClientEvent:Connect(function(Amount: unknown, Rock: unknown, Center: unknown)
			if typeof(Amount) ~= "number" or Amount <= 0 or typeof(Center) ~= "Vector3" then
				return
			end

			const HitRock = if typeof(Rock) == "Instance" and Rock:IsA("Model") then Rock :: Model else nil
			SpawnDrop(HitRock, Center)
		end)
	end)
end

return table.freeze({
	OnHit = OnHit,
	Start = Start,
})
