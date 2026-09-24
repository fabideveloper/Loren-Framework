--!strict
--!optimize 2
local Codec = {}

@native
local function add(a: number, b: number): number
	return a + b
end

	@native
	local function sub(a: number, b: number): number
		return a - b
	end

@native local function mul(a: number, b: number): number
	return a * b
end

-- a comment that mentions @native stays
Codec.add, Codec.sub, Codec.mul = add, sub, mul
return table.freeze(Codec)
