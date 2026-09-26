--!strict
-- Loren 1.5.1 (trimmed fixture): the whole runtime lived in this one file.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Promise = require(ReplicatedStorage.LorenPackages.Promise)

local Loren = {}
local services = {}

function Loren.AddServices(container: Instance)
	for _, m in container:GetChildren() do
		services[m.Name] = require(m :: any)
	end
end

function Loren:SetOnFire()
	local Bridge = Instance.new("RemoteEvent")
	local Handshake = Instance.new("RemoteFunction")
	Bridge.Name, Handshake.Name = "LorenBridge", "LorenHandshake"
	Bridge.OnServerEvent:Connect(function(player, sName, mName, ...)
		local s = services[sName]
		if s.Middleware and s.Middleware[mName] then
			local ok = s.Middleware[mName](player, ...)
			if not ok then
				return
			end
		end
	end)
	return Promise.resolve()
end

return Loren
