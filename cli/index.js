#!/usr/bin/env node
const { program } = require('commander');
const fs = require('fs-extra');
const path = require('path');
const degit = require('degit');
const { execSync } = require('child_process');

program
  .version('1.0.0')
  .description('Loren-Framework - Burning like a beating heart.');

const hasRojo = () => {
  try {
    execSync('rojo --version', { stdio: 'ignore' });
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

      // Normalize project name and paths for the new project structure
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

      // Generate localized .vscode settings for the Luau LSP
      const vscodeDir = path.join(targetDir, '.vscode');
      const settings = {
        "luau-lsp.rojo.projectPath": "default.project.json",
        "luau-lsp.sourcemap.autogenerate": true,
        "luau-lsp.sourcemap.rojoProjectFile": "default.project.json",
        "luau-lsp.sourcemap.enabled": true,
        "luau-lsp.sourcemap.sourcemapFile": "sourcemap.json"
      };
      await fs.ensureDir(vscodeDir);
      await fs.writeJson(path.join(vscodeDir, 'settings.json'), settings, { spaces: 4 });

      if (hasRojo()) {
        console.log(`(LORENঌ) Generating fresh sourcemap...`);
        const oldMap = path.join(targetDir, 'sourcemap.json');
        if (fs.existsSync(oldMap)) fs.removeSync(oldMap);

        execSync('rojo sourcemap default.project.json --output sourcemap.json', { 
          cwd: targetDir,
          stdio: 'ignore' 
        });
      }

      // Formatting commands as bold/underlined to stand out
      console.log(`\n(LORENঌ) Done! Project "${name}" is ready.`);
      console.log(`(LORENঌ) To start coding, run:`);
      console.log(`\x1b[1m\x1b[4mcd ${name}\x1b[0m and then: \x1b[1m\x1b[4mcode .\x1b[0m\n`);

    } catch (err) {
      console.error(`(LORENঌ) Init failed:`, err.message);
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
      
      if (hasRojo()) {
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

program.parse(process.argv);