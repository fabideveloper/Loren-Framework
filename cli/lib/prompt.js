'use strict';

const readline = require('readline');

function detectTTY(stdin = process.stdin, stdout = process.stdout, env = process.env) {
	if (env.CI && env.CI !== 'false' && env.CI !== '0') return false;
	return Boolean(stdin && stdin.isTTY && stdout && stdout.isTTY);
}

// One line from `input`. Resolves null on EOF (Ctrl+D / Ctrl+Z) instead of hanging.
function askLine(question, { input, output }) {
	return new Promise((resolve) => {
		const rl = readline.createInterface({ input, output, terminal: Boolean(output && output.isTTY) });
		let done = false;
		const finish = (value) => {
			if (done) return;
			done = true;
			rl.close();
			resolve(value);
		};
		rl.on('close', () => finish(null));
		rl.on('SIGINT', () => finish(null));
		rl.question(question, (answer) => finish(answer));
	});
}

function createPrompter({ yes = false, isTTY = false, input = process.stdin, output = process.stdout } = {}) {
	return {
		yes,
		isTTY,
		async confirm(message, defaultValue = false) {
			if (yes) return true;
			if (!isTTY) return Boolean(defaultValue);
			const hint = defaultValue ? '(Y/n)' : '(y/N)';
			// Some callers (the lint) already end the question with the hint.
			const text = /\(y\/n\)\s*$/i.test(message) ? `${message.trimEnd()} ` : `${message} ${hint} `;
			const answer = await askLine(text, { input, output });
			if (answer === null) return false;
			const a = answer.trim().toLowerCase();
			if (a === '') return Boolean(defaultValue);
			return a === 'y' || a === 'yes';
		},
		// choices: [{ value, label }]. Returns the default (index 0) without a TTY or with --yes.
		async choose(message, choices, defaultIndex = 0) {
			if (yes || !isTTY) return choices[defaultIndex].value;
			const lines = choices.map((c, i) => `  [${i + 1}] ${c.label}${i === defaultIndex ? ' (default)' : ''}`);
			const answer = await askLine(`${message}\n${lines.join('\n')}\n> `, { input, output });
			if (answer === null) return choices[defaultIndex].value;
			const trimmed = answer.trim().toLowerCase();
			const n = Number.parseInt(trimmed, 10);
			if (Number.isInteger(n) && n >= 1 && n <= choices.length) return choices[n - 1].value;
			const byName = choices.find((c) => String(c.value).toLowerCase() === trimmed);
			return byName ? byName.value : choices[defaultIndex].value;
		},
	};
}

module.exports = { detectTTY, createPrompter, askLine };
