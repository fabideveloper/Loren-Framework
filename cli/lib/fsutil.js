'use strict';

const fs = require('fs');
const path = require('path');

const toPosix = (p) => p.split(path.sep).join('/');

const exists = (p) => fs.existsSync(p);

function isFile(p) {
	try {
		return fs.statSync(p).isFile();
	} catch {
		return false;
	}
}

function isDir(p) {
	try {
		return fs.statSync(p).isDirectory();
	} catch {
		return false;
	}
}

const readText = (p) => fs.readFileSync(p, 'utf8');

function readTextIfExists(p) {
	return isFile(p) ? readText(p) : null;
}

function writeText(p, text) {
	fs.mkdirSync(path.dirname(p), { recursive: true });
	fs.writeFileSync(p, text);
}

const removePath = (p) => fs.rmSync(p, { recursive: true, force: true });

// Project-relative path with forward slashes, for messages.
function rel(root, p) {
	return toPosix(path.relative(root, p)) || '.';
}

// True when `p` is `root` or inside it (no `..` escape, same drive).
function isInside(root, p) {
	const r = path.relative(path.resolve(root), path.resolve(p));
	return r === '' || (!r.startsWith('..') && !path.isAbsolute(r));
}

const DEFAULT_SKIP = new Set(['.git', 'node_modules', '.loren-backup']);

// Every file under `dir` (absolute paths, sorted), skipping VCS and backup folders.
function walkFiles(dir, { skipDirs = DEFAULT_SKIP } = {}) {
	const out = [];
	const visit = (d) => {
		let entries;
		try {
			entries = fs.readdirSync(d, { withFileTypes: true });
		} catch {
			return;
		}
		entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
		for (const e of entries) {
			const full = path.join(d, e.name);
			if (e.isDirectory() || (e.isSymbolicLink() && isDir(full))) {
				if (!skipDirs.has(e.name)) visit(full);
			} else if (e.isFile() || (e.isSymbolicLink() && isFile(full))) {
				out.push(full);
			}
		}
	};
	visit(dir);
	return out;
}

// Relative (posix) paths of every file under `dir`.
function listRelFiles(dir) {
	if (!isDir(dir)) return [];
	return walkFiles(dir, { skipDirs: new Set() }).map((f) => toPosix(path.relative(dir, f)));
}

function copyDir(src, dest, { filter = () => true, transform = null } = {}) {
	const copied = [];
	const visit = (from, to, relBase) => {
		fs.mkdirSync(to, { recursive: true });
		const entries = fs.readdirSync(from, { withFileTypes: true });
		for (const e of entries) {
			const relPath = relBase ? `${relBase}/${e.name}` : e.name;
			const full = path.join(from, e.name);
			const directory = e.isDirectory() || (e.isSymbolicLink() && isDir(full));
			if (!filter(relPath, directory)) continue;
			if (directory) {
				visit(full, path.join(to, e.name), relPath);
			} else {
				let data = fs.readFileSync(full);
				if (transform) {
					const next = transform(relPath, data);
					if (next !== null && next !== undefined) data = next;
				}
				fs.writeFileSync(path.join(to, e.name), data);
				copied.push(relPath);
			}
		}
	};
	visit(src, dest, '');
	return copied;
}

// Copies a file or a folder.
function copyPath(src, dest) {
	if (isDir(src)) {
		copyDir(src, dest);
	} else {
		fs.mkdirSync(path.dirname(dest), { recursive: true });
		fs.copyFileSync(src, dest);
	}
}

// 2026-09-24T03-06-00-123Z: sortable and safe in file names on every OS.
function timestamp(date = new Date()) {
	return date.toISOString().replace(/[:.]/g, '-');
}

const normalizeEol = (text) => text.replace(/\r\n/g, '\n');

module.exports = {
	toPosix,
	exists,
	isFile,
	isDir,
	readText,
	readTextIfExists,
	writeText,
	removePath,
	rel,
	isInside,
	walkFiles,
	listRelFiles,
	copyDir,
	copyPath,
	timestamp,
	normalizeEol,
};
