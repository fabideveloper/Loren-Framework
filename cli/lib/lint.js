'use strict';

// The source lint behind `loren doctor` and `loren update` (BLUEPRINT §6 and §8, CLI.md M4).
// A small Luau tokenizer drops comments and strings, tracks brackets and blocks, and finds:
//   colon-middleware  function X.Middleware:Name(...), Name = function(self, ...) inside a
//                     `Middleware = {` table, and the explicit-self dot forms (a bare local named
//                     Middleware only when the file assigns it to a module's Middleware). Fixable: the
//                     rewrite to dot style drops self (':' becomes '.'); a function that uses self is
//                     left to the user.
//   reserved-name     a Client method named Server, Signals, ClientEvents, Properties or Try.
//   orphan-middleware a Middleware key with no Client method or ClientEvent of that name.
//   orphan-spec       a Spec key with no Client method, ClientEvent or Signal of that name.
//   reserved-key      a Service key Spec or ClientEvents that does not look like the 2.0 key.
// Everything except fixable colon middleware is a warning, as it is in the runtime's boot report.
// The scan is best effort: whatever it cannot read statically (a Client table built at run time)
// it skips instead of guessing.

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { PREFIX, PROJECT_FILE, LUAU_KEYWORDS, RESERVED_CLIENT_NAMES, BACKUP_DIR, DEFAULT_PATHS, SCRIPT_SYNC_PATHS } = require('./constants');
const { walkFiles, readText, writeText, rel, timestamp, isInside } = require('./fsutil');
const { isScriptSync } = require('./scriptsync');

// Tokenizer ---------------------------------------------------------------------------------------

const OPS = ['...', '..=', '//=', '::', '..', '==', '~=', '<=', '>=', '->', '+=', '-=', '*=', '/=', '%=', '^=', '//'];

function longOpen(src, i) {
	let j = i + 1;
	let level = 0;
	while (src[j] === '=') {
		level++;
		j++;
	}
	return src[j] === '[' ? { level, bodyStart: j + 1 } : null;
}

function skipLong(src, from, level) {
	const close = `]${'='.repeat(level)}]`;
	const k = src.indexOf(close, from);
	return k === -1 ? src.length : k + close.length;
}

function skipQuoted(src, i) {
	const q = src[i];
	let j = i + 1;
	while (j < src.length) {
		const c = src[j];
		if (c === '\\') {
			j += 2;
			continue;
		}
		if (c === q) return j + 1;
		if (c === '\n') return j; // unterminated: stop at the line end
		j++;
	}
	return j;
}

function skipInterp(src, i) {
	let j = i + 1;
	while (j < src.length) {
		const c = src[j];
		if (c === '\\') {
			j += 2;
			continue;
		}
		if (c === '`') return j + 1;
		if (c === '{') {
			j = skipInterpExpr(src, j + 1);
			continue;
		}
		j++;
	}
	return j;
}

function skipInterpExpr(src, j) {
	let depth = 1;
	while (j < src.length) {
		const c = src[j];
		if (c === '"' || c === "'") {
			j = skipQuoted(src, j);
			continue;
		}
		if (c === '`') {
			j = skipInterp(src, j);
			continue;
		}
		if (c === '[') {
			const lo = longOpen(src, j);
			if (lo) {
				j = skipLong(src, lo.bodyStart, lo.level);
				continue;
			}
		}
		if (c === '{') depth++;
		else if (c === '}' && --depth === 0) return j + 1;
		j++;
	}
	return j;
}

function lineLocator(src) {
	const starts = [0];
	for (let i = 0; i < src.length; i++) if (src.charCodeAt(i) === 10) starts.push(i + 1);
	return (offset) => {
		let lo = 0;
		let hi = starts.length - 1;
		while (lo < hi) {
			const mid = (lo + hi + 1) >> 1;
			if (starts[mid] <= offset) lo = mid;
			else hi = mid - 1;
		}
		return lo + 1;
	};
}

const isIdentStart = (c) => /[A-Za-z_]/.test(c);
const isIdentChar = (c) => /[A-Za-z0-9_]/.test(c);
const isDigit = (c) => c >= '0' && c <= '9';

// Tokens: { type: 'name'|'kw'|'num'|'str'|'op', value, start, end, line }. Comments are dropped.
// A string token's `text` is its content for quoted and long strings (null for interpolated ones).
function tokenize(src) {
	const lineOf = lineLocator(src);
	const toks = [];
	const n = src.length;
	let i = 0;
	const push = (type, value, start, end, text) => toks.push({ type, value, start, end, line: lineOf(start), text });
	while (i < n) {
		const c = src[i];
		if (c === ' ' || c === '\t' || c === '\r' || c === '\n' || c === '\f' || c === '\v' || c === '\uFEFF') {
			i++;
			continue;
		}
		if (c === '-' && src[i + 1] === '-') {
			i += 2;
			if (src[i] === '[') {
				const lo = longOpen(src, i);
				if (lo) {
					i = skipLong(src, lo.bodyStart, lo.level);
					continue;
				}
			}
			while (i < n && src[i] !== '\n') i++;
			continue;
		}
		if (c === '"' || c === "'") {
			const start = i;
			i = skipQuoted(src, i);
			const closed = src[i - 1] === c && i - 1 > start;
			push('str', src.slice(start, i), start, i, src.slice(start + 1, closed ? i - 1 : i));
			continue;
		}
		if (c === '`') {
			const start = i;
			i = skipInterp(src, i);
			push('str', src.slice(start, i), start, i, null);
			continue;
		}
		if (c === '[') {
			const lo = longOpen(src, i);
			if (lo) {
				const start = i;
				i = skipLong(src, lo.bodyStart, lo.level);
				const bodyEnd = Math.max(lo.bodyStart, i - (lo.level + 2));
				push('str', src.slice(start, i), start, i, src.slice(lo.bodyStart, bodyEnd));
				continue;
			}
		}
		if (isIdentStart(c)) {
			const start = i;
			while (i < n && isIdentChar(src[i])) i++;
			const word = src.slice(start, i);
			push(LUAU_KEYWORDS.has(word) ? 'kw' : 'name', word, start, i);
			continue;
		}
		if (isDigit(c) || (c === '.' && isDigit(src[i + 1] || ''))) {
			const start = i;
			while (i < n) {
				const d = src[i];
				if ((d === '+' || d === '-') && /[eEpP]/.test(src[i - 1]) && !/^0[xX]/.test(src.slice(start, i))) {
					i++;
				} else if (isIdentChar(d) || d === '.') {
					if (d === '.' && src[i + 1] === '.') break;
					i++;
				} else break;
			}
			push('num', src.slice(start, i), start, i);
			continue;
		}
		const op = OPS.find((o) => src.startsWith(o, i)) || c;
		push('op', op, i, i + op.length);
		i += op.length;
	}
	return toks;
}

// Structure ---------------------------------------------------------------------------------------

// An `if` after one of these starts an if-expression (no `end`), not an if statement.
const EXPR_PREV_OPS = new Set([
	'=', '(', '[', '{', ',', '..', '+', '-', '*', '/', '//', '%', '^', '#', '==', '~=', '<', '>', '<=', '>=',
	'+=', '-=', '*=', '/=', '//=', '%=', '^=', '..=',
]);
const EXPR_PREV_KW = new Set(['return', 'and', 'or', 'not', 'in', 'while', 'until', 'elseif', 'if']);

const isOp = (t, v) => Boolean(t) && t.type === 'op' && t.value === v;
const isKw = (t, v) => Boolean(t) && t.type === 'kw' && t.value === v;
const isName = (t, v) => Boolean(t) && t.type === 'name' && (v === undefined || t.value === v);
const isOpener = (t) => isOp(t, '(') || isOp(t, '{') || isOp(t, '[');

// match[i]: the partner of a bracket, or the `end`/`until` of function/if/do/repeat (and back).
// blk[i]: how many blocks are open at token i (0 = the top level of the file).
function structure(toks) {
	const n = toks.length;
	const match = new Int32Array(n).fill(-1);
	const blk = new Int32Array(n);
	const brackets = [];
	const blocks = [];
	let depth = 0;
	let nextIfExpr = false;
	const top = () => blocks[blocks.length - 1];
	for (let i = 0; i < n; i++) {
		const t = toks[i];
		blk[i] = depth;
		const exprContext = nextIfExpr;
		nextIfExpr = false;
		if (t.type === 'op') {
			if (isOpener(t)) {
				brackets.push(i);
			} else if (t.value === ')' || t.value === '}' || t.value === ']') {
				const open = brackets.pop();
				if (open !== undefined) {
					match[open] = i;
					match[i] = open;
				}
			}
			continue;
		}
		if (t.type !== 'kw') continue;
		switch (t.value) {
			case 'function':
			case 'do':
			case 'repeat':
				blocks.push({ kind: t.value, idx: i });
				depth++;
				break;
			case 'if': {
				const p = toks[i - 1];
				const isExpr =
					exprContext || (p && ((p.type === 'op' && EXPR_PREV_OPS.has(p.value)) || (p.type === 'kw' && EXPR_PREV_KW.has(p.value))));
				if (isExpr) {
					blocks.push({ kind: 'ifexpr', idx: i });
				} else {
					blocks.push({ kind: 'if', idx: i });
					depth++;
				}
				break;
			}
			case 'then':
				if (top() && top().kind === 'ifexpr') nextIfExpr = true;
				break;
			case 'else':
				if (top() && top().kind === 'ifexpr') {
					blocks.pop();
					nextIfExpr = true;
				}
				break;
			case 'end':
			case 'until': {
				while (top() && top().kind === 'ifexpr') blocks.pop();
				const open = blocks.pop();
				if (open) {
					match[open.idx] = i;
					match[i] = open.idx;
					depth--;
				}
				break;
			}
			default:
				break;
		}
	}
	return { match, blk };
}

// Direct fields of the table constructor at `openIdx`: { key, keyIdx, valStart, valEnd } (valEnd exclusive).
function tableFields(toks, S, openIdx) {
	const close = S.match[openIdx];
	if (close < 0) return [];
	const fields = [];
	let i = openIdx + 1;
	while (i < close) {
		let key = null;
		let keyIdx = -1;
		let valStart = i;
		const t = toks[i];
		if ((t.type === 'name' || t.type === 'kw') && isOp(toks[i + 1], '=')) {
			key = t.value;
			keyIdx = i;
			valStart = i + 2;
		} else if (isOp(t, '[') && toks[i + 1] && toks[i + 1].type === 'str' && toks[i + 1].text !== null && isOp(toks[i + 2], ']') && isOp(toks[i + 3], '=')) {
			key = toks[i + 1].text;
			keyIdx = i + 1;
			valStart = i + 4;
		}
		let j = valStart;
		while (j < close && !isOp(toks[j], ',') && !isOp(toks[j], ';')) {
			const m = S.match[j];
			if (m > j && (isOpener(toks[j]) || isKw(toks[j], 'function'))) {
				j = m + 1;
				continue;
			}
			j++;
		}
		if (j > valStart || key !== null) fields.push({ key, keyIdx, valStart, valEnd: j });
		i = j + 1;
	}
	return fields;
}

// 'function' | 'table' | 'literal' (string, number, nil, true, false) | 'expr'.
function valueKind(toks, start, end) {
	let k = start;
	while (k < end && isOp(toks[k], '(')) k++;
	const t = toks[k];
	if (!t || k >= end) return 'expr';
	if (isKw(t, 'function')) return 'function';
	if (isOp(t, '{')) return 'table';
	if (t.type === 'str' || t.type === 'num' || isKw(t, 'nil') || isKw(t, 'true') || isKw(t, 'false')) {
		return end - k === 1 || isOp(toks[k + 1], '::') || isOp(toks[k + 1], ')') ? 'literal' : 'expr';
	}
	return 'expr';
}

// The `{` of a table-literal value (through parentheses and a `:: type` assertion), else -1.
function tableOpenOf(toks, start, end) {
	let k = start;
	while (k < end && isOp(toks[k], '(')) k++;
	return isOp(toks[k], '{') ? k : -1;
}

// Parameters of the function whose `function` keyword is at `fi`.
function paramList(toks, S, fi) {
	let k = fi + 1;
	while (k < toks.length && !isOp(toks[k], '(')) {
		const t = toks[k];
		if (!(t.type === 'name' || isOp(t, '.') || isOp(t, ':') || isOp(t, '<') || isOp(t, '>') || isOp(t, ','))) return null;
		k++;
	}
	const open = k;
	const close = S.match[open];
	if (open >= toks.length || close < 0) return null;
	const params = [];
	let start = open + 1;
	let angle = 0;
	for (let j = open + 1; j <= close; j++) {
		const t = toks[j];
		if (j < close) {
			if (isOpener(t) && S.match[j] > j) {
				j = S.match[j];
				continue;
			}
			if (isOp(t, '<')) angle++;
			else if (isOp(t, '>')) angle = Math.max(0, angle - 1);
		}
		if (j === close || (isOp(t, ',') && angle === 0)) {
			if (j > start) params.push({ first: start, last: j - 1, name: toks[start].value });
			start = j + 1;
		}
	}
	return { open, close, params };
}

function bindsSelf(toks, S, fi) {
	for (let k = fi + 1; k < toks.length && !isOp(toks[k], '('); k++) {
		if (isOp(toks[k], ':')) return true;
		if (k - fi > 64) break;
	}
	const pl = paramList(toks, S, fi);
	return Boolean(pl && pl.params.some((p) => p.name === 'self'));
}

// The `{...}` expressions of an interpolated string token (its raw text, backticks included).
function interpExpressions(raw) {
	const out = [];
	let i = 1;
	while (i < raw.length) {
		const c = raw[i];
		if (c === '\\') {
			i += 2;
			continue;
		}
		if (c === '`') break;
		if (c === '{') {
			const end = skipInterpExpr(raw, i + 1);
			out.push(raw.slice(i + 1, Math.max(i + 1, end - 1)));
			i = end;
			continue;
		}
		i++;
	}
	return out;
}

// True when an interpolated string reads `self` (`{self.Name}`), nested interpolations included.
// Conservative: any bare `self` counts.
function interpUsesSelf(raw) {
	for (const expr of interpExpressions(raw)) {
		const toks = tokenize(expr);
		for (let k = 0; k < toks.length; k++) {
			const t = toks[k];
			if (t.type === 'str' && t.text === null && interpUsesSelf(t.value)) return true;
			if (isName(t, 'self') && !isOp(toks[k - 1], '.') && !isOp(toks[k - 1], ':')) return true;
		}
	}
	return false;
}

// After `local <names>` (at `k`: an optional `: type`, then `=`): does the value read `self`?
function rhsUsesSelf(toks, S, k) {
	while (k < toks.length && !isOp(toks[k], '=') && toks[k].type !== 'kw') {
		if (isOpener(toks[k]) && S.match[k] > k) k = S.match[k];
		k++;
	}
	if (!isOp(toks[k], '=')) return false;
	const stop = statementEnd(toks, S, k + 1);
	for (let x = k + 1; x < stop; x++) {
		const t = toks[x];
		if (t.type === 'str' && t.text === null && interpUsesSelf(t.value)) return true;
		if (isName(t, 'self') && !isOp(toks[x - 1], '.') && !isOp(toks[x - 1], ':')) return true;
	}
	return false;
}

// True when the function at `fi` reads `self` from its own parameters: in its body, in an
// interpolated string, or in a parameter or return type (`typeof(self)`). Not from a nested
// function that binds its own self, and not `x.self` or `{ self = ... }`. `skip` is the explicit
// self parameter's token range ({ first, last }), which the rewrite removes.
function bodyUsesSelf(toks, S, fi, paramsOpen, skip = null) {
	const end = S.match[fi];
	if (end < 0) return true; // no matching `end` (a syntax error): the body is unknown, so no auto-fix
	const bodyDepth = S.blk[fi] + 1;
	for (let j = paramsOpen + 1; j < end; j++) {
		if (skip && j >= skip.first && j <= skip.last) continue;
		const t = toks[j];
		if (isKw(t, 'function')) {
			if (bindsSelf(toks, S, j) && S.match[j] > j) j = S.match[j];
			continue;
		}
		if (t.type === 'str' && t.text === null) {
			if (interpUsesSelf(t.value)) return true;
			continue;
		}
		if (isKw(t, 'local')) {
			// `local a, self = ...` directly in the body shadows it from here on. Inside a nested
			// block it only shadows that block, so the scan goes on (a later `self` counts as a use).
			let k = j + 1;
			let shadows = false;
			while (isName(toks[k]) || isOp(toks[k], ',')) {
				if (isName(toks[k], 'self') && S.blk[j] === bodyDepth) shadows = true;
				k++;
			}
			if (shadows) return rhsUsesSelf(toks, S, k); // `local self = self or S` still reads it
			j = k - 1;
			continue;
		}
		if (isName(t, 'self')) {
			const p = toks[j - 1];
			if (isOp(p, '.') || isOp(p, ':')) continue;
			if (isOp(toks[j + 1], '=') && (isOp(p, '{') || isOp(p, ',') || isOp(p, ';'))) continue;
			return true;
		}
	}
	return false;
}

// Dotted name ending just before token `endIdx` (exclusive): { parts, first } or null.
function chainBefore(toks, endIdx) {
	const parts = [];
	let k = endIdx - 1;
	if (!isName(toks[k])) return null;
	parts.unshift(toks[k].value);
	k--;
	while (isOp(toks[k], '.') && isName(toks[k - 1])) {
		parts.unshift(toks[k - 1].value);
		k -= 2;
	}
	if (isOp(toks[k], '.') || isOp(toks[k], ':')) return null; // part of a longer expression
	return { parts, first: k + 1 };
}

// Module analysis -----------------------------------------------------------------------------------

const DECL_KEYS = new Set(['Client', 'Middleware', 'Spec', 'Signals', 'ClientEvents']);
const SPEC_CALLS = new Set(['Method', 'Event', 'Signal']);

function newInfo() {
	return {
		moduleName: null,
		client: { known: true, declared: false, methods: [] }, // methods: { name, line, kind }
		events: { known: true, names: [] },
		signals: { known: true, names: [] },
		middleware: [], // { name, line }
		spec: [], // { name, line }
		specUnknown: false,
		serviceKeys: [], // { key: 'Spec'|'ClientEvents', line, modern, empty }
		middlewareTables: [], // `{` indices of Middleware tables (for the colon scan)
	};
}

function stringEntries(toks, S, openIdx, into) {
	let known = true;
	for (const f of tableFields(toks, S, openIdx)) {
		const t = toks[f.valStart];
		if (f.key === null && f.valEnd - f.valStart === 1 && t.type === 'str' && t.text !== null) {
			into.push({ name: t.text, line: t.line });
		} else {
			known = false;
		}
	}
	return known;
}

// Spec values in 2.0 are calls such as Loren.Method(...), T.Event(...) or Signal(...).
function looksModernSpec(toks, S, openIdx) {
	return tableFields(toks, S, openIdx).every((f) => {
		if (f.key === null) return false;
		const chain = [];
		let k = f.valStart;
		while (k < f.valEnd && (isName(toks[k]) || isOp(toks[k], '.'))) {
			if (isName(toks[k])) chain.push(toks[k].value);
			k++;
		}
		return chain.length > 0 && SPEC_CALLS.has(chain[chain.length - 1]) && isOp(toks[k], '(');
	});
}

// Records one declaration `Key = <value>` (a module-table field or a `X.Key = ...` statement).
function recordDecl(info, toks, S, key, keyTok, valStart, valEnd) {
	const kind = valueKind(toks, valStart, valEnd);
	const open = kind === 'table' ? tableOpenOf(toks, valStart, valEnd) : -1;
	const empty = open >= 0 && S.match[open] === open + 1;
	switch (key) {
		case 'Client':
			if (open < 0) {
				if (!(kind === 'literal' && isKw(toks[valStart], 'nil'))) info.client.known = false;
				info.client.declared = info.client.declared || kind !== 'literal';
				break;
			}
			for (const f of tableFields(toks, S, open)) {
				if (f.key === null) continue;
				info.client.declared = true;
				const vk = valueKind(toks, f.valStart, f.valEnd);
				if (vk === 'function' || vk === 'expr') info.client.methods.push({ name: f.key, line: toks[f.keyIdx].line, kind: vk });
			}
			break;
		case 'Middleware':
			if (open < 0) break;
			info.middlewareTables.push(open);
			for (const f of tableFields(toks, S, open)) if (f.key !== null) info.middleware.push({ name: f.key, line: toks[f.keyIdx].line });
			break;
		case 'Spec': {
			const unknown = open < 0 && kind !== 'literal';
			if (unknown) info.specUnknown = true;
			if (open >= 0) for (const f of tableFields(toks, S, open)) if (f.key !== null) info.spec.push({ name: f.key, line: toks[f.keyIdx].line });
			const empty2 = empty || kind === 'literal';
			info.serviceKeys.push({ key, line: keyTok.line, empty: empty2, unknown, modern: open >= 0 && looksModernSpec(toks, S, open) });
			break;
		}
		case 'Signals':
		case 'ClientEvents': {
			const bucket = key === 'Signals' ? info.signals : info.events;
			if (open < 0) {
				if (kind !== 'literal') bucket.known = false;
			} else if (!stringEntries(toks, S, open, bucket.names)) {
				bucket.known = false;
			}
			if (key === 'ClientEvents') {
				const modern = open >= 0 && tableFields(toks, S, open).every((f) => f.key === null && toks[f.valStart].type === 'str');
				info.serviceKeys.push({ key, line: keyTok.line, empty: empty || kind === 'literal', unknown: open < 0 && kind !== 'literal', modern });
			}
			break;
		}
		default:
			break;
	}
}

// Reads what a Service (or Controller) module declares. `text` is the file's source.
function analyzeLuau(text, tokens) {
	const toks = tokens || tokenize(text);
	const S = structure(toks);
	const info = newInfo();

	// The module: `return X` or `return {` at the top level (the last one wins).
	let returnTable = -1;
	for (let i = 0; i < toks.length; i++) {
		if (isKw(toks[i], 'return') && S.blk[i] === 0) {
			if (isName(toks[i + 1]) && !isOp(toks[i + 2], '.') && !isOp(toks[i + 2], '(') && !isOp(toks[i + 2], ':')) {
				info.moduleName = toks[i + 1].value;
				returnTable = -1;
			} else if (isOp(toks[i + 1], '{')) {
				returnTable = i + 1;
				info.moduleName = null;
			}
		}
	}
	const isModule = (name) => info.moduleName === null || name === info.moduleName;

	// Module tables: `local X = {` (with an optional type annotation) or `X = {` at the top level,
	// and `return {`.
	const moduleTables = [];
	if (returnTable >= 0) moduleTables.push(returnTable);
	for (let i = 0; i < toks.length; i++) {
		if (S.blk[i] !== 0) continue;
		let nameIdx = -1;
		let eqIdx = -1;
		if (isKw(toks[i], 'local') && isName(toks[i + 1])) {
			nameIdx = i + 1;
			let k = i + 2;
			if (isOp(toks[k], ':')) {
				k++;
				while (k < toks.length && !isOp(toks[k], '=') && toks[k].type !== 'kw') {
					if (isOpener(toks[k]) && S.match[k] > k) k = S.match[k];
					k++;
				}
			}
			if (isOp(toks[k], '=')) eqIdx = k;
		} else if (
			isName(toks[i]) &&
			isOp(toks[i + 1], '=') &&
			!isOp(toks[i - 1], '.') &&
			!isOp(toks[i - 1], ':') &&
			!isOp(toks[i - 1], ',') &&
			!isKw(toks[i - 1], 'local')
		) {
			nameIdx = i;
			eqIdx = i + 1;
		}
		if (eqIdx < 0 || !isModule(toks[nameIdx].value)) continue;
		const open = tableOpenOf(toks, eqIdx + 1, toks.length);
		if (open >= 0) moduleTables.push(open);
	}
	for (const open of moduleTables) {
		for (const f of tableFields(toks, S, open)) {
			if (f.key !== null && DECL_KEYS.has(f.key)) recordDecl(info, toks, S, f.key, toks[f.keyIdx], f.valStart, f.valEnd);
		}
	}

	for (let i = 0; i < toks.length; i++) {
		const t = toks[i];
		// function X.Client:Name( / function X.Middleware.Name( (at any depth)
		if (isKw(t, 'function') && isName(toks[i + 1])) {
			const parts = [toks[i + 1].value];
			let k = i + 2;
			while (isOp(toks[k], '.') && isName(toks[k + 1])) {
				parts.push(toks[k + 1].value);
				k += 2;
			}
			if (isOp(toks[k], ':') && isName(toks[k + 1])) {
				parts.push(toks[k + 1].value);
				k += 2;
			}
			if (parts.length >= 3 && isModule(parts[0])) {
				const owner = parts[parts.length - 2];
				const name = parts[parts.length - 1];
				const line = toks[i].line;
				if (owner === 'Client' && parts.length === 3) {
					info.client.declared = true;
					info.client.methods.push({ name, line, kind: 'function' });
				} else if (owner === 'Middleware' && parts.length === 3) {
					info.middleware.push({ name, line });
				}
			}
			continue;
		}
		// X.Key = value / X.Key.Name = value (top level)
		if (isOp(t, '=') && S.blk[i] === 0) {
			const chain = chainBefore(toks, i);
			if (!chain || !isModule(chain.parts[0]) || chain.parts.length < 2 || chain.parts.length > 3) continue;
			if (isOp(toks[chain.first - 1], ',') || isKw(toks[chain.first - 1], 'local')) continue;
			const end = statementEnd(toks, S, i + 1);
			const key = chain.parts[1];
			if (chain.parts.length === 2) {
				if (DECL_KEYS.has(key)) recordDecl(info, toks, S, key, toks[chain.first], i + 1, end);
			} else {
				const name = chain.parts[2];
				const line = toks[chain.first].line;
				const vk = valueKind(toks, i + 1, end);
				if (key === 'Client' && (vk === 'function' || vk === 'expr')) {
					info.client.declared = true;
					info.client.methods.push({ name, line, kind: vk });
				} else if (key === 'Middleware') {
					info.middleware.push({ name, line });
				} else if (key === 'Spec') {
					info.spec.push({ name, line });
				}
			}
		}
	}
	return info;
}

// End (exclusive) of the expression that starts at `start`: it stops where a new statement begins
// (a name or keyword right after a complete operand, other than and/or).
function statementEnd(toks, S, start) {
	let j = start;
	let needValue = true;
	while (j < toks.length) {
		const t = toks[j];
		if (isOp(t, ';')) break;
		if (isKw(t, 'and') || isKw(t, 'or') || isKw(t, 'not')) {
			needValue = true;
			j++;
			continue;
		}
		if (!needValue && (t.type === 'name' || t.type === 'num' || t.type === 'kw')) break;
		const m = S.match[j];
		if (m > j && (isOpener(t) || isKw(t, 'function'))) {
			j = m + 1;
			needValue = false;
			continue;
		}
		needValue = t.type === 'op' ? !(t.value === ')' || t.value === '}' || t.value === ']' || t.value === '...') : false;
		j++;
	}
	return j;
}

// True when a Service with this analysis is on the network (what the runtime calls `networked`):
// Client methods, Signals, ClientEvents or a Spec. Unknown (built at run time) counts as networked.
// Reserved Client names (Try, Signals...) are not networked by the runtime, so they do not count.
function isNetworked(info) {
	return (
		info.client.methods.some((m) => !RESERVED.has(m.name)) ||
		!info.client.known ||
		info.signals.names.length > 0 ||
		!info.signals.known ||
		info.events.names.length > 0 ||
		!info.events.known ||
		info.spec.length > 0 ||
		info.specUnknown
	);
}

// Colon middleware ----------------------------------------------------------------------------------

// One-line form of a (possibly multi-line) signature, for messages.
function collapse(text) {
	return text
		.replace(/\s*\n\s*([.:])(?=\w)/g, '$1') // `S.Middleware\n\t.Name(` -> `S.Middleware.Name(`
		.replace(/\s+/g, ' ')
		.replace(/\( /g, '(')
		.replace(/ \)/g, ')')
		.trim();
}

// Removes the first parameter (self) of the function at `fi` from `src`: returns { start, end, text }.
function dropSelfEdit(toks, pl) {
	if (pl.params.length === 1) return { start: toks[pl.open].end, end: toks[pl.close].start, text: '' };
	return { start: toks[pl.params[0].first].start, end: toks[pl.params[1].first].start, text: '' };
}

function applyEdits(src, edits) {
	let out = src;
	for (const e of [...edits].sort((a, b) => b.start - a.start)) out = out.slice(0, e.start) + e.text + out.slice(e.end);
	return out;
}

// The signature text (from `from` to the `)`), with the edit applied, on one line.
function preview(src, toks, from, pl, edit) {
	const start = toks[from].start;
	const end = toks[pl.close].end;
	const shifted = { start: edit.start - start, end: edit.end - start, text: edit.text };
	return collapse(applyEdits(src.slice(start, end), [shifted]));
}

// A bare `Middleware` variable (`local Middleware = {}` + `function Middleware:Name(`) is only a
// Service's middleware table when the file hands it over: `X.Middleware = Middleware` or
// `{ Middleware = Middleware }`. Otherwise it may be the user's own class, whose methods need self.
function handsOffMiddleware(toks) {
	for (let i = 2; i < toks.length; i++) {
		if (!isName(toks[i], 'Middleware') || !isOp(toks[i - 1], '=') || !isName(toks[i - 2], 'Middleware')) continue;
		const next = toks[i + 1];
		if (isOp(next, '.') || isOp(next, ':') || isOp(next, '[') || isOp(next, '(')) continue;
		const before = toks[i - 3];
		if (isOp(before, '.') || isOp(before, '{') || isOp(before, ',') || isOp(before, ';')) return true;
	}
	return false;
}

function colonIssues(src, toks, S, service) {
	const found = [];
	let bare = null; // handsOffMiddleware(toks), computed on first need
	const bareOk = () => {
		if (bare === null) bare = handsOffMiddleware(toks);
		return bare;
	};
	const add = (fi, from, name, form, pl, edit) => {
		const skip = form === 'self' ? pl.params[0] : null;
		const manual = bodyUsesSelf(toks, S, fi, pl.open, skip);
		const shown = preview(src, toks, from, pl, edit);
		const what = form === 'colon' ? `${service}.Middleware:${name} is colon-style` : `${service}.Middleware.${name} takes self`;
		let message =
			`${what}. Loren calls middleware as (player, ...args) without self, so 2.0 denies every ${name} call. ` +
			`Dot style: ${shown}`;
		if (manual) message += `. Its body uses self, so rewrite it by hand (use ${service} for the Service).`;
		found.push({ kind: 'colon-middleware', line: toks[from].line, name, message, severity: 'fixable', manual, edit: manual ? null : edit, preview: shown, fi });
	};

	for (let i = 0; i < toks.length; i++) {
		const t = toks[i];
		// Form A: function X.Middleware:Name(  /  function X.Middleware.Name(self, ...)
		if (isKw(t, 'function') && isName(toks[i + 1])) {
			const parts = [toks[i + 1].value];
			let k = i + 2;
			let colonIdx = -1;
			while (isOp(toks[k], '.') && isName(toks[k + 1])) {
				parts.push(toks[k + 1].value);
				k += 2;
			}
			if (isOp(toks[k], ':') && isName(toks[k + 1])) {
				colonIdx = k;
				parts.push(toks[k + 1].value);
				k += 2;
			}
			if (parts.length < 2 || parts[parts.length - 2] !== 'Middleware') continue;
			if (parts.length === 2 && !bareOk()) continue;
			const pl = paramList(toks, S, i);
			if (!pl) continue;
			const name = parts[parts.length - 1];
			if (colonIdx >= 0) {
				add(i, i, name, 'colon', pl, { start: toks[colonIdx].start, end: toks[colonIdx].end, text: '.' });
			} else if (pl.params.length > 0 && pl.params[0].name === 'self') {
				add(i, i, name, 'self', pl, dropSelfEdit(toks, pl));
			}
			continue;
		}
		// Form B: X.Middleware.Name = function(self, ...)
		if (isOp(t, '=') && isKw(toks[i + 1], 'function')) {
			const chain = chainBefore(toks, i);
			if (!chain || chain.parts.length < 2 || chain.parts[chain.parts.length - 2] !== 'Middleware') continue;
			if (chain.parts.length === 2 && !bareOk()) continue;
			const pl = paramList(toks, S, i + 1);
			if (pl && pl.params.length > 0 && pl.params[0].name === 'self') {
				add(i + 1, chain.first, chain.parts[chain.parts.length - 1], 'self', pl, dropSelfEdit(toks, pl));
			}
			continue;
		}
		// Form C: Middleware = { Name = function(self, ...) } as a table field or X.Middleware; a
		// `local Middleware = {` (or global) variable only when the file hands it to a module.
		if (isName(t, 'Middleware') && isOp(toks[i + 1], '=') && isOp(toks[i + 2], '{') && !isOp(toks[i - 1], ':')) {
			const p = toks[i - 1];
			const field = isOp(p, '.') || isOp(p, '{') || isOp(p, ',') || isOp(p, ';');
			if (!field && !bareOk()) continue;
			for (const f of tableFields(toks, S, i + 2)) {
				if (f.key === null || !isKw(toks[f.valStart], 'function')) continue;
				const pl = paramList(toks, S, f.valStart);
				if (pl && pl.params.length > 0 && pl.params[0].name === 'self') {
					const from = isOp(toks[f.keyIdx - 1], '[') ? f.keyIdx - 1 : f.keyIdx;
					add(f.valStart, from, f.key, 'self', pl, dropSelfEdit(toks, pl));
				}
			}
		}
	}
	return found;
}

// Per-file scan -------------------------------------------------------------------------------------

function levenshtein(a, b) {
	const dp = Array.from({ length: b.length + 1 }, (_, j) => j);
	for (let i = 1; i <= a.length; i++) {
		let prev = dp[0];
		dp[0] = i;
		for (let j = 1; j <= b.length; j++) {
			const tmp = dp[j];
			dp[j] = Math.min(dp[j] + 1, dp[j - 1] + 1, prev + (a[i - 1].toLowerCase() === b[j - 1].toLowerCase() ? 0 : 1));
			prev = tmp;
		}
	}
	return dp[b.length];
}

function suggestion(name, candidates) {
	let best = null;
	let bestD = Infinity;
	for (const c of candidates) {
		const d = levenshtein(name, c);
		if (d < bestD) {
			best = c;
			bestD = d;
		}
	}
	if (best !== null && bestD <= Math.max(2, Math.floor(name.length / 3))) return ` Did you mean '${best}'?`;
	return '';
}

const RESERVED = new Set(RESERVED_CLIENT_NAMES);
const RESERVED_LIST = [...RESERVED_CLIENT_NAMES].sort().join(', ');

// The Instance name Rojo and Argon give a module file (X.luau, X/init.luau, X/.src.luau).
function moduleNameOf(file) {
	const base = path.basename(file);
	if (/^(init|\.src)\.luau?$/i.test(base)) return path.basename(path.dirname(file));
	return base.replace(/\.luau?$/i, '');
}

// Scripts, not modules: Rojo/Argon's .server/.client, and Script Sync's .local/.legacy/.plugin too.
const isScriptFile = (file) => /\.(server|client|local|legacy|plugin)\.luau?$/i.test(file);

// All issues in one file's text. `service` enables the Service-shape checks.
function scanText(text, { file = 'module.luau', service = false, legacy = false } = {}) {
	const toks = tokenize(text);
	const S = structure(toks);
	const name = moduleNameOf(file);
	const issues = colonIssues(text, toks, S, name).map((i) => ({ ...i, file }));
	if (!service) return issues;

	const info = analyzeLuau(text, toks);
	const warn = (kind, line, message) => issues.push({ file, line, kind, message, severity: 'warn' });

	for (const m of info.client.methods) {
		if (RESERVED.has(m.name)) {
			warn('reserved-name', m.line, `${name}.Client.${m.name} uses a reserved name and is not networked (reserved: ${RESERVED_LIST}). Rename it.`);
		}
	}
	const methods = info.client.methods.filter((m) => !RESERVED.has(m.name)).map((m) => m.name);
	const events = info.events.names.map((e) => e.name);
	const signals = info.signals.names.map((s) => s.name);
	if (info.client.known && info.events.known) {
		const candidates = [...new Set([...methods, ...events])];
		for (const m of info.middleware) {
			if (!candidates.includes(m.name)) {
				warn('orphan-middleware', m.line, `${name}.Middleware.${m.name} matches no Client method or ClientEvent and is ignored.${suggestion(m.name, candidates)}`);
			}
		}
	}
	if (info.client.known && info.events.known && info.signals.known) {
		const candidates = [...new Set([...methods, ...events, ...signals])];
		for (const s of info.spec) {
			if (!candidates.includes(s.name)) {
				warn('orphan-spec', s.line, `${name}.Spec.${s.name} matches no Client method, ClientEvent or Signal and is ignored.${suggestion(s.name, candidates)}`);
			}
		}
	}
	for (const k of info.serviceKeys) {
		if (k.empty || (!legacy && (k.modern || k.unknown))) continue;
		const meaning =
			k.key === 'Spec'
				? 'per-member network specs (Loren.Method, Loren.Event, Loren.Signal)'
				: 'the names of client-to-server events';
		warn('reserved-key', k.line, `${name}.${k.key} is a Loren 2.0 key: Loren reads it as ${meaning}. If it is your own data, rename it.`);
	}
	return issues.sort((a, b) => a.line - b.line);
}

// Project layout ---------------------------------------------------------------------------------

// `$path` may be a string or { optional: "..." }.
function nodePath(node) {
	if (!node || typeof node !== 'object') return null;
	const p = node.$path;
	if (typeof p === 'string') return p;
	if (p && typeof p === 'object' && typeof p.optional === 'string') return p.optional;
	return null;
}

function child(node, ...keys) {
	let n = node;
	for (const k of keys) {
		if (!n || typeof n !== 'object' || Array.isArray(n)) return null;
		n = n[k];
	}
	return n === undefined ? null : n;
}

// Project-relative folders (shared, server, client, packages) from default.project.json's tree, with
// the scaffold's defaults as fallback. `data` is the parsed project file; omitted, it is read from disk.
// A Script Sync project (.loren.json) has fixed folders, plus the runtime folders inside them.
function projectLayout(root, data) {
	if (isScriptSync(root)) return { ...SCRIPT_SYNC_PATHS };
	if (data === undefined) {
		try {
			data = JSON.parse(readText(path.join(root, PROJECT_FILE)).replace(/^\uFEFF/, ''));
		} catch {
			data = null;
		}
	}
	const tree = child(data, 'tree');
	const pick = (keys, fallback) => {
		const p = nodePath(child(tree, ...keys));
		if (!p) return fallback;
		const abs = path.resolve(root, p);
		return isInside(root, abs) ? rel(root, abs) : fallback;
	};
	return {
		shared: pick(['ReplicatedStorage', 'Shared'], DEFAULT_PATHS.shared),
		server: pick(['ServerScriptService', 'Server'], DEFAULT_PATHS.server),
		client: pick(['StarterPlayer', 'StarterPlayerScripts', 'Client'], DEFAULT_PATHS.client),
		packages: pick(['ReplicatedStorage', 'LorenPackages'], DEFAULT_PATHS.packages),
	};
}

// runDoctor ---------------------------------------------------------------------------------------

// Interactive only with a terminal on both ends and outside CI (the same rule as lib/prompt.js).
function defaultIsTTY(env = process.env) {
	if (env.CI && env.CI !== 'false' && env.CI !== '0') return false;
	return Boolean(process.stdin.isTTY && process.stdout.isTTY);
}

// `confirm(question)` resolves true on an explicit yes. Questions carry no (y/N) hint: an injected
// prompter (lib/prompt.js) adds its own, and so does this fallback. EOF or Ctrl+C answers no.
function defaultConfirm(question) {
	return new Promise((resolve) => {
		const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
		let done = false;
		const finish = (value) => {
			if (done) return;
			done = true;
			rl.close();
			resolve(value);
		};
		rl.on('close', () => finish(false));
		rl.on('SIGINT', () => finish(false));
		rl.question(`${question} (y/N) `, (answer) => finish(/^y(es)?$/i.test(String(answer).trim())));
	});
}

// Any object with some of info/ok/warn/error/plain works; missing methods fall back to console.
function withLogger(log) {
	const base = log || require('./log').createConsoleLogger();
	const id = (s) => String(s);
	const pick = (name, fallback) => (typeof base[name] === 'function' ? base[name].bind(base) : fallback);
	return {
		info: pick('info', (m) => console.log(`${PREFIX} ${m}`)),
		ok: pick('ok', (m) => console.log(`${PREFIX} ${m}`)),
		warn: pick('warn', (m) => console.error(`${PREFIX} Warning: ${m}`)),
		error: pick('error', (m) => console.error(`${PREFIX} Error: ${m}`)),
		plain: pick('plain', (m = '') => console.log(m)),
		red: pick('red', id),
		yellow: pick('yellow', id),
		dim: pick('dim', id),
		bold: pick('bold', id),
		cyan: pick('cyan', id),
	};
}

const toDate = (now) => (typeof now === 'function' ? now() : now instanceof Date ? now : new Date());

// Copies `file` (absolute, inside root) to .loren-backup/<stamp>/<relative path>. Keeps an older copy.
function backupFile(root, file, stamp) {
	const target = path.join(root, BACKUP_DIR, stamp, path.relative(root, file));
	if (!fs.existsSync(target)) {
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.copyFileSync(file, target);
	}
	return target;
}

// Every .luau/.lua file under the given project-relative folders, once each, in a stable order.
// Files under `skip` (project-relative folders, e.g. the runtime inside Script Sync's folders) are left out.
function sourceFiles(root, dirs, skip = []) {
	const seen = new Set();
	const out = [];
	const skipped = skip.map((d) => path.join(root, d));
	for (const d of dirs) {
		for (const f of walkFiles(path.join(root, d))) {
			if (skipped.some((s) => isInside(s, f))) continue;
			if (/\.luau?$/i.test(f) && isInside(root, f) && !seen.has(f)) {
				seen.add(f);
				out.push(f);
			}
		}
	}
	return out;
}

// Scans src/** (and the shared/server/client folders default.project.json maps, when they live
// elsewhere), reports, and with `fix` offers the dot-style rewrite (backup first).
// Service checks run on modules under the server folder.
// exitCode: 0 = clean or only warnings left; 1 = fixable issues left; 2 = needs --yes (no TTY).
async function runDoctor(root, opts = {}) {
	const { fix = false, yes = false, isTTY = defaultIsTTY(), confirm = defaultConfirm, log: rawLog, now, legacy = false } = opts;
	const layout = opts.srcDir && opts.serverDir ? null : projectLayout(root);
	const serverDir = opts.serverDir || layout.server;
	const scanDirs = opts.srcDir ? [opts.srcDir] : ['src', layout.shared, layout.server, layout.client];
	// Script Sync keeps the runtime inside the scanned folders; it is never linted or rewritten.
	const skipDirs = layout ? [layout.runtimeShared, layout.runtimeServer].filter(Boolean) : [];
	const log = withLogger(rawLog);
	const serverRoot = path.join(root, serverDir);
	const texts = new Map();
	const issues = [];
	for (const abs of sourceFiles(root, scanDirs, skipDirs)) {
		let text;
		try {
			text = readText(abs);
		} catch (err) {
			log.warn(`Could not read ${rel(root, abs)}: ${err.message}`);
			continue;
		}
		const file = rel(root, abs);
		const service = isInside(serverRoot, abs) && !isScriptFile(abs);
		try {
			const found = scanText(text, { file, service, legacy });
			if (found.length) texts.set(file, { abs, text });
			issues.push(...found);
		} catch (err) {
			log.warn(`Could not scan ${file}: ${err.message}`);
		}
	}

	if (issues.length === 0) {
		log.ok('Middleware lint: no issues.');
		return { issues, fixed: [], remaining: [], exitCode: 0 };
	}

	log.info(`Middleware lint: ${issues.length} issue${issues.length === 1 ? '' : 's'}.`);
	for (const i of issues) {
		const tag = i.severity === 'fixable' ? (i.manual ? log.red('[fix by hand]') : log.yellow('[fixable]')) : log.dim('[warning]');
		log.plain(`  ${i.file}:${i.line} ${tag} ${i.message}`);
	}

	const auto = issues.filter((i) => i.severity === 'fixable' && !i.manual);
	let fixed = [];
	let exitCode = 0;
	if (fix && auto.length > 0) {
		const count = `${auto.length} middleware function${auto.length === 1 ? '' : 's'}`;
		let go = yes;
		if (!go && !isTTY) {
			log.error(`Rewriting ${count} to dot style needs confirmation. Run again with --yes (the originals are backed up to ${BACKUP_DIR}/).`);
			exitCode = 2;
		} else if (!go) {
			go = await confirm(`${PREFIX} Rewrite ${count} to dot style? The originals are backed up to ${BACKUP_DIR}/.`);
		}
		if (go) {
			const stamp = timestamp(toDate(now));
			const byFile = new Map();
			for (const i of auto) {
				if (!byFile.has(i.file)) byFile.set(i.file, []);
				byFile.get(i.file).push(i);
			}
			for (const [file, list] of byFile) {
				const { abs, text } = texts.get(file);
				try {
					backupFile(root, abs, stamp);
					writeText(abs, applyEdits(text, list.map((i) => i.edit)));
					fixed.push(...list);
				} catch (err) {
					log.error(`Could not rewrite ${file}: ${err.message}`);
				}
			}
			if (fixed.length) log.ok(`Rewrote ${fixed.length} middleware function${fixed.length === 1 ? '' : 's'} to dot style (backup: ${BACKUP_DIR}/${stamp}/).`);
		} else if (exitCode === 0) {
			log.info('Left the middleware as it is.');
		}
	}

	const remaining = issues.filter((i) => !fixed.includes(i));
	if (exitCode === 0 && remaining.some((i) => i.severity === 'fixable')) {
		exitCode = 1;
		// --fix only helps when something is auto-fixable; [fix by hand] ones need the user.
		if (!fix && remaining.some((i) => i.severity === 'fixable' && !i.manual)) {
			log.info('Run `loren doctor --fix` to rewrite colon-style middleware to dot style.');
		}
		if (remaining.some((i) => i.manual)) {
			log.info('Rewrite the [fix by hand] middleware to dot style yourself, then run `loren doctor` again.');
		}
	}
	return { issues, fixed, remaining, exitCode };
}

module.exports = {
	runDoctor,
	scanText,
	analyzeLuau,
	isNetworked,
	moduleNameOf,
	isScriptFile,
	tokenize,
	structure,
	applyEdits,
	backupFile,
	defaultConfirm,
	defaultIsTTY,
	withLogger,
	toDate,
	projectLayout,
	nodePath,
};
