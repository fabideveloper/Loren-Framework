'use strict';

const fs = require('fs');
const path = require('path');
const { PACKAGE_PROJECT_DIR, MODULE_TEMPLATES } = require('./constants');
const { normalizeEol } = require('./fsutil');

function renderModule(kind, name, templateDir = PACKAGE_PROJECT_DIR) {
	const t = MODULE_TEMPLATES[kind];
	if (!t) throw new Error(`Unknown module kind "${kind}"`);
	const file = path.join(templateDir, ...t.file.split('/'));
	const text = normalizeEol(fs.readFileSync(file, 'utf8'));
	return text.replace(new RegExp(`\\b${t.placeholder}\\b`, 'g'), name);
}

module.exports = { renderModule };
