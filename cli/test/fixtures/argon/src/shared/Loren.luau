--!strict
--!optimize 2
local rt = script.Parent:FindFirstChild("LorenRuntime")
	or game:GetService("ReplicatedStorage"):WaitForChild("LorenRuntime", 30)
assert(rt, "[Loren] LorenRuntime missing (ReplicatedStorage.LorenRuntime or next to this shim): run loren update")
return (require :: any)(rt)
