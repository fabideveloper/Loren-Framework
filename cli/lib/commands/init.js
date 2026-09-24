'use strict';

const fs = require('fs');
const path = require('path');
const {
	PROJECT_FILE,
	SHIM_SOURCE,
	SCAFFOLD_ENTRIES,
	GLOB_IGNORE_PATHS,
	GITIGNORE_LINES,
	PROMISE_DIR,
	PROMISE_KEEP,
	SCRIPT_SYNC_PATHS,
	isSpecFile,
} = require('../constants');
const { copyDir, exists, isDir, rel, removePath, walkFiles, writeText } = require('../fsutil');
const { validateProjectName } = require('../names');
const { CliError } = require('../errors');
const { newManifest, applyVscodeSettings, installToolchain, toolLabel, isScriptSyncTool, SYNC_CHOICES } = require('../toolchain');
const { generateTypes, sourcemap } = require('../refresh');
const { writeLorenConfig, runtimeVersion, serverRuntimeSource, syncSteps, readmeText } = require('../scriptsync');

// What `loren init` offers, in this order (the first is the default).
const CHOICE_LABELS = Object.freeze({ rojo: 'Rojo', argon: 'Argon', none: 'None: Roblox Script Sync (built into Studio)' });

// What init takes from each scaffold entry. Spec files never reach a project, and of the vendored
// Promise only lib/, LICENSE and its project file are kept (crit-07).
function scaffoldFilter(entry) {
	return (relPath, directory) => {
		const parts = relPath.split('/');
		if (!directory && isSpecFile(parts[parts.length - 1])) return false;
		if (entry === 'loren_packages' && parts[0] === PROMISE_DIR && parts.length >= 2) {
			return PROMISE_KEEP.includes(parts[1]);
		}
		return true;
	};
}

// The project file: the scaffold's, named after the project, with the spec-file ignore globs.
function projectFileFor(templateDir, name) {
	const data = JSON.parse(fs.readFileSync(path.join(templateDir, PROJECT_FILE), 'utf8').replace(/^\uFEFF/, ''));
	const globs = new Set([...(Array.isArray(data.globIgnorePaths) ? data.globIgnorePaths : []), ...GLOB_IGNORE_PATHS]);
	const { tree, ...rest } = data;
	return { ...rest, name, globIgnorePaths: [...globs], tree };
}

// Writes every project file. Throws on any failure (the caller rolls back).
function writeScaffold(templateDir, target, name, tool) {
	fs.mkdirSync(target, { recursive: true });
	for (const entry of SCAFFOLD_ENTRIES) {
		const src = path.join(templateDir, entry);
		if (!exists(src)) throw new Error(`the CLI's project template is missing ${entry} (reinstall: npm i -g loren-framework)`);
		if (entry === PROJECT_FILE) continue;
		if (isDir(src)) copyDir(src, path.join(target, entry), { filter: scaffoldFilter(entry) });
		else fs.copyFileSync(src, path.join(target, entry));
	}
	writeText(path.join(target, PROJECT_FILE), `${JSON.stringify(projectFileFor(templateDir, name), null, 4)}\n`);
	writeText(path.join(target, 'src', 'shared', 'Loren.luau'), SHIM_SOURCE);
	writeText(path.join(target, '.gitignore'), `${GITIGNORE_LINES.join('\n')}\n`);
	writeText(path.join(target, 'rokit.toml'), newManifest(tool));
	const vs = applyVscodeSettings(target, tool);
	if (!vs.ok) throw new Error(vs.reason);
}

// Roblox Script Sync (--tool none): no project file and no toolchain. Only Folders sync, so the four
// synced folders hold everything, the runtime included (SCRIPT_SYNC_PATHS). Throws on any failure.
function writeScriptSyncScaffold(templateDir, target, name) {
	const from = (...parts) => path.join(templateDir, ...parts);
	const to = (relPath, ...parts) => path.join(target, ...relPath.split('/'), ...parts);
	for (const entry of ['loren', 'src', `loren_packages/${PROMISE_DIR}/lib/init.lua`]) {
		if (!exists(from(...entry.split('/')))) {
			throw new Error(`the CLI's project template is missing ${entry} (reinstall: npm i -g loren-framework)`);
		}
	}
	const noSpec = scaffoldFilter('src');
	fs.mkdirSync(target, { recursive: true });
	copyDir(from('src', 'shared'), to(SCRIPT_SYNC_PATHS.shared), { filter: noSpec });
	copyDir(from('src', 'server'), to(SCRIPT_SYNC_PATHS.server), { filter: noSpec });
	copyDir(from('src', 'client'), to(SCRIPT_SYNC_PATHS.client), { filter: noSpec });
	// Script Sync makes X.client.luau a Script with RunContext Client, which runs twice from
	// StarterPlayerScripts: the bootstrap must be X.local.luau (a LocalScript).
	for (const file of walkFiles(to(SCRIPT_SYNC_PATHS.client))) {
		if (/\.client\.luau?$/i.test(file)) fs.renameSync(file, file.replace(/\.client(\.luau?)$/i, '.local$1'));
	}
	copyDir(from('loren', 'shared'), to(SCRIPT_SYNC_PATHS.runtimeShared), { filter: noSpec });
	copyDir(from('loren', 'server'), to(SCRIPT_SYNC_PATHS.runtimeServer), {
		filter: noSpec,
		transform: (relPath, data) => (/\.luau?$/i.test(relPath) ? serverRuntimeSource(data.toString('utf8')) : null),
	});
	// Promise as one ModuleScript: its lib/init.lua, never its specs (crit-07).
	writeText(to(SCRIPT_SYNC_PATHS.packages, `${PROMISE_DIR}.luau`), fs.readFileSync(from('loren_packages', PROMISE_DIR, 'lib', 'init.lua')));
	writeText(to(SCRIPT_SYNC_PATHS.shared, 'Loren.luau'), SHIM_SOURCE);
	writeText(path.join(target, '.gitignore'), `${GITIGNORE_LINES.join('\n')}\n`);
	writeText(path.join(target, 'README.md'), readmeText(name));
	writeLorenConfig(target, runtimeVersion(from('loren', 'shared')) || 'unknown');
	const vs = applyVscodeSettings(target, 'none');
	if (!vs.ok) throw new Error(vs.reason);
}

async function pickTool(ctx, opts) {
	if (opts.tool) return opts.tool;
	if (!ctx.isTTY || opts.yes) {
		ctx.log.info(`Using Rojo (pass --tool argon for Argon, or --tool none for Roblox Script Sync).`);
		return 'rojo';
	}
	return ctx.prompt.choose(
		'Which sync tool should this project use?',
		SYNC_CHOICES.map((id) => ({ value: id, label: CHOICE_LABELS[id] || toolLabel(id) })),
		0,
	);
}

// The end of `loren init --tool none`: nothing to install; the Studio steps.
function finishScriptSync(ctx, target, problems) {
	const where = rel(ctx.cwd, target);
	if (problems > 0) ctx.log.error(`Created "${where}", but ${problems} step(s) failed (see above).`);
	else ctx.log.ok(`Project "${where}" is ready (Roblox Script Sync: nothing to install).`);
	ctx.log.plain('');
	ctx.log.plain(`Next (these steps are also in ${where}/README.md):`);
	for (const line of syncSteps()) ctx.log.plain(`  ${line}`);
	return problems > 0 ? 1 : 0;
}

async function initCommand(ctx, name, opts = {}) {
	const checked = validateProjectName(name);
	if (!checked.ok) throw new CliError(checked.reason);

	const target = path.resolve(ctx.cwd, name);
	const existed = exists(target);
	if (existed && !(isDir(target) && fs.readdirSync(target).length === 0)) {
		throw new CliError(`"${name}" already exists in ${ctx.cwd}.`, 'Pick another name, or remove that folder first.');
	}

	const tool = await pickTool(ctx, opts);
	const scriptSync = isScriptSyncTool(tool);
	ctx.log.info(`Creating "${name}" (${toolLabel(tool)})...`);

	try {
		if (scriptSync) writeScriptSyncScaffold(ctx.templateDir, target, name);
		else writeScaffold(ctx.templateDir, target, name, tool);
	} catch (err) {
		// Leave nothing half-made behind: remove what this run created.
		if (existed) for (const e of fs.readdirSync(target)) removePath(path.join(target, e));
		else removePath(target);
		throw new CliError(`Could not create the project: ${err.message}`);
	}

	let problems = 0;
	if (!(await generateTypes(ctx, target))) problems += 1;
	if (scriptSync) return finishScriptSync(ctx, target, problems);

	if (opts.tools === false) {
		ctx.log.info('Skipped the toolchain install and the sourcemap (--no-tools).');
	} else {
		ctx.log.info(`Installing the toolchain (${toolLabel(tool)})...`);
		const install = installToolchain({ root: target, run: ctx.run, isTTY: ctx.isTTY, yes: Boolean(opts.yes) });
		if (!install.ok) {
			ctx.log.error(install.reason);
			problems += 1;
		}
		if (!(await sourcemap(ctx, target, tool))) problems += 1;
	}

	const where = rel(ctx.cwd, target);
	if (problems > 0) {
		ctx.log.error(`Created "${where}", but ${problems} step(s) failed (see above).`);
	} else {
		ctx.log.ok(`Project "${where}" is ready.`);
	}
	ctx.log.plain('');
	ctx.log.plain('Next:');
	ctx.log.plain(`  cd ${where.includes(' ') ? `"${where}"` : where}`);
	if (opts.tools === false || problems > 0) ctx.log.plain('  rokit install     (installs the sync tool)');
	ctx.log.plain(`  loren serve       (then connect the ${toolLabel(tool)} plugin in Studio and press Play)`);
	return problems > 0 ? 1 : 0;
}

module.exports = { initCommand, scaffoldFilter, projectFileFor, writeScriptSyncScaffold };
