import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';
import lorenPrism from './src/prism-loren';

// Only the faces the CSS uses. JetBrains Mono italic is for code comments (src/prism-loren.ts).
const FONTS =
  'https://fonts.googleapis.com/css2?family=Montserrat:wght@700;800;900' +
  '&family=Source+Serif+4:ital,opsz,wght@0,8..60,400;0,8..60,700;1,8..60,400' +
  '&family=Space+Mono:wght@400;700' +
  '&family=JetBrains+Mono:ital,wght@0,400;0,700;1,400&display=swap';

const GITHUB = 'https://github.com/fabideveloper/Loren-Framework';
const NPM = 'https://www.npmjs.com/package/loren-framework';

const config: Config = {
  title: 'Loren',
  tagline: 'Burning like a beating heart.',
  favicon: 'img/favicon.ico',

  url: 'https://fabideveloper.github.io',
  baseUrl: '/Loren-Framework/',

  organizationName: 'fabideveloper',
  projectName: 'Loren-Framework',

  onBrokenLinks: 'throw',
  onBrokenAnchors: 'throw',
  onDuplicateRoutes: 'throw',

  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'throw',
    },
  },

  headTags: [
    {tagName: 'link', attributes: {rel: 'preconnect', href: 'https://fonts.googleapis.com'}},
    {tagName: 'link', attributes: {rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: 'anonymous'}},
    {tagName: 'link', attributes: {rel: 'apple-touch-icon', href: '/Loren-Framework/img/apple-touch-icon.png'}},
    {
      tagName: 'link',
      attributes: {rel: 'icon', type: 'image/png', sizes: '192x192', href: '/Loren-Framework/img/favicon-192.png'},
    },
    // Reveal animations only hide content once we know JS is running.
    {tagName: 'script', attributes: {}, innerHTML: "document.documentElement.setAttribute('data-js','')"},
  ],

  stylesheets: [{href: FONTS, type: 'text/css'}],

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
          editUrl: 'https://github.com/fabideveloper/Loren-Framework/edit/main/',
          breadcrumbs: true,
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: 'img/og-image.png',
    metadata: [{name: 'theme-color', content: '#1c1c1c'}],
    colorMode: {
      defaultMode: 'dark',
      disableSwitch: true,
      respectPrefersColorScheme: false,
    },
    announcementBar: {
      id: 'beta-2-0',
      isCloseable: true,
      backgroundColor: '#f293b8',
      textColor: '#1c1c1c',
      // Hidden on the homepage (the hero has the command); phones drop the install part (src/css/custom.css).
      content:
        '<span class="lr-ab-tag">2.0 beta</span> ' +
        '<span class="lr-ab-long">Install with <code>npm i -g loren-framework@next</code> · </span>' +
        '<a class="lr-ab-link" href="/Loren-Framework/docs/getting-started/upgrading">Upgrading from 1.5.1 →</a>',
    },
    tableOfContents: {
      minHeadingLevel: 2,
      maxHeadingLevel: 3,
    },
    navbar: {
      title: 'Loren',
      logo: {
        alt: '',
        src: 'img/logo-mark-small.png',
        width: 40,
        height: 40,
      },
      items: [
        {type: 'html', position: 'left', value: '<span class="lr-badge">2.0 beta</span>'},
        // Active on every doc page except the three that have their own nav link.
        {
          to: '/docs/intro',
          label: 'Docs',
          position: 'right',
          activeBaseRegex: '^/Loren-Framework/docs/(?!networking/security|cli-reference|getting-started/upgrading)',
        },
        {to: '/docs/networking/security', label: 'Security', position: 'right'},
        {to: '/docs/cli-reference', label: 'CLI', position: 'right'},
        {to: '/docs/getting-started/upgrading', label: 'Upgrade', position: 'right'},
        {href: GITHUB, label: 'GitHub ↗', position: 'right'},
        {href: NPM, label: 'npm ↗', position: 'right'},
        {to: '/docs/getting-started', label: 'Get the beta →', position: 'right', className: 'lr-nav-cta'},
      ],
    },
    // Rendered by src/theme/Footer (the colophon); only `links` is read.
    footer: {
      links: [
        {
          title: 'Docs',
          items: [
            {label: 'Introduction', to: '/docs/intro'},
            {label: 'Getting started', to: '/docs/getting-started'},
            {label: 'Upgrading from 1.5.1', to: '/docs/getting-started/upgrading'},
            {label: 'CLI', to: '/docs/cli-reference'},
          ],
        },
        {
          title: 'Elsewhere',
          items: [
            {label: 'GitHub ↗', href: GITHUB},
            {label: 'npm ↗', href: NPM},
            {label: 'Report an issue ↗', href: `${GITHUB}/issues`},
          ],
        },
      ],
    },
    prism: {
      theme: lorenPrism,
      darkTheme: lorenPrism,
      additionalLanguages: ['lua', 'bash', 'json', 'toml'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
