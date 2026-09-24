--!strict
--!optimize 2
local rt = game:GetService("ReplicatedStorage"):WaitForChild("LorenRuntime", 30)
assert(rt, "[Loren] ReplicatedStorage.LorenRuntime missing: run loren update")
return (require :: any)(rt)
