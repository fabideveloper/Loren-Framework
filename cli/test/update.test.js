'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { runUpdate, patchProject, stripNative, compareVersions, classifyLorenFile, layoutOf } = require('../lib/update');
const { SHIM_SOURCE } = require('../lib/constants');
const h = require('./fixtures/helpers');

test.after(h.cleanup);

const B = `.loren-backup/${h.STAMP}`;
const GLOBS = ['loren_packages/**/*.spec.lua', 'loren_packages/**/*.spec.luau'];

// Runs an update with the fake package, a fake tool runner and a fixed clock.
async function update(dir, opts = {}) {
	const log = h.memLog();
	const runner = opts.runner || h.fakeRunner();
	const res = await runUpdate(dir, {
		packageRoot: h.PACKAGE_ROOT,
		yes: true,
		isTTY: false,
		now: h.NOW,
		sourcemapRunner: runner,
		log,
		...opts,
	});
	return { res, log, runner };
}

const packageRuntime = () => h.snapshot(path.join(h.PACKAGE_ROOT, 'project', 'loren'));
// TradeService has the one middleware that needs a hand rewrite (exit 1); without it an update ends at 0.
const withoutTrade = (dir, src = 'src') => fs.rmSync(path.join(dir, src, 'server', 'Services', 'TradeService.luau'));

// 1.5.1 -------------------------------------------------------------------------------------------

test('1.5.1 -> 2.0: runtime, shim, project, Promise, types, sourcemap, lint', async () => {
	const dir = h.project('v151');
	const oldProject = h.read(dir, 'default.project.json');
	const oldRuntime = h.read(dir, 'src/shared/Loren.luau');
	const { res, log, runner } = await update(dir);

	assert.deepEqual(res.actions.map((a) => a.kind), ['runtime', 'shim', 'project', 'promise', 'types']);
	assert.equal(res.kind, 'legacy');
	assert.equal(res.fromVersion, '1.5.1');
	assert.equal(res.toVersion, '2.0.0');
	assert.equal(res.exitCode, 1, 'TradeService.Middleware:Offer needs a hand rewrite');

	// runtime: exactly the package's files
	const runtime = h.snapshot(path.join(dir, 'loren'));
	assert.deepEqual(runtime, packageRuntime());
	// shim
	assert.equal(h.read(dir, 'src/shared/Loren.luau'), SHIM_SOURCE);
	// project: patched, the rest preserved, 4 spaces
	const project = JSON.parse(h.read(dir, 'default.project.json'));
	assert.deepEqual(project.globIgnorePaths, GLOBS);
	assert.deepEqual(Object.keys(project), ['name', 'globIgnorePaths', 'tree']);
	assert.deepEqual(project.tree.ReplicatedStorage.LorenRuntime, { $path: 'loren/shared' });
	assert.deepEqual(project.tree.ServerScriptService.LorenServer, { $path: 'loren/server' });
	assert.deepEqual(project.tree.ReplicatedStorage.Shared, { $path: 'src/shared' });
	assert.deepEqual(project.tree.StarterPlayer, JSON.parse(oldProject).tree.StarterPlayer);
	assert.match(h.read(dir, 'default.project.json'), /^\{\n {4}"name": "my-game",\n {4}"globIgnorePaths": \[\n {8}"loren_packages/);
	// Promise: only the three files, no test code
	assert.deepEqual(Object.keys(h.snapshot(path.join(dir, 'loren_packages', 'Promise'))).sort(), ['LICENSE', 'default.project.json', 'lib/init.lua']);
	// types
	assert.match(h.read(dir, 'src/shared/LorenTypes.luau'), /return table\.freeze\(\{\}\)\n$/);
	assert.ok(h.exists(dir, 'src/server/LorenServerTypes.luau'));
	// sourcemap with the project's tool (aftman.toml: rojo), after the types
	assert.deepEqual(runner.calls.map((c) => [c.cmd, ...c.args].join(' ')), ['rojo sourcemap default.project.json -o sourcemap.json']);
	assert.equal(res.tool, 'rojo');
	// lint: colon middleware rewritten, the self-using one left
	assert.equal(res.doctor.fixed.length, 4);
	assert.match(h.read(dir, 'src/server/Services/ShopService.luau'), /function ShopService\.Middleware\.Buy\(player, itemId\)/);
	// backups
	assert.equal(h.read(dir, `${B}/src/shared/Loren.luau`), oldRuntime);
	assert.equal(h.read(dir, `${B}/default.project.json`), oldProject);
	assert.ok(h.exists(dir, `${B}/loren_packages/Promise/lib/init.spec.lua`));
	assert.match(h.read(dir, `${B}/src/shared/LorenTypes.luau`), /return nil/);
	assert.ok(h.exists(dir, `${B}/src/server/Services/ShopService.luau`), 'the lint backs up into the same folder');
	assert.equal(res.backupDir, B);
	// messages
	const out = log.output();
	assert.match(out, /Loren 1\.5\.1 project \(src\/shared\/Loren\.luau is the whole 1\.x runtime\)/);
	assert.match(out, /To update the Loren CLI itself: npm i -g loren-framework/);
});

test('1.5.1 without hand fixes left exits 0, and a second run changes nothing', async () => {
	const dir = h.project('v151');
	withoutTrade(dir);
	const first = await update(dir);
	assert.equal(first.res.exitCode, 0);
	const after = h.snapshot(dir);
	const second = await update(dir, { now: new Date('2026-09-25T00:00:00.000Z') });
	assert.equal(second.res.exitCode, 0);
	assert.deepEqual(second.res.actions, []);
	assert.equal(second.res.kind, 'v2');
	assert.deepEqual(h.snapshot(dir), after, 'nothing changed, no new backup');
	assert.match(second.log.output(), /Already up to date: runtime 2\.0\.0/);
	assert.equal(second.runner.calls.length, 1, 'the sourcemap still runs');
});

test('no TTY and no --yes: exit 2, nothing changed, never prompts', async () => {
	const dir = h.project('v151');
	const before = h.snapshot(dir);
	const confirm = h.fakeConfirm(true);
	const { res, log, runner } = await update(dir, { yes: false, isTTY: false, confirm });
	assert.equal(res.exitCode, 2);
	assert.equal(confirm.asked.length, 0);
	assert.equal(runner.calls.length, 0);
	assert.match(log.stderr(), /needs confirmation\. Run it again with --yes, or with --dry-run to preview\. Nothing was changed\./);
	assert.deepEqual(h.snapshot(dir), before);
});

test('TTY: declining cancels (exit 1, nothing changed); accepting applies', async () => {
	const dir = h.project('v151');
	withoutTrade(dir);
	const before = h.snapshot(dir);
	const no = h.fakeConfirm(false);
	const declined = await update(dir, { yes: false, isTTY: true, confirm: no });
	assert.equal(declined.res.exitCode, 1);
	assert.equal(declined.res.cancelled, true);
	assert.deepEqual(no.asked, ['Update this project to Loren 2.0.0?']);
	assert.deepEqual(h.snapshot(dir), before);

	const yes = h.fakeConfirm(true);
	const accepted = await update(dir, { yes: false, isTTY: true, confirm: yes });
	assert.equal(accepted.res.exitCode, 0);
	assert.equal(yes.asked.length, 2, 'the update and the middleware rewrite are confirmed separately');
	assert.equal(h.read(dir, 'src/shared/Loren.luau'), SHIM_SOURCE);
});

test('--dry-run prints the plan and the lint preview and changes nothing', async () => {
	const dir = h.project('v151');
	const before = h.snapshot(dir);
	const { res, log, runner } = await update(dir, { dryRun: true, yes: false });
	assert.equal(res.exitCode, 0);
	assert.equal(res.dryRun, true);
	assert.deepEqual(res.actions.map((a) => a.kind), ['runtime', 'shim', 'project', 'promise', 'types']);
	assert.equal(runner.calls.length, 0);
	assert.deepEqual(h.snapshot(dir), before);
	const out = log.output();
	assert.match(out, /Would do:/);
	assert.match(out, /add loren\/ with runtime 2\.0\.0 \(4 files\)/);
	assert.match(out, /write the shim to src\/shared\/Loren\.luau \(replaces the 1\.5\.1 runtime\)/);
	assert.match(out, /globIgnorePaths \+= loren_packages\/\*\*\/\*\.spec\.lua, loren_packages\/\*\*\/\*\.spec\.luau/);
	assert.match(out, /it has test files \(lib\/init\.spec\.lua\) that would build into your place/);
	assert.match(out, /ShopService\.luau:41 \[fixable\]/);
	assert.match(out, /Dry run: nothing was changed/);
});

// 2.x -----------------------------------------------------------------------------------------------

test('2.x: replaces loren/ without stale files, keeps the rest of the project file', async () => {
	const dir = h.project('v2');
	const oldProject = JSON.parse(h.read(dir, 'default.project.json'));
	const { res, log } = await update(dir);
	assert.equal(res.exitCode, 0);
	assert.equal(res.kind, 'v2');
	assert.equal(res.fromVersion, '2.0.0-beta.1');
	assert.deepEqual(res.actions.map((a) => a.kind), ['runtime', 'project', 'types']);
	assert.ok(!h.exists(dir, 'loren/shared/Old.luau'), 'stale runtime file removed');
	assert.ok(h.exists(dir, `${B}/loren/shared/Old.luau`), 'but backed up');
	assert.deepEqual(h.snapshot(path.join(dir, 'loren')), packageRuntime());
	const project = JSON.parse(h.read(dir, 'default.project.json'));
	assert.deepEqual(project, { name: 'v2-game', globIgnorePaths: GLOBS, servePort: 34872, tree: oldProject.tree });
	assert.deepEqual(Object.keys(project), ['name', 'globIgnorePaths', 'servePort', 'tree']);
	assert.match(log.output(), /Loren 2\.0\.0-beta\.1 project \(src\/shared\/Loren\.luau is the 2\.x shim\)/);
});

test('2.x: idempotent (second run: no actions, no writes, no backup) and still reports', async () => {
	const dir = h.project('v2');
	await update(dir);
	const after = h.snapshot(dir);
	const again = await update(dir, { now: new Date('2030-01-01T00:00:00.000Z') });
	assert.equal(again.res.exitCode, 0);
	assert.deepEqual(again.res.actions, []);
	assert.deepEqual(h.snapshot(dir), after);
	assert.ok(!h.exists(dir, '.loren-backup/2030-01-01T00-00-00-000Z'));
	assert.match(again.log.output(), /Already up to date/);
	assert.match(again.log.output(), /Middleware lint: no issues/);
});

test('2.x: CRLF checkouts of an up-to-date project count as unchanged', async () => {
	const dir = h.project('v2');
	await update(dir);
	for (const f of ['loren/shared/Codec.luau', 'src/shared/Loren.luau', 'src/shared/LorenTypes.luau', 'loren_packages/Promise/lib/init.lua']) {
		h.write(dir, f, h.read(dir, f).replace(/\n/g, '\r\n'));
	}
	const again = await update(dir, { now: new Date('2030-01-01T00:00:00.000Z') });
	assert.deepEqual(again.res.actions, []);
});

test('--no-native strips @native and --!native, keeps line numbers, and is idempotent', async () => {
	const dir = h.project('v2');
	const { res } = await update(dir, { noNative: true });
	assert.equal(res.exitCode, 0);
	const pkg = packageRuntime();
	for (const [file, text] of Object.entries(h.snapshot(path.join(dir, 'loren')))) {
		assert.ok(!/^\s*@native/m.test(text), `${file} has no @native attribute`);
		assert.ok(!/--!native/.test(text), `${file} has no --!native`);
		assert.equal(text.split('\n').length, pkg[file].split('\n').length, `${file} keeps its line count`);
	}
	const codec = h.read(dir, 'loren/shared/Codec.luau');
	assert.match(codec, /\nlocal function mul\(/);
	assert.match(codec, /-- a comment that mentions @native stays/);
	assert.deepEqual((await update(dir, { noNative: true })).res.actions, []);
	assert.deepEqual((await update(dir)).res.actions.map((a) => a.kind), ['runtime'], 'without the flag @native comes back');
});

test('stripNative on CRLF text', () => {
	assert.equal(stripNative('--!native\r\n@native\r\nlocal x = 1\r\n\t@native local function f() end\r\n'), '\r\n\r\nlocal x = 1\r\n\tlocal function f() end\r\n');
});

test('Argon project: the sourcemap uses argon; --tool overrides detection', async () => {
	const dir = h.project('argon');
	const { res, runner } = await update(dir);
	assert.equal(res.exitCode, 0);
	assert.equal(res.tool, 'argon');
	assert.deepEqual(runner.calls.map((c) => [c.cmd, ...c.args].join(' ')), ['argon sourcemap default.project.json -o sourcemap.json']);

	const rojoProject = h.project('v2');
	const forced = await update(rojoProject, { tool: 'argon' });
	assert.deepEqual(forced.runner.calls.map((c) => c.cmd), ['argon']);
	assert.equal(forced.res.tool, 'argon');
});

test('a failing or missing sync tool: files are updated, exit 1 with a clear message', async () => {
	const dir = h.project('v2');
	const failing = await update(dir, { runner: h.fakeRunner({ fail: { rojo: { status: 1, stderr: 'boom' } } }) });
	assert.equal(failing.res.exitCode, 1);
	assert.equal(h.read(dir, 'src/shared/Loren.luau'), SHIM_SOURCE);
	assert.match(failing.log.stderr(), /sourcemap\.json was not regenerated: Rojo sourcemap failed \(exit 1\): boom\. If rokit\.toml pins a version you do not have, install it first \(rokit install\)\./);

	const bare = h.project('v2');
	fs.rmSync(path.join(bare, 'rokit.toml'));
	const none = await update(bare, { runner: h.fakeRunner({ installed: [] }) });
	assert.equal(none.res.exitCode, 1);
	assert.ok(h.exists(bare, 'loren/shared/Codec.luau'));
	assert.match(none.log.stderr(), /No sync tool found/);
});

test('an unknown --tool fails before anything changes', async () => {
	const dir = h.project('v2');
	const before = h.snapshot(dir);
	const { res, log, runner } = await update(dir, { tool: 'wally' });
	assert.equal(res.exitCode, 1);
	assert.deepEqual(res.actions, []);
	assert.equal(runner.calls.length, 0);
	assert.match(log.stderr(), /Unknown sync tool "wally"\. Use --tool rojo or --tool argon\. Nothing was changed\./);
	assert.deepEqual(h.snapshot(dir), before);
});

test('with the real clock, the update and the lint rewrite back up into one folder', async () => {
	const dir = h.project('v151');
	withoutTrade(dir);
	const { res } = await update(dir, { now: undefined });
	assert.equal(res.exitCode, 0);
	assert.equal(res.doctor.fixed.length, 3);
	const stamps = fs.readdirSync(path.join(dir, '.loren-backup'));
	assert.equal(stamps.length, 1, stamps.join(', '));
	assert.equal(res.backupDir, `.loren-backup/${stamps[0]}`);
	assert.ok(h.exists(dir, `.loren-backup/${stamps[0]}/src/server/Services/ShopService.luau`));
	assert.ok(h.exists(dir, `.loren-backup/${stamps[0]}/src/shared/Loren.luau`));
});

test('dotfiles in loren/ (.DS_Store) do not make an up-to-date runtime differ', async () => {
	const dir = h.project('v2');
	await update(dir);
	h.write(dir, 'loren/shared/.DS_Store', 'finder');
	const again = await update(dir, { now: new Date('2030-01-01T00:00:00.000Z') });
	assert.deepEqual(again.res.actions, []);
	// a real stale file still counts
	h.write(dir, 'loren/shared/Stale.luau', 'return nil');
	const stale = await update(dir, { now: new Date('2030-01-02T00:00:00.000Z') });
	assert.deepEqual(stale.res.actions.map((a) => a.kind), ['runtime']);
	assert.ok(!h.exists(dir, 'loren/shared/Stale.luau') && !h.exists(dir, 'loren/shared/.DS_Store'));
});

test('a project runtime newer than the CLI is refused', async () => {
	const dir = h.project('v2');
	h.write(dir, 'loren/shared/Version.luau', 'return table.freeze({ Version = "2.1.0" })\n');
	const before = h.snapshot(dir);
	const { res, log } = await update(dir);
	assert.equal(res.exitCode, 1);
	assert.match(log.stderr(), /newer than this CLI's \(2\.0\.0\)\. Update the CLI first: npm i -g loren-framework/);
	assert.deepEqual(h.snapshot(dir), before);
	assert.equal((await update(dir, { force: true })).res.exitCode, 0);
});

test('Promise: missing -> vendored; already minimal -> untouched', async () => {
	const dir = h.project('v2');
	fs.rmSync(path.join(dir, 'loren_packages', 'Promise'), { recursive: true });
	const { res } = await update(dir);
	assert.ok(res.actions.some((a) => a.kind === 'promise' && /it is missing/.test(a.detail)));
	assert.equal(h.read(dir, 'loren_packages/Promise/lib/init.lua'), h.read(h.PACKAGE_ROOT, 'project/loren_packages/Promise/lib/init.lua'));
	assert.ok(!h.exists(dir, 'loren_packages/Promise/lib/init.spec.lua'));
	assert.ok(!h.exists(dir, 'loren_packages/Promise/README.md'));
});

test('the shim: a changed shim and a stray Loren.lua are replaced (both backed up)', async () => {
	const dir = h.project('v2');
	h.write(dir, 'src/shared/Loren.luau', `-- my edit\n${SHIM_SOURCE}`);
	const edited = await update(dir);
	assert.ok(edited.res.actions.some((a) => a.kind === 'shim' && /a changed shim/.test(a.detail)));
	assert.equal(h.read(dir, 'src/shared/Loren.luau'), SHIM_SOURCE);

	const legacyLua = h.project('v151');
	fs.renameSync(path.join(legacyLua, 'src', 'shared', 'Loren.luau'), path.join(legacyLua, 'src', 'shared', 'Loren.lua'));
	const res = await update(legacyLua);
	assert.equal(res.res.kind, 'legacy');
	assert.ok(!h.exists(legacyLua, 'src/shared/Loren.lua'));
	assert.equal(h.read(legacyLua, 'src/shared/Loren.luau'), SHIM_SOURCE);
	assert.ok(h.exists(legacyLua, `${B}/src/shared/Loren.lua`));
});

// Not a Loren project ---------------------------------------------------------------------------------

test('not a Loren project: exit 1 with a clear message, nothing written', async () => {
	const empty = h.project(null);
	const a = await update(empty);
	assert.equal(a.res.exitCode, 1);
	assert.match(a.log.stderr(), /is not a Loren project: there is no default\.project\.json/);
	assert.deepEqual(h.snapshot(empty), {});

	const other = h.project(null);
	h.write(other, 'default.project.json', '{ "name": "x", "tree": { "$className": "DataModel" } }');
	const b = await update(other);
	assert.equal(b.res.exitCode, 1);
	assert.match(b.log.stderr(), /is not a Loren project: there is no src\/shared\/Loren\.luau and no loren\/ runtime\. Nothing was changed\./);

	h.write(other, 'src/shared/Loren.luau', 'return "my own module"\n');
	const c = await update(other);
	assert.equal(c.res.exitCode, 1);
	assert.match(c.log.stderr(), /src\/shared\/Loren\.luau is neither the Loren 1\.x runtime nor the 2\.x shim/);

	const broken = h.project('v2');
	h.write(broken, 'default.project.json', '{ "name": ');
	const d = await update(broken);
	assert.equal(d.res.exitCode, 1);
	assert.match(d.log.stderr(), /default\.project\.json is not valid JSON/);
});

test('an incomplete CLI install is reported', async () => {
	const pkg = h.tempDir();
	fs.mkdirSync(path.join(pkg, 'project'));
	const { res, log } = await update(h.project('v2'), { packageRoot: pkg });
	assert.equal(res.exitCode, 1);
	assert.match(log.stderr(), /This install of the Loren CLI is incomplete/);
});

// default.project.json ------------------------------------------------------------------------------

const layout = { shared: 'src/shared', server: 'src/server', client: 'src/client', packages: 'loren_packages' };

test('patchProject: creates missing services with $className', () => {
	const { data, changes } = patchProject({ name: 'x', tree: { $className: 'DataModel', Workspace: {} } }, layout);
	assert.deepEqual(data.tree.ReplicatedStorage, {
		$className: 'ReplicatedStorage',
		LorenRuntime: { $path: 'loren/shared' },
		LorenPackages: { $path: 'loren_packages' },
	});
	assert.deepEqual(data.tree.ServerScriptService, { $className: 'ServerScriptService', LorenServer: { $path: 'loren/server' } });
	assert.deepEqual(Object.keys(data), ['name', 'globIgnorePaths', 'tree']);
	assert.ok(changes.includes('added ReplicatedStorage'));
});

test('patchProject: odd but valid trees are patched in place', () => {
	const input = {
		tree: {
			$className: 'DataModel',
			ReplicatedStorage: { $path: 'src/ReplicatedStorage', LorenRuntime: { $path: 'vendor/loren', $ignoreUnknownInstances: true } },
			ServerScriptService: { $path: { optional: 'src/sss' } },
		},
		globIgnorePaths: ['**/*.tmp', 'loren_packages/**/*.spec.lua'],
		emitLegacyScripts: false,
	};
	const { data, changes } = patchProject(input, layout);
	assert.deepEqual(data.tree.ReplicatedStorage.LorenRuntime, { $path: 'loren/shared', $ignoreUnknownInstances: true });
	assert.ok(changes.includes('ReplicatedStorage.LorenRuntime now points at loren/shared (was vendor/loren)'));
	assert.equal(data.tree.ReplicatedStorage.$path, 'src/ReplicatedStorage');
	assert.deepEqual(data.tree.ServerScriptService.LorenServer, { $path: 'loren/server' });
	assert.deepEqual(data.globIgnorePaths, ['**/*.tmp', 'loren_packages/**/*.spec.lua', 'loren_packages/**/*.spec.luau']);
	assert.equal(data.emitLegacyScripts, false);
	assert.deepEqual(Object.keys(data), ['tree', 'globIgnorePaths', 'emitLegacyScripts']);
	assert.equal(input.tree.ReplicatedStorage.LorenRuntime.$path, 'vendor/loren', 'the input is not mutated');
});

test('patchProject: a $className on LorenRuntime/LorenServer is dropped (Rojo and Argon refuse it with $path)', () => {
	const input = {
		tree: {
			$className: 'DataModel',
			ReplicatedStorage: { LorenRuntime: { $className: 'Folder' } },
			ServerScriptService: { LorenServer: { $className: 'Folder', $path: 'loren/server', Extra: { $path: 'x' } } },
		},
	};
	const { data, changes } = patchProject(input, layout);
	assert.deepEqual(data.tree.ReplicatedStorage.LorenRuntime, { $path: 'loren/shared' });
	assert.deepEqual(data.tree.ServerScriptService.LorenServer, { $path: 'loren/server', Extra: { $path: 'x' } });
	assert.ok(changes.includes('ServerScriptService.LorenServer: removed "$className": "Folder" (it conflicts with $path)'));
	// idempotent: patching the result changes nothing more
	assert.deepEqual(patchProject(data, layout).changes, []);
});

test('patchProject: trees it cannot patch safely are refused with the lines to add by hand', () => {
	const cases = [
		[[], /is not a JSON object/],
		[{ name: 'x' }, /has no "tree" object/],
		[{ tree: { $className: 'Folder', $path: 'src' } }, /does not describe a place: its tree's \$className is "Folder"/],
		[{ tree: { $path: 'src' } }, /its tree's \$className is null/],
		[{ tree: { $className: 'DataModel', ReplicatedStorage: 'x' } }, /tree\.ReplicatedStorage .* is not an object/],
		[{ tree: { $className: 'DataModel', ServerScriptService: { LorenServer: 3 } } }, /LorenServer .* is not an object/],
		[{ globIgnorePaths: '**/*.spec.lua', tree: { $className: 'DataModel' } }, /"globIgnorePaths" .* is not a list/],
	];
	for (const [input, re] of cases) {
		const r = patchProject(input, layout);
		assert.match(r.error, re);
		assert.match(r.manual, /tree\.ReplicatedStorage\.LorenRuntime = \{ "\$path": "loren\/shared" \}/);
	}
});

test('an unpatchable tree stops the update before anything changes', async () => {
	const dir = h.project('v151');
	h.write(dir, 'default.project.json', JSON.stringify({ name: 'model', tree: { $className: 'Folder', $path: 'src' } }));
	const before = h.snapshot(dir);
	const { res, log } = await update(dir);
	assert.equal(res.exitCode, 1);
	assert.match(log.stderr(), /does not describe a place.*nothing was changed/);
	assert.match(log.stdout(), /Add these by hand:/);
	assert.deepEqual(h.snapshot(dir), before);
});

test('custom layout from the tree and CRLF project files', async () => {
	const dir = h.project('v151');
	fs.renameSync(path.join(dir, 'src'), path.join(dir, 'game'));
	fs.renameSync(path.join(dir, 'loren_packages'), path.join(dir, 'packages'));
	const text = h
		.read(dir, 'default.project.json')
		.replace(/src\//g, 'game/')
		.replace('"loren_packages"', '"packages"')
		.replace(/\n/g, '\r\n');
	h.write(dir, 'default.project.json', text);
	withoutTrade(dir, 'game');
	assert.deepEqual(layoutOf(dir, JSON.parse(text)), { shared: 'game/shared', server: 'game/server', client: 'game/client', packages: 'packages' });
	const { res } = await update(dir);
	assert.equal(res.exitCode, 0);
	const out = h.read(dir, 'default.project.json');
	assert.ok(out.includes('\r\n') && !/[^\r]\n/.test(out), 'CRLF kept');
	assert.deepEqual(JSON.parse(out).globIgnorePaths, ['packages/**/*.spec.lua', 'packages/**/*.spec.luau']);
	assert.equal(h.read(dir, 'game/shared/Loren.luau'), SHIM_SOURCE);
	assert.ok(h.exists(dir, 'game/shared/LorenTypes.luau'));
	assert.ok(h.exists(dir, 'game/server/LorenServerTypes.luau'));
	assert.ok(h.exists(dir, 'packages/Promise/lib/init.lua'));
});

test('a tree folder outside the project is explained, and the default folder is used', async () => {
	const dir = h.project('v2');
	const data = JSON.parse(h.read(dir, 'default.project.json'));
	data.tree.ReplicatedStorage.LorenPackages = { $path: '../shared-packages' };
	h.write(dir, 'default.project.json', JSON.stringify(data, null, '\t'));
	const { res, log } = await update(dir);
	assert.equal(res.exitCode, 0);
	assert.match(log.stderr(), /maps ReplicatedStorage\.LorenPackages -> \.\.\/shared-packages, outside this project/);
	assert.equal(JSON.parse(h.read(dir, 'default.project.json')).tree.ReplicatedStorage.LorenPackages.$path, '../shared-packages', 'left as it was');
	assert.ok(!fs.existsSync(path.join(dir, '..', 'shared-packages')), 'nothing written outside the project');
});

// Small helpers ---------------------------------------------------------------------------------------

test('classifyLorenFile and compareVersions', () => {
	assert.equal(classifyLorenFile(SHIM_SOURCE), 'shim');
	assert.equal(classifyLorenFile(`\uFEFF${SHIM_SOURCE.replace(/\n/g, '\r\n')}`), 'shim');
	assert.equal(classifyLorenFile(h.read(h.FIXTURES, 'v151/src/shared/Loren.luau')), 'runtime');
	assert.equal(classifyLorenFile(null), 'missing');
	assert.equal(classifyLorenFile('return 1'), 'other');
	assert.equal(h.read(h.FIXTURES, 'v2/src/shared/Loren.luau').replace(/\r\n/g, '\n'), SHIM_SOURCE, 'the 2.x fixture holds the current shim');
	assert.equal(h.read(h.REAL_PACKAGE_ROOT, 'project/src/shared/Loren.luau').replace(/\r\n/g, '\n'), SHIM_SOURCE, 'the scaffold shim is SHIM_SOURCE');
	assert.equal(compareVersions('2.0.0', '2.0.0'), 0);
	assert.equal(compareVersions('2.0.0-beta.1', '2.0.0'), -1);
	assert.equal(compareVersions('2.1.0', '2.0.9'), 1);
	assert.equal(compareVersions('10.0.0', '9.9.9'), 1);
	// pre-release parts compare as semver does
	assert.equal(compareVersions('2.0.0-beta.10', '2.0.0-beta.9'), 1);
	assert.equal(compareVersions('2.0.0-beta.2', '2.0.0-beta.10'), -1);
	assert.equal(compareVersions('2.0.0-rc-2', '2.0.0-rc-1'), 1, 'a dash inside the pre-release is kept');
	assert.equal(compareVersions('2.0.0-beta', '2.0.0-beta.1'), -1);
	assert.equal(compareVersions('2.0.0-1', '2.0.0-alpha'), -1, 'numeric parts sort before words');
	assert.equal(compareVersions('2.0.0-rc.1', '2.0.0-beta.3'), 1);
	assert.equal(compareVersions('2.0.0+build.5', '2.0.0'), 0);
});

// With the real runtime shipped in this package (read only), and a real Rojo build when installed.
test('the real package: full runtime copied, no spec files anywhere', async (t) => {
	const dir = h.project('v151');
	withoutTrade(dir);
	fs.rmSync(path.join(dir, 'aftman.toml')); // it pins rojo 7.4.1
	const { res } = await update(dir, { packageRoot: h.REAL_PACKAGE_ROOT });
	assert.equal(res.exitCode, 0);
	const real = h.snapshot(path.join(h.REAL_PACKAGE_ROOT, 'project', 'loren'));
	assert.deepEqual(Object.keys(h.snapshot(path.join(dir, 'loren'))).sort(), Object.keys(real).sort());
	const all = Object.keys(h.snapshot(dir)).filter((f) => !f.startsWith('.loren-backup/'));
	assert.deepEqual(all.filter((f) => /\.spec\.luau?$/.test(f)), []);

	const rojo = spawnSync('rojo', ['build', 'default.project.json', '-o', 'place.rbxlx'], { cwd: dir, encoding: 'utf8' });
	if (rojo.error || rojo.status !== 0) {
		t.diagnostic(`rojo build skipped: ${rojo.error ? rojo.error.message : rojo.stderr}`);
		return;
	}
	t.diagnostic('rojo build checked');
	const place = h.read(dir, 'place.rbxlx');
	assert.ok(place.includes('>LorenRuntime<') && place.includes('>LorenServer<') && place.includes('>Promise<'));
	assert.ok(!place.includes('init.spec'));
});
