local ExampleController = {
	-- Names of Controllers, or of Services that have a Client table or Signals, that this one needs.
	-- They appear in self.Dependencies; a Service arrives as a proxy (its Client functions return Promises).
	Dependencies = {},
}

-- Typed deps (optional): local Types = require(game:GetService("ReplicatedStorage").Shared.LorenTypes),
-- then Dependencies = { "OtherController" } :: { Types.ClientDependencyName }, and in LorenIgnite:
-- local deps: Types.ClientDeps = self.Dependencies :: any. `loren types` keeps the names current.

-- Runs first, in dependency order, once the server is ready. Set up state here; do not yield.
function ExampleController:LorenIgnite() end

-- Runs after every Controller has ignited, each in its own thread.
function ExampleController:LorenBurn() end

return ExampleController
