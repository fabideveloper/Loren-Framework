local TestController2 = {
	Dependencies = { "TestController" },
}

function TestController2:LorenBurn() end

function TestController2:LorenIgnite() end

function TestController2:Foo()
	print("TestController2 Foo")
end

return TestController2
