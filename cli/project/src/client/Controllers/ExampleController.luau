local ExampleController = {
	Dependencies = {},
}

-- Runs first, in dependency order, once the server is ready. Set up state here; do not yield.
function ExampleController:LorenIgnite() end

-- Runs after every Controller has ignited, each in its own thread.
function ExampleController:LorenBurn() end

return ExampleController
