import type {ReactNode} from 'react';
import clsx from 'clsx';
import styles from './home.module.css';

export default function PulseLine({className}: {className?: string}): ReactNode {
  return (
    <div className={clsx(styles.pulse, className)} aria-hidden="true">
      <span className={styles.pulseLead} />
      <svg className={styles.pulseBeat} viewBox="0 0 140 64" width="140" height="64" focusable="false">
        <path d="M0 40H22L30 33L37 40H47L57 5L69 60L77 29L83 40H140" />
      </svg>
      <span className={styles.pulseTail} />
    </div>
  );
}
