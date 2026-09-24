'use strict';

// loren add <user/repo | GitHub URL> [alias]: downloads a snapshot of a repository into
// loren_packages/<Name> (crit-01, dx-23). The download goes to a temp folder first, so a failed
// or empty download changes nothing, and an existing package is only replaced with --force.

const fs = require('fs');
const os = require('os');
const path = require('path');
const fse = require('fs-extra');
const { PROJECT_FILE, isSpecFile } = require('../constants');
const { isDir, isFile, isInside, rel, removePath, walkFiles } = require('../fsutil');
const { isScriptSync } = require('../scriptsync');
const { parseRepoSpec, derivePackageName, validateIdentifier, isReservedPackage } = require('../names');
const { CliError } = require('../errors');
const { requireProject, projectPaths, findEntryLoose } = require('../project');
const { resolveProjectTool, refreshProject } = require('../refresh');
const { backupPath } = require('../backup');

// The folder name for a package: the alias, or one derived from the repository name.
function packageName(spec, alias) {
	const res = alias !== undefined && alias !== null ? validateIdentifier(alias, 'Package name') : derivePackageName(spec.repo);
	if (!res.ok) throw new CliError(res.reason);
	return res.value;
}

// Where `require` can find the package: a root default.project.json or init.lua(u).
function hasEntryPoint(dir) {
	return ['default.project.json', 'init.lua', 'init.luau'].some((f) => isFile(path.join(dir, f)));
}

async function addCommand(ctx, repo, alias, opts = {}) {
	const spec = parseRepoSpec(repo);
	if (!spec.ok) throw new CliError(spec.reason);
	const name = packageName(spec, alias);

	const root = requireProject(ctx.cwd);
	const pkgDir = projectPaths(root).packages;
	const target = path.join(pkgDir, name);
	if (!isInside(pkgDir, target) || path.resolve(target) === path.resolve(pkgDir)) {
		throw new CliError(`"${name}" is not a safe package folder name.`);
	}

	if (isReservedPackage(name) && !opts.force) {
		throw new CliError(
			`${rel(root, pkgDir)}/Promise is bundled with Loren and the runtime requires it.`,
			alias ? 'Pick another alias.' : 'Pass an alias (loren add <repo> <Name>), or --force to replace the bundled Promise.',
		);
	}
	const existing = findEntryLoose(pkgDir, name);
	if (existing && !opts.force) {
		throw new CliError(
			`${rel(root, path.join(pkgDir, existing))} already exists.`,
			'Pass another alias (loren add <repo> <Name>), or --force to replace it.',
		);
	}

	const tool = await resolveProjectTool(ctx, root, opts.tool);

	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'loren-add-'));
	const staging = path.join(tmp, name);
	try {
		ctx.log.info(`Downloading ${spec.spec}...`);
		try {
			await ctx.degit(spec.spec, { cache: false, force: false, verbose: false }).clone(staging);
		} catch (err) {
			throw new CliError(`Could not download ${spec.spec}: ${err && err.message ? err.message : err}`);
		}
		if (!isDir(staging) || fs.readdirSync(staging).length === 0) {
			throw new CliError(`The download of ${spec.spec} was empty; nothing was added.`);
		}
		// Script Sync has no ignore list: test files would reach the place, so they are dropped (crit-07).
		if (isScriptSync(root)) {
			const specs = walkFiles(staging).filter((f) => isSpecFile(path.basename(f)));
			for (const f of specs) removePath(f);
			if (specs.length) ctx.log.info(`Left out ${specs.length} test file(s) (*.spec.lua/luau): Script Sync would sync them into your place.`);
		}
		if (existing) {
			const existingPath = path.join(pkgDir, existing);
			const saved = backupPath(root, existingPath);
			removePath(existingPath);
			ctx.log.warn(`Replaced ${rel(root, existingPath)} (backup: ${rel(root, saved)}).`);
		}
		fse.moveSync(staging, target);
	} finally {
		removePath(tmp);
	}

	ctx.log.ok(`Added ${spec.spec} as ${rel(root, target)}.`);
	if (isScriptSync(root) && !isFile(path.join(target, 'init.luau'))) {
		ctx.log.warn(
			`${rel(root, target)} has no init.luau at its root. Script Sync maps folders and .luau files only (no project files), so arrange it by hand if requiring it fails.`,
		);
	} else if (!hasEntryPoint(target)) {
		ctx.log.warn(
			`${rel(root, target)} has no ${PROJECT_FILE} or init.lua(u) at its root, so requiring it may not work. Point at its source folder by hand.`,
		);
	} else {
		ctx.log.info(`Require it with: require(game:GetService("ReplicatedStorage").LorenPackages.${name})`);
	}

	const refreshed = await refreshProject(ctx, root, tool);
	return refreshed.ok ? 0 : 1;
}

module.exports = { addCommand, packageName, hasEntryPoint };
