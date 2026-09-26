import type {CSSProperties, ReactNode} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import SectionShell from './SectionShell';
import MaskedHeading from './MaskedHeading';
import CopyCommand from './CopyCommand';
import Reveal from './Reveal';
import styles from './home.module.css';

type Step = {title: string; command?: string; body: ReactNode; output?: string[]};

const STEPS: Step[] = [
  {
    title: 'Install the beta',
    command: 'npm i -g loren-framework@next',
    body: (
      <>
        You need Node 18 or newer. The beta is on the <code>next</code> tag until 2.0 is stable. Plain{' '}
        <code>npm i -g loren-framework</code> still installs 1.5.1.
      </>
    ),
  },
  {
    title: 'Make a project',
    command: 'loren init my-game',
    body: (
      <>
        Pick Rojo, Argon or None. None uses Studio&rsquo;s built-in Script Sync, so there&rsquo;s nothing else
        to install. You get the runtime, a bootstrap script, and an example Service and Controller.
      </>
    ),
  },
  {
    title: 'Connect Studio',
    command: 'loren serve',
    body: <>Then connect the Rojo or Argon plugin. With Script Sync you sync four folders once instead.</>,
  },
  {
    title: 'Press Play',
    // docs/getting-started/new-project.md, a fresh project's first Play.
    output: [
      '(LORENঌ) Burning on Server: 1 service, 0 routes, 4 ms',
      '(LORENঌ) Burning on Client: 1 controller, 0 services, 180 ms',
    ],
    body: (
      <>
        Loren prints one &ldquo;Burning on Server&rdquo; line when it&rsquo;s up (burning is Loren&rsquo;s word
        for running). If something&rsquo;s wrong, you get one report that lists every problem, with a
        suggestion when it spots a typo.
      </>
    ),
  },
];

const pad = (n: number) => String(n).padStart(2, '0');

export default function StartTerminal(): ReactNode {
  return (
    <SectionShell id="get-started" tab="Get started" labelledBy="start-title" tone="raised" className={styles.start}>
      <div className={clsx('lr-grid', styles.startGrid)}>
        <div className={clsx('lg-span-4', styles.startSide)}>
          <MaskedHeading
            id="start-title"
            lines={[
              'Four steps.',
              <span key="b" className={styles.pinkText}>
                The last one is Play.
              </span>,
            ]}
          />
          <p className={clsx('lr-body', styles.startText)}>
            It&rsquo;s a beta. Try it on a side project, something you can afford to break, and tell us what
            broke. Paste the boot report when you open an issue.
          </p>
          <div className={styles.startActions}>
            <Link to="/docs/getting-started" className="lr-btn lr-btn--pink lr-press">
              Get started →
            </Link>
            <Link href="https://github.com/fabideveloper/Loren-Framework/issues" className="lr-link-under">
              Open an issue <span aria-hidden="true">↗</span>
              <span className={styles.srOnly}> (opens in a new tab)</span>
            </Link>
          </div>
          <p className={clsx('lr-mono', styles.dimNote, styles.startNote)}>
            Coming from 1.5.1? Run <code>loren update</code> in your project.{' '}
            <Link to="/docs/getting-started/upgrading" className={styles.inlineLink}>
              Upgrade guide →
            </Link>
          </p>
        </div>

        <Reveal className={clsx('lg-start-5 lg-span-8', styles.term)}>
          <div className={styles.termBar}>
            <span className={styles.paneDots} aria-hidden="true">
              <i />
              <i />
              <i />
            </span>
            <span className="lr-label-dim">~/my-game</span>
          </div>

          <ol className={styles.termSteps}>
            {STEPS.map((step, i) => (
              <li key={step.title} className={styles.termStep} style={{'--i': i} as CSSProperties}>
                <span className={styles.termNum} aria-hidden="true">
                  {pad(i + 1)}
                </span>
                <div className={styles.termBody}>
                  <h3 className={clsx('lr-head', styles.termTitle)}>{step.title}</h3>
                  {step.command && <CopyCommand command={step.command} className={styles.termCopy} />}
                  {step.output && (
                    <div className={styles.termOutput}>
                      <p className={clsx('lr-label-dim', styles.termOutputLabel)}>Studio Output</p>
                      {step.output.map((line) => (
                        <p key={line} className={styles.termOutputLine}>
                          {line}
                        </p>
                      ))}
                    </div>
                  )}
                  <p className={styles.termText}>{step.body}</p>
                </div>
              </li>
            ))}
          </ol>
        </Reveal>
      </div>
    </SectionShell>
  );
}
