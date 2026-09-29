--!strict

local Probe = {
	early = {} :: { { kind: any, uid: any } },
	uearly = 0,
	connectError = nil :: string?,
}

local OrderController: any = {
	Dependencies = { "OrderService" },
	Probe = Probe,
}

function OrderController:LorenIgnite()
	local ok, err = pcall(function()
		local signals = self.Dependencies.OrderService.Signals
		signals.Early:Connect(function(kind: any, uid: any)
			if #Probe.early < 8 then
				table.insert(Probe.early, { kind = kind, uid = uid })
			end
		end)
		signals.UEarly:Connect(function()
			Probe.uearly += 1
		end)
	end)
	if not ok then
		Probe.connectError = tostring(err)
	end
end

return OrderController
