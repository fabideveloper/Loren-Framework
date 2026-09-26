local ExampleService = {
	-- Names of other Services this one needs. They start first and appear in self.Dependencies.
	Dependencies = {},

	-- Functions clients can call: function ExampleService.Client:Name(player, ...) (self.Server is this Service).
	Client = {},

	-- Signal names. Loren creates them in self.Signals: self.Signals.Name:Fire(player, ...) or :FireAll(...).
	Signals = {},

	Middleware = {},
}

-- Runs first, in dependency order. Set up state here; do not yield.
function ExampleService:LorenIgnite() end

-- Runs after every Service has ignited, each in its own thread.
function ExampleService:LorenBurn() end

return ExampleService
