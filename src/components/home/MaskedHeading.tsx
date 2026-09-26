import {Fragment, type ReactNode} from 'react';
import clsx from 'clsx';
import Reveal from './Reveal';
import styles from './home.module.css';

const DELAY = ['', 'lr-delay-1', 'lr-delay-2', styles.delay3];

export default function MaskedHeading({
  lines,
  as: Tag = 'h2',
  className = 'lr-display-2',
  id,
  immediate = false,
}: {
  lines: readonly ReactNode[];
  as?: 'h1' | 'h2' | 'h3';
  className?: string;
  id?: string;
  immediate?: boolean;
}): ReactNode {
  const heading = (
    <Tag id={id} className={clsx(styles.heading, className)}>
      {/* The space between lines keeps the accessible name readable ("…game. Loren…"); it doesn't render between blocks. */}
      {lines.map((line, i) => (
        <Fragment key={i}>
          {i > 0 && ' '}
          <span className="lr-mask-line">
            <span className={clsx('lr-mask-inner', DELAY[Math.min(i, DELAY.length - 1)])}>{line}</span>
          </span>
        </Fragment>
      ))}
    </Tag>
  );

  if (immediate) {
    return (
      <div data-revealed="true" className="lr-reveal-now">
        {heading}
      </div>
    );
  }

  return <Reveal>{heading}</Reveal>;
}
