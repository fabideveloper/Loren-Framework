'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PassThrough } = require('stream');
const { SHIM_SOURCE, TOOLS, GLOB_IGNORE_PATHS } = require('../lib/constants');
const { tmpDir, fakeRunner, mockLanes, runCli, listFiles, read, TEMPLATE_DIR } = require('./helpers');

async function init(t, args, opts = {}) {
	const dir = opts.dir || tmpDir(t);
	const lanes = opts.lanes || mockLanes({ tool: opts.tool || 'rojo' });
	const runner = opts.runner || fakeRunner();
	const res = await runCli(['init', ...args], { cwd: dir, lanes, run: runner.run, isTTY: opts.isTTY, input: opts.input });
	return { ...res, dir, lanes, runner };
}

for (const tool of ['rojo', 'argon']) {
	test(`init --tool ${tool} writes a complete 2.0 project`, async (t) => {
		const r = await init(t, ['game', '--tool', tool, '--yes'], { tool });
		assert.equal(r.code, 0, r.all);
		const root = path.join(r.dir, 'game');
		const files = listFiles(root);

		// Runtime, shim, bootstraps, templates.
		assert.ok(files.includes('loren/shared/init.luau'));
		assert.ok(files.includes('loren/server/init.luau'));
		assert.equal(read(path.join(root, 'src/shared/Loren.luau')), SHIM_SOURCE);
		assert.match(read(path.join(root, 'src/server/Server.server.luau')), /Loren\.SetOnFire\(\):expect\(\)/);
		assert.match(read(path.join(root, 'src/client/Client.client.luau')), /Loren\.SetOnFire\(\):expect\(\)/);
		for (const f of ['src/server/Services/ExampleService.luau', 'src/client/Controllers/ExampleController.luau']) {
			assert.equal(read(path.join(root, f)), read(path.join(TEMPLATE_DIR, f)));
		}

		// Promise: only lib/init.lua, LICENSE and its project file. No test code anywhere.
		assert.deepEqual(
			files.filter((f) => f.startsWith('loren_packages/')),
			['loren_packages/Promise/LICENSE', 'loren_packages/Promise/default.project.json', 'loren_packages/Promise/lib/init.lua'],
		);
		assert.equal(files.filter((f) => /\.spec\.luau?$/.test(f)).length, 0);
		assert.ok(!files.some((f) => f.startsWith('loren_premade/')), 'premades stay in the CLI');
		assert.ok(!files.includes('aftman.toml'));

		// Project file.
		const pj = JSON.parse(read(path.join(root, 'default.project.json')));
		assert.equal(pj.name, 'game');
		for (const g of GLOB_IGNORE_PATHS) assert.ok(pj.globIgnorePaths.includes(g));
		assert.equal(pj.tree.ReplicatedStorage.Shared.$path, 'src/shared');
		assert.equal(pj.tree.ReplicatedStorage.LorenPackages.$path, 'loren_packages');
		assert.equal(pj.tree.ReplicatedStorage.LorenRuntime.$path, 'loren/shared');
		assert.equal(pj.tree.ServerScriptService.LorenServer.$path, 'loren/server');
		assert.equal(pj.tree.ServerScriptService.Server.$path, 'src/server');
		assert.equal(pj.tree.StarterPlayer.StarterPlayerScripts.Client.$path, 'src/client');

		// Toolchain, gitignore, editor settings for the chosen tool.
		const rokit = read(path.join(root, 'rokit.toml'));
		assert.ok(rokit.includes(`${tool} = "${TOOLS[tool].spec}"`));
		assert.ok(!rokit.includes(tool === 'rojo' ? 'argon' : 'rojo-rbx'));
		const gi = read(path.join(root, '.gitignore')).split('\n');
		for (const line of ['sourcemap.json', '.loren-backup/', '*.rbxl', '*.rbxlx']) assert.ok(gi.includes(line), line);
		const vs = JSON.parse(read(path.join(root, '.vscode/settings.json')));
		assert.equal(vs['luau-lsp.sourcemap.autogenerate'], tool === 'rojo');
		assert.equal(vs['luau-lsp.sourcemap.enabled'], true);

		// Types first, then the toolchain, then the sourcemap with the chosen tool.
		const order = r.lanes.events.filter((e) => e.fn === 'generateTypes' || e.fn === 'sourcemap').map((e) => e.fn);
		assert.deepEqual(order, ['generateTypes', 'sourcemap']);
		assert.equal(r.lanes.events.find((e) => e.fn === 'sourcemap').tool, tool);
		const install = r.runner.calls.find((c) => c.cmd === 'rokit' && c.args[0] === 'install');
		assert.ok(install, 'rokit install ran');
		assert.equal(path.resolve(install.opts.cwd), path.resolve(root));
		assert.ok(install.args.includes('--no-trust-check'), '--yes skips the trust prompt');
		assert.match(r.out, /is ready/);
	});
}

test('init --no-tools skips the install and the sourcemap', async (t) => {
	const r = await init(t, ['game', '--tool', 'rojo', '--no-tools']);
	assert.equal(r.code, 0, r.all);
	assert.equal(r.runner.calls.length, 0);
	assert.ok(!r.lanes.events.some((e) => e.fn === 'sourcemap'));
	assert.ok(r.lanes.events.some((e) => e.fn === 'generateTypes'));
});

test('init without a TTY never prompts and defaults to Rojo', async (t) => {
	const input = new PassThrough(); // never ends: a read would hang the test
	const r = await init(t, ['game', '--no-tools'], { isTTY: false, input });
	assert.equal(r.code, 0, r.all);
	assert.match(read(path.join(r.dir, 'game', 'rokit.toml')), /rojo-rbx\/rojo/);
	assert.match(r.out, /Using Rojo/);
});

test('init in a terminal asks for the tool', async (t) => {
	const input = new PassThrough();
	input.isTTY = true;
	setImmediate(() => input.write('2\n'));
	const r = await init(t, ['game', '--no-tools'], { isTTY: true, input });
	assert.equal(r.code, 0, r.all);
	assert.match(read(path.join(r.dir, 'game', 'rokit.toml')), /argon-rbx\/argon/);
});

test('init refuses an existing folder and bad names', async (t) => {
	const dir = tmpDir(t);
	fs.mkdirSync(path.join(dir, 'taken'));
	fs.writeFileSync(path.join(dir, 'taken', 'keep.txt'), 'x');
	const r = await init(t, ['taken', '--tool', 'rojo', '--no-tools'], { dir });
	assert.equal(r.code, 1);
	assert.match(r.err, /already exists/);
	assert.deepEqual(fs.readdirSync(path.join(dir, 'taken')), ['keep.txt']);

	for (const bad of ['../escape', 'a/b', 'a\\b', 'con', '..', 'bad*name']) {
		const b = await init(t, [bad, '--tool', 'rojo', '--no-tools'], { dir });
		assert.equal(b.code, 1, bad);
	}
	assert.deepEqual(fs.readdirSync(dir).sort(), ['taken']);
});

test('init into an empty folder works', async (t) => {
	const dir = tmpDir(t);
	fs.mkdirSync(path.join(dir, 'empty'));
	const r = await init(t, ['empty', '--tool', 'argon', '--no-tools'], { dir });
	assert.equal(r.code, 0, r.all);
	assert.ok(fs.existsSync(path.join(dir, 'empty', 'loren', 'shared', 'init.luau')));
});

test('init reports a failed toolchain or sourcemap with exit 1 and no success line', async (t) => {
	const noManager = await init(t, ['game', '--tool', 'rojo', '--yes'], {
		runner: fakeRunner({ missing: ['rokit', 'aftman', 'foreman'] }),
	});
	assert.equal(noManager.code, 1);
	assert.match(noManager.err, /No toolchain manager/);
	assert.doesNotMatch(noManager.out, /is ready/);
	assert.ok(fs.existsSync(path.join(noManager.dir, 'game', 'default.project.json')), 'the project is still there');

	const badMap = await init(t, ['game', '--tool', 'argon', '--yes'], { lanes: mockLanes({ tool: 'argon', sourcemapOk: false }) });
	assert.equal(badMap.code, 1);
	assert.match(badMap.err, /sourcemap\.json was not regenerated/);
	assert.doesNotMatch(badMap.out, /is ready/);
});

test('init rolls back when the template is broken', async (t) => {
	const dir = tmpDir(t);
	const broken = path.join(tmpDir(t), 'project');
	fs.mkdirSync(broken);
	fs.copyFileSync(path.join(TEMPLATE_DIR, 'default.project.json'), path.join(broken, 'default.project.json'));
	const res = await runCli(['init', 'game', '--tool', 'rojo', '--no-tools'], { cwd: dir, templateDir: broken });
	assert.equal(res.code, 1);
	assert.match(res.err, /Could not create the project/);
	assert.ok(!fs.existsSync(path.join(dir, 'game')));
});
