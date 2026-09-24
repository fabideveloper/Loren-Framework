local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.LorenTypes)

local ExampleService = {
	-- Names of other Services this one needs. Autocompletes from existing Services.
	Dependencies = ({}) :: { Types.ServiceName },

	-- Functions inside Client are exposed to the network
	Client = {},

	-- List signal names here. Loren injects them automatically.
	Signals = {},

	-- Optional: Security checks for Client functions
	Middleware = {},
}

-- Called when the framework initializes (Synchronous)
function ExampleService:LorenIgnite()
	-- Cast a resolved dependency for full intellisense on it, e.g.:
	-- local Foo = self.Dependencies.Foo :: typeof(require(game:GetService("ServerScriptService").Server.Services.Foo))
end

-- Called after all modules are ignited (Asynchronous)
function ExampleService:LorenBurn()
end

return ExampleService
