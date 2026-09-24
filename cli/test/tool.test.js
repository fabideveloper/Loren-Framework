'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const tool = require('../lib/tool');
const h = require('./fixtures/helpers');

test.after(h.cleanup);

test('manifestTools reads Rokit/Aftman strings and Foreman tables, ignoring comments', () => {
	assert.deepEqual(tool.manifestTools('[tools]\nrojo = "rojo-rbx/rojo@7.5.1"\n'), ['rojo']);
	assert.deepEqual(tool.manifestTools('[tools]\nargon = "argon-rbx/argon@2.0.29"\n'), ['argon']);
	assert.deepEqual(tool.manifestTools('[tools]\nrojo = { source = "rojo-rbx/rojo", version = "7.5.1" }\n'), ['rojo']);
	assert.deepEqual(tool.manifestTools('[tools]\nrojo = { github = "rojo-rbx/rojo", version = "7" }\n'), ['rojo']);
	assert.deepEqual(tool.manifestTools('[tools]\n# argon = "argon-rbx/argon@2.0.29"\nrojo = "rojo-rbx/rojo@7.5.1" # sync\n'), ['rojo']);
	assert.deepEqual(tool.manifestTools('[tools]\nx = "rojo-rbx/rojo-plugin@1.0.0"\n'), []);
	assert.deepEqual(tool.manifestTools('[tools]\nrojo = "Rojo-Rbx/Rojo@7.5.1"\nargon = "argon-rbx/argon@2"\n'), ['rojo', 'argon']);
});

test('detectTool prefers manifests (rokit, aftman, foreman), Argon when one lists both', () => {
	const dir = h.project(null);
	assert.equal(tool.detectTool(dir, h.fakeRunner({ installed: [] })), null);

	const runner = h.fakeRunner({ installed: [] });
	h.write(dir, 'foreman.toml', '[tools]\nargon = { source = "argon-rbx/argon", version = "2.0.29" }\n');
	assert.deepEqual(tool.detectToolInfo(dir, runner), { tool: 'argon', source: 'foreman.toml' });

	h.write(dir, 'aftman.toml', '[tools]\nrojo = "rojo-rbx/rojo@7.5.1"\n');
	assert.deepEqual(tool.detectToolInfo(dir, runner), { tool: 'rojo', source: 'aftman.toml' });

	h.write(dir, 'rokit.toml', '[tools]\nrojo = "rojo-rbx/rojo@7.5.1"\nargon = "argon-rbx/argon@2.0.29"\n');
	assert.deepEqual(tool.detectToolInfo(dir, runner), { tool: 'argon', source: 'rokit.toml' });
	assert.equal(runner.calls.length, 0, 'a manifest answer never runs a program');
});

test('detectTool falls back to what is installed, Rojo first', () => {
	const dir = h.project(null);
	h.write(dir, 'rokit.toml', '[tools]\nstylua = "johnnymorganz/stylua@2.5.2"\n');
	assert.equal(tool.detectTool(dir, h.fakeRunner({ installed: ['argon'] })), 'argon');
	assert.equal(tool.detectTool(dir, h.fakeRunner({ installed: ['rojo', 'argon'] })), 'rojo');
	assert.equal(tool.detectTool(dir, h.fakeRunner({ installed: [] })), null);
	const runner = h.fakeRunner({ installed: ['rojo'] });
	tool.detectTool(dir, runner);
	assert.deepEqual(runner.calls[0], { cmd: 'rojo', args: ['--version'], cwd: dir });
});

test('detectTool reads the fixtures: 1.5.1 aftman rojo, 2.x rokit rojo, Argon project', () => {
	const none = h.fakeRunner({ installed: [] });
	assert.equal(tool.detectTool(h.project('v151'), none), 'rojo');
	assert.equal(tool.detectTool(h.project('v2'), none), 'rojo');
	assert.equal(tool.detectTool(h.project('argon'), none), 'argon');
});

test('resolveTool: --tool wins (any case), bad values and nothing found throw clear errors', () => {
	const dir = h.project('v2');
	const none = h.fakeRunner({ installed: [] });
	assert.equal(tool.resolveTool(dir, 'ARGON', none), 'argon');
	assert.equal(tool.resolveTool(dir, undefined, none), 'rojo');
	assert.equal(tool.resolveTool(dir, '', none), 'rojo');
	assert.throws(() => tool.resolveTool(dir, 'wally', none), /Unknown sync tool "wally".*--tool rojo or --tool argon/);
	assert.throws(() => tool.resolveTool(h.project(null), null, none), /No sync tool found.*--tool rojo\|argon/);
});

test('sourcemap runs the same command with Rojo and with Argon', () => {
	const dir = h.project('v2');
	for (const id of ['rojo', 'argon']) {
		const runner = h.fakeRunner();
		assert.deepEqual(tool.sourcemap(dir, id, runner), { ok: true });
		assert.deepEqual(runner.calls, [{ cmd: id, args: ['sourcemap', 'default.project.json', '-o', 'sourcemap.json'], cwd: dir }]);
	}
});

test('sourcemap reports a missing tool, a failing tool and a bad id without throwing', () => {
	const dir = h.project('v2');
	const missing = tool.sourcemap(dir, 'argon', h.fakeRunner({ installed: ['rojo'] }));
	assert.equal(missing.ok, false);
	assert.match(missing.error, /argon is not installed or not on PATH.*rokit add argon-rbx\/argon/);

	const failing = tool.sourcemap(dir, 'rojo', h.fakeRunner({ fail: { rojo: { status: 3, stderr: '\x1b[31mERROR\x1b[0m bad project\n' } } }));
	assert.equal(failing.ok, false);
	assert.equal(failing.error, 'Rojo sourcemap failed (exit 3): ERROR bad project');

	const throwing = tool.sourcemap(dir, 'rojo', () => {
		throw new Error('boom');
	});
	assert.deepEqual(throwing, { ok: false, error: 'Rojo could not start: boom' });
	assert.equal(tool.sourcemap(dir, 'wally', h.fakeRunner()).ok, false);
});

test('serveArgs: rojo serve / argon serve (Argon writes its own sourcemap)', () => {
	assert.deepEqual(tool.serveArgs('rojo'), ['serve', 'default.project.json']);
	assert.deepEqual(tool.serveArgs('Argon'), ['serve', 'default.project.json', '--sourcemap']);
	assert.throws(() => tool.serveArgs('wally'), /Unknown sync tool/);
});

test('vscodeSettings: Luau-LSP autogenerates the sourcemap only for Rojo', () => {
	assert.equal(tool.vscodeSettings('rojo')['luau-lsp.sourcemap.autogenerate'], true);
	assert.equal(tool.vscodeSettings('argon')['luau-lsp.sourcemap.autogenerate'], false);
	assert.equal(tool.vscodeSettings('argon')['luau-lsp.sourcemap.sourcemapFile'], 'sourcemap.json');
});

test('defaultRun starts a .cmd shim through one quoted shell command line (Windows)', { skip: process.platform !== 'win32' && 'Windows only' }, () => {
	const bin = h.tempDir('loren tool bin ');
	h.write(bin, 'loren-fake-shim.cmd', '@echo off\r\necho [%1][%2][%3]\r\nexit /b 3\r\n');
	const env = { ...process.env, PATH: `${bin};${process.env.PATH}` };
	const r = tool.defaultRun('loren-fake-shim', ['sourcemap', 'my project.json', '-o'], { env, cwd: bin });
	assert.equal(r.error, undefined);
	assert.equal(r.status, 3, 'the shim exit code comes through');
	assert.equal(r.stdout.trim(), '[sourcemap]["my project.json"][-o]');
	// a program that exists nowhere: cmd.exe's 9009, reported as ENOENT
	const missing = tool.defaultRun('loren-no-such-program-xyz', ['--version'], { env });
	assert.equal(missing.error && missing.error.code, 'ENOENT');
});

test('defaultRun runs a real program and reports a missing one as ENOENT', () => {
	const ok = tool.defaultRun(process.execPath, ['-e', 'process.stdout.write("hi")']);
	assert.equal(ok.status, 0);
	assert.equal(ok.stdout, 'hi');
	const missing = tool.defaultRun('loren-no-such-program-xyz', ['--version']);
	assert.equal(missing.error && missing.error.code, 'ENOENT');
	assert.equal(tool.isInstalled('loren-no-such-program-xyz'), false);
});
