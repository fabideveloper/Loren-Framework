--!strict
-- Runner fixture: fails while loading, so collect() must report a load error.
-- Studio may print this error in red during "check"; that is expected.
local shouldFail = true
if shouldFail then
	error("intentional load error (LorenTest runner fixture; expected during check)")
end
return function(_t: any) end
