'use strict';

const { outcome, toolId } = require('./lanes');
const { toolLabel, isToolId, isScriptSyncTool } = require('./toolchain');
const { CliError, isCliError } = require('./errors');
const path = require('path');
const { projectPaths } = require('./project');

// A readable reason from a lane result ({ reason }, { message }, a spawn result's error...).
function reasonOf(res, fallback) {
	const v = res && res.value;
	if (v && typeof v === 'object') {
		if (typeof v.reason === 'string') return v.reason;
		if (typeof v.message === 'string') return v.message;
		if (v.error && v.error.message) return v.error.message;
		if (typeof v.error === 'string') return v.error;
	}
	return fallback;
}

// The project's sync tool: --tool wins, else the project's manifests, else what is installed.
// 'none' is Roblox Script Sync (.loren.json, or --tool none): no program, no sourcemap.
async function resolveProjectTool(ctx, root, override) {
	const resolveTool = ctx.lanes.fn('tool', 'resolveTool');
	let id;
	try {
		id = toolId(await resolveTool(root, override || undefined, ctx.run));
	} catch (err) {
		if (isCliError(err)) throw err;
		throw new CliError(err && err.message ? err.message : String(err));
	}
	if (!isToolId(id) && !isScriptSyncTool(id)) {
		throw new CliError('Could not tell whether this project uses Rojo or Argon.', 'Pass --tool rojo or --tool argon.');
	}
	return id;
}

// The project's folders relative to its root, for the types generator and the lint.
function relativeDirs(root) {
	const p = projectPaths(root);
	const r = (abs) => path.relative(root, abs) || '.';
	return { sharedDir: r(p.shared), serverDir: r(p.server), clientDir: r(p.client) };
}

async function generateTypes(ctx, root) {
	try {
		const res = outcome(await ctx.lanes.fn('types', 'generateTypes')(root, { ...relativeDirs(root), log: ctx.log }));
		if (!res.ok) ctx.log.error(`LorenTypes were not regenerated: ${reasonOf(res, 'the generator reported a failure')}.`);
		else {
			const v = res.value;
			const written = v && Array.isArray(v.written) ? v.written.length : null;
			ctx.log.info(written === 0 ? 'Types are up to date.' : 'Types regenerated.');
		}
		return res.ok;
	} catch (err) {
		if (isCliError(err)) throw err;
		ctx.log.error(`LorenTypes were not regenerated: ${err.message}`);
		return false;
	}
}

async function sourcemap(ctx, root, tool) {
	if (isScriptSyncTool(tool)) return true; // Script Sync: Luau-LSP reads the DataModel from its Studio plugin
	try {
		const res = outcome(await ctx.lanes.fn('tool', 'sourcemap')(root, tool, ctx.run));
		if (!res.ok) {
			ctx.log.error(`sourcemap.json was not regenerated: ${reasonOf(res, `${tool} sourcemap failed`)}.`);
			ctx.log.info(`Install the toolchain (rokit install), then run: loren refresh`);
		} else {
			ctx.log.info(`Sourcemap regenerated with ${toolLabel(tool)}.`);
		}
		return res.ok;
	} catch (err) {
		if (isCliError(err)) throw err;
		ctx.log.error(`sourcemap.json was not regenerated: ${err.message}`);
		return false;
	}
}

// Types first, so a new LorenTypes file is already on disk when the sourcemap is built (crit-08).
async function refreshProject(ctx, root, tool, { types = true, map = true } = {}) {
	const typesOk = types ? await generateTypes(ctx, root) : true;
	const mapOk = map && !isScriptSyncTool(tool) ? await sourcemap(ctx, root, tool) : true;
	return { ok: typesOk && mapOk, typesOk, mapOk };
}

module.exports = { resolveProjectTool, generateTypes, sourcemap, refreshProject, reasonOf, relativeDirs };
