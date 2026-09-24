'use strict';

const fs = require('fs');
const path = require('path');
const { PROJECT_FILE, FOLDERS, DEFAULT_PATHS, SCRIPT_SYNC_PATHS, LOREN_CONFIG_FILE } = require('./constants');
const { isFile, isDir } = require('./fsutil');
const { CliError } = require('./errors');
const { readLorenConfig, isScriptSync } = require('./scriptsync');

// The project root is the current folder; it must hold default.project.json, or a .loren.json
// that says "tool": "none" (Roblox Script Sync).
function requireProject(cwd) {
	const root = path.resolve(cwd);
	const config = readLorenConfig(root);
	if (config && config.error) throw new CliError(`${config.error}.`, `Fix ${LOREN_CONFIG_FILE}, then run this again.`);
	if (!isFile(path.join(root, PROJECT_FILE)) && !isScriptSync(root)) {
		throw new CliError(
			`No ${PROJECT_FILE} in ${root}.`,
			'Run this from the root of a Loren project (the folder that holds default.project.json).',
		);
	}
	return root;
}

function readProjectFile(root) {
	const file = path.join(root, PROJECT_FILE);
	let text;
	try {
		text = fs.readFileSync(file, 'utf8');
	} catch (err) {
		throw new CliError(`Could not read ${PROJECT_FILE}: ${err.message}`);
	}
	try {
		return JSON.parse(text.replace(/^\uFEFF/, ''));
	} catch (err) {
		throw new CliError(`${PROJECT_FILE} is not valid JSON: ${err.message}`);
	}
}

// `$path` may be a string or { optional: "..." }.
function nodePath(node) {
	if (!node || typeof node !== 'object') return null;
	const p = node.$path;
	if (typeof p === 'string') return p;
	if (p && typeof p === 'object' && typeof p.optional === 'string') return p.optional;
	return null;
}

function treeNode(tree, keys) {
	let node = tree;
	for (const k of keys) {
		if (!node || typeof node !== 'object') return null;
		node = node[k];
	}
	return node || null;
}

// On-disk folders of the standard layout, read from default.project.json with the
// scaffold's defaults as fallback. A Script Sync project has fixed folders (SCRIPT_SYNC_PATHS).
function projectPaths(root, projectData) {
	const synced = isScriptSync(root);
	let data = projectData;
	if (data === undefined && !synced) {
		try {
			data = readProjectFile(root);
		} catch {
			data = null;
		}
	}
	const tree = (data && data.tree) || {};
	const pick = (keys, key) =>
		path.resolve(root, synced ? SCRIPT_SYNC_PATHS[key] : nodePath(treeNode(tree, keys)) || DEFAULT_PATHS[key]);
	const shared = pick(['ReplicatedStorage', 'Shared'], 'shared');
	const server = pick(['ServerScriptService', 'Server'], 'server');
	const client = pick(['StarterPlayer', 'StarterPlayerScripts', 'Client'], 'client');
	const packages = pick(['ReplicatedStorage', 'LorenPackages'], 'packages');
	return {
		shared,
		server,
		client,
		packages,
		services: path.join(server, FOLDERS.services),
		controllers: path.join(client, FOLDERS.controllers),
	};
}

// The entry in `dir` that is module `name` (Name.luau, Name.lua or a Name/ folder), compared
// case-insensitively because Windows and macOS file systems are. Returns the entry or null.
function findModuleEntry(dir, name) {
	if (!isDir(dir)) return null;
	const want = name.toLowerCase();
	for (const entry of fs.readdirSync(dir)) {
		const lower = entry.toLowerCase();
		if (lower === `${want}.luau` || lower === `${want}.lua`) return entry;
		if (lower === want && isDir(path.join(dir, entry))) return entry;
	}
	return null;
}

// Any entry whose name (without a .lua/.luau extension) matches, case-insensitively.
function findEntryLoose(dir, name) {
	if (!isDir(dir)) return null;
	const want = name.toLowerCase();
	for (const entry of fs.readdirSync(dir)) {
		if (entry.toLowerCase().replace(/\.luau?$/, '') === want) return entry;
	}
	return null;
}

module.exports = {
	CliError,
	requireProject,
	readProjectFile,
	projectPaths,
	findModuleEntry,
	findEntryLoose,
	nodePath,
};
