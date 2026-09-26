'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { renderModule } = require('../lib/templates');
const { RETIRED_PREMADES } = require('../lib/constants');
const { tmpDir, listFiles, CLI_ROOT, TEMPLATE_DIR, INDEX } = require('./helpers');

const REPO_STYLUA = path.join(CLI_ROOT, '..', 'stylua.toml');
const home = os.homedir();
const STYLUA = [process.env.STYLUA, path.join(home, '.rokit', 'tool-storage', 'johnnymorganz', 'stylua', '2.5.2', 'stylua.exe')].find(
	(p) => p && fs.existsSync(p),
);
const LUAU_LSP = [
	process.env.LUAU_LSP,
	path.join(home, '.rokit', 'tool-storage', 'johnnymorganz', 'luau-lsp', '1.68.1', 'luau-lsp.exe'),
].find((p) => p && fs.existsSync(p));
const DEFS = path.join(CLI_ROOT, '..', 'test-project', 'tools', 'globalTypes.d.luau');

function packedFiles(t) {
	const dir = tmpDir(t);
	for (const entry of ['package.json', 'index.js', 'README.md', 'lib', 'project', 'test']) {
		fs.cpSync(path.join(CLI_ROOT, entry), path.join(dir, entry), { recursive: true });
	}
	const r = spawnSync('npm pack --dry-run --json --ignore-scripts', { cwd: dir, shell: true, encoding: 'utf8', timeout: 120000 });
	assert.equal(r.status, 0, r.stderr);
	const json = JSON.parse(r.stdout.slice(r.stdout.indexOf('[')));
	return json[0].files.map((f) => f.path.replace(/\\/g, '/')).sort();
}

test('npm pack ships the CLI and the runtime, and no tests or vendored extras', (t) => {
	const files = packedFiles(t);
	for (const f of [
		'index.js',
		'package.json',
		'README.md',
		'lib/constants.js',
		'lib/commands/init.js',
		'project/default.project.json',
		'project/src/shared/Loren.luau',
		'project/src/server/Server.server.luau',
		'project/src/client/Client.client.luau',
		'project/loren/shared/init.luau',
		'project/loren/server/init.luau',
		'project/loren_packages/Promise/lib/init.lua',
		'project/loren_packages/Promise/LICENSE',
		'project/loren_packages/Promise/default.project.json',
	]) {
		assert.ok(files.includes(f), `missing ${f}`);
	}
	for (const f of listFiles(path.join(TEMPLATE_DIR, 'loren'))) assert.ok(files.includes(`project/loren/${f}`), f);
	for (const f of listFiles(path.join(TEMPLATE_DIR, 'loren_premade'))) {
		const retired = RETIRED_PREMADES.includes(f);
		assert.equal(files.includes(`project/loren_premade/${f}`), !retired, `premade ${f}`);
	}
	const forbidden = files.filter(
		(f) =>
			/\.spec\.luau?$/i.test(f) ||
			f.startsWith('test/') ||
			f.includes('test-project') ||
			f.includes('node_modules') ||
			/^project\/loren_packages\/Promise\/(docs|\.github|CHANGELOG|README|runTests|test\.project|testez|wally|moonwave|rotriever|selene|aftman|\.)/.test(f) ||
			f === 'project/aftman.toml',
	);
	assert.deepEqual(forbidden, []);
});

test('templates, bootstraps and premades are stylua-formatted, and so is make output', { skip: !STYLUA || !fs.existsSync(REPO_STYLUA) }, (t) => {
	const dir = tmpDir(t);
	fs.cpSync(path.join(TEMPLATE_DIR, 'src'), path.join(dir, 'src'), { recursive: true });
	fs.cpSync(path.join(TEMPLATE_DIR, 'loren_premade'), path.join(dir, 'loren_premade'), { recursive: true });
	for (const f of RETIRED_PREMADES) fs.rmSync(path.join(dir, 'loren_premade', f), { force: true });
	fs.writeFileSync(path.join(dir, 'MadeService.luau'), renderModule('service', 'InventoryService'));
	fs.writeFileSync(path.join(dir, 'MadeController.luau'), renderModule('controller', 'InventoryController'));
	const r = spawnSync(STYLUA, ['--config-path', REPO_STYLUA, '--check', '.'], { cwd: dir, encoding: 'utf8' });
	assert.equal(r.status, 0, r.stdout + r.stderr);
});

// Real tools, no network: rojo/argon/luau-lsp must already be installed. Opt in with LOREN_E2E=1.
const e2e = process.env.LOREN_E2E === '1' && LUAU_LSP && fs.existsSync(DEFS);
for (const tool of ['rojo', 'argon']) {
	test(`E2E: init --tool ${tool}, make, inject, build and luau-lsp`, { skip: !e2e, timeout: 300000 }, (t) => {
		const dir = tmpDir(t);
		const env = { ...process.env, NO_UPDATE_NOTIFIER: '1', CI: '1' };
		const cli = (args, cwd) => spawnSync(process.execPath, [INDEX, ...args], { cwd, input: '', encoding: 'utf8', env });
		const init = cli(['init', 'game', '--tool', tool, '--yes'], dir);
		assert.equal(init.status, 0, init.stdout + init.stderr);
		const root = path.join(dir, 'game');
		for (const args of [
			['make', 'service', 'InventoryService'],
			['make', 'controller', 'InventoryController'],
			['inject', 'service', 'PointsService'],
			['inject', 'controller', 'PointsController'],
			['inject', 'shared', 'ExampleShared'],
		]) {
			const r = cli(args, root);
			assert.equal(r.status, 0, `${args.join(' ')}: ${r.stdout}${r.stderr}`);
		}
		const build =
			tool === 'rojo'
				? spawnSync('rojo', ['build', 'default.project.json', '-o', 'out.rbxlx'], { cwd: root, encoding: 'utf8' })
				: spawnSync('argon', ['build', 'default.project.json', '-o', 'out.rbxlx', '-x', '-y'], { cwd: root, encoding: 'utf8' });
		assert.equal(build.status, 0, build.stdout + build.stderr);
		const place = fs.readFileSync(path.join(root, 'out.rbxlx'), 'utf8');
		assert.doesNotMatch(place, /<string name="Name">init\.spec<\/string>/);
		for (const flags of [[], ['--flag:LuauSolverV2=true']]) {
			const lsp = spawnSync(
				LUAU_LSP,
				['analyze', `--defs=${DEFS}`, `--sourcemap=${path.join(root, 'sourcemap.json')}`, ...flags, 'src'],
				{ cwd: root, encoding: 'utf8' },
			);
			assert.equal(lsp.status, 0, lsp.stdout + lsp.stderr);
		}
	});
}

test('E2E: init --tool none, make, inject, update, doctor and luau-lsp on the Script Sync layout', { skip: !e2e, timeout: 300000 }, (t) => {
	const dir = tmpDir(t);
	const env = { ...process.env, NO_UPDATE_NOTIFIER: '1', CI: '1' };
	const cli = (args, cwd) => spawnSync(process.execPath, [INDEX, ...args], { cwd, input: '', encoding: 'utf8', env });
	const init = cli(['init', 'game', '--tool', 'none', '--yes'], dir);
	assert.equal(init.status, 0, init.stdout + init.stderr);
	const root = path.join(dir, 'game');
	for (const args of [
		['make', 'service', 'InventoryService'],
		['make', 'controller', 'InventoryController'],
		['inject', 'service', 'PointsService'],
		['inject', 'controller', 'PointsController'],
		['inject', 'shared', 'ExampleShared'],
		['update', '--yes'],
		['doctor'],
	]) {
		const r = cli(args, root);
		assert.equal(r.status, 0, `${args.join(' ')}: ${r.stdout}${r.stderr}`);
	}
	assert.ok(!fs.existsSync(path.join(root, 'default.project.json')) && !fs.existsSync(path.join(root, 'sourcemap.json')));
	const folder = (p) => ({ $path: `game/${p}` });
	const map = {
		name: 'scriptsync-map',
		tree: {
			$className: 'DataModel',
			ReplicatedStorage: { Shared: folder('ReplicatedStorage/Shared'), LorenPackages: folder('ReplicatedStorage/LorenPackages') },
			ServerScriptService: { Server: folder('ServerScriptService/Server') },
			StarterPlayer: { StarterPlayerScripts: { Client: folder('StarterPlayer/StarterPlayerScripts/Client') } },
		},
	};
	fs.writeFileSync(path.join(dir, 'map.project.json'), JSON.stringify(map));
	const sm = spawnSync('rojo', ['sourcemap', 'map.project.json', '-o', 'sourcemap.json'], { cwd: dir, encoding: 'utf8' });
	assert.equal(sm.status, 0, sm.stdout + sm.stderr);
	const dirs = ['game/ReplicatedStorage', 'game/ServerScriptService', 'game/StarterPlayer'];
	for (const flags of [[], ['--flag:LuauSolverV2=true']]) {
		// The vendored Promise has old-solver warnings of its own; it is checked upstream, not here.
		const args = ['analyze', `--defs=${DEFS}`, '--sourcemap=sourcemap.json', '--ignore=**/LorenPackages/**', ...flags, ...dirs];
		const lsp = spawnSync(LUAU_LSP, args, { cwd: dir, encoding: 'utf8' });
		assert.equal(lsp.status, 0, lsp.stdout + lsp.stderr);
	}
});
