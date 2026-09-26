'use strict';

const path = require('path');
const { MANAGER_FILES, SCRIPT_SYNC, LOREN_CONFIG_FILE } = require('../constants');
const { rel, timestamp, writeText } = require('../fsutil');
const { CliError } = require('../errors');
const { requireProject } = require('../project');
const { toolId } = require('../lanes');
const { sourcemap } = require('../refresh');
const { backupPath } = require('../backup');
const { hasCommand } = require('../run');
const { isScriptSync } = require('../scriptsync');
const {
	isToolId,
	toolLabel,
	otherTool,
	readManifests,
	switchManifestTool,
	newManifest,
	applyVscodeSettings,
	vscodeSettings,
	installToolchain,
} = require('../toolchain');

async function migrateCommand(ctx, opts = {}) {
	const root = requireProject(ctx.cwd);
	// Roblox Script Sync uses another folder layout and no project file: not automated (yet).
	const fromNone = isScriptSync(root);
	if (fromNone || opts.to === SCRIPT_SYNC.id) {
		throw new CliError(
			`Migrating ${fromNone ? 'from' : 'to'} ${SCRIPT_SYNC.label} is not automated yet. Nothing was changed.`,
			fromNone
				? `Create a project with loren init <name> --tool rojo (or argon) and move your Services and Controllers into it. This one is marked by ${LOREN_CONFIG_FILE}.`
				: 'Create a project with loren init <name> --tool none and move your Services and Controllers into it.',
		);
	}
	const manifests = readManifests(root);
	const named = [...new Set(manifests.flatMap((m) => m.tools))];

	let current = null;
	try {
		current = toolId(await ctx.lanes.fn('tool', 'detectTool')(root, ctx.run));
	} catch (err) {
		if (err && err.name === 'CliError') throw err;
	}
	if (!isToolId(current)) current = named.length === 1 ? named[0] : null;

	const target = opts.to || (current ? otherTool(current) : null);
	if (!target) throw new CliError('Could not tell whether this project uses Rojo or Argon.', 'Pass --to rojo or --to argon.');

	const from = current && current !== target ? current : named.find((t) => t !== target) || null;
	if (!from && named.includes(target)) {
		ctx.log.ok(`This project already uses ${toolLabel(target)}.`);
		return 0;
	}

	const question = from
		? `Switch this project from ${toolLabel(from)} to ${toolLabel(target)}?`
		: `Set this project up for ${toolLabel(target)}?`;
	if (!opts.yes && !ctx.isTTY) {
		throw new CliError('loren migrate needs a confirmation.', 'Run it in a terminal, or pass --yes.');
	}
	if (!(await ctx.prompt.confirm(question, false))) {
		ctx.log.info('Cancelled; nothing was changed.');
		return 1;
	}

	const stamp = timestamp();
	let problems = 0;

	// 1. Toolchain manifests (backed up first).
	if (manifests.length === 0) {
		writeText(path.join(root, MANAGER_FILES.rokit), newManifest(target));
		ctx.log.info(`Created ${MANAGER_FILES.rokit} with ${toolLabel(target)}.`);
	} else {
		for (const m of manifests) {
			if (!m.tools.length && manifests.some((o) => o.tools.length)) continue;
			const next = switchManifestTool(m.text, m.manager, from, target);
			if (next === m.text) continue;
			const saved = backupPath(root, m.file, stamp);
			writeText(m.file, next);
			ctx.log.info(`Updated ${rel(root, m.file)} (backup: ${rel(root, saved)}).`);
		}
	}

	// 2. Luau-LSP settings: only Rojo autogenerates the sourcemap from VS Code.
	const vs = applyVscodeSettings(root, target);
	if (vs.ok) {
		ctx.log.info(`Updated .vscode/settings.json for ${toolLabel(target)}.`);
	} else {
		problems += 1;
		ctx.log.error(`${vs.reason}. Set these by hand: ${JSON.stringify(vscodeSettings(target))}`);
	}

	// 3. Install the new tool, then make sure it runs.
	ctx.log.info(`Installing ${toolLabel(target)}...`);
	const install = installToolchain({ root, run: ctx.run, isTTY: ctx.isTTY, yes: Boolean(opts.yes) });
	const runs = hasCommand(ctx.run, target, root);
	if (!runs) {
		problems += 1;
		ctx.log.error(
			`${target} does not run in this project${install.ok ? '' : ` (${install.reason})`}. Install it (rokit install), then run: loren refresh`,
		);
	} else if (!install.ok) {
		ctx.log.warn(`${install.reason} ${target} is available anyway.`);
	}

	// 4. A fresh sourcemap from the new tool.
	if (runs && !(await sourcemap(ctx, root, target))) problems += 1;

	if (problems > 0) {
		ctx.log.error(`The project files now name ${toolLabel(target)}, but ${problems} step(s) failed (see above).`);
		return 1;
	}
	ctx.log.ok(`Migrated to ${toolLabel(target)}. Start it with: loren serve`);
	return 0;
}

module.exports = { migrateCommand };
