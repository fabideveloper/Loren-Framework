'use strict';

async function checkForUpdates(pkg, { isTTY, env = process.env, importer = (m) => import(m) } = {}) {
	if (!isTTY || env.NO_UPDATE_NOTIFIER || env.LOREN_NO_UPDATE_CHECK || env.NODE_ENV === 'test') return false;
	try {
		const mod = await importer('update-notifier');
		const updateNotifier = mod && (mod.default || mod);
		if (typeof updateNotifier !== 'function') return false;
		const notifier = updateNotifier({ pkg: { name: pkg.name, version: pkg.version } });
		notifier.notify({
			defer: true,
			isGlobal: true,
			message:
				'Loren CLI {currentVersion} -> {latestVersion}\n' +
				'Update the CLI: npm i -g loren-framework\n' +
				"Then update each project's runtime: loren update",
		});
		return true;
	} catch {
		return false;
	}
}

module.exports = { checkForUpdates };
