--!strict
-- Runner fixture (collected only by Runner.spec; "_" folders are skipped by the real run).
return function(t: any)
	t.it("works", function()
		t.expect(1 + 1).toBe(2)
	end)
end
