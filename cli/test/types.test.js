'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { generateTypes, listModules, collectNames, sharedSource } = require('../lib/types');
const { analyzeLuau, isNetworked } = require('../lib/lint');
const h = require('./fixtures/helpers');

test.after(h.cleanup);

const golden = (name) => fs.readFileSync(path.join(h.FIXTURES, 'golden', name), 'utf8').replace(/\r\n/g, '\n');
const networked = (src) => isNetworked(analyzeLuau(src));

test('golden output for the 1.5.1 fixture (shared and server files)', () => {
	const dir = h.project('v151');
	const res = generateTypes(dir);
	assert.deepEqual(
		res.written.map((f) => path.relative(dir, f).split(path.sep).join('/')),
		['src/shared/LorenTypes.luau', 'src/server/LorenServerTypes.luau'],
	);
	assert.equal(h.read(dir, 'src/shared/LorenTypes.luau'), golden('v151.LorenTypes.luau'));
	assert.equal(h.read(dir, 'src/server/LorenServerTypes.luau'), golden('v151.LorenServerTypes.luau'));
	assert.deepEqual(res.names, {
		services: ['DataService', 'Inventory', 'ShopService', 'TradeService'],
		controllers: ['HUD', 'UIController'],
		networked: ['Inventory', 'ShopService', 'TradeService'],
	});
});

test('both files end with return table.freeze({}) and never return nil (dx-01)', () => {
	for (const name of ['v151', 'v2', null]) {
		const dir = h.project(name);
		fs.mkdirSync(path.join(dir, 'src', 'server'), { recursive: true });
		generateTypes(dir);
		for (const f of ['src/shared/LorenTypes.luau', 'src/server/LorenServerTypes.luau']) {
			const text = h.read(dir, f);
			assert.ok(text.endsWith('return table.freeze({})\n'), `${f} ends with the frozen table`);
			assert.ok(!/return nil/.test(text), `${f} never returns nil`);
			assert.ok(text.startsWith('--!strict\n-- AUTO-GENERATED'), `${f} has the header`);
			assert.ok(!/\brequire\s*\(/.test(text), `${f} requires nothing`);
		}
	}
});

test('empty projects fall back to string and { [string]: any }', () => {
	const dir = h.project(null);
	fs.mkdirSync(path.join(dir, 'src', 'server'), { recursive: true });
	generateTypes(dir);
	const shared = h.read(dir, 'src/shared/LorenTypes.luau');
	assert.match(shared, /^export type ServiceName = string -- none yet$/m);
	assert.match(shared, /^export type ControllerName = string -- none yet$/m);
	assert.match(shared, /^export type NetworkedServiceName = string -- none yet$/m);
	assert.match(shared, /^export type ClientDependencyName = ControllerName \| NetworkedServiceName$/m);
	assert.match(shared, /^export type ClientDeps = \{ \[string\]: any \} -- none yet$/m);
	assert.match(shared, /^export type ServerDeps = \{ \[string\]: any \} -- none yet$/m);
	assert.match(h.read(dir, 'src/server/LorenServerTypes.luau'), /^export type ServerDeps = \{ \[string\]: any \} -- none yet$/m);
});

test('ClientDeps: networked Services are ServiceProxy, Controllers any, clashes flagged', () => {
	const dir = h.project(null);
	h.write(dir, 'src/server/Services/Chat.luau', 'local Chat = { ClientEvents = { "Say" } }\nreturn Chat\n');
	h.write(dir, 'src/server/Services/Hidden.luau', 'return { Client = {} }\n');
	h.write(dir, 'src/server/Services/Map.luau', 'local Map = {}\nfunction Map.Client:Get(p) end\nreturn Map\n');
	h.write(dir, 'src/client/Controllers/Map.luau', 'return {}\n');
	h.write(dir, 'src/client/Controllers/Camera.luau', 'return {}\n');
	generateTypes(dir);
	const shared = h.read(dir, 'src/shared/LorenTypes.luau');
	assert.match(shared, /export type NetworkedServiceName = "Chat" \| "Map"\n/);
	assert.match(shared, /export type ClientDeps = \{\n\tCamera: any,\n\tChat: ServiceProxy,\n\tMap: any, -- a Controller and a networked Service: Loren refuses this at boot, rename one\n\}/);
	assert.match(shared, /export type ServerDeps = \{\n\tChat: any,\n\tHidden: any,\n\tMap: any,\n\}/);
});

test('names that are not identifiers become ["quoted"] keys; long unions wrap', () => {
	const dir = h.project(null);
	h.write(dir, 'src/server/Services/My-Odd.luau', 'return { Signals = { "A" } }\n');
	h.write(dir, 'src/server/Services/end.luau', 'return {}\n');
	for (let i = 0; i < 8; i++) h.write(dir, `src/server/Services/LongServiceName${i}.luau`, 'return {}\n');
	fs.mkdirSync(path.join(dir, 'src', 'client'), { recursive: true });
	generateTypes(dir);
	const server = h.read(dir, 'src/server/LorenServerTypes.luau');
	assert.match(server, /\t\["My-Odd"\]: any,\n/);
	assert.match(server, /\t\["end"\]: any,\n/);
	assert.match(server, /export type ServiceName =\n\t"LongServiceName0"\n\t\| "LongServiceName1"\n/);
});

test('control characters in names become 3-digit escapes (a following digit stays a digit)', () => {
	const text = sharedSource({ services: ['A\u00012'], controllers: [], networked: [] });
	assert.match(text, /^export type ServiceName = "A\\0012"$/m);
});

test('listModules follows the runtime: direct ModuleScripts and folder modules only', () => {
	const dir = h.project(null);
	const s = 'src/server/Services';
	h.write(dir, `${s}/A.luau`, 'return {}');
	h.write(dir, `${s}/B.lua`, 'return {}');
	h.write(dir, `${s}/Folder/init.luau`, 'return {}');
	h.write(dir, `${s}/Folder/Child.luau`, 'return {}');
	h.write(dir, `${s}/LuaFolder/init.lua`, 'return {}');
	h.write(dir, `${s}/ArgonFolder/.src.luau`, 'return {}');
	h.write(dir, `${s}/PlainFolder/Nested.luau`, 'return {}');
	h.write(dir, `${s}/ScriptFolder/init.server.luau`, 'print(1)');
	h.write(dir, `${s}/Boot.server.luau`, 'print(1)');
	h.write(dir, `${s}/Ui.client.lua`, 'print(1)');
	h.write(dir, `${s}/init.luau`, 'return {}');
	h.write(dir, `${s}/notes.txt`, 'x');
	h.write(dir, `${s}/Dup.luau`, 'return {}');
	h.write(dir, `${s}/Dup.lua`, 'return {}');
	const mods = listModules(path.join(dir, ...s.split('/')));
	assert.deepEqual([...mods.keys()].sort(), ['A', 'ArgonFolder', 'B', 'Dup', 'Folder', 'LuaFolder']);
	assert.equal(path.basename(mods.get('Folder')), 'init.luau');
	assert.equal(listModules(path.join(dir, 'missing')).size, 0);
});

test('networked detection matches the runtime (Client methods, Signals, ClientEvents, Spec)', () => {
	assert.equal(networked('local S = { Client = {}, Signals = {}, Middleware = {} }\nreturn S'), false, 'the scaffold template is not networked');
	assert.equal(networked('local S = { Client = { Ping = function() end } }\nreturn S'), true);
	assert.equal(networked('local S = { Client = {} }\nfunction S.Client:Ping(p) end\nreturn S'), true);
	assert.equal(networked('local S = { Client = {} }\nS.Client.Ping = function(self, p) end\nreturn S'), true);
	assert.equal(networked('local S = {}\nS.Signals = { "Changed" }\nreturn S'), true);
	assert.equal(networked('return { ClientEvents = { "Say" } }'), true);
	assert.equal(networked('return { Spec = { Ping = Loren.Method() } }'), true);
	assert.equal(networked('local S = { Client = { Try = function() end } }\nfunction S.Client:Signals() end\nreturn S'), false, 'reserved names are not networked');
	assert.equal(networked('local S = { Client = { Try = function() end, Buy = function() end } }\nreturn S'), true);
	assert.equal(networked('local S = { Signals = {} :: { string } }\nreturn S'), false);
	assert.equal(networked('local S: { Client: any } = { Client = ({}) }\nreturn S'), false);
	assert.equal(networked('local API = require(script.API)\nlocal S = { Client = API }\nreturn S'), true, 'unknown counts as networked');
	assert.equal(networked('local S = { Client = {} }\n-- function S.Client:Ping(p) end\nreturn S'), false, 'comments are ignored');
	assert.equal(networked('local S = { Client = {} }\nlocal t = "S.Client.Ping = function() end"\nreturn S'), false, 'strings are ignored');
	assert.equal(networked('local S = { Client = {} }\nlocal t = [[\nfunction S.Client:Ping() end\n]]\nreturn S'), false, 'long strings are ignored');
	assert.equal(networked('local Other = { Client = { X = function() end } }\nlocal S = {}\nreturn S'), false, 'only the returned table');
	assert.equal(networked('local S = {}\nfunction S:Helper() local t = { Client = { X = function() end } } end\nreturn S'), false);
});

test('idempotent: a second run writes nothing; dryRun never writes', () => {
	const dir = h.project('v151');
	const dry = generateTypes(dir, { dryRun: true });
	assert.equal(dry.written.length, 0);
	assert.equal(dry.planned.length, 2);
	assert.match(h.read(dir, 'src/shared/LorenTypes.luau'), /return nil/, 'dry run left the old file');
	generateTypes(dir);
	const again = generateTypes(dir);
	assert.deepEqual(again.written, []);
	assert.deepEqual(again.planned, []);
	assert.equal(again.unchanged.length, 2);
	// CRLF checkouts count as unchanged
	const file = path.join(dir, 'src', 'shared', 'LorenTypes.luau');
	fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace(/\n/g, '\r\n'));
	assert.deepEqual(generateTypes(dir).written, []);
});

test('custom layout: folders from options; no server file without a server folder', () => {
	const dir = h.project(null);
	h.write(dir, 'game/server/Services/Alpha.luau', 'return { Signals = { "X" } }');
	h.write(dir, 'game/client/Controllers/Beta.luau', 'return {}');
	const res = generateTypes(dir, { sharedDir: 'game/shared', serverDir: 'game/server', clientDir: 'game/client' });
	assert.equal(res.written.length, 2);
	assert.match(h.read(dir, 'game/shared/LorenTypes.luau'), /ClientDependencyName = ControllerName \| NetworkedServiceName/);
	assert.deepEqual(collectNames(dir, { serverDir: 'game/server', clientDir: 'game/client' }), {
		services: ['Alpha'],
		controllers: ['Beta'],
		networked: ['Alpha'],
	});
	const bare = h.project(null);
	const only = generateTypes(bare);
	assert.deepEqual(only.written.map((f) => path.basename(f)), ['LorenTypes.luau']);
});

test('without options the folders come from default.project.json', () => {
	const dir = h.project(null);
	h.write(
		dir,
		'default.project.json',
		JSON.stringify({
			name: 'x',
			tree: {
				$className: 'DataModel',
				ReplicatedStorage: { Shared: { $path: 'code/shared' } },
				ServerScriptService: { Server: { $path: { optional: 'code/server' } } },
				StarterPlayer: { StarterPlayerScripts: { Client: { $path: 'code/client' } } },
			},
		}),
	);
	h.write(dir, 'code/server/Services/Gamma.luau', 'return { Signals = { "X" } }');
	h.write(dir, 'code/client/Controllers/Delta.luau', 'return {}');
	const res = generateTypes(dir);
	assert.deepEqual(res.names, { services: ['Gamma'], controllers: ['Delta'], networked: ['Gamma'] });
	assert.ok(h.exists(dir, 'code/shared/LorenTypes.luau'));
	assert.ok(h.exists(dir, 'code/server/LorenServerTypes.luau'));
	assert.ok(!h.exists(dir, 'src'), 'nothing written to the default folders');
});

// Optional: type-check the golden files with luau-lsp on both solvers when it is installed.
const LSP = process.env.LUAU_LSP || 'C:\\Users\\Fabi\\.rokit\\tool-storage\\johnnymorganz\\luau-lsp\\1.68.1\\luau-lsp.exe';
const DEFS = path.join(h.REAL_PACKAGE_ROOT, '..', 'test-project', 'tools', 'globalTypes.d.luau');
const haveLsp = fs.existsSync(LSP) && fs.existsSync(DEFS);

test('generated files type-check with luau-lsp (old and new solver)', { skip: haveLsp ? false : 'luau-lsp not found' }, () => {
	const dir = h.project('v151');
	generateTypes(dir);
	h.write(
		dir,
		'src/Check.luau',
		[
			'--!strict',
			'local Types = require("./shared/LorenTypes")',
			'local ServerTypes = require("./server/LorenServerTypes")',
			'local deps: Types.ClientDeps = {} :: any',
			'deps.ShopService.Signals.Purchased:Connect(function() end)',
			'local _p = deps.ShopService:Buy("sword")',
			'local _n: Types.ClientDependencyName = "UIController"',
			'local _s: ServerTypes.ServiceName = "DataService"',
			'local sdeps: ServerTypes.ServerDeps = {} :: any',
			'local _d = sdeps.DataService',
			'return nil',
			'',
		].join('\n'),
	);
	const files = ['src/shared/LorenTypes.luau', 'src/server/LorenServerTypes.luau', 'src/Check.luau'].map((f) => path.join(dir, f));
	for (const flags of [[], ['--flag:LuauSolverV2=true']]) {
		const r = spawnSync(LSP, ['analyze', ...flags, `--defs=${DEFS}`, ...files], { encoding: 'utf8', cwd: dir });
		const errors = `${r.stdout}\n${r.stderr}`.split(/\r?\n/).filter((l) => /Error/.test(l) && !/\[(INFO|WARN)\]/.test(l));
		assert.deepEqual(errors, [], `luau-lsp ${flags.join(' ')}`);
		assert.equal(r.status, 0);
	}
});
