'use strict';

const fs = require('fs');
const path = require('path');
const { TOOLS, MANAGERS, MANAGER_FILES, PROJECT_FILE, SCRIPT_SYNC } = require('./constants');
const { isFile, readTextIfExists, writeText } = require('./fsutil');
const { hasCommand, describeFailure } = require('./run');
const { PLUGIN_SETTINGS } = require('./scriptsync');

// Programs Loren runs (Rojo, Argon). SYNC_CHOICES adds 'none': Roblox Script Sync, inside Studio.
const TOOL_IDS = Object.freeze(Object.keys(TOOLS));
const SYNC_CHOICES = Object.freeze([...TOOL_IDS, SCRIPT_SYNC.id]);

const isToolId = (t) => TOOL_IDS.includes(t);
const isScriptSyncTool = (t) => t === SCRIPT_SYNC.id;
const toolLabel = (t) => (TOOLS[t] ? TOOLS[t].label : isScriptSyncTool(t) ? SCRIPT_SYNC.label : String(t));
const otherTool = (t) => (t === 'rojo' ? 'argon' : 'rojo');

function splitSpec(tool) {
	const { spec, repo } = TOOLS[tool];
	return { repo, version: spec.slice(spec.indexOf('@') + 1) };
}

// One `[tools]` line for a manager's manifest (Rokit and Aftman share a format; Foreman uses tables).
function manifestEntry(manager, tool) {
	const { repo, version } = splitSpec(tool);
	if (manager === 'foreman') return `${tool} = { source = "${repo}", version = "=${version}" }`;
	return `${tool} = "${TOOLS[tool].spec}"`;
}

// A new manifest for `loren init`: rokit.toml with the chosen tool (dx-31).
function newManifest(tool) {
	return ['# Toolchain for this project. Install it with: rokit install', '[tools]', manifestEntry('rokit', tool), ''].join(
		'\n',
	);
}

function lineHasTool(line, tool) {
	const code = line.replace(/#.*$/, '');
	if (!code.trim()) return false;
	const repo = TOOLS[tool].repo.toLowerCase();
	return code.toLowerCase().includes(repo) || new RegExp(`^\\s*${tool}\\s*=`, 'i').test(code);
}

// Sync tools named in a manifest's text.
function manifestTools(text) {
	const found = new Set();
	for (const line of String(text).split(/\r?\n/)) {
		for (const t of TOOL_IDS) if (lineHasTool(line, t)) found.add(t);
	}
	return [...found];
}

// Every manifest in the project and the sync tools it names.
function readManifests(root) {
	const out = [];
	for (const manager of MANAGERS) {
		const file = path.join(root, MANAGER_FILES[manager]);
		const text = readTextIfExists(file);
		if (text !== null) out.push({ manager, file, text, tools: manifestTools(text) });
	}
	return out;
}

function switchManifestTool(text, manager, from, to) {
	const eol = /\r\n/.test(text) ? '\r\n' : '\n';
	let lines = String(text).split(/\r?\n/);
	if (from && from !== to) lines = lines.filter((line) => !lineHasTool(line, from));
	if (!lines.some((line) => lineHasTool(line, to))) {
		const entry = manifestEntry(manager, to);
		const header = lines.findIndex((line) => /^\s*\[tools\]\s*(#.*)?$/.test(line));
		if (header === -1) {
			while (lines.length && lines[lines.length - 1].trim() === '') lines.pop();
			if (lines.length) lines.push('');
			lines.push('[tools]', entry);
		} else {
			lines.splice(header + 1, 0, entry);
		}
	}
	let out = lines.join(eol);
	if (!out.endsWith(eol)) out += eol;
	return out;
}

function installToolchain({ root, run, isTTY, yes }) {
	const manifests = readManifests(root);
	const has = (m) => hasCommand(run, m, root);
	let manager = null;
	if (manifests.length === 0) return { ok: false, reason: 'No rokit.toml, aftman.toml or foreman.toml in the project.' };
	if (has('rokit')) manager = 'rokit';
	else if (manifests.some((m) => m.manager === 'aftman') && has('aftman')) manager = 'aftman';
	else if (manifests.some((m) => m.manager === 'foreman') && has('foreman')) manager = 'foreman';
	if (!manager) {
		return {
			ok: false,
			reason: 'No toolchain manager found (Rokit, Aftman or Foreman). Install Rokit: https://github.com/rojo-rbx/rokit',
		};
	}
	const args = ['install'];
	if (yes && manager !== 'foreman') args.push('--no-trust-check');
	const result = run(manager, args, { cwd: root, stdio: isTTY ? 'inherit' : ['ignore', 'inherit', 'inherit'] });
	if (result && !result.error && result.status === 0) return { ok: true, manager };
	return { ok: false, manager, reason: `${manager} install failed: ${describeFailure(manager, result)}.` };
}

function vscodeSettings(tool) {
	if (isScriptSyncTool(tool)) return { ...PLUGIN_SETTINGS };
	return {
		'luau-lsp.sourcemap.enabled': true,
		'luau-lsp.sourcemap.autogenerate': tool === 'rojo',
		'luau-lsp.sourcemap.rojoProjectFile': PROJECT_FILE,
		'luau-lsp.sourcemap.sourcemapFile': 'sourcemap.json',
	};
}

function applyVscodeSettings(root, tool) {
	const file = path.join(root, '.vscode', 'settings.json');
	const wanted = vscodeSettings(tool);
	let current = {};
	if (isFile(file)) {
		const text = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
		if (text.trim() !== '') {
			try {
				current = JSON.parse(text);
			} catch {
				return { ok: false, file, wanted, reason: '.vscode/settings.json is not plain JSON (it has comments?)' };
			}
			if (!current || typeof current !== 'object' || Array.isArray(current)) {
				return { ok: false, file, wanted, reason: '.vscode/settings.json is not a JSON object' };
			}
		}
	}
	const next = { ...current };
	for (const [k, v] of Object.entries(wanted)) {
		next[k] = v;
	}
	writeText(file, `${JSON.stringify(next, null, 4)}\n`);
	return { ok: true, file };
}

module.exports = {
	TOOL_IDS,
	SYNC_CHOICES,
	isToolId,
	isScriptSyncTool,
	toolLabel,
	otherTool,
	manifestEntry,
	newManifest,
	manifestTools,
	readManifests,
	switchManifestTool,
	installToolchain,
	vscodeSettings,
	applyVscodeSettings,
};
