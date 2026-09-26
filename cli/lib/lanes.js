'use strict';

const path = require('path');
const { CliError } = require('./errors');
const { CLI_INSTALL } = require('./constants');

const LANE_FILES = Object.freeze({ tool: 'tool', types: 'types', lint: 'lint', update: 'update' });

function createLanes(overrides = {}) {
	const cache = {};
	return {
		get(name) {
			if (overrides[name]) return overrides[name];
			if (name in cache) return cache[name];
			const file = path.join(__dirname, `${LANE_FILES[name]}.js`);
			try {
				cache[name] = require(file);
			} catch (err) {
				const missing = err && err.code === 'MODULE_NOT_FOUND' && String(err.message).includes(file);
				if (!missing) throw err;
				cache[name] = null;
			}
			return cache[name];
		},
		// The named export of a lane module, or an error that says the install is broken.
		fn(name, exportName) {
			const mod = this.get(name);
			const f = mod && mod[exportName];
			if (typeof f !== 'function') {
				throw new CliError(
					`This install of the Loren CLI is incomplete (lib/${LANE_FILES[name]}.js has no ${exportName}).`,
					`Reinstall it: ${CLI_INSTALL}`,
				);
			}
			return f;
		},
	};
}

function outcome(value) {
	if (value === undefined || value === null || value === true) return { ok: true, value };
	if (value === false) return { ok: false, value };
	if (typeof value === 'number') return { ok: value === 0, value };
	if (typeof value === 'string') return { ok: true, value };
	if (typeof value === 'object') {
		if (typeof value.ok === 'boolean') return { ok: value.ok, value };
		if (typeof value.success === 'boolean') return { ok: value.success, value };
		if (typeof value.exitCode === 'number') return { ok: value.exitCode === 0, value };
		if (value.error) return { ok: false, value };
		if (typeof value.status === 'number') return { ok: value.status === 0, value };
		if (Array.isArray(value.errors)) return { ok: value.errors.length === 0, value };
		if (typeof value.errors === 'number') return { ok: value.errors === 0, value };
		if (Array.isArray(value.problems)) return { ok: value.problems.length === 0, value };
		if (typeof value.problems === 'number') return { ok: value.problems === 0, value };
	}
	return { ok: true, value };
}

// A tool id from whatever a detector returns ('rojo', { tool: 'rojo' }, ...), or null.
function toolId(value) {
	if (!value) return null;
	if (typeof value === 'string') return value.toLowerCase();
	if (typeof value === 'object') {
		const v = value.tool || value.id || value.name;
		if (typeof v === 'string') return v.toLowerCase();
		if (v && typeof v === 'object') return toolId(v);
	}
	return null;
}

// serveArgs(tool) may give the args (['serve', ...]), a command line string, or { cmd, args }.
function serveCommand(tool, value) {
	if (Array.isArray(value)) {
		if (value.length && String(value[0]).toLowerCase() === tool) return { cmd: tool, args: value.slice(1).map(String) };
		return { cmd: tool, args: value.map(String) };
	}
	if (typeof value === 'string') {
		const parts = value.trim().split(/\s+/).filter(Boolean);
		if (parts.length && parts[0].toLowerCase() === tool) parts.shift();
		return { cmd: tool, args: parts };
	}
	if (value && typeof value === 'object') {
		const cmd = value.cmd || value.command || tool;
		return { cmd, args: (value.args || []).map(String) };
	}
	return { cmd: tool, args: ['serve'] };
}

module.exports = { createLanes, outcome, toolId, serveCommand };
