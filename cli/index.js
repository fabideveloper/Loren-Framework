#!/usr/bin/env node
const { program } = require('commander');
const fs = require('fs-extra');
const path = require('path');
const degit = require('degit');
const { execSync } = require('child_process');

program
  .version('1.2.0')
  .description('Loren-Framework - Burning like a beating heart.');

const hasRojo = (cwd = process.cwd()) => {
  try {
    execSync('rojo --version', { cwd, stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
};

program
  .command('init <name>')
  .description('Initialize a new Loren-Framework project')
  .action(async (name) => {
    const targetDir = path.join(process.cwd(), name);
    const templateDir = path.join(__dirname, '../project'); 

    if (fs.existsSync(targetDir)) {
      return console.error(`(LORENঌ) Error: Folder "${name}" already exists.`);
    }

    try {
      console.log(`(LORENঌ) Building "${name}"...`);
      await fs.copy(templateDir, targetDir);

      const aftmanPath = path.join(targetDir, 'aftman.toml');
      const rojoTool = 'rojo = "rojo-rbx/rojo@7.4.1"';

      if (!fs.existsSync(aftmanPath)) {
        console.log(`(LORENঌ) Creating new aftman.toml...`);
        fs.writeFileSync(aftmanPath, `[tools]\n${rojoTool}`);
      } else {
        let content = fs.readFileSync(aftmanPath, 'utf8');
        if (!content.includes('rojo =')) {
          console.log(`(LORENঌ) Rojo missing from aftman.toml. Injecting...`);
          if (content.includes('[tools]')) {
            content = content.replace('[tools]', `[tools]\n${rojoTool}`);
          } else {
            content += `\n[tools]\n${rojoTool}`;
          }
          fs.writeFileSync(aftmanPath, content);
        }
      }

      try {
        console.log(`(LORENঌ) Syncing toolchain...`);
        execSync('aftman install', { cwd: targetDir, stdio: 'inherit' });
      } catch (err) {
        console.warn(`(LORENঌ) Aftman failed. Rojo might not be available.`);
      }

      const projectFilePath = path.join(targetDir, 'default.project.json');
      if (fs.existsSync(projectFilePath)) {
        const projectData = await fs.readJson(projectFilePath);
        projectData.name = name;

        if (projectData.tree && projectData.tree.ReplicatedStorage) {
          projectData.tree.ReplicatedStorage.Shared = { "$path": "src/shared" };
          projectData.tree.ReplicatedStorage.LorenPackages = { "$path": "loren_packages" };
        }
        await fs.writeJson(projectFilePath, projectData, { spaces: 4 });
      }

      const vscodeDir = path.join(targetDir, '.vscode');
      const settings = {
        "luau-lsp.rojo.projectPath": "default.project.json",
        "luau-lsp.sourcemap.autogenerate": true,
        "luau-lsp.sourcemap.rojoProjectFile": "default.project.json",
        "luau-lsp.sourcemap.enabled": true,
        "luau-lsp.sourcemap.sourcemapFile": "sourcemap.json",
      };
      await fs.ensureDir(vscodeDir);
      await fs.writeJson(path.join(vscodeDir, 'settings.json'), settings, { spaces: 4 });

      if (hasRojo(targetDir)) {
        console.log(`(LORENঌ) Generating fresh sourcemap...`);
        const oldMap = path.join(targetDir, 'sourcemap.json');
        if (fs.existsSync(oldMap)) fs.removeSync(oldMap);

        execSync('rojo sourcemap default.project.json --output sourcemap.json', { 
          cwd: targetDir,
          stdio: 'ignore' 
        });
      }

      console.log(`\n(LORENঌ) Done! Project "${name}" is ready.`);
      console.log(`(LORENঌ) To start coding, run:`);
      console.log(`\x1b[1m\x1b[4mcd ${name}\x1b[0m and then: \x1b[1m\x1b[4mcode .\x1b[0m\n`);

    } catch (err) {
      console.error(`(LORENঌ) Init failed:`, err.message);
    }
  });

program
  .command('make <type> <name>')
  .description('Create a new service or controller with Loren v1.2.0 boilerplate')
  .action((type, name) => {
    const root = process.cwd();
    if (!fs.existsSync(path.join(root, 'default.project.json'))) {
      return console.error(`(LORENঌ) Error: You must be in the root of a Loren project.`);
    }

    const typeLower = type.toLowerCase();
    let subFolder = '';
    let content = '';

    if (typeLower === 'service') {
      subFolder = 'src/server/Services';
      content = `
local ${name} = {
  Dependencies = {},
  
  Client = {},
  
  -- List signal names here. Loren injects them automatically.
  Signals = {},
  
  -- Optional: Security checks for Client functions
  Middleware = {},
}

-- Called when the framework initializes (Synchronous)
function ${name}:LorenIgnite()
  
end

-- Called after all modules are ignited (Asynchronous)
function ${name}:LorenBurn()
  
end

return ${name}`;

    } else if (typeLower === 'controller') {
      subFolder = 'src/client/Controllers';
      content = `

local ${name} = {
  Dependencies = {},
} 

-- Called when the framework initializes (Synchronous)
function ${name}:LorenIgnite()
  
end

-- Called after all modules are ignited (Asynchronous)
function ${name}:LorenBurn()
  
end

return ${name}`;

    } else {
      return console.error(`(LORENঌ) Error: Type must be 'service' or 'controller'.`);
    }

    const filePath = path.join(root, subFolder, `${name}.luau`);

    if (fs.existsSync(filePath)) {
      return console.error(`(LORENঌ) Error: ${name} already exists at ${subFolder}`);
    }

    try {
      fs.outputFileSync(filePath, content);

      console.log(`(LORENঌ) Successfully forged ${typeLower}: ${name}`);

      if (hasRojo(root)) {
        execSync('rojo sourcemap default.project.json --output sourcemap.json', { cwd: root, stdio: 'ignore' });
      }
    } catch (err) {
      console.error(`(LORENঌ) Failed to create file:`, err.message);
    }
  });


program
  .command('inject <type> <name>')
  .description('Inject a premade module from loren_premade into your project')
  .action((type, name) => {
    const root = process.cwd();
    if (!fs.existsSync(path.join(root, 'default.project.json'))) {
      return console.error(`(LORENঌ) Error: You must be in the root of a Loren project.`);
    }

    const typeLower = type.toLowerCase();
    let srcPath = '';
    let destPath = '';

    if (typeLower === 'service') {
      srcPath = path.join(root, 'loren_premade', 'services');
      destPath = path.join(root, 'src', 'server', 'services');
    } else if (typeLower === 'controller') {
      srcPath = path.join(root, 'loren_premade', 'controllers');
      destPath = path.join(root, 'src', 'client', 'controllers');
    } else if (typeLower === 'shared') {
      srcPath = path.join(root, 'loren_premade', 'shared');
      destPath = path.join(root, 'src', 'shared');
    } else {
      return console.error(`(LORENঌ) Error: Type must be 'service', 'controller' or 'shared'.`);
    }

    const fileSrc = path.join(srcPath, `${name}.luau`);
    const dirSrc = path.join(srcPath, name);
    const fileDest = path.join(destPath, `${name}.luau`);
    const dirDest = path.join(destPath, name);

    let targetSrc = '';
    let targetDest = '';

    if (fs.existsSync(fileSrc)) {
      targetSrc = fileSrc;
      targetDest = fileDest;
    } else if (fs.existsSync(dirSrc)) {
      targetSrc = dirSrc;
      targetDest = dirDest;
    } else {
      return console.error(`(LORENঌ) Error: Premade ${name} not found in ${srcPath}.`);
    }

    if (fs.existsSync(targetDest)) {
      return console.error(`(LORENঌ) Error: ${name} already exists in destination.`);
    }

    try {
      fs.copySync(targetSrc, targetDest);
      console.log(`(LORENঌ) Successfully injected ${typeLower}: ${name}`);

      if (hasRojo(root)) {
        execSync('rojo sourcemap default.project.json --output sourcemap.json', { cwd: root, stdio: 'ignore' });
      }
    } catch (err) {
      console.error(`(LORENঌ) Failed to inject:`, err.message);
    }
  });

program
  .command('add <repo> [alias]')
  .description('Add a module from GitHub into loren_packages')
  .action(async (repo, alias) => {
    const parts = repo.split('/');
    if (parts.length < 2) return console.error(`(LORENঌ) Invalid repo format. Use: user/repo`);

    let folderName = alias || parts[1].split('#')[0].replace('roblox-lua-', '');
    const packageDir = path.join(process.cwd(), 'loren_packages');

    if (!fs.existsSync(path.join(process.cwd(), 'default.project.json'))) {
        console.warn(`(LORENঌ) Warning: Not in a Loren project root.`);
    }

    const targetFolder = path.join(packageDir, folderName);
    console.log(`(LORENঌ) Fetching ${repo} as "${folderName}"...`);

    try {
      await degit(repo, { cache: false, force: true }).clone(targetFolder);
      
      if (hasRojo(process.cwd())) {
        try {
          execSync('rojo sourcemap default.project.json --output sourcemap.json', { 
            cwd: process.cwd(), 
            stdio: 'ignore' 
          });
        } catch (e) {
          console.warn(`(LORENঌ) Module added; manual sourcemap update may be required.`);
        }
      }
      console.log(`(LORENঌ) Module "${folderName}" added to loren_packages!`);
    } catch (err) {
      console.error(`(LORENঌ) Download failed: ${err.message}`);
    }
  });

program
  .command('ignite')
  .description('Start the Rojo server.')
  .action(() => {
    const root = process.cwd();
    console.log(`(LORENঌ) Heart is beating. Rojo is watching...`);
    execSync('rojo serve', { cwd: root, stdio: 'inherit' });
  });

program.parse(process.argv);