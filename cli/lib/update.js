'use strict';

const fs = require('fs');
const path = require('path');
const C = require('./constants');
const {
	PROJECT_FILE,
	SHIM_SOURCE,
	BACKUP_DIR,
	DEFAULT_PATHS,
	TOOLS,
	PROMISE_DIR,
	PACKAGE_PROJECT_DIR,
	FOLDERS,
	DOCS_URL,
	SCRIPT_SYNC,
	LOREN_CONFIG_FILE,
} = C;
const {
	isDir,
	isFile,
	readTextIfExists,
	writeText,
	removePath,
	listRelFiles,
	copyPath,
	rel,
	timestamp,
	normalizeEol,
	isInside,
} = require('./fsutil');
const { generateTypes } = require('./types');
const { runDoctor, defaultConfirm, defaultIsTTY, withLogger, toDate, projectLayout, nodePath } = require('./lint');
const toolLib = require('./tool');
const { isScriptSync, readLorenConfig, lorenConfigText, runtimeVersion, serverRuntimeSource } = require('./scriptsync');

const RUNTIME_DIR = 'loren';
const SHIM_NAMES = ['Loren.luau', 'Loren.lua'];
const PROMISE_FILES = ['lib/init.lua', 'LICENSE', 'default.project.json'];
const isSpec = C.isSpecFile || ((name) => /\.spec\.luau?$/i.test(name));

// Markers of the 1.5.1 single-file runtime (its remotes and its own definitions).
const LEGACY_MARKERS = [
	/\bLorenBridge\b/,
	/\bLorenHandshake\b/,
	/function\s+Loren\s*[:.]\s*SetOnFire\s*\(/,
	/function\s+Loren\s*[:.]\s*AddServices\s*\(/,
];

// Helpers -----------------------------------------------------------------------------------------

const stripBom = (text) => text.replace(/^\uFEFF/, '');
const sameText = (a, b) => a !== null && b !== null && normalizeEol(stripBom(a)) === normalizeEol(stripBom(b));

const readVersion = runtimeVersion;

function compareVersions(a, b) {
	const parse = (v) => {
		const s = String(v).trim().replace(/^v/i, '').replace(/\+.*$/, '');
		const dash = s.indexOf('-');
		const core = dash < 0 ? s : s.slice(0, dash);
		const pre = dash < 0 ? null : s.slice(dash + 1);
		return { nums: core.split('.').map((n) => Number.parseInt(n, 10) || 0), pre: pre ? pre.split('.') : null };
	};
	const x = parse(a);
	const y = parse(b);
	for (let i = 0; i < 3; i++) {
		const d = (x.nums[i] || 0) - (y.nums[i] || 0);
		if (d !== 0) return d < 0 ? -1 : 1;
	}
	if (x.pre === null || y.pre === null) return x.pre === y.pre ? 0 : x.pre === null ? 1 : -1;
	const numeric = (p) => /^\d+$/.test(p);
	for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
		const p = x.pre[i];
		const q = y.pre[i];
		if (p === undefined) return -1;
		if (q === undefined) return 1;
		if (p === q) continue;
		if (numeric(p) && numeric(q)) return Number(p) < Number(q) ? -1 : 1;
		if (numeric(p) !== numeric(q)) return numeric(p) ? -1 : 1;
		return p < q ? -1 : 1;
	}
	return 0;
}

// --no-native: drop `--!native` and `@native` (lines become blank so line numbers still match).
function stripNative(text) {
	return text
		.replace(/^[ \t]*--!native[ \t]*(?=\r?$)/gm, '')
		.replace(/^[ \t]*@native[ \t]*(?=\r?$)/gm, '')
		.replace(/^([ \t]*)@native[ \t]+(?=\S)/gm, '$1');
}

// Project detection ---------------------------------------------------------------------------------

function classifyLorenFile(text) {
	if (text === null) return 'missing';
	const t = normalizeEol(stripBom(text));
	if (t === SHIM_SOURCE) return 'shim';
	if (LEGACY_MARKERS.some((re) => re.test(t))) return 'runtime';
	if (/\bLorenRuntime\b/.test(t)) return 'shim-modified';
	return 'other';
}

function detectProject(root, layout) {
	const sharedDir = path.join(root, layout.shared);
	const existing = SHIM_NAMES.map((n) => path.join(sharedDir, n)).filter(isFile);
	const lorenFile = existing[0] || path.join(sharedDir, SHIM_NAMES[0]);
	const lorenState = classifyLorenFile(readTextIfExists(lorenFile));
	const runtimeLabel = layout.runtimeShared || `${RUNTIME_DIR}/shared`;
	const runtimeShared = path.join(root, runtimeLabel);
	const hasRuntime = isFile(path.join(runtimeShared, 'init.luau')) || isFile(path.join(runtimeShared, 'init.lua'));
	const installedVersion = hasRuntime ? readVersion(runtimeShared) : null;
	const where = rel(root, lorenFile);
	const base = { lorenFile, existing, lorenState, installedVersion, hasRuntime };
	if (lorenState === 'runtime') return { ...base, kind: 'legacy', reason: `${where} is the whole 1.x runtime` };
	if (lorenState === 'shim' || lorenState === 'shim-modified') return { ...base, kind: 'v2', reason: `${where} is the 2.x shim` };
	if (hasRuntime) return { ...base, kind: 'v2', reason: `${runtimeLabel} holds the 2.x runtime` };
	if (lorenState === 'missing') {
		return { ...base, kind: 'none', reason: `there is no ${where} and no ${layout.runtimeShared || RUNTIME_DIR}/ runtime` };
	}
	return { ...base, kind: 'none', reason: `${where} is neither the Loren 1.x runtime nor the 2.x shim` };
}

// default.project.json ------------------------------------------------------------------------------

function globsFor(packagesDir) {
	const base = packagesDir.replace(/\/+$/, '');
	if (base === DEFAULT_PATHS.packages && C.GLOB_IGNORE_PATHS) return [...C.GLOB_IGNORE_PATHS];
	return [`${base}/**/*.spec.lua`, `${base}/**/*.spec.luau`];
}

// Returns { data, changes } or { error, manual } when the tree is too unusual to patch safely.
function patchProject(data, layout) {
	const manual =
		'Add these by hand:\n' +
		'  tree.ReplicatedStorage.LorenRuntime = { "$path": "loren/shared" }\n' +
		'  tree.ServerScriptService.LorenServer = { "$path": "loren/server" }\n' +
		`  "globIgnorePaths": ${JSON.stringify(globsFor(layout.packages))}`;
	const fail = (error) => ({ error, manual });
	if (!data || typeof data !== 'object' || Array.isArray(data)) return fail(`${PROJECT_FILE} is not a JSON object.`);
	const tree = data.tree;
	if (!tree || typeof tree !== 'object' || Array.isArray(tree)) return fail(`${PROJECT_FILE} has no "tree" object.`);
	if (tree.$className !== 'DataModel') {
		return fail(
			`${PROJECT_FILE} does not describe a place: its tree's $className is ${JSON.stringify(tree.$className ?? null)}, not "DataModel".`,
		);
	}
	if (data.globIgnorePaths !== undefined && !Array.isArray(data.globIgnorePaths)) {
		return fail(`"globIgnorePaths" in ${PROJECT_FILE} is not a list.`);
	}

	const out = JSON.parse(JSON.stringify(data));
	const changes = [];
	const service = (name) => {
		const node = out.tree[name];
		if (node === undefined) {
			out.tree[name] = { $className: name };
			changes.push(`added ${name}`);
			return out.tree[name];
		}
		return node && typeof node === 'object' && !Array.isArray(node) ? node : null;
	};
	const mount = (parent, parentName, name, want) => {
		const node = parent[name];
		if (node === undefined) {
			parent[name] = { $path: want };
			changes.push(`added ${parentName}.${name} -> ${want}`);
			return true;
		}
		if (!node || typeof node !== 'object' || Array.isArray(node)) return false;
		const have = nodePath(node);
		if (have !== want) {
			node.$path = want;
			changes.push(`${parentName}.${name} now points at ${want}${have ? ` (was ${have})` : ''}`);
		}
		// The runtime is a folder module: Rojo refuses a $className next to its $path, Argon any.
		if (node.$className !== undefined) {
			changes.push(`${parentName}.${name}: removed "$className": ${JSON.stringify(node.$className)} (it conflicts with $path)`);
			delete node.$className;
		}
		return true;
	};

	const rs = service('ReplicatedStorage');
	const sss = service('ServerScriptService');
	if (!rs) return fail(`tree.ReplicatedStorage in ${PROJECT_FILE} is not an object.`);
	if (!sss) return fail(`tree.ServerScriptService in ${PROJECT_FILE} is not an object.`);
	if (!mount(rs, 'ReplicatedStorage', 'LorenRuntime', DEFAULT_PATHS.runtimeShared)) {
		return fail(`tree.ReplicatedStorage.LorenRuntime in ${PROJECT_FILE} is not an object.`);
	}
	if (!mount(sss, 'ServerScriptService', 'LorenServer', DEFAULT_PATHS.runtimeServer)) {
		return fail(`tree.ServerScriptService.LorenServer in ${PROJECT_FILE} is not an object.`);
	}
	if (rs.LorenPackages === undefined) {
		rs.LorenPackages = { $path: layout.packages };
		changes.push(`added ReplicatedStorage.LorenPackages -> ${layout.packages}`);
	}

	const globs = globsFor(layout.packages);
	const current = Array.isArray(out.globIgnorePaths) ? out.globIgnorePaths : [];
	const missing = globs.filter((g) => !current.includes(g));
	if (missing.length > 0) {
		changes.push(`globIgnorePaths += ${missing.join(', ')}`);
		if (Array.isArray(out.globIgnorePaths)) {
			out.globIgnorePaths.push(...missing);
		} else {
			// Put it right after "name" so it is easy to find.
			const ordered = {};
			let placed = false;
			for (const [k, v] of Object.entries(out)) {
				if (!placed && k !== 'name') {
					ordered.globIgnorePaths = missing;
					placed = true;
				}
				ordered[k] = v;
			}
			if (!placed) ordered.globIgnorePaths = missing;
			return { data: ordered, changes };
		}
	}
	return { data: out, changes };
}

// Package contents ----------------------------------------------------------------------------------

function runtimeFiles(pkgRuntime, noNative, transform = null) {
	const files = new Map();
	for (const relPath of listRelFiles(pkgRuntime)) {
		const name = path.posix.basename(relPath);
		if (name.startsWith('.') || isSpec(name)) continue;
		let data = fs.readFileSync(path.join(pkgRuntime, relPath));
		if ((noNative || transform) && /\.luau?$/i.test(name)) {
			let text = data.toString('utf8');
			if (noNative) text = stripNative(text);
			if (transform) text = transform(text);
			data = Buffer.from(text, 'utf8');
		}
		files.set(relPath, data);
	}
	return files;
}

function runtimeDiffers(target, files) {
	if (!isDir(target)) return true;
	const have = listRelFiles(target).filter((f) => !path.posix.basename(f).startsWith('.'));
	if (have.length !== files.size) return true;
	for (const relPath of have) {
		const want = files.get(relPath);
		if (!want) return true;
		const text = readTextIfExists(path.join(target, relPath));
		if (!sameText(text, want.toString('utf8'))) return true;
	}
	return false;
}

// Why the project's Promise needs replacing ([] = it is fine).
function promiseProblems(pkgPromise, userPromise) {
	if (!isDir(userPromise)) return ['it is missing'];
	const problems = [];
	const libWant = readTextIfExists(path.join(pkgPromise, 'lib', 'init.lua'));
	const libHave = readTextIfExists(path.join(userPromise, 'lib', 'init.lua'));
	if (libHave === null) problems.push('lib/init.lua is missing');
	else if (!sameText(libHave, libWant)) problems.push('lib/init.lua differs from the bundled Promise');
	const projHave = readTextIfExists(path.join(userPromise, PROJECT_FILE));
	const projWant = readTextIfExists(path.join(pkgPromise, PROJECT_FILE));
	let sameProject = false;
	try {
		sameProject = projHave !== null && JSON.stringify(JSON.parse(stripBom(projHave))) === JSON.stringify(JSON.parse(stripBom(projWant)));
	} catch {
		sameProject = false;
	}
	if (!sameProject) problems.push(`${PROJECT_FILE} is ${projHave === null ? 'missing' : 'not the minimal one'}`);
	if (!isFile(path.join(userPromise, 'LICENSE'))) problems.push('LICENSE is missing');
	const specs = listRelFiles(userPromise).filter((f) => isSpec(path.posix.basename(f)));
	if (specs.length) problems.push(`it has test files (${specs.join(', ')}) that would build into your place`);
	return problems;
}

function outsideMappings(root, data) {
	const found = [];
	for (const [label, keys] of Object.entries({
		'ReplicatedStorage.Shared': ['ReplicatedStorage', 'Shared'],
		'ServerScriptService.Server': ['ServerScriptService', 'Server'],
		'StarterPlayer.StarterPlayerScripts.Client': ['StarterPlayer', 'StarterPlayerScripts', 'Client'],
		'ReplicatedStorage.LorenPackages': ['ReplicatedStorage', 'LorenPackages'],
	})) {
		let node = data && data.tree;
		for (const k of keys) node = node && typeof node === 'object' ? node[k] : undefined;
		const p = nodePath(node);
		if (p && !isInside(root, path.resolve(root, p))) found.push(`${label} -> ${p}`);
	}
	return found;
}

// Case-sensitive file systems: 1.5.1's `loren inject` wrote lowercase folders the runtime never reads.
function misplacedFolders(root, layout) {
	const found = [];
	for (const [dir, want] of [
		[layout.server, FOLDERS.services],
		[layout.client, FOLDERS.controllers],
	]) {
		let names = [];
		try {
			names = fs.readdirSync(path.join(root, dir));
		} catch {
			continue;
		}
		for (const n of names) {
			if (n !== want && n.toLowerCase() === want.toLowerCase() && isDir(path.join(root, dir, n))) {
				found.push(`${dir}/${n} (Loren only registers ${dir}/${want})`);
			}
		}
	}
	return found;
}

// runUpdate -----------------------------------------------------------------------------------------

async function runUpdate(root, opts = {}) {
	const {
		packageRoot,
		tool: toolOverride,
		dryRun = false,
		yes = false,
		noNative = false,
		isTTY = defaultIsTTY(),
		confirm = defaultConfirm,
		now,
		sourcemapRunner,
		force = false,
	} = opts;
	const log = withLogger(opts.log);
	root = path.resolve(root);
	const actions = [];
	const result = (exitCode, extra = {}) => ({ exitCode, actions, ...extra });
	// One clock for the whole run, so the update and the lint back up into the same folder.
	const date = toDate(now);

	// A bad --tool fails before anything changes (not after the update, at the sourcemap).
	if (toolOverride !== undefined && toolOverride !== null && toolOverride !== '' && !toolLib.normalizeTool(toolOverride)) {
		log.error(`Unknown sync tool "${toolOverride}". Use --tool rojo or --tool argon. Nothing was changed.`);
		return result(1);
	}

	// The package: runtime and Promise shipped with this CLI.
	const pkgProject = packageRoot ? path.join(path.resolve(packageRoot), 'project') : PACKAGE_PROJECT_DIR;
	const pkgRuntime = path.join(pkgProject, RUNTIME_DIR);
	const pkgPromise = path.join(pkgProject, 'loren_packages', PROMISE_DIR);
	const missingPkg = [path.join(pkgRuntime, 'shared', 'init.luau'), ...PROMISE_FILES.map((f) => path.join(pkgPromise, f))].filter(
		(f) => !isFile(f),
	);
	if (missingPkg.length) {
		log.error(`This install of the Loren CLI is incomplete (missing ${missingPkg.map((f) => path.relative(pkgProject, f)).join(', ')}). Reinstall it: ${C.CLI_INSTALL}`);
		return result(1);
	}
	const toVersion = readVersion(path.join(pkgRuntime, 'shared')) || 'unknown';

	// The project.
	const scriptSync = isScriptSync(root);
	const projectFile = path.join(root, PROJECT_FILE);
	let projectText = null;
	let projectData;
	let layout;
	if (scriptSync) {
		if (toolLib.normalizeTool(toolOverride) && toolLib.normalizeTool(toolOverride) !== SCRIPT_SYNC.id) {
			log.error(`This project uses ${SCRIPT_SYNC.label} (${LOREN_CONFIG_FILE}), so --tool ${toolOverride} does not apply. Nothing was changed.`);
			return result(1);
		}
		layout = projectLayout(root);
	} else {
		projectText = readTextIfExists(projectFile);
		if (projectText === null) {
			log.error(`${root} is not a Loren project: there is no ${PROJECT_FILE}. Run loren update from your project's root folder.`);
			return result(1);
		}
		try {
			projectData = JSON.parse(stripBom(projectText));
		} catch (err) {
			log.error(`${PROJECT_FILE} is not valid JSON (${err.message}). Fix it, then run loren update again.`);
			return result(1);
		}
		layout = projectLayout(root, projectData);
		for (const m of outsideMappings(root, projectData)) {
			log.warn(`${PROJECT_FILE} maps ${m}, outside this project. loren update only manages folders inside it, so it uses the default folder there instead.`);
		}
	}
	const project = detectProject(root, layout);
	if (project.kind === 'none') {
		log.error(`${root} is not a Loren project: ${project.reason}. Nothing was changed.`);
		return result(1, { kind: 'none' });
	}
	const fromLabel = project.kind === 'legacy' ? '1.5.1' : project.installedVersion || '2.x';
	log.info(`Loren ${fromLabel} project (${project.reason}). This CLI ships runtime ${toVersion}.`);

	if (project.installedVersion && toVersion !== 'unknown' && compareVersions(project.installedVersion, toVersion) > 0 && !force) {
		log.error(
			`This project's runtime (${project.installedVersion}) is newer than this CLI's (${toVersion}). ` +
				`Update the CLI first: ${C.CLI_INSTALL}`,
		);
		return result(1, { kind: project.kind });
	}

	const runtimes = scriptSync
		? [
				{ dir: layout.runtimeShared, files: runtimeFiles(path.join(pkgRuntime, 'shared'), noNative) },
				{ dir: layout.runtimeServer, files: runtimeFiles(path.join(pkgRuntime, 'server'), noNative, serverRuntimeSource) },
			]
		: [{ dir: RUNTIME_DIR, files: runtimeFiles(pkgRuntime, noNative) }];
	for (const { dir, files } of runtimes) {
		const target = path.join(root, dir);
		if (!runtimeDiffers(target, files)) continue;
		const looksOurs = !isDir(target) || project.hasRuntime;
		actions.push({
			kind: 'runtime',
			path: dir,
			target,
			files,
			detail:
				`${isDir(target) ? 'replace' : 'add'} ${dir}/ with runtime ${toVersion} (${files.size} files${noNative ? ', no @native' : ''})` +
				(looksOurs ? '' : `; the current ${dir}/ does not look like a Loren runtime`),
		});
	}

	const shimTarget = path.join(root, layout.shared, SHIM_NAMES[0]);
	const staleShims = project.existing.filter((f) => f !== shimTarget);
	if (project.lorenState !== 'shim' || staleShims.length) {
		const what = {
			runtime: 'the 1.5.1 runtime',
			missing: 'nothing',
			shim: 'a second Loren file',
			'shim-modified': 'a changed shim',
			other: 'a file that is not Loren',
		}[project.lorenState];
		actions.push({ kind: 'shim', path: rel(root, shimTarget), detail: `write the shim to ${rel(root, shimTarget)} (replaces ${what})` });
	}

	// default.project.json, or (Script Sync) the runtime version recorded in .loren.json.
	const patched = scriptSync ? { changes: [] } : patchProject(projectData, layout);
	if (patched.error) {
		log.error(`${patched.error} Loren cannot patch it safely, so nothing was changed.`);
		log.plain(patched.manual);
		return result(1, { kind: project.kind });
	}
	if (patched.changes.length) {
		actions.push({ kind: 'project', path: PROJECT_FILE, detail: `patch ${PROJECT_FILE}: ${patched.changes.join('; ')}` });
	}
	const config = scriptSync ? readLorenConfig(root).config : null;
	if (config && toVersion !== 'unknown' && (config.runtime !== toVersion || config.layout !== SCRIPT_SYNC.layout)) {
		actions.push({ kind: 'config', path: LOREN_CONFIG_FILE, detail: `record runtime ${toVersion} in ${LOREN_CONFIG_FILE}` });
	}

	// Promise: a spec-free folder, or (Script Sync) one file, ReplicatedStorage/LorenPackages/Promise.luau.
	const userPromise = path.join(root, layout.packages, scriptSync ? `${PROMISE_DIR}.luau` : PROMISE_DIR);
	const promiseLib = path.join(pkgPromise, 'lib', 'init.lua');
	let promiseWhy;
	if (scriptSync) {
		const have = readTextIfExists(userPromise);
		promiseWhy = sameText(have, readTextIfExists(promiseLib)) ? [] : [have === null ? 'it is missing' : 'it differs from the bundled Promise'];
	} else {
		promiseWhy = promiseProblems(pkgPromise, userPromise);
	}
	if (promiseWhy.length) {
		actions.push({
			kind: 'promise',
			path: rel(root, userPromise),
			detail: scriptSync
				? `write ${rel(root, userPromise)} (the bundled Promise, lib/init.lua): ${promiseWhy.join('; ')}`
				: `vendor ${rel(root, userPromise)} (lib/init.lua, LICENSE, ${PROJECT_FILE}): ${promiseWhy.join('; ')}`,
		});
	}

	const typeOpts = { sharedDir: layout.shared, serverDir: layout.server, clientDir: layout.client };
	const typesPlan = generateTypes(root, { ...typeOpts, dryRun: true });
	if (typesPlan.planned.length) {
		actions.push({ kind: 'types', path: typesPlan.planned.map((f) => rel(root, f)).join(', '), detail: `regenerate ${typesPlan.planned.map((f) => rel(root, f)).join(' and ')}` });
	}

	for (const m of misplacedFolders(root, layout)) log.warn(`Found ${m}. Move its modules, or they never load.`);

	const stamp = timestamp(date);
	const backupRoot = `${BACKUP_DIR}/${stamp}`;
	if (actions.length === 0) {
		log.ok(`Already up to date: runtime ${toVersion}, shim, ${scriptSync ? '' : `${PROJECT_FILE}, `}Promise and types match.`);
	} else {
		log.info(`${dryRun ? 'Would do' : 'Plan'}:`);
		for (const a of actions) log.plain(`  - ${a.detail}`);
		log.plain(`  Replaced files are backed up to ${backupRoot}/.`);
	}

	if (dryRun) {
		log.info(`Then: ${scriptSync ? '' : 'sourcemap, and '}the middleware lint (preview below). Dry run: nothing was changed.`);
		const doctor = await runDoctor(root, { fix: false, log, legacy: project.kind === 'legacy', serverDir: layout.server });
		return result(0, { kind: project.kind, fromVersion: fromLabel, toVersion, doctor, dryRun: true });
	}

	// Confirm -------------------------------------------------------------------------------------
	if (actions.length > 0 && !yes) {
		if (!isTTY) {
			log.error('loren update needs confirmation. Run it again with --yes, or with --dry-run to preview. Nothing was changed.');
			return result(2, { kind: project.kind });
		}
		const ok = await confirm(`Update this project to Loren ${toVersion}?`);
		if (!ok) {
			log.info('Cancelled. Nothing was changed.');
			return result(1, { kind: project.kind, cancelled: true });
		}
	}

	// Apply ---------------------------------------------------------------------------------------
	const backedUp = [];
	const backup = (abs) => {
		if (!fs.existsSync(abs)) return;
		const dest = path.join(root, BACKUP_DIR, stamp, path.relative(root, abs));
		if (fs.existsSync(dest)) return;
		copyPath(abs, dest);
		backedUp.push(rel(root, abs));
	};
	try {
		for (const a of actions) {
			switch (a.kind) {
				case 'runtime':
					backup(a.target);
					removePath(a.target);
					for (const [relPath, data] of a.files) {
						const dest = path.join(a.target, ...relPath.split('/'));
						fs.mkdirSync(path.dirname(dest), { recursive: true });
						fs.writeFileSync(dest, data);
					}
					break;
				case 'shim':
					for (const f of project.existing) backup(f);
					for (const f of staleShims) removePath(f);
					writeText(shimTarget, SHIM_SOURCE);
					break;
				case 'project': {
					backup(projectFile);
					const eol = projectText.includes('\r\n') ? '\r\n' : '\n';
					writeText(projectFile, `${JSON.stringify(patched.data, null, 4)}\n`.replace(/\n/g, eol));
					break;
				}
				case 'config': {
					const configFile = path.join(root, LOREN_CONFIG_FILE);
					backup(configFile);
					writeText(configFile, lorenConfigText(toVersion, config));
					break;
				}
				case 'promise':
					backup(userPromise);
					removePath(userPromise);
					if (scriptSync) copyPath(promiseLib, userPromise);
					else for (const f of PROMISE_FILES) copyPath(path.join(pkgPromise, ...f.split('/')), path.join(userPromise, ...f.split('/')));
					break;
				case 'types':
					for (const f of typesPlan.planned) backup(f);
					generateTypes(root, typeOpts);
					break;
				default:
					break;
			}
		}
	} catch (err) {
		log.error(`loren update stopped: ${err.message}.${backedUp.length ? ` Your previous files are in ${backupRoot}/.` : ''}`);
		return result(1, { kind: project.kind, backupDir: backedUp.length ? backupRoot : null });
	}
	if (actions.length) {
		log.ok(`Updated to runtime ${toVersion}.${backedUp.length ? ` Backup: ${backupRoot}/` : ''}`);
	}

	let exitCode = 0;
	let tool = null;
	const run = sourcemapRunner || toolLib.defaultRun;
	if (scriptSync || toolLib.normalizeTool(toolOverride) === SCRIPT_SYNC.id) {
		tool = SCRIPT_SYNC.id;
		if (!scriptSync) log.info('Skipped the sourcemap (--tool none).');
	} else {
		try {
			tool = toolLib.resolveTool(root, toolOverride, run);
		} catch (err) {
			log.error(`sourcemap.json was not regenerated: ${err.message}`);
			exitCode = 1;
		}
	}
	if (tool && tool !== SCRIPT_SYNC.id) {
		const map = toolLib.sourcemap(root, tool, run);
		if (map.ok) {
			log.info(`Sourcemap regenerated with ${TOOLS[tool].label}.`);
		} else {
			const pinned = Object.values(C.MANAGER_FILES || {}).filter((f) => isFile(path.join(root, f)));
			const hint = pinned.length ? ` If ${pinned.join(' or ')} pins a version you do not have, install it first (rokit install).` : '';
			log.error(
				`sourcemap.json was not regenerated: ${String(map.error).replace(/\.?\s*$/, '.')}${hint} The project itself is updated; run loren refresh once ${TOOLS[tool].label} works.`,
			);
			exitCode = 1;
		}
	}

	// Lint (offers the dot-style rewrite) ------------------------------------------------------------
	const doctor = await runDoctor(root, {
		fix: true,
		yes,
		isTTY,
		confirm,
		log,
		now: date,
		legacy: project.kind === 'legacy',
		serverDir: layout.server,
	});
	if (exitCode === 0) exitCode = doctor.exitCode;

	if (project.kind === 'legacy' && actions.length) {
		log.info(`Next: press Play in Studio and read Loren's boot report. What changed since 1.5.1: ${DOCS_URL}`);
	}
	if (scriptSync && actions.length) {
		log.info('Studio picks up these file changes through Script Sync. If it shows the conflict dialog, choose Keep Disk.');
	}
	if (actions.length) log.info(`This updated the project's runtime. To update the Loren CLI itself: ${C.CLI_INSTALL}`);
	return result(exitCode, {
		kind: project.kind,
		fromVersion: fromLabel,
		toVersion,
		tool,
		backupDir: backedUp.length ? backupRoot : null,
		backedUp,
		doctor,
	});
}

module.exports = {
	runUpdate,
	detectProject,
	classifyLorenFile,
	patchProject,
	layoutOf: projectLayout,
	stripNative,
	compareVersions,
	promiseProblems,
	LEGACY_MARKERS,
};
