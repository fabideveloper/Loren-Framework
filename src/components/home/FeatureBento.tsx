import type {CSSProperties, ReactNode} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import SectionShell from './SectionShell';
import MaskedHeading from './MaskedHeading';
import Reveal from './Reveal';
import styles from './home.module.css';

type Tile = {
  area: string;
  title: string;
  text: ReactNode;
  tag: 'Core' | 'Network' | 'Tools';
  to: string;
  tone?: 'pink' | 'blue';
  art?: ReactNode;
};

const TILES: Tile[] = [
  {
    area: 'sc',
    title: 'Services and Controllers',
    text: 'Server and client modules with the same shape. Point Loren at a folder and it starts them.',
    tag: 'Core',
    to: '/docs/core-concepts/services',
    art: (
      <pre className={styles.tree}>
        {'src/\n├─ server/Services/\n│  └─ '}
        <b>PointsService.luau</b>
        {'\n└─ client/Controllers/\n   └─ '}
        <b>HudController.luau</b>
        {'\n\n'}
        <i>
          Loren.AddServices(
          <wbr />
          script.Parent.Services)
        </i>
      </pre>
    ),
  },
  {
    area: 'deps',
    title: 'Dependencies by name',
    text: 'List what a module needs. Loren works out the start order and catches typos, with a suggestion.',
    tag: 'Core',
    to: '/docs/core-concepts/dependency-injection',
    art: (
      <p className={styles.typo}>
        &lsquo;<u>DataServce</u>&rsquo; is not a registered Service. Did you mean &lsquo;
        <b>DataService</b>&rsquo;?
      </p>
    ),
  },
  {
    area: 'calls',
    title: 'Calls that return Promises',
    text: (
      <>
        Every call has a timeout and fails with an error code instead of hanging. Rather skip the Promise?{' '}
        <code>Try</code> gives you <code>ok</code> plus the values.
      </>
    ),
    tag: 'Network',
    to: '/docs/networking/calls',
    tone: 'pink',
    art: (
      <p className={styles.bigStat}>
        10<span className={styles.bigStatUnit}>s</span>
        <span className={styles.bigStatLabel}>default timeout, per method</span>
      </p>
    ),
  },
  {
    area: 'sig',
    title: 'Signals and client events',
    text: 'Server to client and client to server. Reliable or unreliable, ordered if you want.',
    tag: 'Network',
    to: '/docs/networking/signals',
    art: (
      <p className={styles.directions}>
        <span>
          <b className={styles.pinkText}>↓</b> Signals
        </span>
        <span>
          <b className={styles.blueText}>↑</b> ClientEvents
        </span>
      </p>
    ),
  },
  {
    area: 'spec',
    title: 'Typed specs',
    text: 'Describe arguments and Loren checks them, then packs them smaller.',
    tag: 'Network',
    to: '/docs/networking/typed-specs',
    tone: 'blue',
    art: (
      <p className={styles.chips}>
        <code>T.u16</code> <code>T.string(32)</code> <code>T.Vector3</code>
      </p>
    ),
  },
  {
    area: 'mw',
    title: 'Middleware',
    text: 'Run a check before a handler. Return true to let the call through. Anything else blocks it.',
    tag: 'Network',
    to: '/docs/networking/middleware',
    art: (
      <p className={styles.gateRows}>
        <span>
          <code>return true</code> <b className={styles.pinkText}>→</b> through
        </span>
        <span>
          <code>false</code>, <code>nil</code>, anything else <b className={styles.pinkText}>→</b> blocked
        </span>
      </p>
    ),
  },
  {
    area: 'test',
    title: 'Tests without a server',
    text: 'Loren.Testing mounts a Service in a spec, fires its events and resets between tests.',
    tag: 'Tools',
    to: '/docs/core-concepts/testing',
    art: (
      <p className={styles.chips}>
        <code>Mount</code> <code>Fired</code> <code>Emit</code> <code>Reset</code>
      </p>
    ),
  },
  {
    area: 'cli',
    title: 'A CLI that sets it up',
    text: (
      <>
        <code>loren init</code> makes a project for Rojo, Argon or Studio&rsquo;s Script Sync.{' '}
        <code>loren update</code> upgrades it.
      </>
    ),
    tag: 'Tools',
    to: '/docs/cli-reference',
    art: (
      <p className={styles.prompt}>
        <span className={styles.promptSign}>$</span> loren init my-game
        <span className={styles.promptPick}>Rojo · Argon · None</span>
      </p>
    ),
  },
];

export default function FeatureBento(): ReactNode {
  return (
    <SectionShell id="features" tab="What you get" labelledBy="features-title" tone="raised">
      <ul className={styles.bento}>
        <li className={clsx(styles.bentoHead, styles.area_head)}>
          <MaskedHeading id="features-title" lines={['What’s in', 'the box.']} />
          <p className={clsx('lr-mono', styles.bentoHeadNote)}>
            Eight parts, each with its own page in the docs. Pick one.
          </p>
        </li>

        {TILES.map((t, i) => (
          <li
            key={t.area}
            style={{'--d': `${(i % 3) * 70}ms`} as CSSProperties}
            className={styles[`area_${t.area}`]}>
            <Reveal className={styles.tileReveal}>
              <Link
                to={t.to}
                className={clsx(
                  styles.tile,
                  t.tone === 'pink' && clsx('lr-on-pink', styles.tilePink),
                  t.tone === 'blue' && styles.tileBlue,
                )}>
                <span className={styles.tileTop}>
                  <span className={t.tone === 'pink' ? 'lr-label-ink' : 'lr-label-dim'}>{t.tag}</span>
                  <span className={styles.tileArrow} aria-hidden="true">
                    →
                  </span>
                </span>
                <h3 className={clsx('lr-head', styles.tileTitle)}>{t.title}</h3>
                <p className={styles.tileText}>{t.text}</p>
                {t.art && (
                  <div className={styles.tileArt} aria-hidden="true">
                    {t.art}
                  </div>
                )}
              </Link>
            </Reveal>
          </li>
        ))}
      </ul>
    </SectionShell>
  );
}
