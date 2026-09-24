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
// `loren init` and `loren update` must write exactly this text.
const SHIM_SOURCE = [
	'--!strict',
	'--!optimize 2',
	'local rt = game:GetService("ReplicatedStorage"):WaitForChild("LorenRuntime", 30)',
	'assert(rt, "[Loren] ReplicatedStorage.LorenRuntime missing: run loren update")',
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

module.exports = {
	PREFIX,
	PROJECT_FILE,
	PACKAGE_PROJECT_DIR,
	FOLDERS,
	INSTANCE_PATHS,
	DEFAULT_PATHS,
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
