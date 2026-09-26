import type {ReactNode} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import SectionShell from './SectionShell';
import MaskedHeading from './MaskedHeading';
import Reveal from './Reveal';
import styles from './home.module.css';

type Side = {value: string; note: string; srValue?: string};
type Row = {what: string; old: Side; now: Side};

// FACTS: docs/networking/security.md, "The attack test".
const ROWS: Row[] = [
  {
    what: 'Junk reaching your handlers',
    old: {value: '43', note: 'handler crashes from crafted packets'},
    now: {value: '0', note: 'of 48,190 accepted'},
  },
  {
    what: 'Server warnings',
    old: {value: '47,364', note: 'about 142k a minute'},
    now: {value: '0', note: 'warnings'},
  },
  {
    what: 'Server frame time',
    old: {value: 'About 3x', note: 'slower'},
    now: {value: '6.1 ms', note: 'p99, unchanged'},
  },
  {
    what: 'Route ids',
    old: {value: 'Stolen', note: 'through the handshake RemoteFunction'},
    now: {value: 'Closed', note: 'no RemoteFunction to ask'},
  },
  {
    what: "Honest players' calls",
    old: {value: '83%', note: 'OK; the test ran above its 50 calls/s cap'},
    now: {value: '1,206', note: 'of 1,206 OK'},
  },
];

function Value({side}: {side: Side}): ReactNode {
  return (
    <>
      <span className={styles.scoreValue} aria-hidden={side.srValue ? true : undefined}>
        {side.value}
      </span>
      {side.srValue && <span className={styles.srOnly}>{side.srValue}</span>}{' '}
      <span className={styles.scoreNote}>{side.note}</span>
    </>
  );
}

export default function Scoreboard(): ReactNode {
  return (
    <SectionShell id="security" tab="Under attack" labelledBy="security-title" className={styles.scoreSection}>
      <div className={styles.scoreHead}>
        <MaskedHeading id="security-title" lines={['We threw junk at it.', 'It kept going.']} />
        <p className={clsx('lr-body', styles.scoreIntro)}>
          We pointed an exploiter bot at a Studio test server. It fired 48,190 garbage packets, about 2,400 a
          second, while honest players kept playing. Then we ran the same attack against 1.5.1.
        </p>
      </div>

      <Reveal className={styles.boardWrap}>
        <table className={styles.board} role="table">
          <caption className={styles.srOnly}>The same attack against Loren 1.5.1 and 2.0</caption>
          <thead role="rowgroup">
            <tr role="row" className={styles.boardTop}>
              <th role="columnheader" scope="col" className={styles.boardOld}>
                <span className={styles.boardVersion}>1.5.1</span>
              </th>
              <th role="columnheader" scope="col" className={styles.boardMid}>
                <span className={styles.srOnly}>What we checked</span>
                <span className={styles.boardVs} aria-hidden="true">
                  vs
                </span>
              </th>
              <th role="columnheader" scope="col" className={clsx('lr-on-pink', styles.boardNew)}>
                <span className={styles.boardVersion}>2.0</span>
              </th>
            </tr>
          </thead>
          <tbody role="rowgroup">
            {ROWS.map((r) => (
              <tr role="row" key={r.what} className={styles.boardRow}>
                <td role="cell" className={styles.boardOld}>
                  <Value side={r.old} />
                </td>
                <th role="rowheader" scope="row" className={clsx('lr-label-dim', styles.boardMid)}>
                  {r.what}
                </th>
                <td role="cell" className={clsx('lr-on-pink', styles.boardNew)}>
                  <Value side={r.now} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Reveal>

      <div className={clsx('lr-grid', styles.caveat)}>
        <h3 className={clsx('lr-head lg-span-5', styles.caveatHead)}>
          It won&rsquo;t check your game logic for you.
        </h3>
        <div className="lg-start-7 lg-span-6">
          <p className={clsx('lr-body', styles.caveatText)}>
            Loren stops junk. It can&rsquo;t stop an exploiter from calling BuyItem with arguments a normal
            player could send. Check prices, cooldowns and ownership on the server.
          </p>
          <Link to="/docs/networking/security" className={clsx('lr-link-under', styles.caveatLink)}>
            Read the security page →
          </Link>
        </div>
      </div>
    </SectionShell>
  );
}
