'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { runDoctor, scanText, tokenize, structure, applyEdits } = require('../lib/lint');
const h = require('./fixtures/helpers');

test.after(h.cleanup);

const colon = (src, opts) => scanText(src, opts).filter((i) => i.kind === 'colon-middleware');
const fixAll = (src) => applyEdits(src, colon(src).filter((i) => !i.manual).map((i) => i.edit));
const kinds = (issues) => issues.map((i) => `${i.kind}:${i.line}`);

// Tokenizer and structure -------------------------------------------------------------------------

test('tokenizer drops comments and keeps strings as single tokens', () => {
	const src = [
		'-- function S.Middleware:A(p) end',
		'--[==[ function S.Middleware:B(p) end ]==]',
		'local a = "function S.Middleware:C(p) end"',
		"local b = 'x\\'y'",
		'local c = [[ function S.Middleware:D(p) end ]]',
		'local d = `{S.Middleware} {"}"} text`',
		'local e = 1e-5 + 0x1F + .5',
	].join('\n');
	const toks = tokenize(src);
	const names = toks.filter((t) => t.type === 'name').map((t) => t.value);
	assert.deepEqual(names, ['a', 'b', 'c', 'd', 'e']);
	assert.equal(toks.filter((t) => t.type === 'str').length, 4);
	assert.deepEqual(toks.filter((t) => t.type === 'num').map((t) => t.value), ['1e-5', '0x1F', '.5']);
	assert.equal(toks.find((t) => t.value === 'e').line, 7);
	assert.equal(colon(src).length, 0);
});

test('structure matches blocks, including if-expressions that have no end', () => {
	const src = [
		'local x = if a then 1 else 2',
		'local function f()',
		'\tlocal y = if b then function() if c then return end end else nil',
		'\trepeat local z = 1 until if z then true else false',
		'\twhile true do break end',
		'end',
		'return f',
	].join('\n');
	const toks = tokenize(src);
	const S = structure(toks);
	const fn = toks.findIndex((t) => t.value === 'function');
	assert.equal(toks[S.match[fn]].line, 6, 'local function f() closes on line 6');
	const ret = toks.findIndex((t) => t.value === 'return' && t.line === 7);
	assert.equal(S.blk[ret], 0, 'the file ends at the top level');
});

// Colon middleware --------------------------------------------------------------------------------

test('function X.Middleware:Name( is found at any arity and rewritten to a dot', () => {
	const src = [
		'local S = { Client = {}, Middleware = {} }',
		'function S.Client:A() end',
		'function S.Client:B(p) end',
		'function S.Client:C(p, a, b) end',
		'function S.Middleware:A() return true end',
		'function S.Middleware:B(p) return true end',
		'function S.Middleware:C(p, a, b) return true end',
		'return S',
	].join('\n');
	const found = colon(src, { file: 'src/server/Services/S.luau' });
	assert.deepEqual(found.map((i) => `${i.name}:${i.line}:${i.severity}`), ['A:5:fixable', 'B:6:fixable', 'C:7:fixable']);
	assert.equal(found[2].preview, 'function S.Middleware.C(p, a, b)');
	assert.match(found[2].message, /S\.Middleware:C is colon-style.*denies every C call.*Dot style: function S\.Middleware\.C\(p, a, b\)/);
	const fixed = fixAll(src);
	assert.equal(
		fixed.split('\n').slice(4, 7).join('\n'),
		['function S.Middleware.A() return true end', 'function S.Middleware.B(p) return true end', 'function S.Middleware.C(p, a, b) return true end'].join('\n'),
	);
	assert.equal(colon(fixed).length, 0);
});

test('Name = function(self ...) inside a Middleware table drops self; nested functions are untouched', () => {
	const src = [
		'local S = {',
		'\tMiddleware = {',
		'\t\tA = function(self)',
		'\t\t\treturn true',
		'\t\tend,',
		'\t\tB = function(self: any, player: Player, n: { [string]: number })',
		'\t\t\tlocal obj = { check = function(self) return self end }',
		'\t\t\tlocal g = function(self, x) return x end',
		'\t\t\tsetmetatable({}, { __index = function(self, k) return nil end })',
		'\t\t\treturn obj:check() ~= nil',
		'\t\tend;',
		'\t\t["C"] = function(',
		'\t\t\tself,',
		'\t\t\tplayer',
		'\t\t)',
		'\t\t\treturn player',
		'\t\tend,',
		'\t\tD = function(player, self) return true end,',
		'\t\tE = helper(function(self) end),',
		'\t},',
		'}',
		'return S',
	].join('\n');
	const found = colon(src);
	assert.deepEqual(found.map((i) => `${i.name}:${i.line}`), ['A:3', 'B:6', 'C:12']);
	assert.equal(found[1].preview, 'B = function(player: Player, n: { [string]: number })');
	const fixed = fixAll(src).split('\n');
	assert.equal(fixed[2], '\t\tA = function()');
	assert.equal(fixed[5], '\t\tB = function(player: Player, n: { [string]: number })');
	assert.equal(fixed[6], '\t\t\tlocal obj = { check = function(self) return self end }', 'nested method untouched');
	assert.equal(fixed[7], '\t\t\tlocal g = function(self, x) return x end', 'nested local function untouched');
	assert.equal(fixed[8], '\t\t\tsetmetatable({}, { __index = function(self, k) return nil end })');
	assert.deepEqual(fixed.slice(11, 15), ['\t\t["C"] = function(', '\t\t\tplayer', '\t\t)', '\t\t\treturn player']);
	// C's rewrite joined two lines, so D and E moved up by one
	assert.equal(fixed[16], '\t\tD = function(player, self) return true end,', 'self as a later parameter is not middleware style');
	assert.equal(fixed[17], '\t\tE = helper(function(self) end),');
});

test('explicit-self dot forms and multi-line signatures', () => {
	const src = [
		'local S = {}',
		'function S.Middleware.A(self, p)',
		'\treturn p',
		'end',
		'S.Middleware.B = function(self, p, q)',
		'\treturn q',
		'end',
		'function S.Middleware',
		'\t:C(',
		'\t\tp,',
		'\t\tq',
		'\t)',
		'\treturn q',
		'end',
		'function S.Middleware.D(p, q) return q end',
		'return S',
	].join('\n');
	const found = colon(src);
	assert.deepEqual(found.map((i) => `${i.name}:${i.line}`), ['A:2', 'B:5', 'C:8']);
	assert.equal(found[2].preview, 'function S.Middleware.C(p, q)');
	const fixed = fixAll(src).split('\n');
	assert.equal(fixed[1], 'function S.Middleware.A(p)');
	assert.equal(fixed[4], 'S.Middleware.B = function(p, q)');
	assert.deepEqual(fixed.slice(7, 9), ['function S.Middleware', '\t.C(']);
	assert.equal(colon(fixAll(src)).length, 0);
});

test('a body that uses self is reported for a hand rewrite, never auto-fixed', () => {
	const src = [
		'local S = {}',
		'function S.Middleware:A(p)',
		'\treturn self:Check(p)',
		'end',
		'function S.Middleware:B(p)',
		'\tlocal t = { self = 1 }',
		'\tlocal u = t.self',
		'\tlocal o = {}',
		'\tfunction o:m() return self end',
		'\treturn p',
		'end',
		'function S.Middleware:C(p)',
		'\tlocal self = S',
		'\treturn self:Check(p)',
		'end',
		'return S',
	].join('\n');
	const found = colon(src);
	assert.deepEqual(found.map((i) => `${i.name}:${i.manual}`), ['A:true', 'B:false', 'C:false']);
	assert.equal(found[0].edit, null);
	assert.match(found[0].message, /Its body uses self, so rewrite it by hand \(use module for the Service\)/);
	assert.match(fixAll(src), /function S\.Middleware:A\(p\)/, 'A left as it was');
});

test('self in an interpolated string, a type, or after a nested-block local is a use (hand rewrite)', () => {
	const fn = (sig, body) => `local S = {}\nfunction S.Middleware${sig}\n${body}\n\treturn true\nend\nreturn S\n`;
	const manual = (src) => colon(src).map((i) => i.manual);
	assert.deepEqual(manual(fn(':A(p)', '\tprint(`{self.Name} buys`)')), [true], 'interpolation');
	assert.deepEqual(manual(fn(':A(p)', '\tprint(`a {`b {self}`} c`)')), [true], 'nested interpolation');
	assert.deepEqual(manual(fn(':A(p)', '\tprint(`{p.Name} {x.self} \\{self}`)')), [false], 'x.self and an escaped brace are not uses');
	assert.deepEqual(manual(fn(':A(p: typeof(self))', '')), [true], 'parameter type');
	assert.deepEqual(manual(fn(':A(p): typeof(self)', '')), [true], 'return type');
	assert.deepEqual(manual(fn(':A(p)', '\tif p then local self = 1 end\n\tprint(self)')), [true], 'a nested local only shadows its block');
	assert.deepEqual(manual(fn(':A(p)', '\tlocal self = S\n\tprint(self)')), [false], 'a body-level local shadows the rest');
	assert.deepEqual(manual(fn(':A(p)', '\tlocal self: typeof(S) = self or S\n\tprint(self)')), [true], 'but its value may read self');
	assert.deepEqual(manual(fn('.A(self: typeof(S), p)', '\tprint(p)')), [false], "the dropped self parameter's own type is not a use");
	const src = fn(':A(p)', '\tprint(`{self.Name}`)');
	assert.equal(fixAll(src), src, 'never rewritten');
	// a function whose `end` cannot be found (a syntax error) is never auto-fixed
	assert.deepEqual(manual('local S = {}\nfunction S.Middleware:A(p)\n\treturn (p\nreturn S\n'), [true]);
});

test('a bare local Middleware is only linted when the file assigns it to a module', () => {
	const own = [
		'local Middleware = {}',
		'Middleware.__index = Middleware',
		'function Middleware:Greet(name) return name end',
		'Middleware.Run = function(self, x) return x end',
		'local Other = { Middleware = 1 }',
		'return Middleware',
	].join('\n');
	assert.deepEqual(colon(own), [], "the user's own class keeps its methods");
	assert.deepEqual(colon('local Middleware = { Greet = function(self, name) return name end }\nreturn Middleware\n'), []);

	const handed = 'local Middleware = {}\nfunction Middleware:Buy(p) return true end\nlocal S = { Middleware = Middleware }\nreturn S\n';
	assert.deepEqual(colon(handed).map((i) => `${i.name}:${i.line}`), ['Buy:2']);
	const assigned = 'local S = {}\nlocal Middleware = { Buy = function(self, p) return true end }\nS.Middleware = Middleware\nreturn S\n';
	assert.deepEqual(colon(assigned).map((i) => `${i.name}:${i.line}`), ['Buy:2']);
	assert.match(fixAll(assigned), /Buy = function\(p\)/);
});

test('Middleware calls and other colon methods are not flagged', () => {
	const src = [
		'local S = {}',
		'function S:Middleware(p) end',
		'function S.Client:Buy(p) end',
		'local ok = S.Middleware[name](player, ...)',
		'local ok2 = S.Middleware.Buy(player)',
		'function Other.Middleware_Thing:X(p) end',
		'return S',
	].join('\n');
	assert.deepEqual(colon(src), []);
});

// Service checks ------------------------------------------------------------------------------------

test('reserved Client names, orphan Middleware and Spec keys are warnings', () => {
	const src = [
		'local Shop = {',
		'\tClient = {',
		'\t\tSignals = function() end,',
		'\t\tServer = nil,',
		'\t},',
		'\tClientEvents = { "Pinged" },',
		'\tSignals = { "Bought" },',
		'\tMiddleware = { Pinged = function(p) end, Bye = function(p) end },',
		'\tSpec = { Buy = Loren.Method(), Bought = Loren.Signal(), Pingd = Loren.Event() },',
		'}',
		'function Shop.Client:Buy(p) end',
		'function Shop.Client:Try(p) end',
		'function Shop.Middleware.Buyy(p) end',
		'Shop.Middleware.Buy = function(p) end',
		'return Shop',
	].join('\n');
	const issues = scanText(src, { file: 'src/server/Services/Shop.luau', service: true });
	assert.deepEqual(kinds(issues), ['reserved-name:3', 'orphan-middleware:8', 'orphan-spec:9', 'reserved-name:12', 'orphan-middleware:13']);
	assert.ok(issues.every((i) => i.severity === 'warn' && i.file === 'src/server/Services/Shop.luau'));
	assert.match(issues[0].message, /Shop\.Client\.Signals uses a reserved name/);
	assert.match(issues[2].message, /Shop\.Spec\.Pingd matches no Client method, ClientEvent or Signal.*Did you mean 'Pinged'\?/);
	assert.match(issues[4].message, /Shop\.Middleware\.Buyy matches no Client method or ClientEvent.*Did you mean 'Buy'\?/);
});

test('orphan checks are skipped when the Client table is built at run time', () => {
	const src = 'local API = require(script.API)\nlocal S = { Client = API, Middleware = { Buy = function(p) end } }\nreturn S';
	assert.deepEqual(scanText(src, { service: true }), []);
	const events = 'local S = { ClientEvents = EVENTS, Middleware = { Buy = function(p) end } }\nreturn S';
	assert.deepEqual(scanText(events, { service: true }), []);
});

test('Spec/ClientEvents keys: 1.5.1-looking values warn; 2.0 values only warn in legacy mode', () => {
	const old = 'local S = { Spec = { MaxHealth = 100 }, ClientEvents = { Last = 0 } }\nreturn S';
	const found = scanText(old, { service: true }).filter((i) => i.kind === 'reserved-key');
	assert.deepEqual(found.map((i) => i.message.split(' ')[0]), ['module.Spec', 'module.ClientEvents']);

	const modern = 'local S = { ClientEvents = { "Say" }, Spec = { Say = Loren.Event() } }\nreturn S';
	assert.deepEqual(scanText(modern, { service: true }).filter((i) => i.kind === 'reserved-key'), []);
	assert.equal(scanText(modern, { service: true, legacy: true }).filter((i) => i.kind === 'reserved-key').length, 2);

	const empty = 'local S = { Spec = {}, ClientEvents = {} }\nS.Spec = nil\nreturn S';
	assert.deepEqual(scanText(empty, { service: true, legacy: true }), []);
	const unknown = 'local S = { Spec = require(script.Spec) }\nreturn S';
	assert.deepEqual(scanText(unknown, { service: true }), []);
	const statement = 'local S = {}\nS.ClientEvents = { Count = 1 }\nreturn S';
	assert.deepEqual(kinds(scanText(statement, { service: true })), ['reserved-key:2']);
});

test('Service checks only run where asked (Controllers and shared modules are skipped)', () => {
	const src = 'local C = { Client = { Try = function() end } }\nreturn C';
	assert.deepEqual(scanText(src, { service: false }), []);
	assert.equal(scanText(src, { service: true }).length, 1);
});

// runDoctor -------------------------------------------------------------------------------------

test('runDoctor on the 1.5.1 fixture reports every kind with file and line', async () => {
	const dir = h.project('v151');
	const log = h.memLog();
	const res = await runDoctor(dir, { log, legacy: true, isTTY: false });
	assert.equal(res.exitCode, 1, 'fixable issues remain');
	assert.deepEqual(
		res.issues.map((i) => `${i.file}:${i.line}:${i.kind}`),
		[
			'src/server/Services/ShopService.luau:10:colon-middleware',
			'src/server/Services/ShopService.luau:36:reserved-name',
			'src/server/Services/ShopService.luau:41:colon-middleware',
			'src/server/Services/ShopService.luau:45:colon-middleware',
			'src/server/Services/ShopService.luau:45:orphan-middleware',
			'src/server/Services/TradeService.luau:4:orphan-spec',
			'src/server/Services/TradeService.luau:4:reserved-key',
			'src/server/Services/TradeService.luau:15:colon-middleware',
			'src/server/Services/TradeService.luau:19:colon-middleware',
		],
	);
	assert.ok(res.issues.every((i) => ['warn', 'fixable'].includes(i.severity)));
	assert.match(log.output(), /Run `loren doctor --fix`/);
	assert.deepEqual(res.fixed, []);
});

test('runDoctor --fix without a TTY or --yes exits 2 and changes nothing', async () => {
	const dir = h.project('v151');
	const before = h.snapshot(dir);
	const confirm = h.fakeConfirm(true);
	const log = h.memLog();
	const res = await runDoctor(dir, { fix: true, isTTY: false, confirm, log });
	assert.equal(res.exitCode, 2);
	assert.equal(confirm.asked.length, 0, 'never prompts without a TTY');
	assert.match(log.stderr(), /needs confirmation\. Run again with --yes/);
	assert.deepEqual(h.snapshot(dir), before);
});

test('runDoctor --fix --yes rewrites, backs up and re-scans clean (manual cases stay)', async () => {
	const dir = h.project('v151');
	const shopBefore = h.read(dir, 'src/server/Services/ShopService.luau');
	const res = await runDoctor(dir, { fix: true, yes: true, isTTY: false, log: h.memLog(), now: h.NOW });
	assert.equal(res.fixed.length, 4);
	assert.equal(res.exitCode, 1, 'TradeService.Middleware:Offer uses self: left for a hand fix');
	assert.deepEqual(res.remaining.filter((i) => i.severity === 'fixable').map((i) => i.name), ['Offer']);
	assert.equal(h.read(dir, `.loren-backup/${h.STAMP}/src/server/Services/ShopService.luau`), shopBefore);
	const shop = h.read(dir, 'src/server/Services/ShopService.luau');
	assert.match(shop, /\t\tGift = function\(player, target\)\n/);
	assert.match(shop, /function ShopService\.Middleware\.Buy\(player, itemId\)/);
	assert.match(shop, /function ShopService\.Middleware\n\t\.Refund\(/);
	assert.match(shop, /check = function\(self\)/, 'nested helper untouched');
	assert.match(shop, /function ShopService\.Middleware:Commented\(player\)/, 'commented code untouched');
	assert.match(shop, /"function ShopService\.Middleware:InAString\(player\)"/, 'strings untouched');
	const trade = h.read(dir, 'src/server/Services/TradeService.luau');
	assert.match(trade, /TradeService\.Middleware\.Accept = function\(player, id\)/);
	assert.match(trade, /function TradeService\.Middleware:Offer\(player, offer\)/);
	assert.match(trade, /TradeService\.Client\.Offer = function\(self, player, offer\)/, 'Client methods keep self');

	const again = await runDoctor(dir, { log: h.memLog() });
	assert.deepEqual(again.issues.filter((i) => i.kind === 'colon-middleware').map((i) => i.name), ['Offer']);
});

test('runDoctor exit 0 once only warnings remain; TTY confirm yes/no', async () => {
	const dir = h.project('v151');
	fs.rmSync(path.join(dir, 'src', 'server', 'Services', 'TradeService.luau'));
	const before = h.snapshot(dir);

	const no = h.fakeConfirm(false);
	const declined = await runDoctor(dir, { fix: true, isTTY: true, confirm: no, log: h.memLog() });
	assert.equal(no.asked.length, 1);
	assert.match(no.asked[0], /Rewrite 3 middleware functions to dot style\? The originals are backed up to \.loren-backup\/\.$/);
	assert.equal(declined.exitCode, 1);
	assert.deepEqual(h.snapshot(dir), before);

	const yes = h.fakeConfirm(true);
	const accepted = await runDoctor(dir, { fix: true, isTTY: true, confirm: yes, log: h.memLog(), now: h.NOW });
	assert.equal(accepted.exitCode, 0, 'only warnings remain');
	assert.equal(accepted.fixed.length, 3);
	assert.ok(accepted.remaining.every((i) => i.severity === 'warn'));
});

test('runDoctor: a clean project exits 0; spec-style 2.x services raise nothing', async () => {
	const dir = h.project('v2');
	const log = h.memLog();
	const res = await runDoctor(dir, { fix: true, isTTY: false, log });
	assert.deepEqual(res.issues, []);
	assert.equal(res.exitCode, 0);
	assert.match(log.output(), /no issues/);
	const empty = await runDoctor(h.project(null), { log: h.memLog() });
	assert.equal(empty.exitCode, 0);
});

test('runDoctor only suggests --fix when something is auto-fixable', async () => {
	const dir = h.project(null);
	h.write(dir, 'src/server/Services/S.luau', 'local S = {}\nfunction S.Middleware:A(p)\n\treturn self:Check(p)\nend\nreturn S\n');
	const log = h.memLog();
	const res = await runDoctor(dir, { log, isTTY: false });
	assert.equal(res.exitCode, 1);
	assert.doesNotMatch(log.output(), /loren doctor --fix/);
	assert.match(log.output(), /Rewrite the \[fix by hand\] middleware to dot style yourself/);

	h.write(dir, 'src/server/Services/T.luau', 'local T = {}\nfunction T.Middleware:B(p) return true end\nreturn T\n');
	const both = h.memLog();
	await runDoctor(dir, { log: both, isTTY: false });
	assert.match(both.output(), /Run `loren doctor --fix`/);
});

test('runDoctor keeps the first backup when a file is backed up twice in one stamp', async () => {
	const dir = h.project(null);
	const src = 'local S = {}\nfunction S.Middleware:A(p) end\nreturn S\n';
	h.write(dir, 'src/server/Services/S.luau', src);
	h.write(dir, `.loren-backup/${h.STAMP}/src/server/Services/S.luau`, 'older');
	await runDoctor(dir, { fix: true, yes: true, log: h.memLog(), now: h.NOW });
	assert.equal(h.read(dir, `.loren-backup/${h.STAMP}/src/server/Services/S.luau`), 'older');
	assert.match(h.read(dir, 'src/server/Services/S.luau'), /S\.Middleware\.A\(p\)/);
});

test('runDoctor follows default.project.json when the code is not under src/', async () => {
	const dir = h.project(null);
	h.write(dir, 'default.project.json', JSON.stringify({ name: 'x', tree: { $className: 'DataModel', ServerScriptService: { Server: { $path: 'game/server' } } } }));
	h.write(dir, 'game/server/Services/S.luau', 'local S = { Client = { Try = function() end } }\nfunction S.Middleware:A(p) end\nreturn S\n');
	h.write(dir, 'src/client/C.luau', 'local C = {}\nfunction C.Middleware:B(p) end\nreturn C\n');
	const res = await runDoctor(dir, { log: h.memLog() });
	assert.deepEqual(
		res.issues.map((i) => `${i.file}:${i.kind}`),
		[
			'src/client/C.luau:colon-middleware',
			'game/server/Services/S.luau:reserved-name',
			'game/server/Services/S.luau:colon-middleware',
			'game/server/Services/S.luau:orphan-middleware',
		],
		'src/ first, then the mapped folders; Service checks only under the server folder',
	);
});

test('runDoctor accepts a minimal logger', async () => {
	const lines = [];
	const log = { info: (m) => lines.push(m), plain: (m) => lines.push(m) };
	const res = await runDoctor(h.project('v151'), { log, isTTY: false });
	assert.equal(res.exitCode, 1);
	assert.ok(lines.some((l) => /ShopService\.luau:41/.test(l)));
});
