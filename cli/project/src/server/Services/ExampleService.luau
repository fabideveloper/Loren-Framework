local ExampleService = {
	Dependencies = {},

	-- Functions inside Client are exposed to the network
	Client = {},

	-- List signal names here. Loren injects them automatically.
	Signals = {},

	-- Optional: Security checks for Client functions
	Middleware = {},
}

-- Called when the framework initializes (Synchronous)
function ExampleService:LorenIgnite() end

-- Called after all modules are ignited (Asynchronous)
function ExampleService:LorenBurn() end

return ExampleService
