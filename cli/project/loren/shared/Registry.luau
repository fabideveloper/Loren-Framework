--!strict
--!optimize 2
--[[
	Registry (owner lane: lifecycle): AddServices/AddControllers, module records, declaration
	validation, boot reports and the Dependencies maps.
	Spec: IMPLEMENTATION.md sections 3.9, 8.4 and 11 (#1, #2, #3, #31, #34, #38); robust.md section 5.2.

	- `add` requires each ModuleScript at registration (as 1.5.1 did) and stores load problems;
	  `checkModules` and `buildServices` turn them and every declaration problem into one report.
	- Errors fail the boot; the author-decided soft cases are warnings: colon-style middleware (the
	  member is marked and every call is denied), orphan Middleware/Spec keys, reserved Client names.
	- Module keys are read raw first and through the metatable only under pcall, so a module with a
	  strict __index still loads. Keys that Loren replaces at boot (Dependencies, Signals,
	  ClientEvents, Client.Server) go through `inject`, which remembers the declaration: `declared`
	  keeps returning it, and `_reset` (Testing.Reset) puts it back.
	No side effects on require.
]]

local RunService = game:GetService("RunService")

local C = require(script.Parent.Constants)
local Types = require(script.Parent.Types)
local Log = require(script.Parent.Log)
local Schema = require(script.Parent.Schema)

type ModuleRecord = Types.ModuleRecord
type Report = Types.Report
type MemberDecl = Types.MemberDecl
type ServiceDecl = Types.ServiceDecl
type Config = Types.Config

local PREFIX = C.PREFIX
local KIND = C.Kind
local MAX_NAME = C.Limit.MAX_NAME
local RESERVED: { [string]: boolean } = C.ReservedClientNames :: any
local IS_SERVER = RunService:IsServer()
local IS_STUDIO = RunService:IsStudio()

local KIND_SPEC: { [number]: string } = {
	[KIND.Method] = "Loren.Method",
	[KIND.Event] = "Loren.Event",
	[KIND.Signal] = "Loren.Signal",
}
local KIND_DESC: { [number]: string } = {
	[KIND.Method] = "a Client method",
	[KIND.Event] = "a ClientEvent",
	[KIND.Signal] = "a Signal",
}
local RESERVED_LIST = "ClientEvents, Properties, Server, Signals, Try"
local SPEC_HINT = "; list names only (per-member options go in Spec)"
local LIST_MAX = 12

-- State (cleared in place by _reset) --------------------------------------------------------------

local records: { [string]: { [string]: ModuleRecord } } = { Service = {}, Controller = {} }
local problems: { [string]: { string } } = { Service = {}, Controller = {} } -- stored at add time
local failed: { [string]: { [string]: boolean } } = { Service = {}, Controller = {} }
local seenPath: { [string]: { [string]: string } } = { Service = {}, Controller = {} } -- every name added
local seenInstance: { [Instance]: boolean } = {}
local byModule: { [any]: ModuleRecord } = {}
local locked = false
local anySide = false -- _test: register on either side

-- Injection log: table -> key -> the value before Loren replaced it (NONE = was nil)
local NONE = table.freeze({})
local saved: { [any]: { [string]: any } } = {}
local savedOrder: { any } = {}

local Registry = {}

-- Helpers -----------------------------------------------------------------------------------------

local function index(t: any, k: string): any
	return t[k]
end

local function assign(t: any, k: string, v: any)
	t[k] = v
end

-- t[k] without letting a strict __index break registration: raw first, then the metatable under pcall.
function Registry.field(t: any, k: string): any
	local v = rawget(t, k)
	if v ~= nil or getmetatable(t) == nil then
		return v
	end
	local ok, r = pcall(index, t, k)
	return if ok then r else nil
end
local field = Registry.field

-- The declared value of a key Loren may have replaced (Dependencies, Signals, ClientEvents).
function Registry.declared(t: any, key: string): any
	local s = saved[t]
	if s then
		local v = s[key]
		if v ~= nil then
			return if v == NONE then nil else v
		end
	end
	return field(t, key)
end

-- t[key] = value, remembering the first replaced value so _reset can restore it.
function Registry.inject(t: any, key: string, value: any): ()
	local s = saved[t]
	if s == nil then
		s = {}
		saved[t] = s
		table.insert(savedOrder, t)
	end
	if s[key] == nil then
		local old = rawget(t, key)
		s[key] = if old == nil then NONE else old
	end
	t[key] = value
end

local function callable(v: any): boolean
	if type(v) == "function" then
		return true
	end
	if type(v) == "table" then
		local mt = getmetatable(v)
		return type(mt) == "table" and rawget(mt :: any, "__call") ~= nil
	end
	return false
end

local function describeKey(k: any): string
	if type(k) == "string" then
		return "'" .. k .. "'"
	end
	return tostring(k) .. " (" .. typeof(k) .. ")"
end

local function sortedStringKeys(t: any, report: Report?, owner: string): { string }
	local keys: { string } = {}
	for k in next, t do
		if type(k) == "string" then
			table.insert(keys, k)
		elseif report then
			table.insert(report.errors, owner .. " keys must be member names; found the key " .. describeKey(k))
		end
	end
	table.sort(keys)
	return keys
end

local function listNames(names: { string }): string
	local sorted: { string } = {}
	table.move(names, 1, #names, 1, sorted)
	table.sort(sorted)
	if #sorted <= LIST_MAX then
		return table.concat(sorted, ", ")
	end
	return table.concat(sorted, ", ", 1, LIST_MAX) .. string.format(", ... (%d more)", #sorted - LIST_MAX)
end

-- Levenshtein distance between two strings (bytes).
local function distance(a: string, b: string): number
	local la, lb = #a, #b
	if la == 0 then
		return lb
	elseif lb == 0 then
		return la
	end
	local prev: { number } = table.create(lb + 1, 0)
	local cur: { number } = table.create(lb + 1, 0)
	for j = 0, lb do
		prev[j + 1] = j
	end
	for i = 1, la do
		cur[1] = i
		local ca = string.byte(a, i)
		for j = 1, lb do
			local best = prev[j + 1] + 1 -- deletion
			local ins = cur[j] + 1
			if ins < best then
				best = ins
			end
			local sub = prev[j] + (if ca == string.byte(b, j) then 0 else 1)
			if sub < best then
				best = sub
			end
			cur[j + 1] = best
		end
		prev, cur = cur, prev
	end
	return prev[lb + 1]
end

-- The closest candidate: a case-insensitive match, else Levenshtein <= 2 (ties: byte order).
function Registry.suggest(name: string, candidates: { string }): string?
	local lower = string.lower(name)
	local best: string? = nil
	local bestDistance = 3
	for _, candidate in candidates do
		local lc = string.lower(candidate)
		local d = 3
		if lc == lower then
			d = 0
		elseif math.abs(#lc - #lower) <= 2 then
			d = distance(lower, lc)
		end
		if d < bestDistance or (d == bestDistance and best ~= nil and candidate < best) then
			best = candidate
			bestDistance = d
		end
	end
	return if bestDistance <= 2 then best else nil
end

-- " Did you mean 'X'?" or " <label>: a, b, c" (empty when there is nothing to list).
local function suggestion(name: string, candidates: { string }, label: string): string
	local s = Registry.suggest(name, candidates)
	if s then
		return " Did you mean '" .. s .. "'?"
	elseif #candidates == 0 then
		return ""
	end
	return " " .. label .. ": " .. listNames(candidates) .. "."
end
Registry.suggestion = suggestion

-- Reports -----------------------------------------------------------------------------------------

function Registry.newReport(side: string): Report
	return { side = side, errors = {}, warnings = {} }
end

function Registry.err(report: Report, msg: string): ()
	table.insert(report.errors, msg)
end

function Registry.warn(report: Report, msg: string): ()
	table.insert(report.warnings, msg)
end

local function indented(text: string, pad: string): string
	return (string.gsub(text, "\n", "\n" .. pad))
end

-- The boot failure text (failed = true) or the warnings block after a good boot ("" if none).
function Registry.format(report: Report, failed: boolean): string
	local lines: { string } = {}
	local warnings = report.warnings
	if failed then
		local n = #report.errors
		table.insert(
			lines,
			string.format("%sBoot failed on %s (%d problem%s):", PREFIX, report.side, n, if n == 1 then "" else "s")
		)
		for i, e in report.errors do
			table.insert(lines, string.format("  %d. %s", i, indented(e, "     ")))
		end
		if #warnings > 0 then
			table.insert(lines, string.format("Warnings (%d):", #warnings))
		end
	elseif #warnings == 0 then
		return ""
	else
		table.insert(lines, string.format("%sBoot warnings on %s (%d):", PREFIX, report.side, #warnings))
	end
	for _, w in warnings do
		table.insert(lines, "  - " .. indented(w, "    "))
	end
	return table.concat(lines, "\n")
end

-- Registration ------------------------------------------------------------------------------------

-- Collects ModuleScripts: direct items always; inside Folders only with Recursive (else listed in
-- `nested` for the warning). A ModuleScript's own children are never descended.
local function collect(item: Instance, recursive: boolean, depth: number, out: { ModuleScript }, nested: { string })
	if item:IsA("ModuleScript") then
		if depth == 0 or recursive then
			table.insert(out, item)
		else
			table.insert(nested, item:GetFullName())
		end
	elseif item:IsA("Folder") then
		for _, child in item:GetChildren() do
			collect(child, recursive, depth + 1, out, nested)
		end
	end
end

local function register(kind: string, m: ModuleScript)
	if seenInstance[m] then
		return -- the same ModuleScript added twice: nothing new
	end
	seenInstance[m] = true
	local name = m.Name
	local path = m:GetFullName()
	local label = kind .. " '" .. name .. "'"
	local prior = seenPath[kind][name]
	if prior then
		table.insert(problems[kind], string.format("Duplicate %s name '%s': %s and %s", kind, name, prior, path))
		return
	end
	seenPath[kind][name] = path
	local ok, result = pcall(require, m)
	if not ok then
		failed[kind][name] = true
		table.insert(problems[kind], string.format("%s (%s) failed to load: %s", label, path, tostring(result)))
		return
	end
	if type(result) ~= "table" then
		failed[kind][name] = true
		table.insert(problems[kind], string.format("%s (%s) must return a table, got %s", label, path, typeof(result)))
		return
	end
	local rec: ModuleRecord = {
		name = name,
		kind = kind,
		module = result,
		instance = m,
		path = path,
		deps = {},
	}
	records[kind][name] = rec
	byModule[result] = rec
end

-- Loren.AddServices / Loren.AddControllers. Misuse errors point at the caller of the facade (level 3).
function Registry.add(kind: string, container: any, opts: any?): ()
	local serverKind = kind == "Service"
	if not anySide and serverKind ~= IS_SERVER then
		if serverKind then
			Log.studioOnce("add-side:Service", "AddServices is server-only; the call is ignored on the client")
		else
			Log.studioOnce(
				"add-side:Controller",
				"AddControllers is client-only; the call is ignored on the server (Studio Run mode boots as a server)"
			)
		end
		return
	end
	local api = if serverKind then "AddServices" else "AddControllers"
	if locked then
		error(PREFIX .. "AddServices/AddControllers must be called before SetOnFire", 3)
	end
	local recursive = false
	if opts ~= nil then
		if type(opts) ~= "table" then
			error(
				PREFIX .. api .. ": options must be a table like { Recursive = true } (got " .. typeof(opts) .. ")",
				3
			)
		end
		for k, v in next, opts do
			if k ~= "Recursive" then
				error(PREFIX .. api .. ": unknown option " .. describeKey(k) .. " (options: Recursive)", 3)
			elseif type(v) ~= "boolean" then
				error(PREFIX .. api .. ": Recursive must be a boolean (got " .. typeof(v) .. ")", 3)
			end
			recursive = v
		end
	end

	local items: { Instance }
	local where: string
	if typeof(container) == "Instance" then
		items = container:GetChildren()
		where = container:GetFullName()
	elseif type(container) == "table" then
		local n = rawlen(container)
		local count = 0
		for k, v in next, container do
			count += 1
			if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > n or typeof(v) ~= "Instance" then
				error(PREFIX .. api .. " expects a container Instance or an array of Instances", 3)
			end
		end
		if count ~= n then
			error(PREFIX .. api .. " expects a container Instance or an array of Instances (the array has holes)", 3)
		end
		items = container
		where = "an array"
	else
		error(
			PREFIX .. api .. " expects a container Instance or an array of Instances (got " .. typeof(container) .. ")",
			3
		)
	end

	local modules: { ModuleScript } = {}
	local nested: { string } = {}
	for _, item in items do
		collect(item, recursive, 0, modules, nested)
	end
	if #nested > 0 then
		table.sort(nested)
		Log.studioOnce(
			"add-nested:" .. kind .. ":" .. where,
			string.format(
				"%s(%s) skipped ModuleScripts inside sub-Folders: %s. Pass { Recursive = true } to register them",
				api,
				where,
				listNames(nested)
			)
		)
	end
	table.sort(modules, function(a: ModuleScript, b: ModuleScript): boolean
		if a.Name ~= b.Name then
			return a.Name < b.Name
		end
		return a:GetFullName() < b:GetFullName()
	end)
	for _, m in modules do
		register(kind, m)
	end
end

function Registry.lock(): ()
	locked = true
end

function Registry.records(kind: string): { [string]: ModuleRecord }
	return records[kind] or {}
end

-- Registered names of a kind, sorted.
function Registry.names(kind: string): { string }
	local names: { string } = {}
	local map = records[kind]
	if map then
		for name in map do
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

function Registry.recordOf(module: any): ModuleRecord?
	return byModule[module]
end

-- A module that was added but failed to load (its name is reported once, not again as unknown).
function Registry.isFailed(kind: string, name: string): boolean
	local set = failed[kind]
	return set ~= nil and set[name] == true
end

-- Validation --------------------------------------------------------------------------------------

-- Validates an array of names (Dependencies, Signals, ClientEvents). Returns the names in order
-- without duplicates (one warning per duplicate), or nil after adding an error. nil is an empty list.
function Registry.nameList(report: Report?, owner: string, value: any, hint: string?): { string }?
	if value == nil then
		return {}
	end
	local problem: string? = nil
	if type(value) ~= "table" then
		problem = owner .. ' must be an array of names like { "A", "B" } (got ' .. typeof(value) .. ")"
	else
		local n = rawlen(value)
		local count = 0
		for k, v in next, value do
			count += 1
			if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > n then
				problem = owner .. " must be an array of names; it has the key " .. describeKey(k) .. (hint or "")
				break
			elseif type(v) ~= "string" then
				problem = string.format("%s[%d] must be a name string (got %s)", owner, k, typeof(v))
				break
			end
		end
		if problem == nil and count ~= n then
			problem = owner .. " must be an array of names without holes"
		end
	end
	if problem then
		if report then
			table.insert(report.errors, problem)
		end
		return nil
	end
	local out: { string } = {}
	local has: { [string]: boolean } = {}
	for i = 1, rawlen(value) do
		local v: string = rawget(value, i) :: any
		if has[v] then
			if report then
				table.insert(report.warnings, owner .. " lists '" .. v .. "' twice (duplicates are ignored)")
			end
		else
			has[v] = true
			table.insert(out, v)
		end
	end
	return out
end

-- A Controller's declared Signals when they are an array of names (Loren turns them into
-- LocalSignals at boot); nil when absent, or when the Controller keeps its own signal objects there:
-- 1.5.1 never touched Controller.Signals, so such a table is left as it is.
function Registry.controllerSignals(module: any): { string }?
	local value = Registry.declared(module, "Signals")
	if value == nil then
		return nil
	end
	return Registry.nameList(nil, "Signals", value)
end

-- Per module: frozen tables Loren must write, Dependencies, hook types, Controller Signals.
-- Fills rec.deps with the validated names.
function Registry.checkRecord(report: Report, rec: ModuleRecord): ()
	local module = rec.module
	local label = rec.kind .. " '" .. rec.name .. "'"
	local isService = rec.kind == "Service"
	local declaredSignals = Registry.declared(module, "Signals")
	-- Controllers: only a list of names is replaced (anything else is the module's own table)
	local writesSignals = declaredSignals ~= nil
		and (isService or Registry.nameList(nil, "Signals", declaredSignals) ~= nil)
	if table.isfrozen(module) then
		local keys: { string } = {}
		if Registry.declared(module, "Dependencies") ~= nil then
			table.insert(keys, "Dependencies")
		end
		if writesSignals then
			table.insert(keys, "Signals")
		end
		if isService and Registry.declared(module, "ClientEvents") ~= nil then
			table.insert(keys, "ClientEvents")
		end
		if #keys > 0 then
			table.insert(
				report.errors,
				string.format(
					"%s (%s) is frozen, but Loren must replace its %s at boot; do not freeze the module table",
					label,
					rec.path,
					table.concat(keys, " and ")
				)
			)
		end
	end
	if isService then
		local client = field(module, "Client")
		if type(client) == "table" and table.isfrozen(client) then
			table.insert(
				report.errors,
				label .. ".Client is frozen, but Loren must set Client.Server at boot; do not freeze the Client table"
			)
		end
	end
	local deps = Registry.nameList(report, rec.name .. ".Dependencies", Registry.declared(module, "Dependencies"))
	rec.deps = deps or {}
	for _, hook in { "LorenIgnite", "LorenBurn", "LorenExtinguish" } do
		local fn = field(module, hook)
		if fn ~= nil and not callable(fn) then
			table.insert(report.errors, string.format("%s: %s must be a function (got %s)", label, hook, typeof(fn)))
		end
	end
	if not isService and declaredSignals ~= nil then
		if writesSignals then
			Registry.nameList(report, rec.name .. ".Signals", declaredSignals, SPEC_HINT) -- duplicate warnings
		else
			Log.studioOnce(
				"controller-signals:" .. rec.name,
				rec.name
					.. ".Signals is not an array of names, so Loren leaves it as it is (as 1.5.1 did). "
					.. 'List names like { "Opened" } to get LocalSignals.'
			)
		end
	end
end

-- Load problems (load errors, non-table returns, duplicates) and per-module checks, sorted by name.
function Registry.checkModules(report: Report, kind: string): ()
	local stored = problems[kind]
	if stored then
		for _, p in stored do
			table.insert(report.errors, p)
		end
	end
	local map = records[kind] or {}
	for _, name in Registry.names(kind) do
		Registry.checkRecord(report, map[name])
	end
end

local function newMember(name: string, kind: number, fn: any): MemberDecl
	return { name = name, kind = kind, fn = fn, middleware = nil, colon = false, spec = nil }
end

local function byNameKind(a: MemberDecl, b: MemberDecl): boolean
	if a.name ~= b.name then
		return a.name < b.name
	end
	return a.kind < b.kind
end

local function keysOf(...: { [string]: MemberDecl }): { string }
	local out: { string } = {}
	for i = 1, select("#", ...) do
		local map = select(i, ...)
		for k in map do
			if not table.find(out, k) then
				table.insert(out, k)
			end
		end
	end
	return out
end

-- The network declaration of one Service (IMPLEMENTATION.md section 3.9). Invalid entries add an
-- error and are left out, so the returned decl is always well formed.
function Registry.buildDecl(report: Report, rec: ModuleRecord, cfg: Config): ServiceDecl
	local S = rec.name
	local module = rec.module
	local errors = report.errors
	local warnings = report.warnings
	local decl: ServiceDecl = {
		name = S,
		record = rec,
		module = module,
		client = false,
		members = {},
		networked = false,
	}
	if #S > MAX_NAME then
		table.insert(
			errors,
			string.format("Service name '%s...' is longer than %d bytes", string.sub(S, 1, 40), MAX_NAME)
		)
	end
	local methods: { [string]: MemberDecl } = {}
	local events: { [string]: MemberDecl } = {}
	local signals: { [string]: MemberDecl } = {}

	-- Client: function fields are Methods
	local client = field(module, "Client")
	if client ~= nil then
		if type(client) ~= "table" then
			table.insert(errors, S .. ".Client must be a table (got " .. typeof(client) .. ")")
		else
			decl.client = client
			for k, v in next, client do
				if type(k) ~= "string" then
					if type(v) == "function" then
						Log.studioOnce(
							"client-key:" .. S .. ":" .. tostring(k),
							S
								.. ".Client has a function under the non-string key "
								.. describeKey(k)
								.. "; it is not networked"
						)
					end
				elseif type(v) == "function" then
					if RESERVED[k] then
						table.insert(
							warnings,
							string.format(
								"%s.Client.%s uses a reserved name and is not networked (reserved: %s)",
								S,
								k,
								RESERVED_LIST
							)
						)
					elseif #k > MAX_NAME then
						table.insert(
							errors,
							string.format("%s.Client: member names are limited to %d bytes", S, MAX_NAME)
						)
					else
						methods[k] = newMember(k, KIND.Method, v)
					end
				elseif k ~= "Server" then
					Log.studioOnce(
						"client-field:" .. S .. "." .. k,
						S .. ".Client." .. k .. " is not a function; it is not networked"
					)
				end
			end
		end
	end

	-- ClientEvents and Signals: arrays of names
	local eventNames =
		Registry.nameList(report, S .. ".ClientEvents", Registry.declared(module, "ClientEvents"), SPEC_HINT)
	for _, name in eventNames or ({} :: { string }) do
		if #name > MAX_NAME then
			table.insert(errors, string.format("%s.ClientEvents: member names are limited to %d bytes", S, MAX_NAME))
		elseif methods[name] then
			table.insert(
				errors,
				string.format("%s: '%s' is both a Client method and a ClientEvent; rename one of them", S, name)
			)
		else
			events[name] = newMember(name, KIND.Event, nil)
		end
	end
	local signalNames = Registry.nameList(report, S .. ".Signals", Registry.declared(module, "Signals"), SPEC_HINT)
	for _, name in signalNames or ({} :: { string }) do
		if #name > MAX_NAME then
			table.insert(errors, string.format("%s.Signals: member names are limited to %d bytes", S, MAX_NAME))
		else
			signals[name] = newMember(name, KIND.Signal, nil)
		end
	end

	-- Middleware: per Method or ClientEvent, called (player, ...) without self
	local middleware = field(module, "Middleware")
	if middleware ~= nil then
		if type(middleware) ~= "table" then
			table.insert(errors, S .. ".Middleware must be a table of functions (got " .. typeof(middleware) .. ")")
		else
			local candidates = keysOf(methods, events)
			for _, k in sortedStringKeys(middleware, report, S .. ".Middleware") do
				local f: any = rawget(middleware, k)
				local target = methods[k] or events[k]
				if type(f) ~= "function" then
					table.insert(errors, string.format("%s.Middleware.%s must be a function (got %s)", S, k, typeof(f)))
				elseif target == nil then
					table.insert(
						warnings,
						string.format("%s.Middleware.%s matches no Client method or ClientEvent and is ignored.", S, k)
							.. suggestion(k, candidates, "Members")
					)
				else
					target.middleware = f
					if target.kind == KIND.Method and cfg.MiddlewareArityCheck then
						local ma: number, mv: boolean = (debug.info :: any)(f, "a")
						local fa: number, fv: boolean = (debug.info :: any)(target.fn, "a")
						if ma == fa and ma >= 2 and not mv and not fv then
							target.colon = true
							table.insert(
								warnings,
								string.format(
									"%s.Middleware.%s looks colon-defined (%d parameters, like Client:%s). Middleware is "
										.. "called as (player, ...args) without self, so every %s call is DENIED until "
										.. "you write: function %s.Middleware.%s(player, ...)",
									S,
									k,
									ma,
									k,
									k,
									S,
									k
								)
							)
						end
					end
				end
			end
		end
	end

	-- Spec: Loren.Method/Event/Signal per member name and kind
	local spec = field(module, "Spec")
	if spec ~= nil then
		if type(spec) ~= "table" then
			table.insert(
				errors,
				S .. ".Spec must be a table of Loren.Method/Event/Signal specs (got " .. typeof(spec) .. ")"
			)
		else
			local candidates = keysOf(methods, events, signals)
			for _, k in sortedStringKeys(spec, report, S .. ".Spec") do
				local s: any = rawget(spec, k)
				if not Schema.isSpec(s) then
					table.insert(
						errors,
						string.format(
							"%s.Spec.%s must be Loren.Method(...), Loren.Event(...) or Loren.Signal(...) (got %s)",
							S,
							k,
							typeof(s)
						)
					)
				else
					local kind = s.kind
					local map = if kind == KIND.Method
						then methods
						elseif kind == KIND.Event then events
						elseif kind == KIND.Signal then signals
						else nil
					local target = if map then map[k] else nil
					if target then
						target.spec = s
					else
						local have: { string } = {}
						if methods[k] then
							table.insert(have, KIND_DESC[KIND.Method])
						end
						if events[k] then
							table.insert(have, KIND_DESC[KIND.Event])
						end
						if signals[k] then
							table.insert(have, KIND_DESC[KIND.Signal])
						end
						if #have > 0 then
							table.insert(
								errors,
								string.format(
									"%s.Spec.%s is a %s but %s is %s",
									S,
									k,
									KIND_SPEC[kind] or "spec",
									k,
									table.concat(have, " and ")
								)
							)
						else
							table.insert(
								warnings,
								string.format(
									"%s.Spec.%s matches no Client method, ClientEvent or Signal and is ignored.",
									S,
									k
								) .. suggestion(k, candidates, "Members")
							)
						end
					end
				end
			end
		end
	end

	local members: { MemberDecl } = {}
	for _, m in methods do
		table.insert(members, m)
	end
	for _, m in events do
		table.insert(members, m)
	end
	for _, m in signals do
		table.insert(members, m)
	end
	table.sort(members, byNameKind)
	decl.members = members
	decl.networked = #members > 0
	return decl
end

-- One decl per registered Service (networked or not), sorted by name.
function Registry.buildServices(report: Report, cfg: Config): { ServiceDecl }
	local decls: { ServiceDecl } = {}
	local map = records.Service
	for _, name in Registry.names("Service") do
		table.insert(decls, Registry.buildDecl(report, map[name], cfg))
	end
	return decls
end

-- The injected Dependencies map: declared names only; reading another name warns once in Studio.
function Registry.depsMap(record: ModuleRecord, resolved: { [string]: any }): { [string]: any }
	local owner = record.name
	local map: any = setmetatable(resolved :: any, {
		__index = function(_: any, k: any): any
			if IS_STUDIO then
				local key = tostring(k)
				Log.studioOnce(
					"undeclared-dep:" .. owner .. ":" .. key,
					owner .. " reads undeclared dependency '" .. key .. "'; add it to " .. owner .. ".Dependencies"
				)
			end
			return nil
		end,
	})
	return map
end

function Registry._reset(): ()
	-- Put back every key Loren replaced (newest first), so the same module tables can boot again.
	for i = #savedOrder, 1, -1 do
		local t = savedOrder[i]
		if not table.isfrozen(t) then
			for k, v in saved[t] do
				pcall(assign, t, k, if v == NONE then nil else v)
			end
		end
	end
	table.clear(saved)
	table.clear(savedOrder)
	for _, kind in { "Service", "Controller" } do
		table.clear(records[kind])
		table.clear(problems[kind])
		table.clear(failed[kind])
		table.clear(seenPath[kind])
	end
	table.clear(seenInstance)
	table.clear(byModule)
	locked = false
	anySide = false
end

Registry._test = table.freeze({
	-- Lets add() register either kind on this side (Controller specs on the server).
	setAnySide = function(on: boolean)
		anySide = on
	end,
	isLocked = function(): boolean
		return locked
	end,
	-- Registers a module table without a ModuleScript (specs build modules as plain tables; a
	-- ModuleScript's Source cannot be written at run time). Same record shape as `add`.
	register = function(kind: string, name: string, module: any): ModuleRecord
		local path = "Testing." .. kind .. "." .. name
		local rec: ModuleRecord = {
			name = name,
			kind = kind,
			module = module,
			instance = nil :: any,
			path = path,
			deps = {},
		}
		records[kind][name] = rec
		seenPath[kind][name] = path
		if type(module) == "table" then
			byModule[module] = rec
		end
		return rec
	end,
})

return table.freeze(Registry)
