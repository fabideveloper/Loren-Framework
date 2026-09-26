import type {CSSProperties, ReactNode} from 'react';
import clsx from 'clsx';
import styles from './home.module.css';

// Commands and file names are <code>, so they never split across lines.
const TOOLS: {name: string; text: ReactNode}[] = [
  {name: 'Rojo', text: <><code>loren serve</code> runs <code>rojo serve</code></>},
  {name: 'Argon', text: <>runs <code>argon serve --sourcemap</code></>},
  {name: 'Script Sync', text: "Studio's built-in sync, no extra tools"},
  {name: 'Rokit', text: 'installs Rojo or Argon. Aftman and Foreman work too'},
  {name: 'Luau-LSP', text: 'autocomplete from the sourcemap'},
  {name: 'Promise', text: "evaera's library comes bundled"},
];

const FACTS = [
  '1.5.1 code runs unchanged',
  'About 76 bytes for a 64-byte call',
  '0 lost or reordered signals under stress',
  '141 CLI tests passing',
  'npm i -g loren-framework@next',
];

function Heart(): ReactNode {
  return (
    <svg className={styles.tapeHeart} viewBox="0 0 16 14" aria-hidden="true" focusable="false">
      <path d="M8 13.2 1.6 7A3.9 3.9 0 0 1 8 2.3 3.9 3.9 0 0 1 14.4 7Z" />
    </svg>
  );
}

function ToolList({hidden}: {hidden?: boolean}): ReactNode {
  return (
    <ul className={styles.tapeGroup} aria-hidden={hidden || undefined}>
      <li className={clsx('lr-label-ink', styles.tapeLead)}>Works with</li>
      {TOOLS.map((t) => (
        <li key={t.name} className={styles.tapeItem}>
          <Heart />
          <span className={styles.tapeName}>{t.name}</span>
          <span className={styles.tapeText}>{t.text}</span>
        </li>
      ))}
    </ul>
  );
}

export default function Tapes(): ReactNode {
  return (
    <section aria-labelledby="works-with" className={styles.tapes}>
      <h2 id="works-with" className={styles.srOnly}>
        Works with
      </h2>

      <div className={clsx('lr-marquee lr-no-scrollbar', styles.tape, styles.tapePink)}>
        <div className="lr-marquee-rail" style={{'--lr-marquee-speed': '56s'} as CSSProperties}>
          <ToolList />
          <ToolList hidden />
        </div>
      </div>

      <div className={clsx('lr-marquee', styles.tape, styles.tapeBlue)} aria-hidden="true">
        <div
          className={clsx('lr-marquee-rail', styles.railReverse)}
          style={{'--lr-marquee-speed': '44s'} as CSSProperties}>
          {[0, 1].map((copy) => (
            <p key={copy} className={styles.tapeGroup}>
              {FACTS.map((f) => (
                <span key={f} className={clsx('lr-label-ink', styles.tapeFact)}>
                  {f}
                </span>
              ))}
            </p>
          ))}
        </div>
      </div>
    </section>
  );
}
