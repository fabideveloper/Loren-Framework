#!/usr/bin/env node
'use strict';

const path = require('path');
const { Command, Option, CommanderError } = require('commander');
const pkg = require('./package.json');
const { PACKAGE_PROJECT_DIR, DOCS_URL, MIN_NODE, PREFIX } = require('./lib/constants');
const { createConsoleLogger } = require('./lib/log');
const { detectTTY, createPrompter } = require('./lib/prompt');
const { run } = require('./lib/run');
const { createLanes } = require('./lib/lanes');
const { isCliError } = require('./lib/errors');
const { checkForUpdates } = require('./lib/notifier');
const { initCommand } = require('./lib/commands/init');
const { makeCommand, injectCommand } = require('./lib/commands/modules');
const { addCommand } = require('./lib/commands/add');
const { refreshCommand } = require('./lib/commands/refresh');
const { serveCommand } = require('./lib/commands/serve');
const { migrateCommand } = require('./lib/commands/migrate');
const { updateCommand, typesCommand, doctorCommand } = require('./lib/commands/delegated');

// 'none' is Roblox Script Sync (built into Studio): no program, no project file (.loren.json marks it).
const TOOL_CHOICES = ['rojo', 'argon', 'none'];
const toolOption = () =>
	new Option('--tool <tool>', 'sync tool (default: from .loren.json / rokit.toml / aftman.toml / foreman.toml)').choices(TOOL_CHOICES);

// Everything a command touches from the outside world; tests replace any of it.
function createContext(o = {}) {
	const lanes = createLanes(o.lanes || {});
	const templateDir = o.templateDir || PACKAGE_PROJECT_DIR;
	// lib/tool.js's runner also starts .cmd shims on Windows; lib/run.js is the fallback.
	let runner = o.run;
	if (!runner) {
		const toolLane = lanes.get('tool');
		runner = toolLane && typeof toolLane.defaultRun === 'function' ? toolLane.defaultRun : run;
	}
	// update.js reads <packageRoot>/project; a template dir not named "project" leaves it to
	// PACKAGE_PROJECT_DIR (which honours LOREN_TEMPLATE_DIR).
	let packageRoot = o.packageRoot;
	if (!packageRoot) packageRoot = path.basename(templateDir) === 'project' ? path.dirname(templateDir) : undefined;
	return {
		cwd: o.cwd || process.cwd(),
		log: o.log || createConsoleLogger(),
		isTTY: o.isTTY !== undefined ? Boolean(o.isTTY) : detectTTY(),
		input: o.input || process.stdin,
		output: o.output || process.stdout,
		run: runner,
		lanes,
		degit: o.degit || ((spec, opts) => require('degit')(spec, opts)),
		templateDir,
		packageRoot,
	};
}

// A command's context with a prompter that honours its --yes. Without a TTY no prompt ever reads.
function withPrompt(ctx, opts = {}) {
	const prompt = createPrompter({ yes: Boolean(opts.yes), isTTY: ctx.isTTY, input: ctx.input, output: ctx.output });
	return { ...ctx, prompt };
}

function nodeTooOld(version = process.versions.node) {
	const [maj, min] = version.split('.').map(Number);
	const [needMaj, needMin] = MIN_NODE.split('.').map(Number);
	return maj < needMaj || (maj === needMaj && min < needMin);
}

function buildProgram(ctx, state) {
	const program = new Command();
	program
		.name('loren')
		.description('Loren, a Roblox framework. Burning like a beating heart.')
		.version(pkg.version, '-v, --version', 'print the CLI version')
		.exitOverride()
		.configureOutput({ writeOut: (s) => ctx.log.raw('out', s), writeErr: (s) => ctx.log.raw('err', s) })
		.showHelpAfterError('(run loren --help for usage)')
		.addHelpText('after', `\nDocs: ${DOCS_URL}\nUpdate the CLI itself: npm i -g loren-framework`);

	// Runs a command and records its exit code; CliErrors become "Error: ..." and exit code 1.
	const action =
		(fn) =>
		async (...args) => {
			const command = args[args.length - 1];
			const opts = command.opts();
			state.code = await fn(withPrompt(ctx, opts), args.slice(0, -2), opts);
		};

	program
		.command('init')
		.argument('<name>', 'folder to create')
		.description('create a new Loren project (Rojo, Argon or Roblox Script Sync)')
		.addOption(toolOption())
		.option('-y, --yes', 'never prompt; use the defaults (Rojo unless --tool)')
		.option('--no-tools', 'skip the toolchain install and the sourcemap')
		.action(action((c, [name], opts) => initCommand(c, name, opts)));

	program
		.command('make')
		.argument('<type>', 'service or controller')
		.argument('<name>', 'module name (a Luau identifier, PascalCase)')
		.description('create a Service or Controller from the template')
		.option('-f, --force', 'replace an existing module of that name (backed up first)')
		.addOption(toolOption())
		.action(action((c, [type, name], opts) => makeCommand(c, type, name, opts)));

	program
		.command('inject')
		.argument('[type]', 'service, controller or shared')
		.argument('[name]', 'premade name')
		.description('copy a premade module into your project (see --list)')
		.option('-l, --list', 'list the available premades')
		.option('-f, --force', 'replace an existing module of that name (backed up first)')
		.addOption(toolOption())
		.action(action((c, [type, name], opts) => injectCommand(c, type, name, opts)));

	program
		.command('add')
		.argument('<repo>', 'user/repo[#ref] or a GitHub URL')
		.argument('[alias]', 'folder name under loren_packages (default: the repo name)')
		.description('download a GitHub repository into loren_packages')
		.option('-f, --force', 'replace an existing package of that name (backed up first)')
		.addOption(toolOption())
		.action(action((c, [repo, alias], opts) => addCommand(c, repo, alias, opts)));

	program
		.command('refresh')
		.description('regenerate LorenTypes, then the sourcemap')
		.option('-w, --watch', 'keep regenerating while Services and Controllers change')
		.addOption(toolOption())
		.action(action((c, _args, opts) => refreshCommand(c, opts)));

	program
		.command('serve')
		.alias('ignite')
		.description('start the sync server (rojo serve / argon serve; Script Sync runs inside Studio)')
		.addOption(toolOption())
		.action(action((c, _args, opts) => serveCommand(c, opts)));

	program
		.command('migrate')
		.description('switch this project between Rojo and Argon')
		.addOption(new Option('--to <tool>', 'the tool to switch to (default: the other one)').choices(TOOL_CHOICES))
		.option('-y, --yes', 'do not ask for confirmation')
		.action(action((c, _args, opts) => migrateCommand(c, opts)));

	program
		.command('update')
		.summary("update this PROJECT's Loren runtime (the CLI itself: npm i -g loren-framework)")
		.description(
			"update this PROJECT's Loren runtime to the one bundled with this CLI (loren/, the shim, " +
				'default.project.json, types, sourcemap, lint). To update the CLI itself: npm i -g loren-framework',
		)
		.option('--dry-run', 'show what would change; change nothing')
		.option('-y, --yes', 'do not ask for confirmation')
		.option('--no-native', 'install the runtime without @native attributes')
		.addOption(toolOption())
		.action(action((c, _args, opts) => updateCommand(c, opts)));

	program
		.command('types')
		.description('regenerate LorenTypes (and LorenServerTypes) from your Services and Controllers')
		.action(action((c) => typesCommand(c)));

	program
		.command('doctor')
		.description('check the toolchain and the project (including colon-style middleware)')
		.option('--fix', 'offer to rewrite colon-style middleware to dot style (with a backup)')
		.option('-y, --yes', 'apply fixes without asking')
		.action(action((c, _args, opts) => doctorCommand(c, opts)));

	return program;
}

// Runs the CLI and resolves its exit code. Never calls process.exit (tests run it in-process).
async function main(argv = process.argv, overrides = {}) {
	const ctx = createContext(overrides);
	if (nodeTooOld(overrides.nodeVersion)) {
		ctx.log.error(`Loren needs Node ${MIN_NODE} or newer (this is ${overrides.nodeVersion || process.versions.node}).`);
		return 1;
	}
	if (overrides.notify !== false) await checkForUpdates(pkg, { isTTY: ctx.isTTY });

	const state = { code: 0 };
	const program = buildProgram(ctx, state);
	try {
		await program.parseAsync(argv);
	} catch (err) {
		if (err instanceof CommanderError) return err.exitCode === 0 ? 0 : err.exitCode || 1;
		if (isCliError(err)) {
			ctx.log.error(err.message);
			if (err.hint) ctx.log.raw('err', `${PREFIX} ${err.hint}\n`);
			return 1;
		}
		ctx.log.error(`Unexpected failure: ${err && err.stack ? err.stack : err}`);
		return 1;
	}
	return typeof state.code === 'number' ? state.code : 0;
}

module.exports = { main, buildProgram, createContext, nodeTooOld };

if (require.main === module) {
	main().then(
		(code) => {
			process.exitCode = code;
		},
		(err) => {
			console.error(err);
			process.exitCode = 1;
		},
	);
}
