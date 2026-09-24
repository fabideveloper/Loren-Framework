local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.LorenTypes)

local ExampleController = {
	-- Names of other Controllers this one needs. Autocompletes from existing Controllers.
	Dependencies = ({}) :: { Types.ControllerName },
}

-- Called when the framework initializes (Synchronous)
function ExampleController:LorenIgnite()
	-- Cast a resolved dependency for full intellisense on it, e.g.:
	-- local Foo = self.Dependencies.Foo :: typeof(require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.Controllers.Foo))
end

-- Called after all modules are ignited (Asynchronous)
function ExampleController:LorenBurn()
end

return ExampleController