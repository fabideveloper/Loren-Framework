'use strict';

// An expected failure: printed as "Error: <message>" (plus a hint), exit code 1, no stack.
class CliError extends Error {
	constructor(message, hint) {
		super(message);
		this.name = 'CliError';
		this.hint = hint || null;
	}
}

const isCliError = (err) => Boolean(err) && (err instanceof CliError || err.name === 'CliError');

module.exports = { CliError, isCliError };
