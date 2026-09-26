'use strict';

const fs = require('fs');
const path = require('path');
const { PREMADE_KINDS, PREMADE_DIR, RETIRED_PREMADES } = require('../constants');
const { copyPath, isDir, isFile, rel, removePath, writeText } = require('../fsutil');
const { validateIdentifier, isPascalCase } = require('../names');
const { CliError } = require('../errors');
const { requireProject, projectPaths, findModuleEntry } = require('../project');
const { renderModule } = require('../templates');
const { resolveProjectTool, refreshProject } = require('../refresh');
const { backupPath } = require('../backup');

const KIND_LABEL = { service: 'Service', controller: 'Controller', shared: 'shared module' };

function parseKind(type, allowed) {
	const kind = String(type || '').toLowerCase();
	if (!allowed.includes(kind)) {
		throw new CliError(`Unknown type "${type}". Use ${allowed.join(', ').replace(/, ([^,]*)$/, ' or $1')}.`);
	}
	return kind;
}

function destinationDir(paths, kind) {
	return paths[PREMADE_KINDS[kind].target];
}

function checkCollisions(root, paths, kind, name, force) {
	const dir = destinationDir(paths, kind);
	const existing = findModuleEntry(dir, name);
	if (existing && !force) {
		throw new CliError(
			`${rel(root, path.join(dir, existing))} already exists.`,
			'Pick another name, or pass --force to replace it (the old file is backed up to .loren-backup/).',
		);
	}
	if (kind !== 'shared') {
		const otherKind = kind === 'service' ? 'controller' : 'service';
		const otherDir = destinationDir(paths, otherKind);
		const clash = findModuleEntry(otherDir, name);
		if (clash && !force) {
			throw new CliError(
				`"${name}" is already a ${KIND_LABEL[otherKind]} (${rel(root, path.join(otherDir, clash))}); the two would clash in Dependencies.`,
				'Pick another name, or pass --force to create it anyway.',
			);
		}
	}
	return existing ? path.join(dir, existing) : null;
}

// Moves an entry that --force replaces into .loren-backup/ first.
function replaceExisting(ctx, root, existingPath, newPath) {
	if (!existingPath) return;
	const saved = backupPath(root, existingPath);
	if (path.resolve(existingPath) !== path.resolve(newPath) || isDir(existingPath)) removePath(existingPath);
	ctx.log.warn(`Replaced ${rel(root, existingPath)} (backup: ${rel(root, saved)}).`);
}

async function makeCommand(ctx, type, name, opts = {}) {
	const kind = parseKind(type, ['service', 'controller']);
	const checked = validateIdentifier(name, `${KIND_LABEL[kind]} name`);
	if (!checked.ok) throw new CliError(checked.reason);

	const root = requireProject(ctx.cwd);
	const tool = await resolveProjectTool(ctx, root, opts.tool);
	const paths = projectPaths(root);
	const existing = checkCollisions(root, paths, kind, name, opts.force);
	if (!isPascalCase(name)) ctx.log.warn(`"${name}" is not PascalCase; Services and Controllers usually are.`);

	const file = path.join(destinationDir(paths, kind), `${name}.luau`);
	const text = renderModule(kind, name, ctx.templateDir);
	replaceExisting(ctx, root, existing, file);
	writeText(file, text);
	ctx.log.ok(`Created ${KIND_LABEL[kind]} ${name}: ${rel(root, file)}`);

	const refreshed = await refreshProject(ctx, root, tool);
	return refreshed.ok ? 0 : 1;
}

// Premade folders, the project's own first (1.5.1 projects keep theirs), then the CLI's.
function premadeSources(ctx, root) {
	const sources = [];
	if (root) sources.push({ label: 'project', dir: path.join(root, PREMADE_DIR), builtIn: false });
	sources.push({ label: 'built-in', dir: path.join(ctx.templateDir, PREMADE_DIR), builtIn: true });
	return sources;
}

// { service: [{ name, file, source }], controller: [...], shared: [...] }
function listPremades(ctx, root) {
	const out = { service: [], controller: [], shared: [] };
	for (const source of premadeSources(ctx, root)) {
		for (const [kind, spec] of Object.entries(PREMADE_KINDS)) {
			const dir = path.join(source.dir, spec.premadeDir);
			if (!isDir(dir)) continue;
			for (const entry of fs.readdirSync(dir).sort()) {
				const full = path.join(dir, entry);
				let name = null;
				if (isFile(full) && /\.luau?$/i.test(entry)) name = entry.replace(/\.luau?$/i, '');
				else if (isDir(full)) name = entry;
				if (!name || !validateIdentifier(name).ok) continue;
				if (source.builtIn && RETIRED_PREMADES.includes(`${spec.premadeDir}/${entry}`)) continue;
				if (out[kind].some((p) => p.name.toLowerCase() === name.toLowerCase())) continue;
				out[kind].push({ name, file: full, entry, source: source.label });
			}
		}
	}
	return out;
}

function tryProjectRoot(cwd) {
	try {
		return requireProject(cwd);
	} catch {
		return null;
	}
}

function printList(ctx, premades, kindFilter) {
	const kinds = kindFilter ? [kindFilter] : Object.keys(premades);
	ctx.log.info('Premades (loren inject <type> <name>):');
	let count = 0;
	for (const kind of kinds) {
		for (const p of premades[kind]) {
			ctx.log.plain(`  ${kind.padEnd(11)} ${p.name.padEnd(24)} ${p.source}`);
			count += 1;
		}
	}
	if (count === 0) ctx.log.plain('  (none)');
}

async function injectCommand(ctx, type, name, opts = {}) {
	if (opts.list) {
		const kindFilter = type ? parseKind(type, Object.keys(PREMADE_KINDS)) : null;
		printList(ctx, listPremades(ctx, tryProjectRoot(ctx.cwd)), kindFilter);
		return 0;
	}
	if (!type || !name) {
		throw new CliError('Usage: loren inject <service|controller|shared> <name>', 'See what is available: loren inject --list');
	}
	const kind = parseKind(type, Object.keys(PREMADE_KINDS));
	const checked = validateIdentifier(name, 'Premade name');
	if (!checked.ok) throw new CliError(checked.reason);

	const root = requireProject(ctx.cwd);
	const premades = listPremades(ctx, root)[kind];
	const premade = premades.find((p) => p.name.toLowerCase() === name.toLowerCase());
	if (!premade) {
		const names = premades.map((p) => p.name).join(', ') || 'none';
		throw new CliError(`No ${kind} premade named "${name}". Available: ${names}.`, 'See all premades: loren inject --list');
	}

	const tool = await resolveProjectTool(ctx, root, opts.tool);
	const paths = projectPaths(root);
	const existing = checkCollisions(root, paths, kind, premade.name, opts.force);
	const dest = path.join(destinationDir(paths, kind), premade.entry);
	replaceExisting(ctx, root, existing, dest);
	copyPath(premade.file, dest);
	ctx.log.ok(`Injected ${kind} ${premade.name} (${premade.source}): ${rel(root, dest)}`);

	const refreshed = await refreshProject(ctx, root, tool);
	return refreshed.ok ? 0 : 1;
}

module.exports = { makeCommand, injectCommand, listPremades, parseKind };
