'use strict';

const { requireProject } = require('../project');
const { resolveProjectTool } = require('../refresh');
const { serveCommand: serveCmdLine } = require('../lanes');
const { toolLabel, isScriptSyncTool } = require('../toolchain');
const { describeFailure } = require('../run');

// loren serve (alias: ignite): runs `rojo serve` / `argon serve` in the foreground with its
// output shown, and exits with the tool's status (dx-30). Script Sync: a note, exit 0.
async function serveCommand(ctx, opts = {}) {
	const root = requireProject(ctx.cwd);
	const tool = await resolveProjectTool(ctx, root, opts.tool);
	if (isScriptSyncTool(tool)) {
		ctx.log.info('This project uses Roblox Script Sync, which runs inside Studio: there is nothing to serve.');
		ctx.log.info('In Studio, sync the four Folders once (see README.md), then press Play.');
		return 0;
	}
	const { cmd, args } = serveCmdLine(tool, await ctx.lanes.fn('tool', 'serveArgs')(tool));
	ctx.log.info(`Serving with ${toolLabel(tool)}: ${[cmd, ...args].join(' ')}  (Ctrl+C to stop)`);
	const result = ctx.run(cmd, args, { cwd: root, stdio: 'inherit' });
	if (!result || result.error) {
		ctx.log.error(`${describeFailure(cmd, result)}.`);
		ctx.log.info('Install the toolchain with: rokit install');
		return 1;
	}
	if (typeof result.status === 'number' && result.status !== 0) {
		ctx.log.error(`${describeFailure(cmd, result)}.`);
		return result.status > 0 && result.status < 256 ? result.status : 1;
	}
	return 0;
}

module.exports = { serveCommand };
