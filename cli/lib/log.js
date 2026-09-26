'use strict';

const { PREFIX } = require('./constants');

const ANSI = { bold: 1, dim: 2, red: 31, green: 32, yellow: 33, cyan: 36 };

function colorEnabled(stream) {
	if (process.env.NO_COLOR) return false;
	if (process.env.FORCE_COLOR && process.env.FORCE_COLOR !== '0') return true;
	return Boolean(stream && stream.isTTY);
}

// A logger writes through `write(channel, text)`; channel is 'out' or 'err'.
function createLogger({ write, color = false } = {}) {
	const paint = (code, text) => (color ? `\x1b[${code}m${text}\x1b[0m` : String(text));
	const log = {
		color,
		paint,
		bold: (t) => paint(ANSI.bold, t),
		dim: (t) => paint(ANSI.dim, t),
		cyan: (t) => paint(ANSI.cyan, t),
		green: (t) => paint(ANSI.green, t),
		yellow: (t) => paint(ANSI.yellow, t),
		red: (t) => paint(ANSI.red, t),
		info: (msg) => write('out', `${PREFIX} ${msg}\n`),
		ok: (msg) => write('out', `${PREFIX} ${paint(ANSI.green, msg)}\n`),
		warn: (msg) => write('err', `${PREFIX} ${paint(ANSI.yellow, 'Warning:')} ${msg}\n`),
		error: (msg) => write('err', `${PREFIX} ${paint(ANSI.red, 'Error:')} ${msg}\n`),
		plain: (msg = '') => write('out', `${msg}\n`),
		// Unformatted text (commander's help and usage errors).
		raw: (channel, text) => write(channel === 'err' ? 'err' : 'out', String(text)),
	};
	return log;
}

function createConsoleLogger() {
	return createLogger({
		color: colorEnabled(process.stdout),
		write: (channel, text) => (channel === 'err' ? process.stderr : process.stdout).write(text),
	});
}

// Collects everything in memory (tests).
function createMemoryLogger() {
	const chunks = [];
	const log = createLogger({ write: (channel, text) => chunks.push({ channel, text }) });
	log.output = () => chunks.map((c) => c.text).join('');
	log.stdout = () => chunks.filter((c) => c.channel === 'out').map((c) => c.text).join('');
	log.stderr = () => chunks.filter((c) => c.channel === 'err').map((c) => c.text).join('');
	return log;
}

module.exports = { createLogger, createConsoleLogger, createMemoryLogger, colorEnabled };
