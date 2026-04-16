#!/usr/bin/env node
const { program } = require('commander');
const fs = require('fs-extra');
const path = require('path');
const degit = require('degit');
const { execSync } = require('child_process');
const readline = require('readline');

program
  .version('1.4.0')
  .description('Loren-Framework - Burning like a beating heart.');

const hasCommand = (cmd, cwd = process.cwd()) => {
  try {
    execSync(`${cmd} --version`, { cwd, stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
};

const getProjectTool = (cwd = process.cwd()) => {
  const aftmanPath = path.join(cwd, 'aftman.toml');
  if (fs.existsSync(aftmanPath)) {
    const content = fs.readFileSync(aftmanPath, 'utf8');
    if (content.includes('argon-rbx/argon')) return 'argon';
    if (content.includes('rojo-rbx/rojo')) return 'rojo';
  }
  return hasCommand('argon', cwd) ? 'argon' : 'rojo'; 
};

// Wraps sourcemap generation based on the active tool
const generateSourcemap = (cwd, tool = getProjectTool(cwd)) => {
  if (!hasCommand(tool, cwd)) return;
  try {
    const cmd = tool === 'argon' 
      ? 'argon sourcemap default.project.json -o sourcemap.json' 
      : 'rojo sourcemap default.project.json --output sourcemap.json';
      
    execSync(cmd, { cwd, stdio: 'ignore' });
  } catch (err) {
    console.warn(`(LORENঌ) Warning: Failed to generate sourcemap with ${tool}.`);
  }
};

// Interactive prompt for init
const askSyncTool = () => {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    console.log('\n(LORENঌ) Which sync tool do you prefer?');
    rl.question('  [1] Rojo (Default)\n  [2] Argon\n> ', (answer) => {
      rl.close();
      resolve(answer.trim() === '2' ? 'argon' : 'rojo');
    });
  });
};

const confirmMigration = (targetTool) => {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(`\n(LORENঌ) Migrate project to ${targetTool}? (y/N): `, (answer) => {
      rl.close();
      resolve(answer.trim().toLowerCase() === 'y');
    });
  });
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

    const tool = await askSyncTool();
    const toolString = tool === 'argon' 
      ? 'argon = "argon-rbx/argon@2.0.6"' 
      : 'rojo = "rojo-rbx/rojo@7.4.1"';

    try {
      console.log(`(LORENঌ) Building "${name}"...`);
      await fs.copy(templateDir, targetDir);

      const aftmanPath = path.join(targetDir, 'aftman.toml');

      // Inject the selected sync tool into aftman.toml
      if (!fs.existsSync(aftmanPath)) {
        console.log(`(LORENঌ) Creating new aftman.toml...`);
        fs.writeFileSync(aftmanPath, `[tools]\n${toolString}`);
      } else {
        let content = fs.readFileSync(aftmanPath, 'utf8');
        const toolCheck = tool === 'argon' ? 'argon =' : 'rojo =';
        
        if (!content.includes(toolCheck)) {
          console.log(`(LORENঌ) ${tool === 'argon' ? 'Argon' : 'Rojo'} missing from aftman.toml. Injecting...`);
          if (content.includes('[tools]')) {
            content = content.replace('[tools]', `[tools]\n${toolString}`);
          } else {
            content += `\n[tools]\n${toolString}`;
          }
          fs.writeFileSync(aftmanPath, content);
        }
      }

      try {
        console.log(`(LORENঌ) Syncing toolchain...`);
        execSync('aftman install', { cwd: targetDir, stdio: 'inherit' });
      } catch (err) {
        console.warn(`(LORENঌ) Aftman failed. ${tool} might not be available.`);
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
        "luau-lsp.sourcemap.autogenerate": tool === 'rojo', 
        "luau-lsp.sourcemap.rojoProjectFile": "default.project.json",
        "luau-lsp.sourcemap.enabled": true,
        "luau-lsp.sourcemap.sourcemapFile": "sourcemap.json",
      };
      await fs.ensureDir(vscodeDir);
      await fs.writeJson(path.join(vscodeDir, 'settings.json'), settings, { spaces: 4 });

      console.log(`(LORENঌ) Generating fresh sourcemap...`);
      const oldMap = path.join(targetDir, 'sourcemap.json');
      if (fs.existsSync(oldMap)) fs.removeSync(oldMap);
      
      generateSourcemap(targetDir, tool);

      console.log(`\n(LORENঌ) Done! Project "${name}" is ready.`);
      console.log(`(LORENঌ) To start coding, run:`);
      console.log(`\x1b[1m\x1b[4mcd ${name}\x1b[0m and then: \x1b[1m\x1b[4mcode .\x1b[0m\n`);

    } catch (err) {
      console.error(`(LORENঌ) Init failed:`, err.message);
    }
  });

program
  .command('make <type> <name>')
  .description('Create a new service or controller with Loren v1.4.0 boilerplate')
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
      generateSourcemap(root);
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
      generateSourcemap(root);
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
      generateSourcemap(process.cwd());
      console.log(`(LORENঌ) Module "${folderName}" added to loren_packages!`);
    } catch (err) {
      console.error(`(LORENঌ) Download failed: ${err.message}`);
    }
  });

program
  .command('refresh')
  .description('Manually refresh the sourcemap to update VS Code IntelliSense')
  .action(() => {
    const root = process.cwd();
    
    if (!fs.existsSync(path.join(root, 'default.project.json'))) {
      return console.error(`(LORENঌ) Error: You must be in the root of a Loren project.`);
    }

    const tool = getProjectTool(root);
    if (hasCommand(tool, root)) {
      console.log(`(LORENঌ) Refreshing sourcemap via ${tool === 'argon' ? 'Argon' : 'Rojo'}...`);
      generateSourcemap(root, tool);
      console.log(`(LORENঌ) Sourcemap updated successfully!`);
    } else {
      console.error(`(LORENঌ) Error: ${tool === 'argon' ? 'Argon' : 'Rojo'} is not installed or available in this directory.`);
    }
  });

program
  .command('ignite')
  .description('Start the local sync server.')
  .action(() => {
    const root = process.cwd();
    const tool = getProjectTool(root);
    
    console.log(`(LORENঌ) Heart is beating. ${tool === 'argon' ? 'Argon' : 'Rojo'} server enabled`);
    execSync(`${tool} serve`, { cwd: root, stdio: 'inherit' });
  });

  program
  .command('migrate')
  .description('Migrate the current project between Rojo and Argon')
  .action(async () => {
    const root = process.cwd();
    
    if (!fs.existsSync(path.join(root, 'default.project.json'))) {
      return console.error(`(LORENঌ) Error: You must be in the root of a Loren project.`);
    }

    const currentTool = getProjectTool(root);
    const targetTool = currentTool === 'rojo' ? 'argon' : 'rojo';
    
    console.log(`(LORENঌ) Detected current sync tool: ${currentTool}`);
    const shouldMigrate = await confirmMigration(targetTool);
    
    if (!shouldMigrate) {
      return console.log(`(LORENঌ) Migration cancelled.`);
    }

    console.log(`(LORENঌ) Migrating to ${targetTool}...`);

    const aftmanPath = path.join(root, 'aftman.toml');
    const rojoString = 'rojo = "rojo-rbx/rojo@7.4.1"';
    const argonString = 'argon = "argon-rbx/argon@2.0.6"';

    if (fs.existsSync(aftmanPath)) {
      let content = fs.readFileSync(aftmanPath, 'utf8');
      
      if (targetTool === 'argon') {
        content = content.replace(/rojo\s*=\s*['"].*?['"]/g, '');
        if (!content.includes('argon =')) content = content.replace('[tools]', `[tools]\n${argonString}`);
      } else {
        content = content.replace(/argon\s*=\s*['"].*?['"]/g, '');
        if (!content.includes('rojo =')) content = content.replace('[tools]', `[tools]\n${rojoString}`);
      }
      
      fs.writeFileSync(aftmanPath, content.replace(/^\s*[\r\n]/gm, ''));

      try {
        console.log(`(LORENঌ) Updating toolchain via Aftman...`);
        execSync('aftman install', { cwd: root, stdio: 'ignore' });
      } catch (err) {
        console.warn(`(LORENঌ) Warning: Aftman failed. ${targetTool} might not be installed globally.`);
      }
    }

    const vscodeSettingsPath = path.join(root, '.vscode', 'settings.json');
    if (fs.existsSync(vscodeSettingsPath)) {
      try {
        const settings = await fs.readJson(vscodeSettingsPath);
        settings["luau-lsp.sourcemap.autogenerate"] = targetTool === 'rojo';
        await fs.writeJson(vscodeSettingsPath, settings, { spaces: 4 });
        console.log(`(LORENঌ) Updated VS Code Luau-LSP settings.`);
      } catch (err) {
        console.warn(`(LORENঌ) Warning: Failed to update VS Code settings.`);
      }
    }

    console.log(`(LORENঌ) Generating fresh sourcemap with ${targetTool}...`);
    generateSourcemap(root, targetTool);

    console.log(`(LORENঌ) Success! Project fully migrated to ${targetTool}.`);
  });

program.parse(process.argv);