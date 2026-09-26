import type {ReactNode} from 'react';
import clsx from 'clsx';
import Reveal from './Reveal';
import styles from './home.module.css';

type Tone = 'ink' | 'raised';

export default function SectionShell({
  id,
  tab,
  labelledBy,
  tone = 'ink',
  className,
  children,
}: {
  id: string;
  tab: string;
  /** id of the section's own heading */
  labelledBy: string;
  tone?: Tone;
  className?: string;
  children: ReactNode;
}): ReactNode {
  return (
    <section
      id={id}
      aria-labelledby={labelledBy}
      className={clsx(styles.section, tone === 'raised' ? 'lr-tone-raised' : styles.toneInk, className)}>
      <Reveal className={styles.tabRow}>
        <div className="lr-rule-draw" />
        <div className="lr-page-x">
          <div className={styles.tabClip}>
            <p className={clsx('lr-label-ink', styles.tab)}>{tab}</p>
          </div>
        </div>
      </Reveal>

      <div className={clsx('lr-page-x', styles.band)}>{children}</div>
    </section>
  );
}
