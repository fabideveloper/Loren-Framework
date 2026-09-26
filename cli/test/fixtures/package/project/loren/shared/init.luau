--!strict
--!native
-- Fixture runtime facade (not the real runtime).
local Version = require(script.Version)
local Codec = require(script.Codec)

return table.freeze({
	Version = Version.Version,
	Codec = Codec,
})
