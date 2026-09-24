--!strict
--!optimize 2
--[[
	Errors (owner lane: lifecycle): error codes to 1.5.1-compatible rejection strings, the frozen
	ErrorInfo record, incident ids and the Loren.Reject sentinel.
	Spec: IMPLEMENTATION.md sections 3.3 and 5.

	Every rejection is (message: string, info: ErrorInfo). The message keeps the 1.5.1 strings
	("(LORENঌ) Timeout", "Denied", a middleware reason), so code that compares the first value keeps
	working. No side effects on require (a Random is a value, not an Instance).
]]

local C = require(script.Parent.Constants)
local Types = require(script.Parent.Types)

type ErrorInfo = Types.ErrorInfo
type RejectSentinel = Types.RejectSentinel

local ERR = C.Err
local MSG: { [string]: string } = C.Msg :: any
local NAME: { [number]: string } = C.ErrName :: any
local MSG_MAX = C.Limit.ERR_MSG_MAX

local Errors = {}

-- Loren.Errors: every error name maps to itself (compare with info.Code).
local public: { [string]: string } = {}
for _, name in NAME do
	public[name] = name
end
Errors.Public = table.freeze(public)

local rng = Random.new()

-- The private metatable that marks a Loren.Reject sentinel.
local RejectMeta = table.freeze({
	__tostring = function(self: any): string
		return self.Message
	end,
})

-- First ERR_MSG_MAX bytes of s. A cut never splits a UTF-8 sequence (the result may be up to 3 bytes
-- shorter); bytes that are not valid UTF-8 are cut at exactly ERR_MSG_MAX.
function Errors.truncate(s: string): string
	if #s <= MSG_MAX then
		return s
	end
	local cut = MSG_MAX
	for _ = 1, 3 do
		local b = string.byte(s, cut + 1) :: number
		if b < 0x80 or b >= 0xC0 then
			break -- the first dropped byte starts a character
		end
		cut -= 1
	end
	local first = string.byte(s, cut + 1) :: number
	if first >= 0x80 and first < 0xC0 then
		cut = MSG_MAX -- more than 3 continuation bytes: not UTF-8
	end
	return string.sub(s, 1, cut)
end

-- Eight lowercase hex digits, the form users see in "(LORENঌ) InternalError [a1b2c3d4]".
function Errors.hex(incident: number): string
	return string.format("%08x", incident)
end

-- A uniform u32 (server incident ids).
function Errors.newIncident(): number
	return rng:NextInteger(0, 0xFFFFFFFF)
end

-- The rejection string for a code (IMPLEMENTATION.md section 3.3 table).
function Errors.message(code: number, msg: string?, incident: number?, arg: number?): string
	if code == ERR.Rejected then
		return msg or ""
	elseif code == ERR.Denied then
		return msg or MSG.Denied
	elseif code == ERR.BadRequest or code == ERR.BadArgument then
		local text = if code == ERR.BadRequest then MSG.BadRequest else MSG.BadArgument
		if arg and arg > 0 then
			text ..= ": arg " .. tostring(arg)
		end
		if msg then
			text ..= " (" .. msg .. ")"
		end
		return text
	elseif code == ERR.InternalError or code == ERR.BadResult then
		local text = if code == ERR.InternalError then MSG.InternalError else MSG.BadResult
		if incident then
			text ..= " [" .. Errors.hex(incident) .. "]"
		end
		if msg then
			text ..= ": " .. msg
		end
		return text
	end
	local name = NAME[code]
	local text = if name then MSG[name] else nil
	return text or MSG.InternalError
end

-- The frozen second value of a rejection. An unknown code is reported as InternalError.
function Errors.info(
	code: number,
	service: string,
	member: string,
	message: string,
	data: any,
	incident: number?,
	arg: number?
): ErrorInfo
	local name = NAME[code]
	local codeId = code
	if name == nil then
		name = "InternalError"
		codeId = ERR.InternalError
	end
	local info: ErrorInfo = {
		Code = name,
		CodeId = codeId,
		Message = message,
		Service = service,
		Member = member,
		Incident = if incident then Errors.hex(incident) else nil,
		Arg = arg,
		Data = data,
	}
	return table.freeze(info) :: any
end

-- (message, info) for a rejection; info.Message is the same string.
function Errors.rejection(
	code: number,
	service: string,
	member: string,
	msg: string?,
	data: any,
	incident: number?,
	arg: number?
): (string, ErrorInfo)
	local message = Errors.message(code, msg, incident, arg)
	return message, Errors.info(code, service, member, message, data, incident, arg)
end

-- Loren.Reject(msg, data?): an intended failure. Works returned or thrown (error(Loren.Reject(...))
-- keeps the table as the error value). The message is truncated to ERR_MSG_MAX bytes.
function Errors.reject(msg: any, data: any?): RejectSentinel
	local text: string
	if msg == nil then
		text = ""
	elseif type(msg) == "string" then
		text = msg
	else
		text = tostring(msg)
	end
	local sentinel = setmetatable({ Message = Errors.truncate(text), Data = data }, RejectMeta)
	return table.freeze(sentinel) :: any
end

function Errors.isReject(v: any): boolean
	return type(v) == "table" and getmetatable(v) == RejectMeta
end

return table.freeze(Errors)
