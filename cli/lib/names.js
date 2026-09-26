'use strict';

const { IDENTIFIER, LUAU_KEYWORDS, PROMISE_DIR } = require('./constants');

// Every validator returns { ok: true, value } or { ok: false, reason }.
const good = (value) => ({ ok: true, value });
const bad = (reason) => ({ ok: false, reason });

const WINDOWS_RESERVED = /^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$/i;

function validateIdentifier(name, what = 'Name') {
	if (typeof name !== 'string' || name.length === 0) return bad(`${what} is empty.`);
	if (/[\\/]/.test(name) || name.includes('..')) return bad(`${what} "${name}" must not contain path separators or "..".`);
	if (!IDENTIFIER.test(name)) {
		return bad(`${what} "${name}" is not a valid Luau identifier (letters, digits and _, not starting with a digit).`);
	}
	if (LUAU_KEYWORDS.has(name)) return bad(`${what} "${name}" is a Luau keyword.`);
	if (WINDOWS_RESERVED.test(name)) return bad(`${what} "${name}" is a reserved file name on Windows.`);
	if (name.length > 100) return bad(`${what} is longer than 100 characters.`);
	return good(name);
}

const isPascalCase = (name) => /^[A-Z]/.test(name);

function validateProjectName(name) {
	if (typeof name !== 'string' || name.trim().length === 0) return bad('Project name is empty.');
	if (name === '.' || name === '..' || name.includes('..')) return bad(`Project name "${name}" must not contain "..".`);
	if (/[\\/]/.test(name)) return bad(`Project name "${name}" must not contain path separators.`);
	if (!/^[A-Za-z0-9_][A-Za-z0-9_. -]*$/.test(name)) {
		return bad(`Project name "${name}" may only use letters, digits, spaces, "_", "-" and ".", and must start with a letter, digit or "_".`);
	}
	if (/[. ]$/.test(name)) return bad(`Project name "${name}" must not end with "." or a space.`);
	if (WINDOWS_RESERVED.test(name)) return bad(`Project name "${name}" is reserved on Windows.`);
	if (name.length > 100) return bad('Project name is longer than 100 characters.');
	return good(name);
}

const OWNER = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/;
const REPO = /^[A-Za-z0-9._-]{1,100}$/;
const REF = /^[A-Za-z0-9._/-]{1,200}$/;

function parseRepoSpec(input) {
	if (typeof input !== 'string' || input.trim().length === 0) return bad('Repository is empty. Use user/repo.');
	let s = input.trim();
	let ref = null;

	const hash = s.indexOf('#');
	if (hash !== -1) {
		ref = s.slice(hash + 1);
		s = s.slice(0, hash);
		if (ref.length === 0) return bad(`"${input}" has an empty #ref.`);
	}

	s = s
		.replace(/^git\+/, '')
		.replace(/^(?:https?:\/\/|ssh:\/\/)?(?:git@|www\.)?github\.com[/:]/i, '')
		.replace(/^github:/i, '');
	if (/^[a-z][a-z0-9+.-]*:/i.test(s) || s.startsWith('//')) {
		return bad(`"${input}" is not a GitHub repository. Use user/repo or https://github.com/user/repo.`);
	}

	s = s.replace(/\/+$/, '');
	const parts = s.split('/');
	if (parts.length > 2) {
		// https://github.com/user/repo/tree/<ref>: the ref may itself contain slashes.
		if (parts[2] === 'tree' && parts.length > 3 && ref === null) {
			ref = parts.slice(3).join('/');
		} else {
			return bad(`"${input}" is not a repository. Use user/repo[#ref].`);
		}
	}
	const owner = parts[0];
	const repo = (parts[1] || '').replace(/\.git$/i, '');

	if (!owner || !repo) return bad(`"${input}" is missing the user or the repository. Use user/repo[#ref].`);
	if (!OWNER.test(owner)) return bad(`"${owner}" is not a valid GitHub user or organization.`);
	if (!REPO.test(repo) || repo === '.' || repo === '..') return bad(`"${repo}" is not a valid repository name.`);
	if (ref !== null && (!REF.test(ref) || ref.includes('..') || ref.startsWith('/') || ref.endsWith('/'))) {
		return bad(`"${ref}" is not a valid branch, tag or commit.`);
	}

	return { ok: true, owner, repo, ref, spec: ref ? `${owner}/${repo}#${ref}` : `${owner}/${repo}` };
}

function derivePackageName(repo) {
	let base = String(repo || '').replace(/\.git$/i, '').replace(/^roblox-lua-/i, '');
	if (IDENTIFIER.test(base) && !LUAU_KEYWORDS.has(base)) return good(base);

	const words = base.split(/[^A-Za-z0-9]+/).filter(Boolean);
	base = words.map((w) => w[0].toUpperCase() + w.slice(1)).join('');
	if (/^[0-9]/.test(base)) base = `_${base}`;
	const checked = validateIdentifier(base, 'Package name');
	if (!checked.ok) return bad(`Could not derive a package name from "${repo}". Pass one: loren add <repo> <Name>.`);
	return checked;
}

// Loren's own dependency lives in loren_packages/Promise; `loren add` must never replace it.
const isReservedPackage = (name) => name.toLowerCase() === PROMISE_DIR.toLowerCase();

module.exports = {
	validateIdentifier,
	validateProjectName,
	isPascalCase,
	parseRepoSpec,
	derivePackageName,
	isReservedPackage,
};
