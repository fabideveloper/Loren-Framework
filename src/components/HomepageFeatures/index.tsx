import type {ReactNode} from 'react';
import clsx from 'clsx';
import Heading from '@theme/Heading';
import styles from './styles.module.css';

type FeatureItem = {
  title: string;
  description: ReactNode;
};

const FeatureList: FeatureItem[] = [
  {
    title: 'Dependency Injection',
    description: (
      <>
        Never write a manual <code>require()</code> path again. Declare what a
        module needs by name and Loren resolves and injects it during the boot
        sequence — no race conditions, no infinite yields.
      </>
    ),
  },
  {
    title: 'Optimized Networking',
    description: (
      <>
        A custom binary protocol drives cross-boundary calls through Promises
        and network-optimized Signals, with built-in middleware and global
        rate-limiting baked in.
      </>
    ),
  },
  {
    title: 'Zero-Friction CLI',
    description: (
      <>
        <code>loren init</code> scaffolds Rojo/Argon, VS Code settings, and your
        sourcemap instantly. Forge services, inject templates, and ignite your
        sync server from one terminal.
      </>
    ),
  },
];

function Feature({title, description}: FeatureItem) {
  return (
    <div className={clsx('col col--4')}>
      <div className={styles.card}>
        <Heading as="h3" className={styles.cardTitle}>
          {title}
        </Heading>
        <p className={styles.cardText}>{description}</p>
      </div>
    </div>
  );
}

export default function HomepageFeatures(): ReactNode {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}
