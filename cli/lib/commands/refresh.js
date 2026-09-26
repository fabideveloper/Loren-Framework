'use strict';

const fs = require('fs');
const { isDir, listRelFiles } = require('../fsutil');
const { CliError } = require('../errors');
const { requireProject, projectPaths } = require('../project');
const { resolveProjectTool, refreshProject } = require('../refresh');

// loren refresh: types first, then the sourcemap (crit-08). Exit 1 if either fails.
async function refreshCommand(ctx, opts = {}) {
	const root = requireProject(ctx.cwd);
	const tool = await resolveProjectTool(ctx, root, opts.tool);
	const result = await refreshProject(ctx, root, tool);
	if (!opts.watch) {
		if (result.ok) ctx.log.ok(tool === 'none' ? 'Refreshed (Script Sync needs no sourcemap).' : 'Types and sourcemap are up to date.');
		return result.ok ? 0 : 1;
	}
	return watchProject(ctx, root, tool);
}

function watchProject(ctx, root, tool, { debounceMs = 300, signal = null } = {}) {
	const paths = projectPaths(root);
	const dirs = [paths.services, paths.controllers].filter(isDir);
	if (dirs.length === 0) throw new CliError('No Services or Controllers folder to watch.');

	const fileSet = () => dirs.map((d) => listRelFiles(d).join('\n')).join('\n--\n');
	let last = fileSet();
	let timer = null;
	let running = false;
	let again = false;

	const tick = async () => {
		if (running) {
			again = true;
			return;
		}
		running = true;
		const now = fileSet();
		const setChanged = now !== last;
		last = now;
		await refreshProject(ctx, root, tool, { map: setChanged });
		running = false;
		if (again) {
			again = false;
			schedule();
		}
	};
	function schedule() {
		clearTimeout(timer);
		timer = setTimeout(tick, debounceMs);
	}

	const watchers = dirs.map((d) => {
		try {
			return fs.watch(d, { recursive: true }, schedule);
		} catch {
			return fs.watch(d, schedule); // recursive watching is missing on some platforms / Node versions
		}
	});
	ctx.log.info('Watching Services and Controllers (Ctrl+C to stop)...');

	return new Promise((resolve) => {
		const stop = () => {
			for (const w of watchers) w.close();
			clearTimeout(timer);
			process.off('SIGINT', stop);
			resolve(0);
		};
		process.on('SIGINT', stop);
		if (signal) signal.addEventListener('abort', stop, { once: true });
	});
}

module.exports = { refreshCommand, watchProject };
