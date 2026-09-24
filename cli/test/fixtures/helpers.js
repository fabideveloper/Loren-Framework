'use strict';

// Shared by the update/types/lint/tool tests. Every test works on a copy in the OS temp folder.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { createMemoryLogger } = require('../../lib/log');

const FIXTURES = __dirname;
const PACKAGE_ROOT = path.join(FIXTURES, 'package'); // a fake CLI package (project/loren, project/loren_packages)
const REAL_PACKAGE_ROOT = path.join(FIXTURES, '..', '..'); // cli/ (read only)
const NOW = new Date('2026-09-24T12:00:00.000Z');
const STAMP = '2026-09-24T12-00-00-000Z';

const temps = [];

function tempDir(prefix = 'loren-test-') {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
	temps.push(dir);
	return dir;
}

// A fresh copy of fixtures/<name> (or an empty folder when name is null).
function project(name) {
	const dir = tempDir(`loren-${name || 'empty'}-`);
	if (name) fs.cpSync(path.join(FIXTURES, name), dir, { recursive: true });
	return dir;
}

function cleanup() {
	while (temps.length) fs.rmSync(temps.pop(), { recursive: true, force: true });
}

// relative posix path -> file text, for every file under dir.
function snapshot(dir) {
	const out = {};
	const visit = (d) => {
		for (const e of fs.readdirSync(d, { withFileTypes: true })) {
			const full = path.join(d, e.name);
			if (e.isDirectory()) visit(full);
			else out[path.relative(dir, full).split(path.sep).join('/')] = fs.readFileSync(full, 'utf8');
		}
	};
	visit(dir);
	return out;
}

const read = (dir, rel) => fs.readFileSync(path.join(dir, ...rel.split('/')), 'utf8');
const exists = (dir, rel) => fs.existsSync(path.join(dir, ...rel.split('/')));
const write = (dir, rel, text) => {
	const file = path.join(dir, ...rel.split('/'));
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, text);
};

// A spawnSync stand-in: records calls; `installed` lists programs whose --version works;
// `fail` maps a program to a result for its other commands.
function fakeRunner({ installed = ['rojo', 'argon'], fail = {} } = {}) {
	const calls = [];
	const runner = (cmd, args = [], opts = {}) => {
		calls.push({ cmd, args: [...args], cwd: opts.cwd });
		if (!installed.includes(cmd)) {
			return { status: null, stdout: '', stderr: '', error: Object.assign(new Error(`spawn ${cmd} ENOENT`), { code: 'ENOENT' }) };
		}
		if (args[0] !== '--version' && fail[cmd]) return { status: 1, stdout: '', stderr: '', ...fail[cmd] };
		return { status: 0, stdout: '', stderr: '' };
	};
	runner.calls = calls;
	return runner;
}

// A confirm() that records its questions and answers `answer`.
function fakeConfirm(answer) {
	const asked = [];
	const confirm = async (q) => {
		asked.push(q);
		return answer;
	};
	confirm.asked = asked;
	return confirm;
}

module.exports = {
	FIXTURES,
	PACKAGE_ROOT,
	REAL_PACKAGE_ROOT,
	NOW,
	STAMP,
	tempDir,
	project,
	cleanup,
	snapshot,
	read,
	exists,
	write,
	fakeRunner,
	fakeConfirm,
	memLog: createMemoryLogger,
};
