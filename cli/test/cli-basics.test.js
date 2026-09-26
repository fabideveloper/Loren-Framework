'use strict';

// Name validation, prompts without a TTY, the update notifier, and exit codes of the real binary.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { PassThrough } = require('stream');
const { validateIdentifier, validateProjectName } = require('../lib/names');
const { createPrompter, detectTTY } = require('../lib/prompt');
const { checkForUpdates } = require('../lib/notifier');
const { nodeTooOld } = require('../index.js');
const { tmpDir, INDEX } = require('./helpers');
const pkg = require('../package.json');

test('validateIdentifier: Luau identifiers only, no paths, no keywords', () => {
	for (const good of ['Foo', 'FooService', '_private', 'a1', 'HTTPService']) {
		assert.equal(validateIdentifier(good).ok, true, good);
	}
	for (const bad of ['', '1abc', 'foo-bar', 'foo bar', 'a/b', 'a\\b', '..', 'a..b', 'end', 'local', 'nil', 'Foo.Bar', 'CON', 'nul', 'x'.repeat(101)]) {
		assert.equal(validateIdentifier(bad).ok, false, bad);
	}
	assert.match(validateIdentifier('a/b').reason, /path separators/);
	assert.match(validateIdentifier('end').reason, /keyword/);
});

test('validateProjectName: one folder, Windows-safe', () => {
	for (const good of ['my-game', 'My Game', 'game_2', 'v1.0']) assert.equal(validateProjectName(good).ok, true, good);
	for (const bad of ['', ' ', '.', '..', '../x', 'a/b', 'a\\b', 'con', 'LPT1', 'x.', 'x ', '-x', 'a:b', 'a*b']) {
		assert.equal(validateProjectName(bad).ok, false, bad);
	}
});

test('prompts never read without a TTY', async () => {
	const input = new PassThrough(); // a read would wait forever
	const p = createPrompter({ isTTY: false, input, output: new PassThrough() });
	assert.equal(await p.confirm('Go?'), false);
	assert.equal(await p.confirm('Go?', true), true);
	assert.equal(await p.choose('Tool?', [{ value: 'rojo', label: 'Rojo' }, { value: 'argon', label: 'Argon' }]), 'rojo');
	const yes = createPrompter({ yes: true, isTTY: false, input });
	assert.equal(await yes.confirm('Go?'), true);
	assert.equal(detectTTY({ isTTY: true }, { isTTY: true }, { CI: 'true' }), false);
	assert.equal(detectTTY({ isTTY: true }, { isTTY: true }, {}), true);
	assert.equal(detectTTY({}, { isTTY: true }, {}), false);
});

test('a terminal prompt resolves on EOF instead of hanging', async () => {
	const input = new PassThrough();
	const p = createPrompter({ isTTY: true, input, output: new PassThrough() });
	setImmediate(() => input.end());
	assert.equal(await p.confirm('Go?'), false);
	const input2 = new PassThrough();
	const p2 = createPrompter({ isTTY: true, input: input2, output: new PassThrough() });
	setImmediate(() => input2.write('yes\n'));
	assert.equal(await p2.confirm('Rewrite? (y/N)'), true);
});

test('the update notifier is lazy, optional and never throws', async () => {
	let imported = 0;
	const importer = async () => {
		imported += 1;
		throw new Error('ERR_REQUIRE_ESM');
	};
	assert.equal(await checkForUpdates(pkg, { isTTY: false, env: {}, importer }), false);
	assert.equal(imported, 0, 'no terminal: not even loaded');
	assert.equal(await checkForUpdates(pkg, { isTTY: true, env: { NO_UPDATE_NOTIFIER: '1' }, importer }), false);
	assert.equal(await checkForUpdates(pkg, { isTTY: true, env: {}, importer }), false);
	assert.equal(imported, 1);

	let notified = null;
	const fake = async () => ({ default: () => ({ notify: (o) => (notified = o) }) });
	assert.equal(await checkForUpdates(pkg, { isTTY: true, env: {}, importer: fake }), true);
	assert.equal(notified.defer, true);
	assert.match(notified.message, /npm i -g loren-framework/);
	assert.match(notified.message, /loren update/);
});

test('the Node version floor matches package.json engines', () => {
	assert.equal(pkg.engines.node, '>=18');
	assert.equal(nodeTooOld('16.20.0'), true);
	assert.equal(nodeTooOld('18.0.0'), false);
	assert.equal(nodeTooOld('22.14.0'), false);
});

// The real binary, no TTY (stdin is a pipe), no update check, no network.
function cli(args, cwd) {
	const r = spawnSync(process.execPath, [INDEX, ...args], {
		cwd,
		input: '',
		encoding: 'utf8',
		timeout: 60000,
		env: { ...process.env, NO_UPDATE_NOTIFIER: '1', CI: '1', NO_COLOR: '1' },
	});
	return { code: r.status, out: r.stdout, err: r.stderr, timedOut: Boolean(r.error) };
}

test('exit codes of the real binary', (t) => {
	const dir = tmpDir(t);
	const v = cli(['--version'], dir);
	assert.equal(v.code, 0);
	assert.equal(v.out.trim(), pkg.version);
	assert.equal(cli(['--help'], dir).code, 0);
	assert.equal(cli(['frobnicate'], dir).code, 1);
	assert.equal(cli(['init'], dir).code, 1, 'missing argument');
	assert.equal(cli(['init', 'x', '--tool', 'wally'], dir).code, 1, 'bad --tool');

	const make = cli(['make', 'service', 'Foo'], dir);
	assert.equal(make.code, 1);
	assert.match(make.err, /Error: No default\.project\.json/);
	assert.equal(make.out, '', 'no success output on failure');
	assert.equal(cli(['init', '../escape', '--no-tools'], dir).code, 1);
	assert.equal(cli(['refresh'], dir).code, 1);
	assert.equal(cli(['serve'], dir).code, 1);
	assert.equal(cli(['migrate', '--yes'], dir).code, 1);
	assert.deepEqual(fs.readdirSync(dir), []);
});

test('the real binary never waits for input without a TTY', (t) => {
	const dir = tmpDir(t);
	// init with no --tool: must not ask (defaults to Rojo); uses the real types generator.
	const init = cli(['init', 'game', '--no-tools'], dir);
	assert.equal(init.timedOut, false);
	assert.equal(init.code, 0, init.err);
	assert.match(fs.readFileSync(path.join(dir, 'game', 'rokit.toml'), 'utf8'), /rojo-rbx\/rojo/);
	assert.match(fs.readFileSync(path.join(dir, 'game', 'src', 'shared', 'LorenTypes.luau'), 'utf8'), /return table\.freeze\(\{\}\)/);

	// migrate without --yes: refuses at once, changes nothing.
	const root = path.join(dir, 'game');
	const migrate = cli(['migrate'], root);
	assert.equal(migrate.timedOut, false);
	assert.equal(migrate.code, 1);
	assert.match(migrate.err, /--yes/);
	assert.match(fs.readFileSync(path.join(root, 'rokit.toml'), 'utf8'), /rojo-rbx\/rojo/);
});
