--!strict
local shouldFail = true
if shouldFail then
	error("intentional load error (LorenTest runner fixture; expected during check)")
end
return function(_t: any) end
