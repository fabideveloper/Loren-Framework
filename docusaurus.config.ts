import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'Loren',
  tagline: 'Burning like a beating heart.',
  favicon: 'img/favicon.png',

  url: 'https://fabideveloper.github.io',
  baseUrl: '/Loren-Framework/',

  organizationName: 'fabideveloper',
  projectName: 'Loren-Framework',

  onBrokenLinks: 'warn',

  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  clientModules: ['./src/js/ripple.js'],

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          editUrl:
            'https://github.com/fabideveloper/Loren-Framework/edit/main/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: 'img/logo.png',
    colorMode: {
      defaultMode: 'dark',
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'Loren',
      logo: {
        alt: 'Loren Logo',
        src: 'img/logo.png',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'docsSidebar',
          position: 'left',
          label: 'Docs',
        },
        {
          to: '/docs/cli-reference',
          label: 'CLI',
          position: 'left',
        },
        {
          href: 'https://www.npmjs.com/package/loren-framework',
          label: 'npm',
          position: 'right',
        },
        {
          href: 'https://github.com/fabideveloper/Loren-Framework',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      links: [
        {
          title: 'Docs',
          items: [
            {label: 'Introduction', to: '/docs/intro'},
            {label: 'Getting Started', to: '/docs/getting-started'},
            {label: 'CLI Reference', to: '/docs/cli-reference'},
          ],
        },
        {
          title: 'Core Concepts',
          items: [
            {label: 'Dependency Injection', to: '/docs/core-concepts/dependency-injection'},
            {label: 'Services', to: '/docs/core-concepts/services'},
            {label: 'Controllers', to: '/docs/core-concepts/controllers'},
          ],
        },
        {
          title: 'More',
          items: [
            {label: 'GitHub', href: 'https://github.com/fabideveloper/Loren-Framework'},
            {label: 'npm', href: 'https://www.npmjs.com/package/loren-framework'},
          ],
        },
      ],
      copyright: `© ${new Date().getFullYear()} Loren Framework. Burning like a beating heart.`,
    },
    prism: {
      theme: prismThemes.oneLight,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['lua', 'bash', 'toml', 'json'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
