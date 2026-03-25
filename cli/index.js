#!/usr/bin/env node
const { program } = require('commander');
const fs = require('fs-extra');
const path = require('path');
const degit = require('degit');

program
  .version('1.0.0')
  .description('Loren-Framework CLI');

// Command: loren init <project-name>
program
  .command('init <name>')
  .description('Initialize a new Loren-Framework project')
  .action((name) => {
    const targetDir = path.join(process.cwd(), name);
    // This points to  /template folder
    const templateDir = path.join(__dirname, '../template');

    if (fs.existsSync(targetDir)) {
      console.error(`[<LOREN>] Error: Folder "${name}" already exists.`);
      return;
    }

    try {
      fs.copySync(templateDir, targetDir);
      console.log(`[<LOREN>] Successfully created Loren project: ${name}`);
      console.log(`[<LOREN>] Next: cd ${name} and run 'rojo serve'`);
    } catch (err) {
      console.error(`[<LOREN>] Error copying template:`, err);
    }
  });

program
    .command('add <repo> [alias]')
    .description('Add a module from GitHub')
    .action(async (repo, alias) => {
    const parts = repo.split('/');
    let folderName = alias || parts[1].split('#')[0]; 
    
    if (parts[2]) {
        folderName = parts[1].split('#')[0];
    }

    const targetFolder = path.join(process.cwd(), 'loren_packages', folderName);
    
    console.log(`[<LOREN>] Fetching ${repo} into ${folderName}...`);

    const emitter = degit(repo, {
      cache: false,
      force: true,
    });

    try {
      await emitter.clone(targetFolder);
      console.log(`[<LOREN>] Module "${folderName}" is ready!`);
    } catch (err) {
      console.error(`[<LOREN>] Error: ${err.message}`);
    }
  });

program.parse(process.argv);