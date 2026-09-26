'use strict';

const { spawnSync } = require('child_process');
const path = require('path');
const { TOOLS, MANAGERS, MANAGER_FILES, PROJECT_FILE, SCRIPT_SYNC, LOREN_CONFIG_FILE } = require('./constants');
const { readTextIfExists } = require('./fsutil');
const { isScriptSync, PLUGIN_SETTINGS } = require('./scriptsync');

const TOOL_IDS = Object.freeze(Object.keys(TOOLS)); // ['rojo', 'argon']
const NONE = SCRIPT_SYNC.id; // 'none': Roblox Script Sync, inside Studio (no program to run)
const SOURCEMAP_FILE = 'sourcemap.json';

// A manifest entry names the tool by its GitHub repo, whatever the alias on the left is.
const MANIFEST_PATTERNS = Object.freeze({
	rojo: /["'\s=]rojo-rbx\/rojo(?:@|["'\s]|$)/im,
	argon: /["'\s=]argon-rbx\/argon(?:@|["'\s]|$)/im,
});

const notFound = (r) =>
	r.status === 9009 || /is not recognized as an internal or external command/i.test(String(r.stderr || ''));

// One cmd.exe argument. Callers pass fixed arguments; quoting only guards spaces and quotes.
const cmdQuote = (s) => (/^[\w@%+=:,./\\-]+$/.test(String(s)) ? String(s) : `"${String(s).replace(/"/g, '""')}"`);

function defaultRun(cmd, args = [], opts = {}) {
	const base = { encoding: 'utf8', windowsHide: true, ...opts };
	const first = spawnSync(cmd, args, { ...base, shell: false });
	const code = first.error && first.error.code;
	if (process.platform !== 'win32' || (code !== 'ENOENT' && code !== 'EINVAL')) return first;
	const line = [cmd, ...args].map(cmdQuote).join(' ');
	const second = spawnSync(line, { ...base, shell: true });
	if (!second.error && second.status !== 0 && notFound(second)) {
		return { ...second, error: Object.assign(new Error(`${cmd} was not found`), { code: 'ENOENT' }) };
	}
	return second;
}

function manifestTools(text) {
	const clean = String(text)
		.split(/\r?\n/)
		.map((line) => line.replace(/#.*$/, ''))
		.join('\n');
	return TOOL_IDS.filter((id) => MANIFEST_PATTERNS[id].test(clean));
}

// 'rojo' | 'argon' | 'none' | null.
function normalizeTool(value) {
	if (typeof value !== 'string') return null;
	const id = value.trim().toLowerCase();
	return TOOL_IDS.includes(id) || id === NONE ? id : null;
}

function isInstalled(tool, run = defaultRun, cwd = process.cwd()) {
	try {
		const r = run(tool, ['--version'], { cwd, stdio: 'pipe' });
		return Boolean(r) && !r.error && r.status === 0;
	} catch {
		return false;
	}
}

function detectToolInfo(root, run = defaultRun) {
	if (isScriptSync(root)) return { tool: NONE, source: LOREN_CONFIG_FILE };
	for (const manager of MANAGERS) {
		const file = MANAGER_FILES[manager];
		const text = readTextIfExists(path.join(root, file));
		if (text === null) continue;
		const found = manifestTools(text);
		// Both listed (Argon to sync, Rojo to build is common): Argon wins, as it did in 1.5.1.
		if (found.includes('argon')) return { tool: 'argon', source: file };
		if (found.includes('rojo')) return { tool: 'rojo', source: file };
	}
	// No manifest names one: whichever is installed, Rojo first (the documented default).
	for (const id of ['rojo', 'argon']) {
		if (isInstalled(id, run, root)) return { tool: id, source: 'installed' };
	}
	return { tool: null, source: null };
}

function detectTool(root, run = defaultRun) {
	return detectToolInfo(root, run).tool;
}

function resolveTool(root, override, run = defaultRun) {
	if (override !== undefined && override !== null && override !== '') {
		const id = normalizeTool(override);
		if (!id) throw new Error(`Unknown sync tool "${override}". Use --tool rojo or --tool argon (or --tool none for Roblox Script Sync).`);
		if (id !== NONE && isScriptSync(root)) {
			throw new Error(
				`This project uses Roblox Script Sync (${LOREN_CONFIG_FILE} says "tool": "none"), so --tool ${id} does not apply. Switching is not automated yet.`,
			);
		}
		return id;
	}
	const found = detectTool(root, run);
	if (found) return found;
	throw new Error(
		'No sync tool found. Add rojo-rbx/rojo or argon-rbx/argon to rokit.toml (or aftman.toml / foreman.toml), ' +
			`install one (for example: rokit add ${TOOLS.rojo.repo}), or pass --tool rojo|argon|none.`,
	);
}

const sourcemapArgs = () => ['sourcemap', PROJECT_FILE, '-o', SOURCEMAP_FILE];

// Argon writes its own sourcemap while serving (--sourcemap); Luau-LSP autogenerates it only for Rojo.
function serveArgs(tool) {
	const id = normalizeTool(tool);
	if (!id) throw new Error(`Unknown sync tool "${tool}". Use rojo or argon.`);
	if (id === NONE) throw new Error('Roblox Script Sync runs inside Studio: there is nothing to serve.');
	return id === 'argon' ? ['serve', PROJECT_FILE, '--sourcemap'] : ['serve', PROJECT_FILE];
}

function sourcemap(root, tool, run = defaultRun) {
	const id = normalizeTool(tool);
	if (!id) return { ok: false, error: `Unknown sync tool "${tool}". Use rojo or argon.` };
	if (id === NONE) return { ok: true, skipped: true };
	const label = TOOLS[id].label;
	let r;
	try {
		r = run(id, sourcemapArgs(id), { cwd: root, stdio: 'pipe' });
	} catch (err) {
		return { ok: false, error: `${label} could not start: ${err.message}` };
	}
	if (!r) return { ok: false, error: `${label} did not run.` };
	if (r.error) {
		if (r.error.code === 'ENOENT') {
			return {
				ok: false,
				error: `${id} is not installed or not on PATH. Install it (rokit add ${TOOLS[id].repo}) or pass --tool.`,
			};
		}
		return { ok: false, error: `${label} could not start: ${r.error.message}` };
	}
	if (r.status !== 0) {
		const detail = String(r.stderr || r.stdout || '')
			.replace(/\x1b\[[0-9;]*m/g, '')
			.trim()
			.split(/\r?\n/)
			.slice(-3)
			.join(' ');
		return { ok: false, error: `${label} sourcemap failed (exit ${r.status})${detail ? `: ${detail}` : ''}` };
	}
	return { ok: true };
}

function vscodeSettings(tool) {
	const id = normalizeTool(tool) || 'rojo';
	if (id === NONE) return { ...PLUGIN_SETTINGS };
	return {
		'luau-lsp.sourcemap.enabled': true,
		'luau-lsp.sourcemap.autogenerate': id === 'rojo',
		'luau-lsp.sourcemap.rojoProjectFile': PROJECT_FILE,
		'luau-lsp.sourcemap.sourcemapFile': SOURCEMAP_FILE,
	};
}

module.exports = {
	TOOL_IDS,
	NONE,
	SOURCEMAP_FILE,
	defaultRun,
	manifestTools,
	normalizeTool,
	isInstalled,
	detectToolInfo,
	detectTool,
	resolveTool,
	sourcemapArgs,
	serveArgs,
	sourcemap,
	vscodeSettings,
};
