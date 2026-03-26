local TestController = {
	Dependencies = { "TestController2" },
}

function TestController:LorenIgnite() end

function TestController:LorenBurn()
	-- Main logic
	self.Dependencies.TestController2:Foo()
end

return TestController
