--!strict
--!optimize 2
-- LorenServer index (owner lane: lifecycle): ServerScriptService.LorenServer, required lazily by the
-- facade on the server only. Returns the frozen table of server modules (IMPLEMENTATION.md section 2).

return table.freeze({
	Transport = require(script.Transport),
	Routes = require(script.Routes),
	Dispatch = require(script.Dispatch),
	Outbox = require(script.Outbox),
	ServerSignal = require(script.ServerSignal),
	Limits = require(script.Limits),
	Violations = require(script.Violations),
})
