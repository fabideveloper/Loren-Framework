'use strict';

const path = require('path');
const { BACKUP_DIR } = require('./constants');
const { copyPath, exists, isInside, timestamp } = require('./fsutil');

// Copies `target` (inside `root`) to .loren-backup/<stamp>/<same relative path> before a
// command replaces or rewrites it. Returns the backup's path.
function backupPath(root, target, stamp = timestamp()) {
	if (!exists(target)) return null;
	if (!isInside(root, target)) throw new Error(`Refusing to back up ${target}: it is outside the project`);
	const dest = path.join(root, BACKUP_DIR, stamp, path.relative(root, target));
	copyPath(target, dest);
	return dest;
}

module.exports = { backupPath };
