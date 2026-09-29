--!strict
-- Stand-in for ffrostflame/wally-instance-manager@0.1.0, which BridgeNet2 1.0.0 requires but whose
-- repository carries no license, so it is not vendored. This is new code with the same three calls
-- BridgeNet2 makes: a package's instances live in ReplicatedStorage[<package name>]. See PROVENANCE.md.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shim = {}

local function folderFor(project: Instance): Instance
	local existing = ReplicatedStorage:FindFirstChild(project.Name)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = project.Name
	folder.Parent = ReplicatedStorage
	return folder
end

function shim.add(project: Instance, target: Instance)
	target.Parent = folderFor(project)
end

function shim.get(project: Instance, name: string): any
	local folder = ReplicatedStorage:FindFirstChild(project.Name)
	return if folder then folder:FindFirstChild(name) else nil
end

function shim.waitForInstance(project: Instance, name: string, timeout: number?): any
	return ReplicatedStorage:WaitForChild(project.Name):WaitForChild(name, timeout or 1)
end

return shim
