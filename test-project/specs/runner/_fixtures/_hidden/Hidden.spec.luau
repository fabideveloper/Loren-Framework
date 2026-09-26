--!strict
-- Runner fixture: inside a "_" folder, so collect() must skip it.
return function(t: any)
	t.it("must never run", function()
		error("collect() did not skip a '_' folder")
	end)
end
