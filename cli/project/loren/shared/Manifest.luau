--!strict
--!optimize 2

local C = require(script.Parent.Constants)
local Types = require(script.Parent.Types)
local Codec = require(script.Parent.Codec)
local Schema = require(script.Parent.Schema)

type Writer = Types.Writer
type Descriptor = Types.Descriptor
type ManifestModel = Types.ManifestModel
type ManifestLimits = Types.ManifestLimits
type ManifestMember = Types.ManifestMember
type ManifestService = Types.ManifestService

local KIND_METHOD = C.Kind.Method
local KIND_EVENT = C.Kind.Event
local KIND_SIGNAL = C.Kind.Signal
local HAS_ARGS = C.MemberFlag.HasArgs
local HAS_RETURNS = C.MemberFlag.HasReturns
local FLAG_RESERVED = 0x80
local F32_MAX = C.Limit.F32_MAX
local MAX_TYPED_FIELDS = C.Limit.MAX_TYPED_FIELDS
local BACKLOG_MAX = C.Limit.BACKLOG_MAX
local TIMEOUT_DS_MIN = C.Limit.TIMEOUT_MIN * 10
local TIMEOUT_DS_MAX = C.Limit.TIMEOUT_MAX * 10

-- 7 x f32, 2 x u32, 3 x u16, 5 x u8
local LIMITS_BYTES = 7 * 4 + 2 * 4 + 3 * 2 + 5
local MIN_SERVICE_BYTES = 3
local MIN_MEMBER_BYTES = 7

-- [[ Encode ]] ---------------------------------------------------------------------------------------------------

local function bad(what: string): never
	error(C.PREFIX .. "Manifest.encode: " .. what, 3)
end

-- min: smallest accepted value (the decoder rejects 0 for counts and limits that must be positive)
local function putUInt(w: Writer, v: any, bytes: number, what: string, min: number)
	local max = if bytes == 1 then 255 elseif bytes == 2 then 65535 else 4294967295
	if not (type(v) == "number" and v % 1 == 0 and math.floor(v) == v and v >= min and v <= max) then
		bad(string.format("%s must be an integer in %d..%.0f (got %s)", what, min, max, tostring(v)))
	end
	if bytes == 1 then
		Codec.writeU8(w, v)
	elseif bytes == 2 then
		Codec.writeU16(w, v)
	else
		Codec.writeU32(w, v)
	end
end

local f32Scratch = buffer.create(4)

-- A rate, burst or fraction: > 0 and <= hi, also after rounding to f32 (the decoder checks the f32 value).
local function putPositiveF32(w: Writer, v: any, hi: number, what: string)
	local ok = type(v) == "number" and v > 0 and v <= hi
	if ok then
		buffer.writef32(f32Scratch, 0, v)
		local r = buffer.readf32(f32Scratch, 0)
		ok = r > 0 and r <= hi
	end
	if not ok then
		bad(string.format("%s must be a number > 0 and <= %s (got %s)", what, tostring(hi), tostring(v)))
	end
	Codec.writeF32(w, v)
end

local function putStr8(w: Writer, s: any, what: string)
	if type(s) ~= "string" or #s > 255 then
		bad(what .. " must be a string of at most 255 bytes")
	end
	Codec.writeU8(w, #s)
	Codec.writeString(w, s)
end

local function putDescs(w: Writer, list: any, what: string)
	if type(list) ~= "table" or #list > MAX_TYPED_FIELDS then
		bad(what .. " must be an array of at most 32 Loren.T types")
	end
	Codec.writeU8(w, #list)
	for i = 1, #list do
		local d = list[i]
		if not Schema.isDescriptor(d) then
			bad(string.format("%s[%d] is not a Loren.T type", what, i))
		end
		Schema.writeDescriptor(w, d)
	end
end

local function putMember(w: Writer, m: ManifestMember, where: string, seenRoutes: { [number]: boolean })
	local kind = m.kind
	putStr8(w, m.name, where .. " name")
	if kind ~= KIND_METHOD and kind ~= KIND_EVENT and kind ~= KIND_SIGNAL then
		bad(where .. " has an unknown kind " .. tostring(kind))
	end
	Codec.writeU8(w, kind)
	putUInt(w, m.route, 2, where .. " route", 1)
	if seenRoutes[m.route] then
		bad(where .. " reuses route " .. tostring(m.route))
	end
	seenRoutes[m.route] = true
	-- the presence bits always describe what is written
	local flags = m.flags
	if
		not (
			type(flags) == "number"
			and flags % 1 == 0
			and math.floor(flags) == flags
			and flags >= 0
			and flags < FLAG_RESERVED
		)
	then
		bad(where .. " flags must be an integer in 0..127")
	end
	if m.returns ~= nil and kind ~= KIND_METHOD then
		bad(where .. " has Returns but is not a Method")
	end
	flags = bit32.band(flags, bit32.bnot(HAS_ARGS + HAS_RETURNS))
	if m.args ~= nil then
		flags += HAS_ARGS
	end
	if m.returns ~= nil then
		flags += HAS_RETURNS
	end
	Codec.writeU8(w, flags)
	if kind == KIND_METHOD then
		local ds = if type(m.timeout) == "number" then math.round(m.timeout * 10) else -1
		if not (ds >= TIMEOUT_DS_MIN and ds <= TIMEOUT_DS_MAX) then
			bad(where .. " timeout must be 1..120 s")
		end
		Codec.writeU16(w, ds)
		putPositiveF32(w, m.rate, F32_MAX, where .. " rate")
		putPositiveF32(w, m.burst, F32_MAX, where .. " burst")
	elseif kind == KIND_EVENT then
		putPositiveF32(w, m.rate, F32_MAX, where .. " rate")
		putPositiveF32(w, m.burst, F32_MAX, where .. " burst")
	else
		if not (type(m.backlog) == "number" and m.backlog <= BACKLOG_MAX) then
			bad(where .. " backlog must be 0..1024")
		end
		putUInt(w, m.backlog, 2, where .. " backlog", 0)
	end
	if m.args ~= nil then
		putDescs(w, m.args, where .. " args")
	end
	if m.returns ~= nil then
		putDescs(w, m.returns, where .. " returns")
	end
end

-- Exact-size, deterministic bytes for a model (services sorted by name, members by (name, kind)).
local function encode(model: ManifestModel): buffer
	local w = Codec.newWriter(1024, false)
	putUInt(w, model.proto, 1, "proto", 0)
	putStr8(w, model.version, "version")
	local l = model.limits
	putPositiveF32(w, l.frameRate, F32_MAX, "limits.frameRate")
	putPositiveF32(w, l.frameBurst, F32_MAX, "limits.frameBurst")
	putPositiveF32(w, l.byteRate, F32_MAX, "limits.byteRate")
	putPositiveF32(w, l.byteBurst, F32_MAX, "limits.byteBurst")
	putPositiveF32(w, l.msgRate, F32_MAX, "limits.msgRate")
	putPositiveF32(w, l.msgBurst, F32_MAX, "limits.msgBurst")
	putPositiveF32(w, l.mirror, 1, "limits.mirror")
	putUInt(w, l.sealC2S, 4, "limits.sealC2S", 1)
	putUInt(w, l.maxMessageC2S, 4, "limits.maxMessageC2S", 1)
	putUInt(w, l.unreliableMax, 2, "limits.unreliableMax", 1)
	putUInt(w, l.maxPending, 2, "limits.maxPending", 1)
	putUInt(w, l.maxNodes, 2, "limits.maxNodes", 1)
	putUInt(w, l.maxArgs, 1, "limits.maxArgs", 1)
	putUInt(w, l.maxRefs, 1, "limits.maxRefs", 0)
	putUInt(w, l.maxDepth, 1, "limits.maxDepth", 0)
	putUInt(w, l.flushHz, 1, "limits.flushHz", 1)
	putUInt(w, l.backlogWindow, 1, "limits.backlogWindow", 0)

	local services = model.services
	putUInt(w, #services, 2, "service count", 0)
	local seenRoutes: { [number]: boolean } = {}
	local prevService: string? = nil
	for si = 1, #services do
		local s = services[si]
		local name = s.name
		if type(name) ~= "string" or name == "" then
			bad(string.format("service %d has no name", si))
		end
		if prevService ~= nil and not (prevService < name) then
			bad("services must be sorted by name and unique ('" .. name .. "' after '" .. prevService .. "')")
		end
		prevService = name
		putStr8(w, name, "service name")
		local members = s.members
		putUInt(w, #members, 2, name .. " member count", 0)
		local prevName: string?, prevKind = nil, 0
		for mi = 1, #members do
			local m = members[mi]
			local mname = m.name
			if type(mname) ~= "string" or mname == "" then
				bad(string.format("%s member %d has no name", name, mi))
			end
			if prevName ~= nil and not (prevName < mname or (prevName == mname and prevKind < m.kind)) then
				bad("members of " .. name .. " must be sorted by (name, kind) and unique")
			end
			prevName, prevKind = mname, m.kind
			putMember(w, m, name .. "." .. mname, seenRoutes)
		end
	end

	local out = buffer.create(w.n)
	buffer.copy(out, 0, w.buf, 0, w.n)
	return out
end

-- [[ Decode ]] ---------------------------------------------------------------------------------------------------

local function readStr8(b: buffer, o: number, lim: number): (string?, number)
	if o >= lim then
		return nil, o
	end
	local n = buffer.readu8(b, o)
	if n > lim - o - 1 then
		return nil, o
	end
	return buffer.readstring(b, o + 1, n), o + 1 + n
end

local function positiveF32(x: number): boolean
	return x > 0 and x <= F32_MAX
end

local function readDescs(b: buffer, o: number, lim: number): ({ Descriptor }?, number)
	if o >= lim then
		return nil, o
	end
	local n = buffer.readu8(b, o)
	o += 1
	if n > MAX_TYPED_FIELDS or n > lim - o then -- every descriptor is at least one byte
		return nil, o
	end
	local list: { Descriptor } = table.create(n) :: any
	for i = 1, n do
		local d: Descriptor?
		d, o = Schema.readDescriptor(b, o, lim, 1)
		if d == nil then
			return nil, o
		end
		list[i] = d
	end
	table.freeze(list :: any)
	return list, o
end

local function decodeBody(b: buffer, o: number, lim: number): (ManifestModel?, string?)
	if o >= lim then
		return nil, "truncated"
	end
	local proto = buffer.readu8(b, o)
	if proto ~= C.PROTO then
		return nil, "protocol mismatch"
	end
	o += 1
	local version: string?
	version, o = readStr8(b, o, lim)
	if version == nil then
		return nil, "truncated"
	end
	if lim - o < LIMITS_BYTES then
		return nil, "truncated"
	end
	local limits: ManifestLimits = {
		frameRate = buffer.readf32(b, o),
		frameBurst = buffer.readf32(b, o + 4),
		byteRate = buffer.readf32(b, o + 8),
		byteBurst = buffer.readf32(b, o + 12),
		msgRate = buffer.readf32(b, o + 16),
		msgBurst = buffer.readf32(b, o + 20),
		mirror = buffer.readf32(b, o + 24),
		sealC2S = buffer.readu32(b, o + 28),
		maxMessageC2S = buffer.readu32(b, o + 32),
		unreliableMax = buffer.readu16(b, o + 36),
		maxPending = buffer.readu16(b, o + 38),
		maxNodes = buffer.readu16(b, o + 40),
		maxArgs = buffer.readu8(b, o + 42),
		maxRefs = buffer.readu8(b, o + 43),
		maxDepth = buffer.readu8(b, o + 44),
		flushHz = buffer.readu8(b, o + 45),
		backlogWindow = buffer.readu8(b, o + 46),
	}
	o += LIMITS_BYTES
	if
		not (
			positiveF32(limits.frameRate)
			and positiveF32(limits.frameBurst)
			and positiveF32(limits.byteRate)
			and positiveF32(limits.byteBurst)
			and positiveF32(limits.msgRate)
			and positiveF32(limits.msgBurst)
			and limits.mirror > 0
			and limits.mirror <= 1
			and limits.sealC2S > 0
			and limits.maxMessageC2S > 0
			and limits.unreliableMax > 0
			and limits.maxPending > 0
			and limits.maxNodes > 0
			and limits.maxArgs > 0
			and limits.flushHz > 0
		)
	then
		return nil, "bad limits"
	end

	if lim - o < 2 then
		return nil, "truncated"
	end
	local serviceCount = buffer.readu16(b, o)
	o += 2
	if serviceCount * MIN_SERVICE_BYTES > lim - o then
		return nil, "truncated"
	end
	local services: { ManifestService } = table.create(serviceCount) :: any
	local seenRoutes: { [number]: boolean } = {}
	local prevService: string? = nil
	for si = 1, serviceCount do
		local name: string?
		name, o = readStr8(b, o, lim)
		if name == nil then
			return nil, "truncated"
		end
		if name == "" or (prevService ~= nil and not (prevService < name)) then
			return nil, "bad service name or order"
		end
		prevService = name
		if lim - o < 2 then
			return nil, "truncated"
		end
		local memberCount = buffer.readu16(b, o)
		o += 2
		if memberCount * MIN_MEMBER_BYTES > lim - o then
			return nil, "truncated"
		end
		local members: { ManifestMember } = table.create(memberCount) :: any
		local prevName: string?, prevKind = nil, 0
		for mi = 1, memberCount do
			local mname: string?
			mname, o = readStr8(b, o, lim)
			if mname == nil or lim - o < 4 then
				return nil, "truncated"
			end
			local kind = buffer.readu8(b, o)
			local route = buffer.readu16(b, o + 1)
			local flags = buffer.readu8(b, o + 3)
			o += 4
			if kind ~= KIND_METHOD and kind ~= KIND_EVENT and kind ~= KIND_SIGNAL then
				return nil, "bad member kind"
			end
			if
				mname == "" or (prevName ~= nil and not (prevName < mname or (prevName == mname and prevKind < kind)))
			then
				return nil, "bad member name or order"
			end
			prevName, prevKind = mname, kind
			if route == 0 or seenRoutes[route] then
				return nil, "bad route"
			end
			seenRoutes[route] = true
			if
				bit32.band(flags, FLAG_RESERVED) ~= 0 or (kind ~= KIND_METHOD and bit32.band(flags, HAS_RETURNS) ~= 0)
			then
				return nil, "bad member flags"
			end
			local timeout, rate, burst, backlog = 0, 0, 0, 0
			if kind == KIND_METHOD then
				if lim - o < 10 then
					return nil, "truncated"
				end
				local ds = buffer.readu16(b, o)
				rate = buffer.readf32(b, o + 2)
				burst = buffer.readf32(b, o + 6)
				o += 10
				if ds < TIMEOUT_DS_MIN or ds > TIMEOUT_DS_MAX then
					return nil, "bad timeout"
				end
				timeout = ds / 10
			elseif kind == KIND_EVENT then
				if lim - o < 8 then
					return nil, "truncated"
				end
				rate = buffer.readf32(b, o)
				burst = buffer.readf32(b, o + 4)
				o += 8
			else
				if lim - o < 2 then
					return nil, "truncated"
				end
				backlog = buffer.readu16(b, o)
				o += 2
				if backlog > BACKLOG_MAX then
					return nil, "bad backlog"
				end
			end
			if kind ~= KIND_SIGNAL and not (positiveF32(rate) and positiveF32(burst)) then
				return nil, "bad rate limit"
			end
			local args: { Descriptor }?, returns: { Descriptor }? = nil, nil
			if bit32.band(flags, HAS_ARGS) ~= 0 then
				args, o = readDescs(b, o, lim)
				if args == nil then
					return nil, "bad descriptor"
				end
			end
			if bit32.band(flags, HAS_RETURNS) ~= 0 then
				returns, o = readDescs(b, o, lim)
				if returns == nil then
					return nil, "bad descriptor"
				end
			end
			members[mi] = {
				name = mname,
				kind = kind,
				route = route,
				flags = flags,
				timeout = timeout,
				rate = rate,
				burst = burst,
				backlog = backlog,
				args = args,
				returns = returns,
			}
		end
		services[si] = { name = name, members = members }
	end
	if o ~= lim then
		return nil, "trailing bytes"
	end
	return {
		proto = proto,
		version = version,
		limits = limits,
		services = services,
	}, nil
end

-- The model in b[o, lim), or nil + a reason. Never throws.
local function decode(b: buffer, o: number, lim: number): (ManifestModel?, string?)
	if typeof(b) ~= "buffer" or type(o) ~= "number" or type(lim) ~= "number" then
		return nil, "bad arguments"
	end
	if not (o >= 0 and o <= lim and lim <= buffer.len(b)) or o % 1 ~= 0 or lim % 1 ~= 0 then
		return nil, "bad bounds"
	end
	-- backstop only: decodeBody checks every read itself
	local ok, model, reason = pcall(decodeBody, b, o, lim)
	if not ok then
		return nil, "malformed manifest"
	end
	if model == nil then
		return nil, reason or "malformed manifest"
	end
	return model, nil
end

return table.freeze({
	encode = encode,
	decode = decode,
})
