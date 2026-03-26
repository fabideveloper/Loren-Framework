--!strict
-- o iubesc pe lore
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loren = {}
Loren.IsServer = RunService:IsServer()
Loren.IsClient = RunService:IsClient()
Loren.IsOnFire = false

local Services: { [string]: any } = {}
local Controllers: { [string]: any } = {}

local function GetModule(name: string): any?
	return Services[name] or Controllers[name]
end

function Loren.AddControllers(container: Instance | { Instance }): boolean
	if Loren.IsOnFire or not Loren.IsClient then
		return false
	end
	local instances = (
		typeof(container) == "Instance" and container:GetChildren() or container :: { Instance }
	) :: { Instance }
	for _, child in instances do
		if child:IsA("ModuleScript") then
			Controllers[child.Name] = require(child :: ModuleScript) :: any
		end
	end
	return true
end

function Loren.AddServices(container: Instance | { Instance }): boolean
	if Loren.IsOnFire or not Loren.IsServer then
		return false
	end
	local instances = (
		typeof(container) == "Instance" and container:GetChildren() or container :: { Instance }
	) :: { Instance }
	for _, child in instances do
		if child:IsA("ModuleScript") then
			Services[child.Name] = require(child :: ModuleScript) :: any
		end
	end
	return true
end

function Loren:SetOnFire()
	if self.IsOnFire then
		return
	end
	self.IsOnFire = true

	local registry = (self.IsServer and Services or Controllers)

	-- Resolve Dependencies (Strings -> Modules)
	for name, module in registry do
		if typeof(module) == "table" and typeof(module.Dependencies) == "table" then
			local resolved = {}
			for _, depName in module.Dependencies do
				local dep = GetModule(depName :: string)
				if dep then
					resolved[depName] = dep
				else
					warn("(LORENঌ) Missing dependency: " .. depName .. " for " .. name)
				end
			end
			module.Dependencies = resolved
		end
	end

	-- Ignition (Init)
	for _, module in registry do
		if typeof(module) == "table" and typeof(module.LorenIgnite) == "function" then
			module:LorenIgnite()
		end
	end

	-- Burn (Start)
	for _, module in registry do
		if typeof(module) == "table" and typeof(module.LorenBurn) == "function" then
			task.spawn(module.LorenBurn, module)
		end
	end

	print("(LORENঌ) Is burning.")
end

function Loren.import(moduleName: string): any
	local packages = ReplicatedStorage:FindFirstChild("LorenPackages") :: Folder
	local found = packages and packages:FindFirstChild(moduleName)
	if found then
		return require(found :: ModuleScript) :: any
	end
	error("(LORENঌ) Package '" .. moduleName .. "' not found.")
end

return Loren
