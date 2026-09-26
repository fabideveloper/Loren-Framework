--!strict
-- Runner fixture: collect() recurses into folders.
return function(t: any)
	t.describe("nested", function()
		t.it("runs", function()
			t.expect(true).toBeTruthy()
		end)
	end)
end
