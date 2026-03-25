#!/usr/bin/env node
const { program } = require('commander');
const fs = require('fs-extra');
const path = require('path');

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
      console.error(`Error: Folder "${name}" already exists.`);
      return;
    }

    try {
      fs.copySync(templateDir, targetDir);
      console.log(`Successfully created Loren project: ${name}`);
      console.log(`Next: cd ${name} and run 'rojo serve'`);
    } catch (err) {
      console.error('Error copying template:', err);
    }
  });

program.parse(process.argv);