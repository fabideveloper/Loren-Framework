import type {CSSProperties, ReactNode} from 'react';
import clsx from 'clsx';
import Reveal from './Reveal';
import ArrowHand from './ArrowHand';
import styles from './home.module.css';

// Every value here is in FACTS (docs/intro.md "What 2.0 changes", security.md, how-it-works.md).
const RESULTS: {key: string; value: string}[] = [
  {key: 'Junk packets accepted', value: '0 of 48,190'},
  {key: 'Honest calls OK', value: '1,206 of 1,206'},
  {key: 'Server frame p99 during the attack', value: '6.1 ms'},
  {key: 'Server warnings', value: '0'},
  {key: 'Studio tests', value: '1,212 passed, 0 failed'},
  {key: 'Signals lost or reordered under stress', value: '0'},
  {key: 'Bytes on the wire for a 64-byte call', value: 'about 76'},
  {key: 'CLI tests', value: '141 passing'},
];

export default function BootLog(): ReactNode {
  return (
    <section id="numbers" aria-labelledby="numbers-title" className={styles.proof}>
      <div className={clsx('lr-page-x lr-grid', styles.proofGrid)}>
        <div className={clsx('lg-span-5', styles.proofIntro)}>
          <p className={clsx('lr-label', styles.proofKicker)}>Measured, not estimated</p>
          <h2 id="numbers-title" className={clsx('lr-display-2', styles.heading, styles.proofTitle)}>
            Numbers from Studio.
          </h2>
          <p className={clsx('lr-body', styles.proofText)}>
            Everything in this log comes from Roblox Studio, September 2026. Only the CLI tests run on Node.
            The attack came from an exploiter bot at about 2,400 packets a second, while honest players kept
            playing.
          </p>
          <ArrowHand className={styles.proofArrow} />
        </div>

        <Reveal className={clsx('lg-start-6 lg-span-7', styles.pane)}>
          <div className={styles.paneBar}>
            <span className={styles.paneDots} aria-hidden="true">
              <i />
              <i />
              <i />
            </span>
            <span className="lr-label-ink">Output</span>
            <span className={clsx('lr-label-ink', styles.paneBarSide)}>Server · Sept 2026</span>
          </div>

          <div className={styles.paneBody}>
            <p className={clsx(styles.logLine, styles.logBoot)} style={{'--i': 0} as CSSProperties}>
              (LORENঌ) Burning on Server: 4 services, 9 routes, 6 ms
            </p>
            <p className={clsx(styles.logLine, styles.logComment)} style={{'--i': 1} as CSSProperties}>
              -- attack test: exploiter bot, about 2,400 junk packets a second
            </p>
            <dl className={styles.logList}>
              {RESULTS.map((r, i) => (
                <div key={r.key} className={styles.logLine} style={{'--i': i + 2} as CSSProperties}>
                  <dt className={styles.logKey}>{r.key}</dt>
                  <dd className={styles.logValue}>{r.value}</dd>
                </div>
              ))}
            </dl>
          </div>

          <div className={clsx('lr-on-pink', styles.paneStatus)}>
            <p className={styles.statusBig}>
              0<span className={styles.statusOf}>/48,190</span>
            </p>
            <p className={clsx('lr-label-ink', styles.statusLabel)}>
              junk packets reached your handlers
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
