'use strict';

// Roblox Script Sync (`--tool none`): Studio's built-in two-way sync of Folders with directories.
// There is no project file: .loren.json marks the project ({ "tool": "none", "layout": "scriptsync" })
// and wins over every other tool hint. Only Scripts, LocalScripts, ModuleScripts and Folders sync,
// and only Folders can be synced, so LorenRuntime and LorenServer live inside the synced folders
// (SCRIPT_SYNC_PATHS). Nothing here runs a program.

const path = require('path');
const { SCRIPT_SYNC, LOREN_CONFIG_FILE, SCRIPT_SYNC_PATHS } = require('./constants');
const { readTextIfExists, writeText } = require('./fsutil');

// The Studio Folders to sync, each with the project directory of the same path.
const SYNCED_FOLDERS = Object.freeze(
	['shared', 'packages', 'server', 'client'].map((key) =>
		Object.freeze({ instance: SCRIPT_SYNC_PATHS[key].split('/').join('.'), dir: SCRIPT_SYNC_PATHS[key] }),
	),
);

// Luau-LSP in plugin mode: the Luau Language Server Companion Studio plugin sends the DataModel,
// so there is no sourcemap.
const PLUGIN_SETTINGS = Object.freeze({
	'luau-lsp.plugin.enabled': true,
	'luau-lsp.sourcemap.enabled': false,
	'luau-lsp.sourcemap.autogenerate': false,
});

const COMPANION_PLUGIN = 'Luau Language Server Companion';

// null (no .loren.json), { error } (unreadable) or { config }.
function readLorenConfig(root) {
	const text = readTextIfExists(path.join(root, LOREN_CONFIG_FILE));
	if (text === null) return null;
	try {
		const config = JSON.parse(text.replace(/^﻿/, ''));
		if (!config || typeof config !== 'object' || Array.isArray(config)) return { error: `${LOREN_CONFIG_FILE} is not a JSON object` };
		return { config };
	} catch (err) {
		return { error: `${LOREN_CONFIG_FILE} is not valid JSON (${err.message})` };
	}
}

// True when .loren.json says "tool": "none".
function isScriptSync(root) {
	const found = readLorenConfig(root);
	return Boolean(found && found.config && String(found.config.tool).toLowerCase() === SCRIPT_SYNC.id);
}

function lorenConfigText(runtime, base = {}) {
	return `${JSON.stringify({ ...base, tool: SCRIPT_SYNC.id, layout: SCRIPT_SYNC.layout, runtime }, null, 4)}\n`;
}

function writeLorenConfig(root, runtime, base) {
	writeText(path.join(root, LOREN_CONFIG_FILE), lorenConfigText(runtime, base));
}

// The runtime version in <runtime shared dir>/Version.luau, or null.
function runtimeVersion(runtimeSharedDir) {
	const text = readTextIfExists(path.join(runtimeSharedDir, 'Version.luau'));
	const m = text && /Version\s*=\s*"([^"]+)"/.exec(text);
	return m ? m[1] : null;
}

// Server runtime modules name the shared runtime as ReplicatedStorage.LorenRuntime (IMPLEMENTATION.md
// section 0). In this layout it is ReplicatedStorage.Shared.LorenRuntime, so installs rewrite that
// one path (a static path, so Luau-LSP still types the requires). Comments are left alone.
function serverRuntimeSource(text) {
	return String(text).replace(/^([ \t]*local[ \t]+[A-Za-z_]\w*[ \t]*=[ \t]*ReplicatedStorage)\.LorenRuntime\b/gm, '$1.Shared.LorenRuntime');
}

// The numbered Studio steps, as lines (init prints them; the project README holds them too).
function syncSteps() {
	const width = Math.max(...SYNCED_FOLDERS.map((f) => f.instance.length));
	return [
		`1. Open your place in Studio. In the Explorer, create these Folders if they are missing:`,
		`   ${SYNCED_FOLDERS.slice(0, 2).map((f) => f.instance).join(', ')},`,
		`   ${SYNCED_FOLDERS.slice(2).map((f) => f.instance).join(', ')}.`,
		`2. Right-click each Folder > Sync to… and pick the matching directory of this project:`,
		...SYNCED_FOLDERS.map((f) => `     ${f.instance.padEnd(width)}  ->  ${f.dir}/`),
		`   When Studio shows the conflict dialog, choose Keep Disk.`,
		`3. Autocomplete (optional): the Luau Language Server extension in VS Code plus the`,
		`   "${COMPANION_PLUGIN}" Studio plugin (.vscode/settings.json turns plugin mode on).`,
		`4. Press Play.`,
	];
}

function readmeText(name) {
	return [
		`# ${name}`,
		'',
		'A [Loren](https://fabideveloper.github.io/Loren-Framework/) project synced with Roblox Script Sync,',
		'which is built into Studio. There is no Rojo or Argon and no project file; `.loren.json` marks the project.',
		'',
		'## Sync it in Studio',
		'',
		...syncSteps(),
		'',
		'Script Sync only syncs scripts and folders, and drops attributes and tags on scripts: keep those on',
		'other instances. Client scripts are `*.local.luau` (a LocalScript); never `*.client.luau`, which',
		'Script Sync turns into a Script with RunContext Client that runs twice from StarterPlayerScripts.',
		'',
		'## Commands',
		'',
		'- `loren make service <Name>` / `loren make controller <Name>`, `loren inject --list`',
		'- `loren types`: regenerate `LorenTypes` (and `LorenServerTypes`)',
		'- `loren update`: update the runtime (`ReplicatedStorage/Shared/LorenRuntime`, `ServerScriptService/Server/LorenServer`)',
		'- `loren doctor`: check the project',
		'',
		'Studio picks up the file changes through Script Sync. If it shows the conflict dialog, choose Keep Disk.',
		'',
	].join('\n');
}

module.exports = {
	SYNCED_FOLDERS,
	PLUGIN_SETTINGS,
	COMPANION_PLUGIN,
	readLorenConfig,
	isScriptSync,
	lorenConfigText,
	writeLorenConfig,
	runtimeVersion,
	serverRuntimeSource,
	syncSteps,
	readmeText,
};
