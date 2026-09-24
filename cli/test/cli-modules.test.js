'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { renderModule } = require('../lib/templates');
const { tmpDir, mockLanes, runCli, makeProject, listFiles, read, TEMPLATE_DIR } = require('./helpers');

const SERVICES = 'src/server/Services';
const CONTROLLERS = 'src/client/Controllers';

test('make service/controller writes the scaffold template into Services/Controllers', async (t) => {
	const root = await makeProject(t);
	const lanes = mockLanes();
	const s = await runCli(['make', 'service', 'CombatService'], { cwd: root, lanes });
	assert.equal(s.code, 0, s.all);
	const file = path.join(root, SERVICES, 'CombatService.luau');
	assert.equal(read(file), renderModule('service', 'CombatService'));
	assert.match(read(file), /^local CombatService = \{/);
	assert.doesNotMatch(read(file), /ExampleService/);
	// Types before the sourcemap, with the project's tool.
	assert.deepEqual(
		lanes.events.filter((e) => e.fn !== 'resolveTool').map((e) => e.fn),
		['generateTypes', 'sourcemap'],
	);

	const c = await runCli(['make', 'Controller', 'HudController'], { cwd: root });
	assert.equal(c.code, 0, c.all);
	assert.equal(read(path.join(root, CONTROLLERS, 'HudController.luau')), renderModule('controller', 'HudController'));
});

test('make uses exactly the scaffold examples as its templates', () => {
	for (const [kind, file, name] of [
		['service', `${SERVICES}/ExampleService.luau`, 'ExampleService'],
		['controller', `${CONTROLLERS}/ExampleController.luau`, 'ExampleController'],
	]) {
		const scaffold = read(path.join(TEMPLATE_DIR, file)).replace(/\r\n/g, '\n');
		assert.equal(renderModule(kind, name), scaffold);
		assert.equal(renderModule(kind, 'Zed'), scaffold.replace(new RegExp(`\\b${name}\\b`, 'g'), 'Zed'));
	}
});

test('make validates names and never writes outside the folder', async (t) => {
	const root = await makeProject(t);
	const before = listFiles(root);
	for (const bad of ['Combat/Damage', '..', '../Evil', '1Service', 'end', 'my-service', 'CON', '', 'a\\b']) {
		const r = await runCli(['make', 'service', bad], { cwd: root });
		assert.equal(r.code, 1, `accepted ${JSON.stringify(bad)}`);
	}
	assert.deepEqual(listFiles(root), before);
});

test('make refuses existing names (any case, either kind) unless --force', async (t) => {
	const root = await makeProject(t);
	const same = await runCli(['make', 'service', 'exampleservice'], { cwd: root });
	assert.equal(same.code, 1);
	assert.match(same.err, /already exists/);

	const cross = await runCli(['make', 'controller', 'ExampleService'], { cwd: root });
	assert.equal(cross.code, 1);
	assert.match(cross.err, /already a Service/);
	assert.ok(!fs.existsSync(path.join(root, CONTROLLERS, 'ExampleService.luau')));

	fs.writeFileSync(path.join(root, SERVICES, 'ExampleService.luau'), '-- mine\nreturn {}\n');
	const forced = await runCli(['make', 'service', 'ExampleService', '--force'], { cwd: root });
	assert.equal(forced.code, 0, forced.all);
	assert.equal(read(path.join(root, SERVICES, 'ExampleService.luau')), renderModule('service', 'ExampleService'));
	const backups = listFiles(path.join(root, '.loren-backup'));
	assert.equal(backups.length, 1);
	assert.equal(read(path.join(root, '.loren-backup', backups[0])), '-- mine\nreturn {}\n');
});

test('make warns about non-PascalCase names, rejects unknown types and non-projects', async (t) => {
	const root = await makeProject(t);
	const lower = await runCli(['make', 'controller', 'hud'], { cwd: root });
	assert.equal(lower.code, 0);
	assert.match(lower.err, /not PascalCase/);

	const kind = await runCli(['make', 'widget', 'Foo'], { cwd: root });
	assert.equal(kind.code, 1);
	assert.match(kind.err, /Unknown type "widget"/);

	const outside = await runCli(['make', 'service', 'Foo'], { cwd: tmpDir(t) });
	assert.equal(outside.code, 1);
	assert.match(outside.err, /No default\.project\.json/);
});

test('make exits 1 when the sourcemap or the types fail, after saying what was created', async (t) => {
	const root = await makeProject(t);
	const r = await runCli(['make', 'service', 'Foo'], { cwd: root, lanes: mockLanes({ sourcemapOk: false }) });
	assert.equal(r.code, 1);
	assert.match(r.out, /Created Service Foo/);
	assert.match(r.err, /sourcemap\.json was not regenerated/);

	const r2 = await runCli(['make', 'service', 'Bar'], { cwd: root, lanes: mockLanes({ typesResult: new Error('boom') }) });
	assert.equal(r2.code, 1);
	assert.match(r2.err, /LorenTypes were not regenerated: boom/);
});

test('make follows the folders in default.project.json', async (t) => {
	const root = await makeProject(t);
	const pj = JSON.parse(read(path.join(root, 'default.project.json')));
	pj.tree.ServerScriptService.Server.$path = 'game/server';
	fs.writeFileSync(path.join(root, 'default.project.json'), JSON.stringify(pj));
	const r = await runCli(['make', 'service', 'Moved'], { cwd: root });
	assert.equal(r.code, 0, r.all);
	assert.ok(fs.existsSync(path.join(root, 'game', 'server', 'Services', 'Moved.luau')));
});

test('inject --list shows the built-in premades (no retired Example* ones), even outside a project', async (t) => {
	const r = await runCli(['inject', '--list'], { cwd: tmpDir(t) });
	assert.equal(r.code, 0, r.all);
	assert.match(r.out, /service\s+PointsService\s+built-in/);
	assert.match(r.out, /controller\s+PointsController\s+built-in/);
	assert.match(r.out, /shared\s+ExampleShared\s+built-in/);
	assert.doesNotMatch(r.out, /ExampleService|ExampleController/);

	const filtered = await runCli(['inject', '--list', 'controller'], { cwd: tmpDir(t) });
	assert.equal(filtered.code, 0);
	assert.doesNotMatch(filtered.out, /PointsService/);
});

test('inject writes into the correctly cased Services / Controllers / shared folders', async (t) => {
	const root = await makeProject(t);
	const lanes = mockLanes();
	assert.equal((await runCli(['inject', 'service', 'PointsService'], { cwd: root, lanes })).code, 0);
	assert.equal((await runCli(['inject', 'controller', 'pointscontroller'], { cwd: root })).code, 0);
	assert.equal((await runCli(['inject', 'shared', 'ExampleShared'], { cwd: root })).code, 0);
	const files = listFiles(root);
	assert.ok(files.includes(`${SERVICES}/PointsService.luau`));
	assert.ok(files.includes(`${CONTROLLERS}/PointsController.luau`), 'premade casing kept');
	assert.ok(files.includes('src/shared/ExampleShared.luau'));
	assert.ok(!files.some((f) => /\/services\/|\/controllers\//.test(f)), 'no lowercase folders');
	assert.equal(
		read(path.join(root, SERVICES, 'PointsService.luau')),
		read(path.join(TEMPLATE_DIR, 'loren_premade/services/PointsService.luau')),
	);
	assert.deepEqual(
		lanes.events.filter((e) => e.fn !== 'resolveTool').map((e) => e.fn),
		['generateTypes', 'sourcemap'],
	);
});

test("inject prefers the project's own loren_premade and refuses collisions without --force", async (t) => {
	const root = await makeProject(t);
	const own = path.join(root, 'loren_premade', 'services');
	fs.mkdirSync(own, { recursive: true });
	fs.writeFileSync(path.join(own, 'MyThing.luau'), 'return {}\n');
	const list = await runCli(['inject', '--list'], { cwd: root });
	assert.match(list.out, /service\s+MyThing\s+project/);
	assert.equal((await runCli(['inject', 'service', 'MyThing'], { cwd: root })).code, 0);

	const again = await runCli(['inject', 'service', 'MyThing'], { cwd: root });
	assert.equal(again.code, 1);
	assert.match(again.err, /already exists/);
	assert.equal((await runCli(['inject', 'service', 'MyThing', '--force'], { cwd: root })).code, 0);

	const missing = await runCli(['inject', 'service', 'Nope'], { cwd: root });
	assert.equal(missing.code, 1);
	assert.match(missing.err, /No service premade named "Nope"\. Available: .*PointsService/);

	const noArgs = await runCli(['inject'], { cwd: root });
	assert.equal(noArgs.code, 1);
	const badKind = await runCli(['inject', 'widget', 'X'], { cwd: root });
	assert.equal(badKind.code, 1);
});
