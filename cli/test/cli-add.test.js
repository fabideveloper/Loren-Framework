'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { parseRepoSpec, derivePackageName } = require('../lib/names');
const { tmpDir, mockLanes, runCli, makeProject, listFiles, read } = require('./helpers');

// A degit stand-in: records the spec and writes `files` into the clone target (no network).
function fakeDegit({ files = { 'default.project.json': '{"name":"x","tree":{"$path":"src"}}', 'src/init.luau': 'return {}' }, fail = null } = {}) {
	const calls = [];
	const degit = (spec, opts) => ({
		async clone(dest) {
			calls.push({ spec, opts, dest });
			if (fail) throw new Error(fail);
			for (const [rel, text] of Object.entries(files)) {
				fs.mkdirSync(path.dirname(path.join(dest, rel)), { recursive: true });
				fs.writeFileSync(path.join(dest, rel), text);
			}
		},
	});
	return { degit, calls };
}

test('parseRepoSpec accepts user/repo, refs and GitHub URLs', () => {
	const cases = [
		['user/repo', 'user', 'repo', null],
		['user/repo#v1.2.0', 'user', 'repo', 'v1.2.0'],
		['https://github.com/user/repo', 'user', 'repo', null],
		['https://github.com/user/repo.git', 'user', 'repo', null],
		['https://github.com/user/repo/', 'user', 'repo', null],
		['http://www.github.com/user/repo', 'user', 'repo', null],
		['https://github.com/user/repo/tree/feature/x', 'user', 'repo', 'feature/x'],
		['https://github.com/user/repo#dev', 'user', 'repo', 'dev'],
		['git@github.com:user/repo.git', 'user', 'repo', null],
		['github:user/repo', 'user', 'repo', null],
		['  Some-Org/my.repo_1  ', 'Some-Org', 'my.repo_1', null],
	];
	for (const [input, owner, repo, ref] of cases) {
		const r = parseRepoSpec(input);
		assert.equal(r.ok, true, `${input}: ${r.reason}`);
		assert.equal(r.owner, owner, input);
		assert.equal(r.repo, repo, input);
		assert.equal(r.ref, ref, input);
		assert.equal(r.spec, ref ? `${owner}/${repo}#${ref}` : `${owner}/${repo}`);
	}
});

test('parseRepoSpec rejects anything that is not a GitHub repository', () => {
	for (const bad of [
		'',
		'   ',
		'user',
		'https://github.com/',
		'https://gitlab.com/user/repo',
		'user/repo/extra',
		'us er/repo',
		'user/..',
		'user/repo#',
		'user/repo#../x',
		'-user/repo',
		'file:///etc/passwd',
	]) {
		assert.equal(parseRepoSpec(bad).ok, false, `accepted ${JSON.stringify(bad)}`);
	}
});

test('derivePackageName turns repo names into safe identifiers', () => {
	const ok = (repo) => derivePackageName(repo).value;
	assert.equal(ok('Janitor'), 'Janitor');
	assert.equal(ok('roblox-lua-promise'), 'promise');
	assert.equal(ok('my-lib'), 'MyLib');
	assert.equal(ok('rbx.util'), 'RbxUtil');
	assert.equal(ok('3d-math'), '_3dMath');
	assert.equal(ok('end'), 'End');
});

test('add downloads into loren_packages/<Name> and refreshes types then sourcemap', async (t) => {
	const root = await makeProject(t);
	const { degit, calls } = fakeDegit();
	const lanes = mockLanes();
	const r = await runCli(['add', 'https://github.com/howmanysmall/Janitor.git'], { cwd: root, degit, lanes });
	assert.equal(r.code, 0, r.all);
	assert.equal(calls.length, 1);
	assert.equal(calls[0].spec, 'howmanysmall/Janitor');
	assert.ok(!calls[0].dest.startsWith(root), 'clones into a temp folder first');
	assert.ok(fs.existsSync(path.join(root, 'loren_packages', 'Janitor', 'src', 'init.luau')));
	assert.match(r.out, /LorenPackages\.Janitor/);
	assert.deepEqual(
		lanes.events.filter((e) => e.fn !== 'resolveTool').map((e) => e.fn),
		['generateTypes', 'sourcemap'],
	);
	assert.ok(!fs.existsSync(calls[0].dest), 'temp folder removed');
});

test('add uses the alias, validates it, and keeps refs', async (t) => {
	const root = await makeProject(t);
	const { degit, calls } = fakeDegit();
	const r = await runCli(['add', 'user/some-lib#v2.0.0', 'Lib'], { cwd: root, degit });
	assert.equal(r.code, 0, r.all);
	assert.equal(calls[0].spec, 'user/some-lib#v2.0.0');
	assert.ok(fs.existsSync(path.join(root, 'loren_packages', 'Lib')));

	for (const bad of ['../x', 'a/b', 'my-lib', '1x', 'nil', 'CON']) {
		const b = await runCli(['add', 'user/other', bad], { cwd: root, degit });
		assert.equal(b.code, 1, bad);
	}
	assert.equal(calls.length, 1, 'no download for a bad alias');
});

test('add never replaces the bundled Promise or an existing package without --force', async (t) => {
	const root = await makeProject(t);
	const promiseBefore = listFiles(path.join(root, 'loren_packages', 'Promise'));
	const { degit, calls } = fakeDegit();

	const promise = await runCli(['add', 'evaera/roblox-lua-promise'], { cwd: root, degit });
	assert.equal(promise.code, 1);
	assert.match(promise.err, /bundled with Loren/);
	const promiseAlias = await runCli(['add', 'user/repo', 'PROMISE'], { cwd: root, degit });
	assert.equal(promiseAlias.code, 1);
	assert.equal(calls.length, 0);
	assert.deepEqual(listFiles(path.join(root, 'loren_packages', 'Promise')), promiseBefore);

	assert.equal((await runCli(['add', 'user/Thing'], { cwd: root, degit })).code, 0);
	const dup = await runCli(['add', 'other/thing'], { cwd: root, degit });
	assert.equal(dup.code, 1, 'case-insensitive collision');
	assert.match(dup.err, /already exists/);

	fs.writeFileSync(path.join(root, 'loren_packages', 'Thing', 'marker.txt'), 'old');
	const forced = await runCli(['add', 'other/thing', 'Thing', '--force'], { cwd: root, degit });
	assert.equal(forced.code, 0, forced.all);
	assert.ok(!fs.existsSync(path.join(root, 'loren_packages', 'Thing', 'marker.txt')), 'replaced, not merged');
	const backup = listFiles(path.join(root, '.loren-backup'));
	assert.ok(backup.some((f) => f.endsWith('loren_packages/Thing/marker.txt')));
});

test('add leaves nothing behind when the download fails or is empty', async (t) => {
	const root = await makeProject(t);
	const before = fs.readdirSync(path.join(root, 'loren_packages')).sort();
	const failed = await runCli(['add', 'user/repo'], { cwd: root, degit: fakeDegit({ fail: 'could not find commit hash' }).degit });
	assert.equal(failed.code, 1);
	assert.match(failed.err, /Could not download user\/repo/);
	const empty = await runCli(['add', 'user/repo'], { cwd: root, degit: fakeDegit({ files: {} }).degit });
	assert.equal(empty.code, 1);
	assert.deepEqual(fs.readdirSync(path.join(root, 'loren_packages')).sort(), before);
});

test('add warns when the package has no entry point, and rejects bad input and non-projects', async (t) => {
	const root = await makeProject(t);
	const r = await runCli(['add', 'user/docs-only'], { cwd: root, degit: fakeDegit({ files: { 'README.md': '# hi' } }).degit });
	assert.equal(r.code, 0, r.all);
	assert.match(r.err, /no default\.project\.json or init\.lua\(u\)/);

	const bad = await runCli(['add', 'https://gitlab.com/a/b'], { cwd: root, degit: fakeDegit().degit });
	assert.equal(bad.code, 1);
	const outside = await runCli(['add', 'user/repo'], { cwd: tmpDir(t), degit: fakeDegit().degit });
	assert.equal(outside.code, 1);
	assert.match(outside.err, /No default\.project\.json/);
	assert.equal(read(path.join(root, 'loren_packages', 'Promise', 'lib', 'init.lua')).length > 0, true);
});
