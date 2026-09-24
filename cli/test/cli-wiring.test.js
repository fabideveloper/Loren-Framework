'use strict';

// update, types, doctor, serve, migrate and refresh: they call the right module with the right
// options and turn every failure into a non-zero exit code.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PassThrough } = require('stream');
const { tmpDir, fakeRunner, mockLanes, runCli, makeProject, read, CLI_ROOT } = require('./helpers');

test('update passes its flags to runUpdate and returns its exit code', async (t) => {
	const root = await makeProject(t);
	const lanes = mockLanes();
	const runner = fakeRunner();
	const r = await runCli(['update', '--dry-run', '--yes', '--no-native', '--tool', 'argon'], { cwd: root, lanes, run: runner.run });
	assert.equal(r.code, 0, r.all);
	const call = lanes.events.find((e) => e.fn === 'runUpdate');
	assert.equal(path.resolve(call.root), path.resolve(root));
	assert.equal(call.opts.dryRun, true);
	assert.equal(call.opts.yes, true);
	assert.equal(call.opts.noNative, true);
	assert.equal(call.opts.tool, 'argon');
	assert.equal(call.opts.isTTY, false);
	assert.equal(typeof call.opts.confirm, 'function');
	assert.equal(call.opts.log, r.log);
	assert.equal(call.opts.sourcemapRunner, runner.run);
	assert.equal(path.resolve(call.opts.packageRoot), path.resolve(CLI_ROOT));
	assert.ok(fs.existsSync(path.join(call.opts.packageRoot, 'project', 'loren', 'shared', 'init.luau')));

	const plain = mockLanes();
	await runCli(['update'], { cwd: root, lanes: plain });
	const o = plain.events.find((e) => e.fn === 'runUpdate').opts;
	assert.equal(o.dryRun, false);
	assert.equal(o.noNative, false);
	assert.equal(o.tool, undefined, 'no --tool: runUpdate detects it');

	const needsYes = await runCli(['update'], { cwd: root, lanes: mockLanes({ updateResult: { exitCode: 2 } }) });
	assert.equal(needsYes.code, 2);
	const failed = await runCli(['update'], { cwd: root, lanes: mockLanes({ updateResult: false }) });
	assert.equal(failed.code, 1);
	assert.match(failed.err, /did not finish/);
	const outside = await runCli(['update'], { cwd: tmpDir(t) });
	assert.equal(outside.code, 1);
});

test('update help says it updates the project, not the CLI', async (t) => {
	const r = await runCli(['update', '--help'], { cwd: tmpDir(t) });
	assert.equal(r.code, 0);
	assert.match(r.out, /PROJECT's Loren runtime/);
	assert.match(r.out, /npm i -g loren-framework/);
});

test('types calls generateTypes with the project folders; a throw exits 1', async (t) => {
	const root = await makeProject(t);
	const lanes = mockLanes();
	const r = await runCli(['types'], { cwd: root, lanes });
	assert.equal(r.code, 0, r.all);
	const call = lanes.events.find((e) => e.fn === 'generateTypes');
	assert.deepEqual(
		{ shared: call.opts.sharedDir, server: call.opts.serverDir, client: call.opts.clientDir },
		{ shared: path.join('src', 'shared'), server: path.join('src', 'server'), client: path.join('src', 'client') },
	);
	const bad = await runCli(['types'], { cwd: root, lanes: mockLanes({ typesResult: new Error('disk full') }) });
	assert.equal(bad.code, 1);
	assert.match(bad.err, /disk full/);
});

test('doctor runs the checks and the lint, and reports failures', async (t) => {
	const root = await makeProject(t);
	const lanes = mockLanes();
	const ok = await runCli(['doctor', '--fix', '--yes'], { cwd: root, lanes });
	assert.equal(ok.code, 0, ok.all);
	const call = lanes.events.find((e) => e.fn === 'runDoctor');
	assert.equal(call.opts.fix, true);
	assert.equal(call.opts.yes, true);
	assert.equal(call.opts.isTTY, false);
	assert.match(ok.out, /Runtime layout/);

	const lint = await runCli(['doctor'], { cwd: root, lanes: mockLanes({ doctorResult: { exitCode: 1 } }) });
	assert.equal(lint.code, 1);

	const noTool = await runCli(['doctor'], { cwd: root, run: fakeRunner({ missing: ['rojo'] }).run });
	assert.equal(noTool.code, 1);
	assert.match(noTool.err, /rojo does not run/);

	fs.writeFileSync(path.join(root, 'src', 'shared', 'Loren.luau'), '-- 1.5.1 runtime\nlocal Loren = {}\nreturn Loren\n');
	const legacy = await runCli(['doctor'], { cwd: root });
	assert.equal(legacy.code, 1);
	assert.match(legacy.err, /loren update/);

	const outsideLanes = mockLanes();
	const outside = await runCli(['doctor'], { cwd: tmpDir(t), lanes: outsideLanes });
	assert.equal(outside.code, 0, outside.all);
	assert.ok(!outsideLanes.events.some((e) => e.fn === 'runDoctor'));
});

test('serve (and ignite) run the tool in the foreground and pass on its exit code', async (t) => {
	const root = await makeProject(t);
	const runner = fakeRunner();
	const r = await runCli(['serve'], { cwd: root, run: runner.run });
	assert.equal(r.code, 0, r.all);
	assert.deepEqual(runner.calls[0].args, ['serve', 'default.project.json']);
	assert.equal(runner.calls[0].cmd, 'rojo');
	assert.equal(runner.calls[0].opts.stdio, 'inherit');
	assert.equal(path.resolve(runner.calls[0].opts.cwd), path.resolve(root));

	const argon = fakeRunner();
	assert.equal((await runCli(['ignite', '--tool', 'argon'], { cwd: root, run: argon.run })).code, 0);
	assert.equal(argon.calls[0].cmd, 'argon');
	assert.deepEqual(argon.calls[0].args, ['serve', 'default.project.json', '--sourcemap']);

	const crashed = await runCli(['serve'], { cwd: root, run: fakeRunner({ handlers: { rojo: () => ({ status: 3 }) } }).run });
	assert.equal(crashed.code, 3);
	const missing = await runCli(['serve'], { cwd: root, run: fakeRunner({ missing: ['rojo'] }).run });
	assert.equal(missing.code, 1);
	assert.match(missing.err, /not installed/);
	const badTool = await runCli(['serve', '--tool', 'wally'], { cwd: root });
	assert.equal(badTool.code, 1);
	const noTool = await runCli(['serve'], { cwd: root, lanes: mockLanes({ tool: new Error('No sync tool found.') }) });
	assert.equal(noTool.code, 1);
	assert.match(noTool.err, /No sync tool found/);
	assert.equal((await runCli(['serve'], { cwd: tmpDir(t) })).code, 1);
});

test('refresh runs the types, then the sourcemap; either failure exits 1', async (t) => {
	const root = await makeProject(t);
	const lanes = mockLanes({ tool: 'argon' });
	const ok = await runCli(['refresh'], { cwd: root, lanes });
	assert.equal(ok.code, 0, ok.all);
	const steps = lanes.events.filter((e) => e.fn === 'generateTypes' || e.fn === 'sourcemap');
	assert.deepEqual(
		steps.map((e) => e.fn),
		['generateTypes', 'sourcemap'],
	);
	assert.equal(steps[1].tool, 'argon');
	const bad = await runCli(['refresh'], { cwd: root, lanes: mockLanes({ sourcemapOk: false }) });
	assert.equal(bad.code, 1);
	assert.doesNotMatch(bad.out, /up to date/);
});

test('migrate needs --yes or a terminal; without either nothing changes', async (t) => {
	const root = await makeProject(t);
	const before = read(path.join(root, 'rokit.toml'));
	const input = new PassThrough(); // never answered: a prompt here would hang
	const r = await runCli(['migrate'], { cwd: root, isTTY: false, input });
	assert.equal(r.code, 1);
	assert.match(r.err, /needs a confirmation/);
	assert.equal(read(path.join(root, 'rokit.toml')), before);

	const tty = new PassThrough();
	setImmediate(() => tty.write('n\n'));
	const declined = await runCli(['migrate'], { cwd: root, isTTY: true, input: tty });
	assert.equal(declined.code, 1);
	assert.equal(read(path.join(root, 'rokit.toml')), before);
});

test('migrate rojo -> argon rewrites the manifest and settings, installs, and rebuilds the sourcemap', async (t) => {
	const root = await makeProject(t);
	fs.writeFileSync(path.join(root, 'rokit.toml'), '[tools]\nrojo = "rojo-rbx/rojo@7.4.1"\nstylua = "JohnnyMorganz/StyLua@2.0.0"\n');
	const lanes = mockLanes({ tool: 'rojo' });
	const runner = fakeRunner();
	const r = await runCli(['migrate', '--yes'], { cwd: root, lanes, run: runner.run });
	assert.equal(r.code, 0, r.all);
	const toml = read(path.join(root, 'rokit.toml'));
	assert.match(toml, /argon = "argon-rbx\/argon@2\.0\.29"/);
	assert.doesNotMatch(toml, /rojo-rbx/);
	assert.match(toml, /stylua/);
	const vs = JSON.parse(read(path.join(root, '.vscode', 'settings.json')));
	assert.equal(vs['luau-lsp.sourcemap.autogenerate'], false);
	assert.ok(fs.readdirSync(path.join(root, '.loren-backup')).length === 1);
	assert.ok(runner.calls.some((c) => c.cmd === 'rokit' && c.args.join(' ') === 'install --no-trust-check'));
	assert.equal(lanes.events.find((e) => e.fn === 'sourcemap').tool, 'argon');
	assert.match(r.out, /Migrated to Argon/);
});

test('migrate handles aftman.toml and foreman.toml, and a terminal "y"', async (t) => {
	const root = await makeProject(t);
	fs.rmSync(path.join(root, 'rokit.toml'));
	fs.writeFileSync(path.join(root, 'aftman.toml'), '[tools]\r\nargon = "argon-rbx/argon@2.0.6"\r\n');
	fs.writeFileSync(path.join(root, 'foreman.toml'), '[tools]\nargon = { source = "argon-rbx/argon", version = "2.0.6" }\n');
	const tty = new PassThrough();
	setImmediate(() => tty.write('y\n'));
	const r = await runCli(['migrate', '--to', 'rojo'], { cwd: root, lanes: mockLanes({ tool: 'argon' }), isTTY: true, input: tty });
	assert.equal(r.code, 0, r.all);
	assert.equal(read(path.join(root, 'aftman.toml')), '[tools]\r\nrojo = "rojo-rbx/rojo@7.5.1"\r\n');
	assert.match(read(path.join(root, 'foreman.toml')), /rojo = \{ source = "rojo-rbx\/rojo", version = "=7\.5\.1" \}/);
	assert.doesNotMatch(read(path.join(root, 'foreman.toml')), /argon/);
});

test('migrate fails without a success line when the new tool does not run', async (t) => {
	const root = await makeProject(t);
	const lanes = mockLanes({ tool: 'rojo' });
	const runner = fakeRunner({ missing: ['argon'], handlers: { rokit: () => ({ status: 1 }) } });
	const r = await runCli(['migrate', '--yes'], { cwd: root, lanes, run: runner.run });
	assert.equal(r.code, 1);
	assert.match(r.err, /argon does not run/);
	assert.doesNotMatch(r.out, /Migrated/);
	assert.ok(!lanes.events.some((e) => e.fn === 'sourcemap'));

	const same = await runCli(['migrate', '--to', 'rojo', '--yes'], { cwd: await makeProject(t), lanes: mockLanes({ tool: 'rojo' }) });
	assert.equal(same.code, 0);
	assert.match(same.out, /already uses Rojo/);
});

test('a missing module fails cleanly', async (t) => {
	const root = await makeProject(t);
	const r = await runCli(['update'], { cwd: root, lanes: { ...mockLanes(), update: {} } });
	assert.equal(r.code, 1);
	assert.match(r.err, /incomplete/);
});

test('refresh --watch regenerates the types on changes and the sourcemap when files are added', async (t) => {
	const { watchProject } = require('../lib/commands/refresh');
	const { createMemoryLogger } = require('../lib/log');
	const { createLanes } = require('../lib/lanes');
	const root = await makeProject(t);
	const lanes = mockLanes();
	const ctx = { cwd: root, log: createMemoryLogger(), run: fakeRunner().run, lanes: createLanes(lanes) };
	const controller = new AbortController();
	const done = watchProject(ctx, root, 'rojo', { debounceMs: 30, signal: controller.signal });
	await new Promise((r) => setTimeout(r, 100));
	fs.writeFileSync(path.join(root, 'src', 'server', 'Services', 'NewService.luau'), 'return {}\n');
	const deadline = Date.now() + 5000;
	while (!lanes.events.some((e) => e.fn === 'sourcemap') && Date.now() < deadline) {
		await new Promise((r) => setTimeout(r, 25));
	}
	controller.abort();
	assert.equal(await done, 0);
	assert.ok(lanes.events.some((e) => e.fn === 'generateTypes'), 'types regenerated');
	assert.ok(lanes.events.some((e) => e.fn === 'sourcemap'), 'sourcemap regenerated for a new file');
});
