'use strict';

const path = require('path');

const PREFIX = '(LORENঌ)';

// The project file every command reads. Rojo and Argon both default to it.
const PROJECT_FILE = 'default.project.json';

// The scaffold shipped with this CLI (runtime, templates, premades, Promise).
// LOREN_TEMPLATE_DIR points the CLI at another copy; the test suite uses it.
const PACKAGE_PROJECT_DIR = process.env.LOREN_TEMPLATE_DIR
	? path.resolve(process.env.LOREN_TEMPLATE_DIR)
	: path.join(__dirname, '..', 'project');

// Module folders. make, inject and types all use these (dx-24, life:corr-19).
const FOLDERS = Object.freeze({ services: 'Services', controllers: 'Controllers' });

// DataModel paths of the standard layout, and where they live on disk by default.
const INSTANCE_PATHS = Object.freeze({
	shared: ['ReplicatedStorage', 'Shared'],
	server: ['ServerScriptService', 'Server'],
	client: ['StarterPlayer', 'StarterPlayerScripts', 'Client'],
	packages: ['ReplicatedStorage', 'LorenPackages'],
	runtimeShared: ['ReplicatedStorage', 'LorenRuntime'],
	runtimeServer: ['ServerScriptService', 'LorenServer'],
});

const DEFAULT_PATHS = Object.freeze({
	shared: 'src/shared',
	server: 'src/server',
	client: 'src/client',
	packages: 'loren_packages',
	runtimeShared: 'loren/shared',
	runtimeServer: 'loren/server',
});

// `--tool none`: Roblox Script Sync, built into Studio (lib/scriptsync.js). No project file:
// .loren.json marks the project, and only Folders sync, so the runtime lives inside the synced
// folders. Each directory is synced to the Studio Folder with the same path.
const SCRIPT_SYNC = Object.freeze({ id: 'none', label: 'Roblox Script Sync', layout: 'scriptsync' });
const LOREN_CONFIG_FILE = '.loren.json';
const SCRIPT_SYNC_PATHS = Object.freeze({
	shared: 'ReplicatedStorage/Shared',
	server: 'ServerScriptService/Server',
	client: 'StarterPlayer/StarterPlayerScripts/Client',
	packages: 'ReplicatedStorage/LorenPackages',
	runtimeShared: 'ReplicatedStorage/Shared/LorenRuntime',
	runtimeServer: 'ServerScriptService/Server/LorenServer',
});

// Tool pins live here and nowhere else (dx-31).
const TOOLS = Object.freeze({
	rojo: Object.freeze({ id: 'rojo', label: 'Rojo', spec: 'rojo-rbx/rojo@7.5.1', repo: 'rojo-rbx/rojo' }),
	argon: Object.freeze({ id: 'argon', label: 'Argon', spec: 'argon-rbx/argon@2.0.29', repo: 'argon-rbx/argon' }),
});

// Toolchain managers, in order of preference. Rokit reads aftman.toml and foreman.toml too.
const MANAGERS = Object.freeze(['rokit', 'aftman', 'foreman']);

// The manifest each manager reads. Rokit and Aftman share one format; Foreman uses tables.
const MANAGER_FILES = Object.freeze({ rokit: 'rokit.toml', aftman: 'aftman.toml', foreman: 'foreman.toml' });

// ReplicatedStorage.Shared.Loren: the old require path, kept as a shim over the managed runtime.
// `loren init` and `loren update` must write exactly this text. It finds the runtime next to itself
// first (Script Sync keeps it in ReplicatedStorage.Shared), else ReplicatedStorage.LorenRuntime.
// Byte-identical to project/src/shared/Loren.luau and IMPLEMENTATION.md section 1 (a test checks).
const SHIM_SOURCE = [
	'--!strict',
	'--!optimize 2',
	'local rt = script.Parent:FindFirstChild("LorenRuntime")',
	'\tor game:GetService("ReplicatedStorage"):WaitForChild("LorenRuntime", 30)',
	'assert(rt, "[Loren] LorenRuntime missing (ReplicatedStorage.LorenRuntime or next to this shim): run loren update")',
	'return (require :: any)(rt)',
	'',
].join('\n');

// Keep in sync with package.json "engines". update-notifier (loaded lazily) needs 18.
const MIN_NODE = '18.0.0';

const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;

const LUAU_KEYWORDS = new Set([
	'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'if', 'in',
	'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while',
]);

// Names Loren 2.0 reserves on a Service's Client table (BLUEPRINT §5).
const RESERVED_CLIENT_NAMES = Object.freeze(['Server', 'Signals', 'ClientEvents', 'Properties', 'Try']);

// Service keys that are new framework keys in 2.0; a 1.5.1 field with this name changes meaning.
const LEGACY_SERVICE_KEYS = Object.freeze(['Spec', 'ClientEvents']);

const TYPES_FILE = 'LorenTypes.luau';
const SERVER_TYPES_FILE = 'LorenServerTypes.luau';
const BACKUP_DIR = '.loren-backup';
const PROMISE_DIR = 'Promise';

// What we keep of the vendored Promise (its wally.toml include list). Spec files never ship (crit-07).
const PROMISE_KEEP = Object.freeze(['lib', 'default.project.json', 'LICENSE']);

// Shipped without the dot (npm drops .gitignore from tarballs); init renames it (crit-13).
const TEMPLATE_GITIGNORE = 'gitignore';

const DOCS_URL = 'https://fabideveloper.github.io/Loren-Framework/';

// The npm package root (holds package.json, index.js, lib/, project/).
const PACKAGE_ROOT = path.join(__dirname, '..');

// What `loren init` copies from the package's project/ folder. Anything else there
// (loren_premade, the old aftman.toml, a stray sourcemap) stays out of new projects.
const SCAFFOLD_ENTRIES = Object.freeze(['default.project.json', 'selene.toml', 'loren', 'loren_packages', 'src']);

// Test code never reaches a user's place (crit-07): Rojo and Argon skip these under loren_packages.
const GLOB_IGNORE_PATHS = Object.freeze(['loren_packages/**/*.spec.lua', 'loren_packages/**/*.spec.luau']);

const isSpecFile = (name) => /\.spec\.luau?$/i.test(name);

// Written as .gitignore by `loren init` (npm never ships a .gitignore, so it lives here; crit-13).
const GITIGNORE_LINES = Object.freeze([
	'sourcemap.json',
	`${BACKUP_DIR}/`,
	'*.rbxl',
	'*.rbxlx',
	'*.rbxl.lock',
	'*.rbxlx.lock',
]);

// `loren inject <kind>`: premade folder -> project folder (dx-24, life:corr-19).
const PREMADE_KINDS = Object.freeze({
	service: Object.freeze({ premadeDir: 'services', target: 'services' }),
	controller: Object.freeze({ premadeDir: 'controllers', target: 'controllers' }),
	shared: Object.freeze({ premadeDir: 'shared', target: 'shared' }),
});

const PREMADE_DIR = 'loren_premade';

// Premades that used the scaffold's Example* names. They are not shipped (package.json "files")
// and `inject --list` hides them, so an inject can never collide with the scaffold (dx-25).
const RETIRED_PREMADES = Object.freeze(['services/ExampleService.luau', 'controllers/ExampleController.luau']);

// The single source for `loren make`: the scaffold's own examples (dx-33).
const MODULE_TEMPLATES = Object.freeze({
	service: Object.freeze({ file: 'src/server/Services/ExampleService.luau', placeholder: 'ExampleService' }),
	controller: Object.freeze({ file: 'src/client/Controllers/ExampleController.luau', placeholder: 'ExampleController' }),
});

module.exports = {
	PACKAGE_ROOT,
	SCAFFOLD_ENTRIES,
	GLOB_IGNORE_PATHS,
	isSpecFile,
	GITIGNORE_LINES,
	PREMADE_KINDS,
	PREMADE_DIR,
	RETIRED_PREMADES,
	MODULE_TEMPLATES,
	PREFIX,
	PROJECT_FILE,
	PACKAGE_PROJECT_DIR,
	FOLDERS,
	INSTANCE_PATHS,
	DEFAULT_PATHS,
	SCRIPT_SYNC,
	LOREN_CONFIG_FILE,
	SCRIPT_SYNC_PATHS,
	TOOLS,
	MANAGERS,
	MANAGER_FILES,
	SHIM_SOURCE,
	TEMPLATE_GITIGNORE,
	MIN_NODE,
	IDENTIFIER,
	LUAU_KEYWORDS,
	RESERVED_CLIENT_NAMES,
	LEGACY_SERVICE_KEYS,
	TYPES_FILE,
	SERVER_TYPES_FILE,
	BACKUP_DIR,
	PROMISE_DIR,
	PROMISE_KEEP,
	DOCS_URL,
};
