'use strict';

// loren update, loren types and loren doctor. update and the middleware lint live in
// lib/update.js and lib/lint.js; these wrappers add the environment checks and exit codes.

const path = require('path');
const { MIN_NODE, PROJECT_FILE, SHIM_SOURCE, MANAGERS, PROMISE_DIR, SCRIPT_SYNC, SCRIPT_SYNC_PATHS } = require('../constants');
const { isFile, isDir, readTextIfExists, normalizeEol, walkFiles, rel } = require('../fsutil');
const { requireProject, readProjectFile, projectPaths } = require('../project');
const { outcome, toolId } = require('../lanes');
const { isCliError } = require('../errors');
const { hasCommand } = require('../run');
const { toolLabel, isToolId } = require('../toolchain');
const { generateTypes, reasonOf, relativeDirs } = require('../refresh');
const { isScriptSync, PLUGIN_SETTINGS, COMPANION_PLUGIN, SYNCED_FOLDERS } = require('../scriptsync');

const isShim = (text) => text !== null && normalizeEol(text).trim() === SHIM_SOURCE.trim();

// A Script Sync project (.loren.json): nothing to install; the runtime lives in the synced folders.
function scriptSyncChecks(ctx, root, fail) {
	const { log } = ctx;
	const at = (p, ...more) => path.join(root, ...p.split('/'), ...more);
	log.ok(`Sync: ${SCRIPT_SYNC.label} (built into Studio; nothing to install)`);
	const shimFile = at(SCRIPT_SYNC_PATHS.shared, 'Loren.luau');
	if (!isShim(readTextIfExists(shimFile))) {
		fail(`${rel(root, shimFile)} is missing or not the current 2.x shim. Run: loren update`);
	} else if (!isFile(at(SCRIPT_SYNC_PATHS.runtimeShared, 'init.luau')) || !isFile(at(SCRIPT_SYNC_PATHS.runtimeServer, 'init.luau'))) {
		fail(`${SCRIPT_SYNC_PATHS.runtimeShared} or ${SCRIPT_SYNC_PATHS.runtimeServer} is missing. Run: loren update`);
	} else {
		log.ok('Runtime layout: LorenRuntime, LorenServer and the shim are in place.');
	}
	if (!isFile(at(SCRIPT_SYNC_PATHS.packages, `${PROMISE_DIR}.luau`))) {
		fail(`${SCRIPT_SYNC_PATHS.packages}/${PROMISE_DIR}.luau is missing (the runtime requires it). Run: loren update`);
	}
	// Script Sync makes X.client.luau a Script with RunContext Client: it runs twice from StarterPlayerScripts.
	for (const file of walkFiles(at('StarterPlayer'))) {
		if (/\.client\.luau?$/i.test(file)) {
			fail(`${rel(root, file)} syncs as a Script with RunContext Client, which runs twice from StarterPlayerScripts. Rename it to *.local.luau (a LocalScript).`);
		}
	}
	const settingsFile = path.join(root, '.vscode', 'settings.json');
	if (isFile(settingsFile)) {
		try {
			const settings = JSON.parse(readTextIfExists(settingsFile).replace(/^﻿/, ''));
			if (settings['luau-lsp.plugin.enabled'] !== true) {
				log.warn(`.vscode/settings.json: set ${JSON.stringify(PLUGIN_SETTINGS)} for Luau-LSP plugin mode.`);
			}
		} catch {
			log.warn('.vscode/settings.json is not plain JSON; its Luau-LSP settings were not checked.');
		}
	}
	log.info(`Studio: sync ${SYNCED_FOLDERS.map((f) => f.instance).join(', ')} (right-click > Sync to…; see README.md).`);
	log.info(`Autocomplete: the "${COMPANION_PLUGIN}" Studio plugin with the Luau Language Server extension.`);
}

// A failed lane result's own exit code (2 = "needs --yes"), else 1.
const failCode = (res) => {
	const code = res && res.value && res.value.exitCode;
	return Number.isInteger(code) && code > 0 && code < 256 ? code : 1;
};

// loren update: runUpdate resolves the tool itself (after updating), so --tool is passed through
// as given and a missing tool only fails the sourcemap step, never the runtime update.
async function updateCommand(ctx, opts = {}) {
	const root = requireProject(ctx.cwd);
	const runUpdate = ctx.lanes.fn('update', 'runUpdate');
	const res = outcome(
		await runUpdate(root, {
			packageRoot: ctx.packageRoot,
			tool: opts.tool,
			dryRun: Boolean(opts.dryRun),
			yes: Boolean(opts.yes),
			noNative: opts.native === false,
			isTTY: ctx.isTTY,
			confirm: ctx.prompt.confirm,
			log: ctx.log,
			sourcemapRunner: ctx.run,
		}),
	);
	if (!res.ok) {
		// runUpdate reports its own failures; add a line only when it gave no exit code.
		const reported = res.value && typeof res.value === 'object' && Number.isInteger(res.value.exitCode);
		if (!reported) ctx.log.error(`loren update did not finish: ${reasonOf(res, 'see the messages above')}.`);
		return failCode(res);
	}
	return 0;
}

async function typesCommand(ctx) {
	const root = requireProject(ctx.cwd);
	return (await generateTypes(ctx, root)) ? 0 : 1;
}

function nodeOk(version = process.versions.node) {
	const [a, b] = version.split('.').map(Number);
	const [x, y] = MIN_NODE.split('.').map(Number);
	return a > x || (a === x && b >= y);
}

// Environment and project checks (CLI.md dx-30 / doc-24). Returns the number of problems.
async function environmentChecks(ctx, root, inProject) {
	const { log, run } = ctx;
	let problems = 0;
	const fail = (msg) => {
		problems += 1;
		log.error(msg);
	};

	if (nodeOk()) log.ok(`Node ${process.versions.node}`);
	else fail(`Node ${process.versions.node} is too old; Loren needs ${MIN_NODE} or newer.`);

	if (inProject && isScriptSync(root)) {
		scriptSyncChecks(ctx, root, fail);
		return problems;
	}

	const managers = MANAGERS.filter((m) => hasCommand(run, m, root));
	if (managers.length) log.ok(`Toolchain manager: ${managers.join(', ')}`);
	else log.warn('No Rokit, Aftman or Foreman found. Install Rokit: https://github.com/rojo-rbx/rokit');

	if (!inProject) {
		log.info(`No ${PROJECT_FILE} here: skipped the project checks. Run loren doctor in a project root to check it.`);
		return problems;
	}

	let tool = null;
	try {
		tool = toolId(await ctx.lanes.fn('tool', 'resolveTool')(root, undefined, run));
	} catch (err) {
		if (isCliError(err)) throw err;
		fail(err.message);
	}
	if (isToolId(tool)) {
		if (hasCommand(run, tool, root)) log.ok(`Sync tool: ${toolLabel(tool)}`);
		else fail(`${tool} does not run in this project. Install it: rokit install`);
		log.info(`Studio: install the ${toolLabel(tool)} plugin once with: ${tool} plugin install`);
	}

	// The 2.0 layout: the managed runtime, the shim and the project file mappings.
	let tree = {};
	try {
		tree = readProjectFile(root).tree || {};
	} catch (err) {
		fail(err.message);
	}
	const rs = tree.ReplicatedStorage || {};
	const sss = tree.ServerScriptService || {};
	const shim = readTextIfExists(path.join(projectPaths(root).shared, 'Loren.luau'));
	if (shim !== null && !isShim(shim)) {
		fail('Shared/Loren.luau is not the current 2.x shim (an older shim, or a Loren 1.x project). Run: loren update');
	} else if (!rs.LorenRuntime || !sss.LorenServer) {
		fail(`${PROJECT_FILE} does not map LorenRuntime and LorenServer. Run: loren update`);
	} else {
		log.ok('Runtime layout: LorenRuntime, LorenServer and the shim are in place.');
	}
	if (!isDir(path.join(projectPaths(root).packages, PROMISE_DIR))) {
		fail(`loren_packages/${PROMISE_DIR} is missing (the runtime requires it). Run: loren update`);
	}

	// Luau-LSP: the sourcemap must come from the project's tool.
	const settingsFile = path.join(root, '.vscode', 'settings.json');
	if (isToolId(tool) && isFile(settingsFile)) {
		try {
			const settings = JSON.parse(readTextIfExists(settingsFile).replace(/^\uFEFF/, ''));
			const auto = settings['luau-lsp.sourcemap.autogenerate'];
			if (auto !== undefined && auto !== (tool === 'rojo')) {
				log.warn(
					`.vscode/settings.json has luau-lsp.sourcemap.autogenerate = ${auto}; use ${tool === 'rojo'} with ${toolLabel(tool)}.`,
				);
			}
		} catch {
			log.warn('.vscode/settings.json is not plain JSON; its Luau-LSP settings were not checked.');
		}
	}
	return problems;
}

async function doctorCommand(ctx, opts = {}) {
	const root = path.resolve(ctx.cwd);
	const inProject = isFile(path.join(root, PROJECT_FILE)) || isScriptSync(root);
	const problems = await environmentChecks(ctx, root, inProject);
	if (!inProject) return problems > 0 ? 1 : 0;

	const runDoctor = ctx.lanes.fn('lint', 'runDoctor');
	const { serverDir } = relativeDirs(root);
	const lint = outcome(
		await runDoctor(root, {
			fix: Boolean(opts.fix),
			yes: Boolean(opts.yes),
			isTTY: ctx.isTTY,
			confirm: ctx.prompt.confirm,
			log: ctx.log,
			serverDir,
		}),
	);
	if (!lint.ok) return failCode(lint);
	return problems > 0 ? 1 : 0;
}

module.exports = { updateCommand, typesCommand, doctorCommand, environmentChecks };
