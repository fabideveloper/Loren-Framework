import type {ReactNode} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useBaseUrl from '@docusaurus/useBaseUrl';
import MaskedHeading from './MaskedHeading';
import CopyCommand from './CopyCommand';
import PulseLine from './PulseLine';
import styles from './home.module.css';

export default function Hero(): ReactNode {
  const heart = useBaseUrl('/img/home-heart.png');

  return (
    <section className={styles.hero} aria-labelledby="hero-title">
      <div className={clsx('lr-page-x lr-grid', styles.heroGrid)}>
        <div className={clsx('lg-span-5', styles.heroArt)}>
          <img
            src={heart}
            alt=""
            width={880}
            height={880}
            decoding="async"
            className={styles.heroHeart}
          />
        </div>

        <div className={clsx('lg-start-6 lg-span-7', styles.heroCopy)}>
          <p className={clsx('lr-label', styles.heroKicker)}>
            Luau framework for Roblox <span className="lr-marker">2.0 beta</span>
          </p>

          <MaskedHeading
            as="h1"
            id="hero-title"
            immediate
            className={clsx('lr-display-1', styles.heroTitle)}
            lines={[
              'Write',
              'the game.',
              <span key="c" className={styles.pinkText}>
                Loren wires
              </span>,
              <span key="d" className={styles.pinkText}>
                it up.
              </span>,
            ]}
          />

          <p className={clsx('lr-body', styles.heroDeck)}>
            Loren is a Luau framework for Roblox. You write Services for the server and Controllers for the
            client. Loren starts them in the right order, hands each one what it needs, and carries calls and
            signals between them.
          </p>

          <div className={styles.heroButtons}>
            <Link to="/docs/getting-started" className="lr-btn lr-btn--pink lr-press">
              Get the 2.0 beta →
            </Link>
            <Link to="/docs/intro" className="lr-link-under">
              Read the docs
            </Link>
          </div>

          <CopyCommand label="Beta · Node 18+" command="npm i -g loren-framework@next" className={styles.heroInstall} />

          <p className={clsx('lr-mono', styles.dimNote)}>
            On 1.5.1? Your code runs unchanged.{' '}
            <Link to="/docs/getting-started/upgrading" className={styles.inlineLink}>
              Upgrade guide →
            </Link>
          </p>
        </div>
      </div>

      <PulseLine className={styles.heroPulse} />
    </section>
  );
}
