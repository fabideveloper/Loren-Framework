'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { PassThrough } = require('stream');
const { main } = require('../index.js');
const { createMemoryLogger } = require('../lib/log');

const CLI_ROOT = path.join(__dirname, '..');
const INDEX = path.join(CLI_ROOT, 'index.js');
const TEMPLATE_DIR = path.join(CLI_ROOT, 'project');

function tmpDir(t) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'loren-cli-test-'));
	if (t && typeof t.after === 'function') t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
	return dir;
}

function fakeRunner({ handlers = {}, missing = [] } = {}) {
	const calls = [];
	const run = (cmd, args = [], opts = {}) => {
		calls.push({ cmd, args: [...args], opts });
		if (missing.includes(cmd)) {
			return { status: null, error: Object.assign(new Error(`spawn ${cmd} ENOENT`), { code: 'ENOENT' }), stdout: '', stderr: '' };
		}
		if (handlers[cmd]) {
			const r = handlers[cmd](args, opts);
			if (r) return { stdout: '', stderr: '', error: undefined, ...r };
		}
		return { status: 0, stdout: '', stderr: '', error: undefined };
	};
	return { run, calls };
}

// Mocks of the other modules. `events` records the order of calls across all of them.
function mockLanes({ tool = 'rojo', events = [], sourcemapOk = true, typesResult, doctorResult, updateResult } = {}) {
	return {
		events,
		tool: {
			resolveTool(root, override) {
				events.push({ fn: 'resolveTool', root, override });
				if (override) return override;
				if (tool instanceof Error) throw tool;
				return tool;
			},
			detectTool(root) {
				events.push({ fn: 'detectTool', root });
				return tool instanceof Error ? null : tool;
			},
			sourcemap(root, t, run) {
				events.push({ fn: 'sourcemap', root, tool: t, run });
				return sourcemapOk ? { ok: true } : { ok: false, error: `${t} is not installed or not on PATH.` };
			},
			serveArgs(t) {
				return t === 'argon' ? ['serve', 'default.project.json', '--sourcemap'] : ['serve', 'default.project.json'];
			},
		},
		types: {
			generateTypes(root, opts) {
				events.push({ fn: 'generateTypes', root, opts });
				if (typesResult instanceof Error) throw typesResult;
				return typesResult !== undefined ? typesResult : { written: [path.join(root, 'src', 'shared', 'LorenTypes.luau')] };
			},
		},
		lint: {
			async runDoctor(root, opts) {
				events.push({ fn: 'runDoctor', root, opts });
				return doctorResult !== undefined ? doctorResult : { issues: [], exitCode: 0 };
			},
		},
		update: {
			async runUpdate(root, opts) {
				events.push({ fn: 'runUpdate', root, opts });
				return updateResult !== undefined ? updateResult : { exitCode: 0, actions: [] };
			},
		},
	};
}

// Runs the CLI in-process. Returns { code, out, err, all, log }.
async function runCli(args, opts = {}) {
	const log = createMemoryLogger();
	const input = opts.input || new PassThrough();
	const code = await main(['node', 'loren', ...args], {
		cwd: opts.cwd,
		log,
		lanes: opts.lanes || mockLanes(),
		run: opts.run || fakeRunner().run,
		isTTY: Boolean(opts.isTTY),
		input,
		output: opts.output || new PassThrough(),
		degit: opts.degit,
		templateDir: opts.templateDir,
		packageRoot: opts.packageRoot,
		notify: false,
	});
	return { code, out: log.stdout(), err: log.stderr(), all: log.output(), log };
}

// A fresh project made by `loren init --no-tools` with mocks. Returns its root.
async function makeProject(t, { tool = 'rojo', name = 'game' } = {}) {
	const dir = tmpDir(t);
	const res = await runCli(['init', name, '--tool', tool, '--yes', '--no-tools'], { cwd: dir, lanes: mockLanes({ tool }) });
	if (res.code !== 0) throw new Error(`init failed: ${res.all}`);
	return path.join(dir, name);
}

// Every file under dir, as posix relative paths.
function listFiles(dir) {
	const out = [];
	const walk = (d, base) => {
		for (const e of fs.readdirSync(d, { withFileTypes: true })) {
			const rel = base ? `${base}/${e.name}` : e.name;
			if (e.isDirectory()) walk(path.join(d, e.name), rel);
			else out.push(rel);
		}
	};
	walk(dir, '');
	return out.sort();
}

const read = (p) => fs.readFileSync(p, 'utf8');

module.exports = { CLI_ROOT, INDEX, TEMPLATE_DIR, tmpDir, fakeRunner, mockLanes, runCli, makeProject, listFiles, read };
