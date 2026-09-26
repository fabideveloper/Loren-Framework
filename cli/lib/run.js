'use strict';

const { spawnSync } = require('child_process');

function run(cmd, args = [], opts = {}) {
	const result = spawnSync(cmd, args, {
		cwd: opts.cwd,
		stdio: opts.stdio || 'pipe',
		input: opts.input,
		encoding: 'utf8',
		windowsHide: true,
		shell: false,
	});
	result.ok = !result.error && result.status === 0;
	return result;
}

// True when `cmd --version` runs and exits 0.
function hasCommand(runner, cmd, cwd) {
	try {
		const r = runner(cmd, ['--version'], { cwd, stdio: 'pipe' });
		return Boolean(r && !r.error && r.status === 0);
	} catch {
		return false;
	}
}

// "not found" vs "failed with status N", for messages.
function describeFailure(cmd, result) {
	if (!result) return `${cmd} did not run`;
	if (result.error && result.error.code === 'ENOENT') return `${cmd} is not installed or not on PATH`;
	if (result.error) return `${cmd} could not start (${result.error.message})`;
	if (result.signal) return `${cmd} was stopped by ${result.signal}`;
	return `${cmd} exited with status ${result.status}`;
}

module.exports = { run, hasCommand, describeFailure };
