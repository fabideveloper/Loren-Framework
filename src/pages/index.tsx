import type {ReactNode} from 'react';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import useBaseUrl from '@docusaurus/useBaseUrl';
import Layout from '@theme/Layout';
import CodeBlock from '@theme/CodeBlock';
import Heading from '@theme/Heading';
import HomepageFeatures from '@site/src/components/HomepageFeatures';
import styles from './index.module.css';

const SAMPLE = `local Service = {
    Dependencies = {"DatabaseService"};
    Signals = {"PointsUpdated"};
    Client = {};
}

function Service:LorenIgnite()
    self.points = {}
end

function Service.Client:Award(player, amount)
    self.Server.points[player] = amount
    self.Server.Signals.PointsUpdated:Fire(player, amount)
    return true
end`;

function Hero() {
  const {siteConfig} = useDocusaurusContext();
  const logo = useBaseUrl('/img/logo.png');
  return (
    <header className={styles.hero}>
      <div className={styles.heroInner}>
        <img src={logo} alt="Loren" className={styles.heroLogo} />
        <Heading as="h1" className={styles.heroTitle}>
          {siteConfig.title}
        </Heading>
        <p className={styles.heroTagline}>“{siteConfig.tagline}”</p>
        <p className={styles.heroSubtitle}>
          A CLI-driven, lightweight Roblox framework that eliminates pathing
          headaches, automates your toolchain, and gives game logic a clean,
          predictable lifecycle.
        </p>
        <div className={styles.buttons}>
          <Link className="button button--primary button--lg" to="/docs/getting-started">
            Get Started
          </Link>
          <Link
            className="button button--secondary button--lg"
            to="/docs/intro">
            Read the Docs
          </Link>
        </div>

        <div className={styles.codeShowcase}>
          <CodeBlock language="lua" title="PointsService.luau">
            {SAMPLE}
          </CodeBlock>
        </div>
      </div>
    </header>
  );
}

export default function Home(): ReactNode {
  const {siteConfig} = useDocusaurusContext();
  return (
    <Layout
      title={`${siteConfig.title} — Roblox Framework`}
      description="A CLI-driven, lightweight Roblox framework. Burning like a beating heart.">
      <Hero />
      <main>
        <Heading as="h2" className={styles.sectionTitle}>
          Built to keep the heart burning
        </Heading>
        <p className={styles.sectionSub}>
          Focus on feature logic. Loren handles the network and toolchain layers.
        </p>
        <HomepageFeatures />
      </main>
    </Layout>
  );
}
