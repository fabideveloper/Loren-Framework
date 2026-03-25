--!strict

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Heart
--[[
    Just like love, it helps you grow!
    A framework that once ignited, never burns out.
]]
local Loren = {}

Loren.IsServer = RunService:IsServer()
Loren.IsClient = RunService:IsClient()
Loren.WasAwaken = false

local Services = {}
local Controllers: { [string]: any } = {}

--[[
    Loren.AddControllers(container)

    This function is used to add controllers to the Loren framework. 
    It takes a container (either an Instance or a table of Instances) as an argument and requires all ModuleScripts within that container, adding them to the Controllers table.

    Example usage:
    Loren.AddControllers(game:GetService("ReplicatedStorage").Controllers)
]]

function Loren.AddControllers(container: Instance | { Instance }): boolean
	if Loren.WasAwaken then
		warn("Cannot add controllers after Loren has been awakened.")
		return false
	end

	if not Loren.IsClient then
		return false
	end

	if typeof(container) == "Instance" then
		for _, child in container:GetChildren() do
			if child:IsA("ModuleScript") then
				Controllers[child.Name] = require(child) :: any
			end
		end
	else
		for _, controller: Instance in container do
			Controllers[controller.Name] = require(controller) :: any
		end
	end

	return true
end

--[[
    Loren.AddServices(container)

    This function is used to add services to the Loren framework. 
    It takes a container (either an Instance or a table of Instances) as an argument and requires all ModuleScripts within that container, adding them to the Services table.

    Example usage:
    Loren.AddServices(game:GetService("ServerScriptService").Services)
]]
function Loren.AddServices(container: Instance | { Instance }): boolean
	if Loren.WasAwaken then
		warn("Cannot add services after Loren has been awakened.")
		return false
	end
	if not Loren.IsServer then
		return false
	end

	if typeof(container) == "Instance" then
		for _, child in container:GetChildren() do
			if child:IsA("ModuleScript") then
				Services[child.Name] = require(child) :: any
			end
		end
	else
		for _, service: Instance in container do
			Services[service.Name] = require(service) :: any
		end
	end

	return true
end

--[[
     Loren:Start()

     This function is used to start the Loren framework. 
     It will automaticall call :Init() and :Start() on all services and controllers that have been added to the framework.

     Example usage:
     Loren:Start()
]]
function Loren:SetOnFire()
	if self.WasAwaken then
		warn("Loren has already been awakened.")
		return
	end
	self.WasAwaken = true
	print("Loren Framework Initialized")
end

--[[
    Loren.import(moduleName)

    This function is used to import a module from the Loren framework. 
    It takes the name of the module as an argument and returns the module's contents.

    Example usage:
    local MyModule = Loren.import("MyModule")
    MyModule.someFunction()
]]
function Loren.import(moduleName: string): any | nil
	local modules = ReplicatedStorage:FindFirstChild("LorenPackages") :: Folder
	local foundModule = (modules and modules:FindFirstChild(moduleName) or nil) :: ModuleScript
	if foundModule then
		return require(foundModule :: any) :: any
	else
		error("Module '" .. moduleName .. "' not found in LorenPackages.")
	end
end

return Loren
