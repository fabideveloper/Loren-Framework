--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Runtime = ReplicatedStorage:WaitForChild("LorenRuntime")
local Loren = require(Runtime) :: any
local C = require(Runtime:WaitForChild("Constants")) :: any
local Codec = require(Runtime:WaitForChild("Codec")) :: any
local Schema = require(Runtime:WaitForChild("Schema")) :: any
local Bucket = require(Runtime:WaitForChild("Bucket")) :: any
local Config = require(Runtime:WaitForChild("Config")) :: any
local Log = require(Runtime:WaitForChild("Log")) :: any
local Manifest = require(Runtime:WaitForChild("Manifest")) :: any
local ClientNet = require(Runtime:WaitForChild("ClientNet")) :: any
local Calls = require(Runtime:WaitForChild("Calls")) :: any
local Proxy = require(Runtime:WaitForChild("Proxy")) :: any

local FrozenV2 = ServerStorage:WaitForChild("LorenTest"):WaitForChild("Frozen"):WaitForChild("v2")
local OldCodec = require(FrozenV2:WaitForChild("Codec")) :: any
local OldSchema = require(FrozenV2:WaitForChild("Schema")) :: any

local Server = ServerScriptService:WaitForChild("LorenServer")
local Routes = require(Server:WaitForChild("Routes")) :: any
local Transport = require(Server:WaitForChild("Transport")) :: any
local Outbox = require(Server:WaitForChild("Outbox")) :: any
local Dispatch = require(Server:WaitForChild("Dispatch")) :: any
local ServerSignal = require(Server:WaitForChild("ServerSignal")) :: any
local Limits = require(Server:WaitForChild("Limits")) :: any
local Violations = require(Server:WaitForChild("Violations")) :: any

local T = Schema.T
local K = C.Kind
local F = C.MemberFlag
local LIM = C.Limit
local P = C.PREFIX
local SVC = "Svc"
local HEADER = C.C2S_HEADER
local NAN = 0 / 0
local MIRROR = 0.9

type Args = { n: number, [number]: any }
type Def = {
	name: string,
	id: number,
	kind: number?,
	build: ((any) -> { any })?,
	unreliable: boolean?,
	ordered: boolean?,
	coalesce: boolean?,
	rate: number?,
	burst: number?,
}
type Action = { fire: string?, args: Args? }
type Shot = { unreliable: boolean, frame: buffer, refs: { any }?, nodes: number, side: number }
type Run = { frames: { Shot }, errors: { string } }
type Step = { at: number, fire: boolean, dt: number }
type Pair = { rt: any, p: any, c2s: { any }, got: { any } }

local function noop(...: any) end

local function args(...: any): Args
	return table.pack(...)
end

local function inputStruct(TT: any): any
	return TT.struct({
		seq = TT.u16,
		moveX = TT.i8,
		moveZ = TT.i8,
		yaw = TT.f32,
		jump = TT.bool,
		sprint = TT.bool,
	})
end

local DEFS: { Def } = {
	{ name = "Any", id = 1 },
	{
		name = "Aim",
		id = 2,
		unreliable = true,
		coalesce = true,
		build = function(TT: any): { any }
			return { TT.Vector3 }
		end,
	},
	{
		name = "Input",
		id = 3,
		build = function(TT: any): { any }
			return { inputStruct(TT) }
		end,
	},
	{
		name = "Name",
		id = 4,
		build = function(TT: any): { any }
			return { TT.string(64) }
		end,
	},
	{
		name = "Pair",
		id = 5,
		build = function(TT: any): { any }
			return { TT.u8, TT.Vector3, TT.bool }
		end,
	},
	{
		name = "UFix",
		id = 6,
		unreliable = true,
		build = function(TT: any): { any }
			return { TT.u16, TT.Vector3 }
		end,
	},
	{
		name = "USeq",
		id = 7,
		unreliable = true,
		ordered = true,
		build = function(TT: any): { any }
			return { TT.u32 }
		end,
	},
	{
		name = "UStr",
		id = 8,
		unreliable = true,
		build = function(TT: any): { any }
			return { TT.string(1000) }
		end,
	},
	{
		name = "Big",
		id = 9,
		build = function(TT: any): { any }
			return { TT.CFrame, TT.CFrame, TT.CFrame }
		end,
	},
	{
		name = "Mix",
		id = 10,
		build = function(TT: any): { any }
			return {
				TT.enum({ "Red", "Green", "Blue" }),
				TT.EnumItem(Enum.Material),
				TT.Color3,
				TT.Vector2,
				TT.i16,
				TT.f64,
				TT.i32,
				TT.u32,
				TT.i8,
				TT.f32(-10, 10),
			}
		end,
	},
	{
		name = "Tight",
		id = 11,
		rate = 60,
		burst = 10,
		build = function(TT: any): { any }
			return { TT.u16 }
		end,
	},
	{ name = "TightAny", id = 12, rate = 60, burst = 10 },
	{
		name = "TightU",
		id = 13,
		unreliable = true,
		rate = 60,
		burst = 10,
		build = function(TT: any): { any }
			return { TT.string(100) }
		end,
	},
	{
		name = "OrdFix",
		id = 14,
		unreliable = true,
		ordered = true,
		build = function(TT: any): { any }
			return { TT.u8, TT.bool }
		end,
	},
	{
		name = "Ref",
		id = 15,
		build = function(TT: any): { any }
			return { TT.Instance("BasePart"), TT.any, TT.optional(TT.u8) }
		end,
	},
	{
		name = "Arr",
		id = 16,
		build = function(TT: any): { any }
			return { TT.array(TT.u16, 50), TT.map(TT.string(8), TT.bool, 10) }
		end,
	},
	{
		name = "RelAim",
		id = 17,
		coalesce = true,
		build = function(TT: any): { any }
			return { TT.Vector3, TT.u8 }
		end,
	},
	{
		name = "None",
		id = 18,
		build = function(_: any): { any }
			return {}
		end,
	},
	{
		name = "Duo",
		id = 19,
		build = function(TT: any): { any }
			return { TT.u8, inputStruct(TT) }
		end,
	},
	{
		name = "Nest",
		id = 20,
		unreliable = true,
		build = function(TT: any): { any }
			return { TT.struct({ a = TT.u8, inner = TT.struct({ x = TT.i16, y = TT.bool }) }) }
		end,
	},
}

local function limits(over: { [string]: any }?): any
	local l: { [string]: any } = {
		frameRate = 1e6,
		frameBurst = 1e6,
		byteRate = 1e9,
		byteBurst = 1e9,
		msgRate = 1e7,
		msgBurst = 1e7,
		mirror = MIRROR,
		sealC2S = 16384,
		maxMessageC2S = 65536,
		unreliableMax = 900,
		maxPending = 4096,
		maxNodes = 2048,
		maxArgs = 20,
		maxRefs = 255,
		maxDepth = 16,
		flushHz = 61,
		backlogWindow = 10,
	}
	if over then
		for k, v in over do
			l[k] = v
		end
	end
	return l
end

local function member(d: Def): any
	local flags = 0
	if d.unreliable then
		flags = bit32.bor(flags, F.Unreliable)
	end
	if d.ordered then
		flags = bit32.bor(flags, F.Ordered)
	end
	if d.coalesce then
		flags = bit32.bor(flags, F.Coalesce)
	end
	local descs = if d.build then d.build(T) else nil
	if descs then
		flags = bit32.bor(flags, F.HasArgs)
	end
	local kind = d.kind or K.Event
	return {
		name = d.name,
		kind = kind,
		route = d.id,
		flags = flags,
		timeout = if kind == K.Method then 10 else 0,
		rate = if kind == K.Signal then 0 else (d.rate or 1e7),
		burst = if kind == K.Signal then 0 else (d.burst or 1e7),
		backlog = 0,
		args = descs,
		returns = nil,
	}
end

local function makeModel(defs: { Def }, lim: any): any
	local members: { any } = {}
	for _, d in defs do
		table.insert(members, member(d))
	end
	return { proto = C.PROTO, version = "2.0.0", limits = lim, services = { { name = SVC, members = members } } }
end

local now = 1000
local shots: { Shot } = {}

local function clock(): number
	return now
end

local function capture(unreliable: boolean, frame: buffer, refs: { any }?, nodes: number, side: number)
	table.insert(shots, { unreliable = unreliable, frame = frame, refs = refs, nodes = nodes, side = side })
end

local function start(defs: { Def }, lim: any): any
	ClientNet._reset()
	Calls._reset()
	Proxy._reset()
	now = 1000
	ClientNet._test.setClock(clock)
	table.clear(shots)
	ClientNet._test.setFire(capture)
	local model = makeModel(defs, lim)
	ClientNet._test.loadManifest(model)
	return Proxy.build(model)[SVC]
end

local function routeOf(name: string): any
	for _, r in ClientNet.routes() do
		if r.member == name then
			return r
		end
	end
	error("no route " .. name)
end

local function lost(): number
	return ClientNet.getStats().EventsLost
end

local function drain()
	for _ = 1, 2000 do
		ClientNet._test.flushNow()
		local s = ClientNet._test.state()
		if s.relQueued == 0 and s.unrQueued == 0 and s.relOpen == 0 and s.unrOpen == 0 then
			return
		end
		now += 1
	end
	error("the channels did not drain")
end

local function textOf(err: any): string
	local s = tostring(err)
	local at = string.find(s, P, 1, true)
	return if at then string.sub(s, at) else s
end

local function show(x: any, depth: number?): string
	local d = depth or 0
	if d > 40 then
		return "<deep>"
	end
	local t = typeof(x)
	if t == "number" then
		if x ~= x then
			return "nan"
		elseif x == 0 then
			return if 1 / x < 0 then "-0" else "0"
		end
		return string.format("%.17g", x)
	elseif t == "string" then
		return string.format("%q", x)
	elseif t == "table" then
		local parts: { string } = {}
		for k, v in next, x do
			table.insert(parts, show(k, d + 1) .. "=" .. show(v, d + 1))
		end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	elseif t == "Instance" then
		return "I:" .. (x :: Instance):GetFullName() .. ":" .. tostring(x)
	elseif t == "buffer" then
		return "buf" .. string.format("%q", buffer.tostring(x))
	end
	return t .. "(" .. tostring(x) .. ")"
end

local function refsText(refs: { any }?): string
	if refs == nil then
		return "nil"
	end
	local parts: { string } = {}
	for i = 1, #refs do
		parts[i] = show(refs[i])
	end
	return table.concat(parts, ";")
end

local function hex(s: string): string
	return (string.gsub(s, ".", function(ch: string): string
		return string.format("%02x", string.byte(ch))
	end))
end

type RefFrame = {
	n: number,
	nmsg: number,
	nrefs: number,
	nodes: number,
	side: number,
	parts: { string },
	refs: { any },
}
type RefChan = { unreliable: boolean, open: RefFrame, frames: { RefFrame } }
type Ref = {
	seal: number,
	msgCap: number,
	rel: RefChan,
	unr: RefChan,
	seqs: { [number]: number },
	co: { [number]: string },
	pcs: { [number]: any },
	defs: { [string]: Def },
}

local function newRefFrame(): RefFrame
	return { n = HEADER, nmsg = 0, nrefs = 0, nodes = 0, side = 0, parts = {}, refs = {} }
end

local function varint(v: number): string
	if v < 0x80 then
		return string.char(v)
	elseif v < 0x4000 then
		return string.char(bit32.bor(bit32.band(v, 0x7F), 0x80), bit32.rshift(v, 7))
	end
	return string.char(
		bit32.bor(bit32.band(v, 0x7F), 0x80),
		bit32.bor(bit32.band(bit32.rshift(v, 7), 0x7F), 0x80),
		bit32.rshift(v, 14)
	)
end

local function newRef(defs: { Def }, lim: any): Ref
	local byName: { [string]: Def } = {}
	local pcs: { [number]: any } = {}
	for _, d in defs do
		byName[d.name] = d
		local descs = if d.build then d.build(OldSchema.T) else nil
		pcs[d.id] = OldSchema.compile(descs, false, LIM.MAX_ARGS_C2S, d.unreliable == true)
	end
	return {
		seal = math.min(lim.sealC2S, LIM.C2S_MAX_FRAME),
		msgCap = math.clamp(math.floor(lim.msgBurst * lim.mirror), 1, LIM.MAX_MSGS_PER_FRAME),
		rel = { unreliable = false, open = newRefFrame(), frames = {} },
		unr = { unreliable = true, open = newRefFrame(), frames = {} },
		seqs = {},
		co = {},
		pcs = pcs,
		defs = byName,
	}
end

local function refEncode(ref: Ref, d: Def, refBase: number, seq: number, a: Args): (number, any)
	local fw = OldCodec.newWriter(64, true)
	fw.unreliable = d.unreliable == true
	fw.inlineTables = true
	fw.refBase = refBase
	OldCodec.writeHead(fw, d.id)
	if d.ordered then
		OldCodec.writeU16(fw, seq)
	end
	local st = ref.pcs[d.id].encode(fw, a.n, table.unpack(a, 1, a.n))
	return st, fw
end

local function writerBytes(fw: any): string
	return buffer.readstring(fw.buf, 0, fw.n)
end

local function refNeedsSeal(ref: Ref, ch: RefChan, len: number, nrefs: number, nodes: number, side: number): boolean
	local fr = ch.open
	if fr.nmsg == 0 then
		return false
	end
	if fr.nmsg >= ref.msgCap then
		return true
	end
	local bytes = OldCodec.varintSize(len) + len
	if ch.unreliable then
		return fr.n + bytes > LIM.UNRELIABLE_SEAL
	end
	return fr.n + 8 * fr.nodes + fr.side + bytes + 8 * nodes + side > ref.seal
		or fr.nrefs + nrefs > LIM.MAX_REFS
		or fr.nodes + nodes > LIM.MAX_NODES
end

local function refSeal(ch: RefChan)
	if ch.open.nmsg > 0 then
		table.insert(ch.frames, ch.open)
		ch.open = newRefFrame()
	end
end

local function refCommit(ch: RefChan, bytes: string, refs: { any }, nrefs: number, nodes: number, side: number)
	local fr = ch.open
	local prefix = varint(#bytes)
	table.insert(fr.parts, prefix .. bytes)
	fr.n += #prefix + #bytes
	for i = 1, nrefs do
		table.insert(fr.refs, refs[i])
	end
	fr.nrefs += nrefs
	fr.nodes += nodes
	fr.side += side
	fr.nmsg += 1
end

local function refFire(ref: Ref, name: string, a: Args): string?
	local d = ref.defs[name]
	local ch = if d.unreliable then ref.unr else ref.rel
	local seq = 0
	if d.ordered then
		seq = ((ref.seqs[d.id] or 0) + 1) % 65536
		ref.seqs[d.id] = seq
	end
	local st, fw = refEncode(ref, d, if d.unreliable then 0 else ch.open.nrefs, seq, a)
	if st ~= 0 then
		local code: string = C.EncodeName[st] or tostring(st)
		local arg: number = fw.errArg
		return string.format("%s%s.%s:Fire: arg %d %s", P :: string, SVC, d.name, arg, code)
	end
	local len, nrefs, nodes, side = fw.n, fw.nrefs, fw.nodes, fw.sideBytes
	local problem: string? = nil
	if d.unreliable then
		local total = HEADER + OldCodec.varintSize(len) + len
		if total > LIM.UNRELIABLE_SEAL then
			problem = string.format(
				"%d bytes is over the unreliable limit (%d bytes per frame, header included)",
				total,
				LIM.UNRELIABLE_SEAL
			)
		end
	elseif len + 8 * nodes + side > LIM.C2S_MAX_MESSAGE then
		problem = string.format("payload too large (%d, max %d)", len + 8 * nodes + side, LIM.C2S_MAX_MESSAGE)
	elseif nodes > LIM.MAX_NODES then
		problem = "more than " .. LIM.MAX_NODES .. " table values in the arguments"
	elseif nrefs > LIM.MAX_REFS then
		problem = "more than " .. LIM.MAX_REFS .. " Instances or other non-plain values in the arguments"
	end
	if problem then
		return P .. SVC .. "." .. d.name .. ":Fire: " .. problem
	end
	if d.coalesce and nrefs == 0 then
		ref.co[d.id] = writerBytes(fw)
		return nil
	end
	if refNeedsSeal(ref, ch, len, nrefs, nodes, side) then
		refSeal(ch)
		if nrefs > 0 then
			st, fw = refEncode(ref, d, 0, seq, a)
			assert(st == 0, "the reference re-encode failed")
			len, nrefs, nodes, side = fw.n, fw.nrefs, fw.nodes, fw.sideBytes
		end
	end
	refCommit(ch, writerBytes(fw), fw.refs, nrefs, nodes, side)
	return nil
end

local function refFlush(ref: Ref)
	local ids: { number } = {}
	for id in ref.co do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local bytes = ref.co[id]
		local d: Def? = nil
		for _, x in ref.defs do
			if x.id == id then
				d = x
			end
		end
		local ch = if (d :: Def).unreliable then ref.unr else ref.rel
		if refNeedsSeal(ref, ch, #bytes, 0, 0, 0) then
			refSeal(ch)
		end
		refCommit(ch, bytes, {}, 0, 0, 0)
		ref.co[id] = nil
	end
	refSeal(ref.rel)
	refSeal(ref.unr)
end

local function refFrames(ch: RefChan): { string }
	local out: { string } = {}
	for i, fr in ch.frames do
		local head = buffer.create(HEADER)
		buffer.writeu16(head, 0, (i - 1) % 65536)
		buffer.writeu16(head, 2, fr.nmsg)
		buffer.writeu8(head, 4, fr.nrefs)
		out[i] = buffer.tostring(head)
			.. table.concat(fr.parts)
			.. "|"
			.. refsText(if fr.nrefs > 0 then fr.refs else nil)
	end
	return out
end

local function shotFrames(list: { Shot }, unreliable: boolean): { string }
	local out: { string } = {}
	for _, s in list do
		if s.unreliable == unreliable then
			table.insert(out, buffer.tostring(s.frame) .. "|" .. refsText(s.refs))
		end
	end
	return out
end

local function sameFrames(what: string, got: { string }, want: { string })
	if #got ~= #want then
		error(string.format("%s: %d frames, expected %d", what, #got, #want), 0)
	end
	for i = 1, #want do
		if got[i] ~= want[i] then
			error(
				string.format(
					"%s: frame %d differs\n    got  %s\n    want %s",
					what,
					i,
					string.sub(hex(got[i]), 1, 240),
					string.sub(hex(want[i]), 1, 240)
				),
				0
			)
		end
	end
end

local function playProxy(defs: { Def }, lim: any, actions: { Action }): Run
	local svc = start(defs, lim)
	local errors: { string } = {}
	for i, act in actions do
		local name = act.fire
		if name then
			local a = act.args :: Args
			local ev = svc.ClientEvents[name]
			local ok, err = pcall(ev.Fire, ev, table.unpack(a, 1, a.n))
			errors[i] = if ok then "" else textOf(err)
		else
			drain()
			errors[i] = ""
		end
	end
	drain()
	return { frames = table.clone(shots), errors = errors }
end

local function playNet(defs: { Def }, lim: any, actions: { Action }): Run
	start(defs, lim)
	local byName: { [string]: any } = {}
	for _, r in ClientNet.routes() do
		byName[r.member] = r
	end
	local errors: { string } = {}
	for i, act in actions do
		local name = act.fire
		if name then
			local a = act.args :: Args
			local ok, err = pcall(ClientNet.fire, byName[name], a.n, table.unpack(a, 1, a.n))
			errors[i] = if ok then "" else textOf(err)
		else
			drain()
			errors[i] = ""
		end
	end
	drain()
	return { frames = table.clone(shots), errors = errors }
end

local function playRef(defs: { Def }, lim: any, actions: { Action }): (Ref, { string })
	local ref = newRef(defs, lim)
	local errors: { string } = {}
	for i, act in actions do
		local name = act.fire
		if name then
			errors[i] = refFire(ref, name, act.args :: Args) or ""
		else
			refFlush(ref)
			errors[i] = ""
		end
	end
	refFlush(ref)
	return ref, errors
end

local function differential(what: string, defs: { Def }, lim: any, actions: { Action })
	local ref, refErrors = playRef(defs, lim, actions)
	local proxy = playProxy(defs, lim, actions)
	local net = playNet(defs, lim, actions)
	for i = 1, #actions do
		if proxy.errors[i] ~= net.errors[i] then
			error(
				string.format(
					"%s: action %d (%s) error, proxy vs ClientNet.fire\n    got  %s\n    want %s",
					what,
					i,
					tostring(actions[i].fire),
					proxy.errors[i],
					net.errors[i]
				),
				0
			)
		end
	end
	sameFrames(
		what .. " reliable (proxy vs ClientNet.fire)",
		shotFrames(proxy.frames, false),
		shotFrames(net.frames, false)
	)
	sameFrames(
		what .. " unreliable (proxy vs ClientNet.fire)",
		shotFrames(proxy.frames, true),
		shotFrames(net.frames, true)
	)
	for i = 1, #actions do
		if proxy.errors[i] ~= refErrors[i] then
			error(
				string.format(
					"%s: action %d (%s) error, runtime vs frozen v2\n    got  %s\n    want %s",
					what,
					i,
					tostring(actions[i].fire),
					proxy.errors[i],
					refErrors[i]
				),
				0
			)
		end
	end
	sameFrames(what .. " reliable (runtime vs frozen v2)", shotFrames(proxy.frames, false), refFrames(ref.rel))
	sameFrames(what .. " unreliable (runtime vs frozen v2)", shotFrames(proxy.frames, true), refFrames(ref.unr))
end

local parts: { Instance } = {}
local cyclic: { [string]: any } = {}
cyclic.self = cyclic
local deep: { any } = {}
do
	local cur = deep
	for _ = 1, 20 do
		local nextLevel = {}
		cur[1] = nextLevel
		cur = nextLevel
	end
end

local function f32(rng: Random): number
	return rng:NextInteger(-524288, 524287) / 64
end

local function vec(rng: Random): Vector3
	return Vector3.new(f32(rng), f32(rng), f32(rng))
end

local function str(rng: Random, lo: number, hi: number): string
	return string.rep(string.char(rng:NextInteger(97, 122)), rng:NextInteger(lo, hi))
end

local function anyValue(rng: Random, depth: number): any
	local r = rng:NextInteger(1, 16)
	if r == 1 then
		return rng:NextInteger(0, 127)
	elseif r == 2 then
		return rng:NextInteger(-70000, 70000)
	elseif r == 3 then
		return rng:NextNumber() * 1e6 - 5e5
	elseif r == 4 then
		return str(rng, 0, 300)
	elseif r == 5 then
		return rng:NextNumber() < 0.5
	elseif r == 6 then
		return nil
	elseif r == 7 then
		return vec(rng)
	elseif r == 8 then
		return parts[rng:NextInteger(1, #parts)]
	elseif r == 9 and depth < 3 then
		local t: { any } = {}
		for i = 1, rng:NextInteger(0, 5) do
			t[i] = rng:NextInteger(0, 1000)
		end
		return t
	elseif r == 10 and depth < 3 then
		local t: { [string]: any } = {}
		for i = 1, rng:NextInteger(1, 4) do
			t["k" .. i] = anyValue(rng, depth + 1)
		end
		return t
	elseif r == 11 then
		local t: { [any]: any } = { rng:NextInteger(1, 9), "x" }
		t.key = str(rng, 1, 40)
		return t
	elseif r == 12 then
		return { f = print, n = rng:NextInteger(1, 50) }
	elseif r == 13 then
		return Vector2.new(f32(rng), f32(rng))
	elseif r == 14 then
		return CFrame.new(f32(rng), 2, 3)
	elseif r == 15 then
		local b = buffer.create(rng:NextInteger(0, 20))
		return b
	end
	return print
end

local GEN: { [string]: (Random) -> Args } = {
	Any = function(rng: Random): Args
		local roll = rng:NextNumber()
		if roll < 0.02 then
			return args(table.unpack(table.create(21, 1)))
		elseif roll < 0.03 then
			return args(cyclic)
		elseif roll < 0.04 then
			return args(deep)
		end
		local n = rng:NextInteger(0, 5)
		local t: { any } = table.create(n)
		for i = 1, n do
			t[i] = anyValue(rng, 0)
		end
		return table.pack(table.unpack(t, 1, n))
	end,
	Aim = function(rng: Random): Args
		if rng:NextNumber() < 0.05 then
			return args("not a vector")
		end
		return args(vec(rng))
	end,
	Input = function(rng: Random): Args
		local roll = rng:NextNumber()
		if roll < 0.03 then
			return args("not a struct")
		end
		local v: { [string]: any } = {
			seq = rng:NextInteger(0, 65535),
			moveX = rng:NextInteger(-128, 127),
			moveZ = rng:NextInteger(-128, 127),
			yaw = f32(rng),
			jump = rng:NextNumber() < 0.5,
			sprint = rng:NextNumber() < 0.5,
		}
		if roll < 0.05 then
			v.seq = 70000
		elseif roll < 0.07 then
			v.jump = nil
		elseif roll > 0.98 then
			return args(v, 1)
		end
		return args(v)
	end,
	Name = function(rng: Random): Args
		local roll = rng:NextNumber()
		if roll < 0.03 then
			return args(str(rng, 65, 80))
		elseif roll < 0.05 then
			return args(12)
		elseif roll < 0.06 then
			return args("\255bad")
		end
		return args(str(rng, 0, 64))
	end,
	Pair = function(rng: Random): Args
		local roll = rng:NextNumber()
		if roll < 0.03 then
			return args(256, vec(rng), true)
		elseif roll < 0.05 then
			return args(1, Vector3.new(NAN, 0, 0), false)
		elseif roll < 0.06 then
			return args(1, vec(rng))
		end
		return args(rng:NextInteger(0, 255), vec(rng), rng:NextNumber() < 0.5)
	end,
	UFix = function(rng: Random): Args
		return args(rng:NextInteger(0, 65535), vec(rng))
	end,
	USeq = function(rng: Random): Args
		if rng:NextNumber() < 0.05 then
			return args(-1)
		end
		return args(rng:NextInteger(0, 4294967295))
	end,
	UStr = function(rng: Random): Args
		if rng:NextNumber() < 0.05 then
			return args(str(rng, 890, 1000))
		end
		return args(str(rng, 0, 400))
	end,
	Big = function(rng: Random): Args
		return args(CFrame.new(f32(rng), 1, 2), CFrame.Angles(0, f32(rng) / 100, 0), CFrame.new())
	end,
	Mix = function(rng: Random): Args
		if rng:NextNumber() < 0.05 then
			return args("Purple", Enum.Material.Plastic, Color3.new(), Vector2.new(), 1, 2, 3, 4, 5, 6)
		end
		return args(
			({ "Red", "Green", "Blue" })[rng:NextInteger(1, 3)],
			Enum.Material.Wood,
			Color3.new(0.5, 0.25, 1),
			Vector2.new(f32(rng), 1),
			rng:NextInteger(-32768, 32767),
			rng:NextNumber(),
			rng:NextInteger(-2147483648, 2147483647),
			rng:NextInteger(0, 4294967295),
			rng:NextInteger(-128, 127),
			rng:NextInteger(-640, 640) / 64
		)
	end,
	OrdFix = function(rng: Random): Args
		return args(rng:NextInteger(0, 255), rng:NextNumber() < 0.5)
	end,
	Ref = function(rng: Random): Args
		local roll = rng:NextNumber()
		if roll < 0.04 then
			return args("not a part", 1)
		elseif roll < 0.4 then
			return args(parts[rng:NextInteger(1, #parts)], anyValue(rng, 0))
		end
		return args(parts[rng:NextInteger(1, #parts)], anyValue(rng, 0), rng:NextInteger(0, 255))
	end,
	Arr = function(rng: Random): Args
		local list: { number } = {}
		for i = 1, rng:NextInteger(0, 55) do
			list[i] = rng:NextInteger(0, 65535)
		end
		local map: { [string]: boolean } = {}
		for i = 1, rng:NextInteger(0, 11) do
			map["m" .. i] = rng:NextNumber() < 0.5
		end
		return args(list, map)
	end,
	RelAim = function(rng: Random): Args
		if rng:NextNumber() < 0.05 then
			return args(vec(rng), 300)
		end
		return args(vec(rng), rng:NextInteger(0, 255))
	end,
	None = function(rng: Random): Args
		local roll = rng:NextNumber()
		if roll < 0.04 then
			return args(1)
		elseif roll < 0.06 then
			return args(nil)
		end
		return args()
	end,
	Duo = function(rng: Random): Args
		local input: { [string]: any } = {
			seq = rng:NextInteger(0, 65535),
			moveX = rng:NextInteger(-128, 127),
			moveZ = rng:NextInteger(-128, 127),
			yaw = f32(rng),
			jump = rng:NextNumber() < 0.5,
			sprint = rng:NextNumber() < 0.5,
		}
		local roll = rng:NextNumber()
		if roll < 0.03 then
			return args(300, input)
		elseif roll < 0.06 then
			return args(1, "x")
		elseif roll < 0.08 then
			input.yaw = nil
			return args(2, input)
		elseif roll < 0.1 then
			return args(3, input, 1)
		end
		return args(rng:NextInteger(0, 255), input)
	end,
	Nest = function(rng: Random): Args
		local inner: { [string]: any } = { x = rng:NextInteger(-32768, 32767), y = rng:NextNumber() < 0.5 }
		local v: { [string]: any } = { a = rng:NextInteger(0, 255), inner = inner }
		local roll = rng:NextNumber()
		if roll < 0.03 then
			v.inner = nil
		elseif roll < 0.06 then
			inner.x = 1.5
		elseif roll < 0.08 then
			return args(v, true)
		end
		return args(v)
	end,
}

local function actionsFor(
	seed: number,
	count: number,
	names: { string },
	flushEvery: number,
	maxRun: number?
): { Action }
	local rng = Random.new(seed)
	local list: { Action } = {}
	local run = 0
	local cap = maxRun or 1000
	for _ = 1, count do
		if run >= cap or rng:NextInteger(1, flushEvery) == 1 then
			table.insert(list, {})
			run = 0
		else
			local name = names[rng:NextInteger(1, #names)]
			table.insert(list, { fire = name, args = GEN[name](rng) })
			run += 1
		end
	end
	return list
end

local function repeated(name: string, a: Args, count: number): { Action }
	local list: { Action } = {}
	for _ = 1, count do
		table.insert(list, { fire = name, args = a })
	end
	return list
end

local function probe(_: any, ...: any)
	error("probe", 2)
end

local function callSite(fn: any, self: any, ...: any): string
	local ok, err = pcall(function(...: any)
		fn(self, ...)
	end, ...)
	assert(not ok, "the call did not raise")
	return tostring(err)
end

local function position(err: string): string
	return string.match(err, "^(.-:%d+):") or ("<none> " .. err)
end

local function newBucket(rate: number, burst: number, t: number): any
	return Bucket.new(rate * MIRROR, math.max(1, burst * MIRROR), t)
end

local function serverServices(): any
	local members: { any } = {
		{
			name = "Bulk",
			kind = K.Event,
			fn = nil,
			spec = Schema.event({ RateLimit = { 1e6, 1e6 } }),
			middleware = nil,
			colon = false,
		},
		{
			name = "Input",
			kind = K.Event,
			fn = nil,
			spec = Schema.event(inputStruct(T), { RateLimit = { 1e6, 1e6 } }),
			middleware = nil,
			colon = false,
		},
	}
	local module = { Client = {}, Signals = {}, ClientEvents = {}, Middleware = {} }
	return {
		{
			name = "S",
			record = { name = "S", kind = "Service", module = module, instance = script, path = "S", deps = {} },
			module = module,
			client = {},
			members = members,
			networked = true,
		},
	}
end

local function resetServer()
	Transport._reset()
	Routes._reset()
	Dispatch._reset()
	Outbox._reset()
	ServerSignal._reset()
	Limits._reset()
	Violations._reset()
end

local function connectPair(uid: number): Pair
	resetServer()
	local c = Config.get()
	Limits.configure(c)
	Violations.configure(c)
	local report: any = { side = "Server", errors = {}, warnings = {} }
	local rt = Routes.build(serverServices(), c, report)
	assert(rt ~= nil, "Routes.build failed: " .. table.concat(report.errors, "; "))
	local fires: { any } = {}
	Outbox._test.capture(function(channel: string, player: any, frame: buffer, refs: { any }?)
		table.insert(fires, { channel = channel, player = player, frame = frame, refs = refs })
	end)
	now = 1000
	Transport._test.setClock(clock)
	Transport._test.attach(rt)
	Dispatch._test.setForwardErrors(false)
	local p: any = { UserId = uid, Name = "SendClient" .. uid, Kick = noop }
	Transport._test.addPlayer(p)
	ClientNet._reset()
	Calls._reset()
	Proxy._reset()
	ClientNet._test.setClock(clock)
	local c2s: { any } = {}
	ClientNet._test.setFire(function(unreliable: boolean, frame: buffer, refs: { any }?)
		table.insert(c2s, { unreliable = unreliable, frame = frame, refs = refs })
	end)
	ClientNet._test.begin()
	local hello = buffer.create(HEADER + 3)
	buffer.writeu16(hello, 2, 1)
	buffer.writeu8(hello, 5, 2)
	buffer.writeu8(hello, 6, C.Op.HELLO)
	buffer.writeu8(hello, 7, C.PROTO)
	Transport._test.frame(false, p, hello, nil)
	Transport._test.flush()
	for _, f in fires do
		if f.player == p then
			ClientNet._test.receive(f.frame, f.refs, f.channel == "Unreliable")
		end
	end
	assert(#ClientNet.routes() == rt.count, "the client did not install the server's MANIFEST")
	local got: { any } = {}
	rt.events.S.Bulk:Connect(function(_: any, ...: any)
		table.insert(got, table.pack(...))
	end)
	return { rt = rt, p = p, c2s = c2s, got = got }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeAll, afterAll, beforeEach = t.beforeAll, t.afterAll, t.beforeEach

	beforeAll(function()
		Loren.Testing.Reset({ Offline = true })
		for i = 1, 3 do
			local part = Instance.new("Part")
			part.Name = "SendClientPart" .. i
			table.insert(parts, part)
		end
	end)

	afterAll(function()
		ClientNet._reset()
		Calls._reset()
		Proxy._reset()
		resetServer()
		Log._reset()
		for _, part in parts do
			part:Destroy()
		end
		table.clear(parts)
		Loren.Testing.Reset()
	end)

	beforeEach(function()
		Log._test.setSink(noop, noop)
	end)

	describe("frames: the lean Fire path against the frozen v2 encoder and ClientNet.fire", function()
		local ALL = {
			"Any",
			"Aim",
			"Input",
			"Name",
			"Pair",
			"UFix",
			"USeq",
			"UStr",
			"Big",
			"Mix",
			"OrdFix",
			"Ref",
			"Arr",
			"RelAim",
			"None",
			"Duo",
			"Nest",
		}

		it("a random mix at the 16 KiB seal: every byte, ref and error matches", function()
			differential("mix 16K", DEFS, limits(), actionsFor(11, 2500, ALL, 25))
		end, { timeout = 60 })

		it("a random mix at a 700 B seal: every seal boundary matches", function()
			differential("mix 700", DEFS, limits({ sealC2S = 700 }), actionsFor(12, 2500, ALL, 60))
		end, { timeout = 60 })

		it("a random mix at the 60 KiB seal with rare flushes: frames grow and the direct path steps aside", function()
			differential("mix 60K", DEFS, limits({ sealC2S = 61440 }), actionsFor(13, 3000, ALL, 400))
		end, { timeout = 60 })

		it("fixed-size routes only, at the message cap and the unreliable seal", function()
			local lim = limits({ sealC2S = 61440, msgBurst = 12 })
			local names = { "Input", "Pair", "UFix", "USeq", "Big", "Mix", "OrdFix", "None", "Duo", "Nest" }
			differential("fixed msgCap", DEFS, lim, actionsFor(14, 1500, names, 5000, 18))
		end, { timeout = 60 })

		it("5000 Inputs through the direct path, frames of 1024 messages", function()
			local list: { Action } = {}
			local rng = Random.new(15)
			for i = 1, 5000 do
				table.insert(list, { fire = "Input", args = GEN.Input(rng) })
				if i % 1700 == 0 then
					table.insert(list, {})
				end
			end
			differential("inputs", DEFS, limits({ sealC2S = 61440 }), list)
		end, { timeout = 60 })

		it("refs: a frame seals at 255 refs and the moved message is re-encoded with index 0", function()
			local list = repeated("Any", args(parts[1], "x", parts[2]), 130)
			differential("refs", DEFS, limits(), list)
		end)

		it("sidecar weight counts against the seal (8 per node plus string bytes)", function()
			local list: { Action } = {}
			for i = 1, 60 do
				local heavy: { [any]: any } = { f = print }
				for k = 1, 30 do
					heavy["key" .. k .. string.rep("w", i % 7)] = k
				end
				table.insert(list, { fire = "Any", args = args(heavy, i) })
			end
			differential("sidecar", DEFS, limits({ sealC2S = 4000 }), list)
		end)

		it("2-byte and 3-byte route heads, in the direct and the scratch path", function()
			local defs: { Def } = {}
			for id = 1, 5000 do
				table.insert(defs, { name = "S" .. id, id = id, kind = K.Signal })
			end
			defs[300] = {
				name = "Far2",
				id = 300,
				build = function(TT: any): { any }
					return { TT.u16, TT.bool }
				end,
			}
			defs[4063] = { name = "Far2Any", id = 4063 }
			defs[4064] = {
				name = "Far3",
				id = 4064,
				unreliable = true,
				ordered = true,
				build = function(TT: any): { any }
					return { TT.u8 }
				end,
			}
			defs[5000] = {
				name = "Far3Str",
				id = 5000,
				build = function(TT: any): { any }
					return { TT.string(20) }
				end,
			}
			local list: { Action } = {}
			for i = 1, 40 do
				table.insert(list, { fire = "Far2", args = args(i * 100, i % 2 == 0) })
				table.insert(list, { fire = "Far2Any", args = args(i, "t") })
				table.insert(list, { fire = "Far3", args = args(i) })
				table.insert(list, { fire = "Far3Str", args = args(string.rep("q", i % 21)) })
			end
			differential("heads", defs, limits(), list)
		end, { timeout = 60 })

		it("an encode that throws leaves the writer dirty; the next Fire resets it fully (no false Cycle)", function()
			local svc = start(DEFS, limits())
			local ev = svc.ClientEvents.Any
			local w = ClientNet._test.scratch()
			local held = { parts[1] }
			w.refs = table.freeze({})
			expect(function()
				ev:Fire(held)
			end).toThrow()
			expect(ClientNet._test.state().encoding).toBe(true)
			w.refs = {}
			ev:Fire(held)
			expect(ClientNet._test.state().encoding).toBe(false)
			expect(Codec._test.visitingCount()).toBe(0)
			ClientNet._test.flushNow()
			local ref = newRef(DEFS, limits())
			expect(refFire(ref, "Any", args(held))).toBeNil()
			refFlush(ref)
			sameFrames("after a throw", shotFrames(shots, false), refFrames(ref.rel))
		end)

		it("the scratch writer is clean after every path", function()
			local svc = start(DEFS, limits())
			local E = svc.ClientEvents
			local function clean()
				local w = ClientNet._test.scratch()
				expect(w.nrefs).toBe(0)
				expect(w.nodes).toBe(0)
				expect(w.sideBytes).toBe(0)
				expect(w.lossy).toBe(0)
				expect(w.errArg).toBe(0)
				expect(w.refs[1]).toBeNil()
				expect(Codec._test.visitingCount()).toBe(0)
			end
			E.Any:Fire({ f = print })
			clean()
			local nested: { any } = { 1, { 2 } }
			E.Any:Fire(parts[1], nested)
			clean()
			pcall(E.Any.Fire, E.Any, cyclic)
			clean()
			pcall(E.Name.Fire, E.Name, 5)
			clean()
			pcall(E.UStr.Fire, E.UStr, string.rep("z", 950))
			clean()
			pcall(E.Input.Fire, E.Input, { seq = 1 })
			clean()
			E.Aim:Fire(Vector3.new(1, 2, 3))
			clean()
		end)

		it("a Fire after ClientNet._reset reaches the new channel; before the manifest it counts EventsLost", function()
			local svc = start(DEFS, limits())
			ClientNet._reset()
			ClientNet._test.setFire(capture)
			svc.ClientEvents.Input:Fire({ seq = 1, moveX = 0, moveZ = 0, yaw = 0, jump = true, sprint = false })
			expect(lost()).toBe(1)
			ClientNet._test.setClock(clock)
			ClientNet._test.loadManifest(makeModel(DEFS, limits()))
			table.clear(shots)
			svc.ClientEvents.Input:Fire({ seq = 7, moveX = 1, moveZ = -1, yaw = 0.5, jump = true, sprint = true })
			svc.ClientEvents.Any:Fire("after")
			ClientNet._test.flushNow()
			expect(#shots).toBe(1)
			local ref = newRef(DEFS, limits())
			refFire(ref, "Input", args({ seq = 7, moveX = 1, moveZ = -1, yaw = 0.5, jump = true, sprint = true }))
			refFire(ref, "Any", args("after"))
			refFlush(ref)
			sameFrames("after reset", shotFrames(shots, false), refFrames(ref.rel))
			expect(lost()).toBe(1)
		end)
	end)

	describe("rate mirror: every decision equals HEAD's per-Fire bucket on the real clock", function()
		local function fireAt(name: string, v: any): boolean
			local before = lost()
			local ev = Proxy.get(SVC).ClientEvents[name]
			ev:Fire(v)
			return lost() == before
		end

		local function netFireAt(name: string, v: any): boolean
			local before = lost()
			ClientNet.fire(routeOf(name), 1, v)
			return lost() == before
		end

		local function valueFor(name: string): any
			return if name == "TightAny" then "a" elseif name == "TightU" then "u" else 7
		end

		local function timeline(seed: number): { Step }
			local rng = Random.new(seed)
			local steps: { Step } = {}
			local t = 1000
			for _ = 1, 260 do
				local roll = rng:NextNumber()
				local dt = if roll < 0.04
					then 0.5 + rng:NextNumber() * 2.5
					elseif roll < 0.3 then 1 / 10
					elseif roll < 0.55 then 1 / 30
					elseif roll < 0.85 then 1 / 60
					else 1 / 240
				local burst = rng:NextNumber() < 0.08
				local fires = if burst then rng:NextInteger(10, 16) else rng:NextInteger(0, 5)
				local times: { number } = {}
				for i = 1, fires do
					times[i] = if burst then t else t + rng:NextNumber() * dt
				end
				table.sort(times)
				for _, at in times do
					table.insert(steps, { at = at, fire = true, dt = 0 })
				end
				t += dt
				table.insert(steps, { at = t, fire = false, dt = dt })
			end
			return steps
		end

		local function replay(
			name: string,
			steps: { Step },
			via: (string, any) -> boolean
		): ({ boolean }, { boolean }, number)
			start(DEFS, limits())
			local v = valueFor(name)
			local head = newBucket(60, 10, now)
			local got: { boolean } = {}
			local want: { boolean } = {}
			local drops = 0
			for _, s in steps do
				now = s.at
				if s.fire then
					table.insert(got, via(name, v))
					local ok: boolean = Bucket.take(head, 1, s.at)
					table.insert(want, ok)
					if not ok then
						drops += 1
					end
				else
					ClientNet._test.heartbeat(s.dt)
				end
			end
			return got, want, drops
		end

		for _, name in { "Tight", "TightAny", "TightU" } do
			it(name .. ": HEAD's accepts, drops and EventsLost at any frame rate, after stalls, in bursts", function()
				for seed = 1, 6 do
					local steps = timeline(seed * 7 + #name)
					for _, via in { fireAt, netFireAt } do
						local got, want, drops = replay(name, steps, via)
						expect(got).toEqual(want)
						expect(lost()).toBe(drops)
						expect(drops > 0).toBe(true)
						expect(drops < #want).toBe(true)
					end
				end
			end, { timeout = 60 })
		end

		it("a Fire between Heartbeats refills up to its own time (a 30 FPS client at its limit)", function()
			start(DEFS, limits())
			for _ = 1, 9 do
				expect(fireAt("Tight", 1)).toBe(true)
			end
			expect(fireAt("Tight", 1)).toBe(false)
			ClientNet._test.heartbeat(0)
			now += 0.025
			expect(fireAt("Tight", 1)).toBe(true)
			expect(fireAt("Tight", 1)).toBe(false)
			expect(lost()).toBe(2)
		end)

		it("a burst after a long stall gets the whole bucket back", function()
			start(DEFS, limits())
			for _ = 1, 9 do
				fireAt("Tight", 1)
			end
			ClientNet._test.heartbeat(1 / 60)
			now += 2
			local accepted = 0
			for _ = 1, 12 do
				if fireAt("Tight", 1) then
					accepted += 1
				end
			end
			expect(accepted).toBe(9)
			expect(lost()).toBe(3)
		end)

		it("after _reset the bucket is full again, stamped at the new connect", function()
			start(DEFS, limits())
			for _ = 1, 12 do
				fireAt("Tight", 1)
			end
			expect(lost()).toBe(3)
			start(DEFS, limits())
			local bucket = ClientNet._test.routeBucket(routeOf("Tight").id)
			expect(bucket.tokens).toBe(9)
			expect(bucket.stamp).toBe(1000)
			local decisions: { boolean } = {}
			for _ = 1, 10 do
				table.insert(decisions, fireAt("Tight", 1))
			end
			expect(decisions).toEqual({ true, true, true, true, true, true, true, true, true, false })
			expect(lost()).toBe(1)
		end)

		it("the unsent cap drops before the mirror is charged", function()
			start(DEFS, limits({ msgBurst = 12 }))
			local cap = ClientNet._test.state().unsentCap
			for i = 1, cap do
				Proxy.get(SVC).ClientEvents.Input:Fire({
					seq = i,
					moveX = 0,
					moveZ = 0,
					yaw = 0,
					jump = false,
					sprint = false,
				})
			end
			now += 1
			local bucket = ClientNet._test.routeBucket(routeOf("Tight").id)
			local tokens, stamp = bucket.tokens, bucket.stamp
			expect(fireAt("Tight", 1)).toBe(false)
			expect(bucket.tokens).toBe(tokens)
			expect(bucket.stamp).toBe(stamp)
			expect(netFireAt("Tight", 1)).toBe(false)
			expect(bucket.tokens).toBe(tokens)
			expect(bucket.stamp).toBe(stamp)
		end)
	end)

	describe("errors: text and call site", function()
		local function expectRaise(fn: any, self: any, want: string, ...: any)
			local err = callSite(fn, self, ...)
			expect(textOf(err)).toBe(want)
			expect(position(err)).toBe(position(callSite(probe, self, ...)))
		end

		it("typed, untyped, unreliable and dot-call errors match HEAD's text and point at the caller", function()
			local svc = start(DEFS, limits())
			local E = svc.ClientEvents
			local pre = P .. SVC .. "."
			expectRaise(E.Input.Fire, E.Input, pre .. "Input:Fire: arg 1 BadType", "nope")
			expectRaise(E.Input.Fire, E.Input, pre .. "Input:Fire: arg 1 Missing", { seq = 1 })
			local good = { seq = 1, moveX = 0, moveZ = 0, yaw = 0, jump = true, sprint = false }
			expectRaise(E.Input.Fire, E.Input, pre .. "Input:Fire: arg 2 TooManyValues", good, 1)
			expectRaise(E.Pair.Fire, E.Pair, pre .. "Pair:Fire: arg 1 Range", 256, Vector3.zero, true)
			expectRaise(E.Pair.Fire, E.Pair, pre .. "Pair:Fire: arg 2 NonFinite", 1, Vector3.new(NAN, 0, 0), true)
			expectRaise(E.Pair.Fire, E.Pair, pre .. "Pair:Fire: arg 3 Missing", 1, Vector3.zero)
			expectRaise(E.Name.Fire, E.Name, pre .. "Name:Fire: arg 1 TooLong", string.rep("n", 65))
			expectRaise(E.Name.Fire, E.Name, pre .. "Name:Fire: arg 1 BadUtf8", "\255")
			expectRaise(E.Any.Fire, E.Any, pre .. "Any:Fire: arg 21 TooManyArgs", table.unpack(table.create(21, 0)))
			expectRaise(E.Any.Fire, E.Any, pre .. "Any:Fire: arg 2 Cycle", 1, cyclic)
			expectRaise(E.Any.Fire, E.Any, pre .. "Any:Fire: arg 1 TooDeep", deep)
			expectRaise(E.Aim.Fire, E.Aim, pre .. "Aim:Fire: arg 1 BadType", "not a vector")
			expectRaise(E.USeq.Fire, E.USeq, pre .. "USeq:Fire: arg 1 Range", -1)
			expectRaise(E.None.Fire, E.None, pre .. "None:Fire: arg 1 TooManyValues", 1)
			expectRaise(E.None.Fire, E.None, pre .. "None:Fire: arg 1 TooManyValues", nil)
			expectRaise(E.Duo.Fire, E.Duo, pre .. "Duo:Fire: arg 1 Range", 256, good)
			expectRaise(E.Duo.Fire, E.Duo, pre .. "Duo:Fire: arg 2 BadType", 1, "x")
			expectRaise(E.Duo.Fire, E.Duo, pre .. "Duo:Fire: arg 3 TooManyValues", 1, good, 1)
			expectRaise(E.Nest.Fire, E.Nest, pre .. "Nest:Fire: arg 1 Missing", { a = 1 })
			expectRaise(E.Nest.Fire, E.Nest, pre .. "Nest:Fire: arg 1 Range", { a = 1, inner = { x = 0.5, y = true } })
			local long = string.rep("u", 900)
			local ref = newRef(DEFS, limits())
			expectRaise(E.UStr.Fire, E.UStr, refFire(ref, "UStr", args(long)) :: string, long)
			local huge = string.rep("p", 70000)
			expectRaise(E.Any.Fire, E.Any, refFire(ref, "Any", args(huge)) :: string, huge)
			local wide: { [string]: any } = { f = print }
			for k = 1, 1000 do
				wide[string.rep("k", 60) .. k] = k
			end
			expectRaise(E.Any.Fire, E.Any, refFire(ref, "Any", args(wide)) :: string, wide)
			local dot = P .. "Call Svc.ClientEvents.Input:Fire(...) with ':' (a '.' call shifts every argument)"
			expectRaise(E.Input.Fire, nil, dot, good)
			expectRaise(E.Input.Fire, 5, dot)
			E.Any.Fire()
			ClientNet._test.flushNow()
			expect(#shots).toBe(1)
			expect(buffer.tostring(shots[1].frame)).toBe(string.char(0, 0, 1, 0, 0, 2, 1, 0))
		end)

		it("the same errors on the scratch path of a fixed route (open frame full) and nothing is queued", function()
			local svc = start(DEFS, limits({ msgBurst = 2 }))
			local E = svc.ClientEvents
			local good = { seq = 1, moveX = 0, moveZ = 0, yaw = 0, jump = true, sprint = false }
			E.Input:Fire(good)
			expect(ClientNet._test.state().relOpen).toBe(1)
			local pre = P .. SVC .. "."
			expectRaise(E.Input.Fire, E.Input, pre .. "Input:Fire: arg 1 BadType", 3)
			expectRaise(E.Input.Fire, E.Input, pre .. "Input:Fire: arg 2 TooManyValues", good, good)
			expectRaise(E.Pair.Fire, E.Pair, pre .. "Pair:Fire: arg 3 BadType", 1, Vector3.zero, 1)
			expectRaise(E.None.Fire, E.None, pre .. "None:Fire: arg 1 TooManyValues", 1)
			expect(ClientNet._test.state().unsent).toBe(1)
			expect(ClientNet._test.state().relQueued).toBe(0)
		end)

		it("a failed Ordered Fire still takes its seq, as before", function()
			local svc = start(DEFS, limits())
			local E = svc.ClientEvents
			E.USeq:Fire(1)
			pcall(E.USeq.Fire, E.USeq, -1)
			E.USeq:Fire(3)
			E.OrdFix:Fire(9, true)
			pcall(E.OrdFix.Fire, E.OrdFix, 999, true)
			E.OrdFix:Fire(8, false)
			ClientNet._test.flushNow()
			local ref = newRef(DEFS, limits())
			refFire(ref, "USeq", args(1))
			refFire(ref, "USeq", args(-1))
			refFire(ref, "USeq", args(3))
			refFire(ref, "OrdFix", args(9, true))
			refFire(ref, "OrdFix", args(999, true))
			refFire(ref, "OrdFix", args(8, false))
			refFlush(ref)
			sameFrames("ordered", shotFrames(shots, true), refFrames(ref.unr))
		end)
	end)

	describe("module-local copies", function()
		it("varintSize matches Codec.varintSize for every value up to VARINT_MAX and past it", function()
			local mine, theirs = ClientNet._test.varintSize, Codec.varintSize
			local bad = 0
			for v = 0, LIM.VARINT_MAX do
				if mine(v) ~= theirs(v) then
					bad += 1
				end
				if v % 262144 == 0 then
					task.wait()
				end
			end
			expect(bad).toBe(0)
			for _, v in { LIM.VARINT_MAX + 1, 4194304, 2 ^ 31, 1e12 } do
				expect(mine(v)).toBe(theirs(v))
			end
		end, { timeout = 60 })
	end)

	describe("B3: the C->S seal comes from the manifest", function()
		it("the client seals at the manifest's sealC2S, clamped to the server's envelope bound", function()
			start(DEFS, limits({ sealC2S = 20000 }))
			expect(ClientNet._test.state().seal).toBe(20000)
			expect(ClientNet._test.state().relLim).toBe(20000)
			expect(ClientNet._test.state().unrLim).toBe(LIM.UNRELIABLE_SEAL)
			start(DEFS, limits({ sealC2S = 100000 }))
			expect(ClientNet._test.state().seal).toBe(LIM.C2S_MAX_FRAME)
			start(DEFS, limits())
			expect(ClientNet._test.state().seal).toBe(16384)
			ClientNet._reset()
			expect(ClientNet._test.state().seal).toBe(LIM.C2S_SEAL)
			expect(LIM.C2S_SEAL).toBe(61440)
			local list = repeated("Any", args(string.rep("v", 115)), 500)
			differential("seal 20000", DEFS, limits({ sealC2S = 20000 }), list)
			differential("seal 61440", DEFS, limits({ sealC2S = 61440 }), list)
			local run = playProxy(DEFS, limits({ sealC2S = 61440 }), list)
			expect(#run.frames).toBe(1)
			expect(buffer.len(run.frames[1].frame)).toBe(60005)
			local old = playProxy(DEFS, limits({ sealC2S = 16384 }), list)
			expect(#old.frames).toBe(4)
		end, { timeout = 30 })

		it("the server's manifest carries 61440 in the existing sealC2S field; the format is unchanged", function()
			resetServer()
			local report: any = { side = "Server", errors = {}, warnings = {} }
			local rt = Routes.build(serverServices(), Config.get(), report)
			assert(rt ~= nil, "Routes.build failed: " .. table.concat(report.errors, "; "))
			expect(rt.model.limits.sealC2S).toBe(61440)
			local bytes = Manifest.encode(rt.model)
			local decoded, why = Manifest.decode(bytes, 0, buffer.len(bytes))
			expect(why).toBeNil()
			expect(decoded.limits.sealC2S).toBe(61440)
			expect(buffer.tostring(Manifest.encode(decoded))).toBe(buffer.tostring(bytes))
			local checkReport: any = { side = "Server", errors = {}, warnings = {} }
			Config.check(checkReport)
			expect(#checkReport.errors).toBe(0)
			resetServer()
		end)

		it("a 60 KiB C->S frame is admitted and parsed by the server: no violation, every event in order", function()
			resetServer()
			local c = Config.get()
			Limits.configure(c)
			Violations.configure(c)
			local report: any = { side = "Server", errors = {}, warnings = {} }
			local rt = Routes.build(serverServices(), c, report)
			assert(rt ~= nil, "Routes.build failed: " .. table.concat(report.errors, "; "))
			local fires: { any } = {}
			Outbox._test.capture(function(channel: string, player: any, frame: buffer, refs: { any }?)
				table.insert(fires, { channel = channel, player = player, frame = frame, refs = refs })
			end)
			now = 1000
			Transport._test.setClock(clock)
			Transport._test.attach(rt)
			Dispatch._test.setForwardErrors(false)
			local p: any = { UserId = 4801, Name = "SendClient4801", Kick = noop }
			Transport._test.addPlayer(p)
			ClientNet._reset()
			Calls._reset()
			Proxy._reset()
			ClientNet._test.setClock(clock)
			local c2s: { any } = {}
			ClientNet._test.setFire(function(unreliable: boolean, frame: buffer, refs: { any }?)
				table.insert(c2s, { unreliable = unreliable, frame = frame, refs = refs })
			end)
			ClientNet._test.begin()
			local hello = buffer.create(HEADER + 3)
			buffer.writeu16(hello, 2, 1)
			buffer.writeu8(hello, 5, 2)
			buffer.writeu8(hello, 6, C.Op.HELLO)
			buffer.writeu8(hello, 7, C.PROTO)
			Transport._test.frame(false, p, hello, nil)
			Transport._test.flush()
			for _, f in fires do
				if f.player == p then
					ClientNet._test.receive(f.frame, f.refs, f.channel == "Unreliable")
				end
			end
			assert(#ClientNet.routes() == rt.count, "the client did not install the server's MANIFEST")
			expect(ClientNet._test.state().seal).toBe(61440)
			local got: { string } = {}
			rt.events.S.Bulk:Connect(function(_: any, s: any)
				table.insert(got, s)
			end)
			local ev = {}
			local fire = ClientNet.eventFire(routeOf("Bulk"), ev, "S.ClientEvents.Bulk")
			local sent: { string } = {}
			for i = 1, 500 do
				local s = string.format("%03d", i) .. string.rep("b", 112)
				sent[i] = s
				fire(ev, s)
			end
			ClientNet._test.flushNow()
			expect(#c2s).toBe(1)
			local frame = c2s[1].frame
			expect(buffer.len(frame)).toBe(60005)
			expect(buffer.len(frame) > 16384).toBe(true)
			local ps = Transport._test.state(p)
			local violations = ps.viol.total
			local tokens = ps.lim.bytes.tokens
			local stats = Transport.getStats()
			Transport._test.frame(false, p, frame, c2s[1].refs)
			expect(ps.viol.total).toBe(violations)
			expect(ps.lim.bytes.tokens).toBe(tokens - buffer.len(frame))
			expect(Transport.getStats().FramesIn).toBe(stats.FramesIn + 1)
			expect(Transport.getStats().MessagesIn).toBe(stats.MessagesIn + 500)
			expect(got).toEqual(sent)
			Outbox._test.capture(nil)
			resetServer()
		end, { timeout = 30 })

		it("one frame takes exactly 2,048 sidecar nodes, the server admits it, the next table seals it", function()
			local pair = connectPair(4802)
			expect(ClientNet._test.state().seal).toBe(61440)
			local ev = {}
			local fire = ClientNet.eventFire(routeOf("Bulk"), ev, "S.ClientEvents.Bulk")
			for i = 1, 17 do
				local t: { [string]: any } = { f = print }
				for k = 1, 127 do
					t[string.format("k%03d", k)] = i
				end
				fire(ev, t)
			end
			local s = ClientNet._test.state()
			expect(s.relQueued).toBe(1)
			expect(s.relOpen).toBe(1)
			expect(s.relNodes).toBe(128)
			ClientNet._test.flushNow()
			expect(#pair.c2s).toBe(2)
			local first, second = pair.c2s[1], pair.c2s[2]
			expect(buffer.readu16(first.frame, 2)).toBe(16)
			expect(buffer.readu8(first.frame, 4)).toBe(16)
			expect(buffer.readu16(second.frame, 2)).toBe(1)
			expect(buffer.readu8(second.frame, 4)).toBe(1)
			local ps = Transport._test.state(pair.p)
			local violations = ps.viol.total
			local stats = Transport.getStats()
			Transport._test.frame(false, pair.p, first.frame, first.refs)
			Transport._test.frame(false, pair.p, second.frame, second.refs)
			expect(ps.viol.total).toBe(violations)
			expect(Transport.getStats().FramesDropped).toBe(stats.FramesDropped)
			expect(Transport.getStats().MessagesIn).toBe(stats.MessagesIn + 17)
			expect(#pair.got).toBe(17)
			for i = 1, 17 do
				local t = pair.got[i][1]
				expect(t.k001).toBe(i)
				expect(t.k127).toBe(i)
				expect(t.f).toBeNil()
			end
			Outbox._test.capture(nil)
			resetServer()
		end, { timeout = 30 })

		it("one frame takes exactly 255 refs, the server admits it, the next ref seals it", function()
			local pair = connectPair(4803)
			local ev = {}
			local fire = ClientNet.eventFire(routeOf("Bulk"), ev, "S.ClientEvents.Bulk")
			for i = 1, 86 do
				fire(ev, i, parts[1], parts[2], parts[3])
			end
			ClientNet._test.flushNow()
			expect(#pair.c2s).toBe(2)
			local first, second = pair.c2s[1], pair.c2s[2]
			expect(buffer.readu16(first.frame, 2)).toBe(85)
			expect(buffer.readu8(first.frame, 4)).toBe(255)
			expect(#first.refs).toBe(255)
			expect(buffer.readu16(second.frame, 2)).toBe(1)
			expect(buffer.readu8(second.frame, 4)).toBe(3)
			local ps = Transport._test.state(pair.p)
			local violations = ps.viol.total
			local stats = Transport.getStats()
			Transport._test.frame(false, pair.p, first.frame, first.refs)
			Transport._test.frame(false, pair.p, second.frame, second.refs)
			expect(ps.viol.total).toBe(violations)
			expect(Transport.getStats().FramesDropped).toBe(stats.FramesDropped)
			expect(#pair.got).toBe(86)
			for i = 1, 86 do
				local a = pair.got[i]
				expect(a.n).toBe(4)
				expect(a[1]).toBe(i)
				expect(a[2]).toBe(parts[1])
				expect(a[3]).toBe(parts[2])
				expect(a[4]).toBe(parts[3])
			end
			Outbox._test.capture(nil)
			resetServer()
		end, { timeout = 30 })
	end)

	describe("memory: pooled frames and the scratch writer", function()
		it("a recycled frame keeps a 64 KiB buffer and drops a bigger one", function()
			local svc = start(DEFS, limits({ sealC2S = 61440 }))
			expect(#ClientNet._test.framePool() < 60).toBe(true)
			for _ = 1, 500 do
				svc.ClientEvents.Any:Fire(string.rep("v", 115))
			end
			ClientNet._test.flushNow()
			expect(#shots).toBe(1)
			expect(buffer.len(shots[1].frame)).toBe(60005)
			local pool = ClientNet._test.framePool()
			expect(pool[#pool]).toBe(65536)
			svc.ClientEvents.Any:Fire(string.rep("w", 65524))
			ClientNet._test.flushNow()
			expect(#shots).toBe(2)
			expect(buffer.len(shots[2].frame)).toBe(65538)
			pool = ClientNet._test.framePool()
			expect(pool[#pool]).toBe(1024)
			for _, cap in pool do
				expect(cap <= 65536).toBe(true)
			end
		end)

		it("the scratch writer is small again after an oversized call or Fire", function()
			local defs = table.clone(DEFS)
			table.insert(defs, { name = "Up", id = #DEFS + 1, kind = K.Method })
			local svc = start(defs, limits())
			local E = svc.ClientEvents
			local keep = 2 * LIM.C2S_MAX_MESSAGE
			local sw = ClientNet._test.scratch()
			ClientNet.call(routeOf("Up"), false, 1, string.rep("x", 200000)):catch(noop)
			expect(sw.cap <= keep).toBe(true)
			expect(ClientNet._test.state().unsent).toBe(0)
			expect((pcall(E.Any.Fire, E.Any, string.rep("y", 200000)))).toBe(false)
			expect(sw.cap <= keep).toBe(true)
			expect((pcall(ClientNet.fire, routeOf("Any"), 1, string.rep("z", 200000)))).toBe(false)
			expect(sw.cap > keep).toBe(true)
			local good = { seq = 1, moveX = 0, moveZ = 0, yaw = 0, jump = true, sprint = false }
			E.Input:Fire(good)
			expect(sw.cap > keep).toBe(true)
			E.Any:Fire("small")
			expect(sw.cap <= keep).toBe(true)
			ClientNet._test.flushNow()
			local ref = newRef(defs, limits())
			refFire(ref, "Input", args(good))
			refFire(ref, "Any", args("small"))
			refFlush(ref)
			sameFrames("after the oversized payloads", shotFrames(shots, false), refFrames(ref.rel))
			expect(lost()).toBe(0)
		end)
	end)
end
