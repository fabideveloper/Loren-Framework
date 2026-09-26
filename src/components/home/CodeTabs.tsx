import {useRef, useState, type CSSProperties, type KeyboardEvent, type ReactNode} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import CodeBlock from '@theme/CodeBlock';
import SectionShell from './SectionShell';
import MaskedHeading from './MaskedHeading';
import styles from './home.module.css';

const SERVICE = `local PointsService = {
	Client = {},
	Signals = { "PointsChanged" },
}

local points: { [Player]: number } = {}

function PointsService:AddPoints(player: Player, amount: number)
	points[player] = (points[player] or 0) + amount
	self.Signals.PointsChanged:Fire(player, points[player])
end

function PointsService.Client:GetPoints(player: Player): number
	return points[player] or 0
end

return PointsService`;

const CONTROLLER = `local HudController = {
	Dependencies = { "PointsService" },
}

function HudController:LorenBurn()
	local Points = self.Dependencies.PointsService

	Points.Signals.PointsChanged:Connect(function(total)
		print("Points:", total)
	end)

	local ok, total = Points.Try:GetPoints()
	if ok then
		print("Starting with", total)
	end
end

return HudController`;

type Note = {n: number; line: number; text: ReactNode};
type File = {
  id: 'service' | 'controller';
  side: string;
  name: string;
  path: string;
  code: string;
  notes: Note[];
};

const FILES: File[] = [
  {
    id: 'service',
    side: 'Server',
    name: 'PointsService.luau',
    path: 'src/server/Services/',
    code: SERVICE,
    notes: [
      {
        n: 1,
        line: 3,
        text: (
          <>
            <code>Signals = {'{ "PointsChanged" }'}</code> is all the setup. Fire it for one player, a list,
            everyone, or everyone but one.
          </>
        ),
      },
      {
        n: 2,
        line: 13,
        text: (
          <>
            Client methods get the calling player first. Loren fills it in from the connection, so a client
            can&rsquo;t pretend to be someone else.
          </>
        ),
      },
    ],
  },
  {
    id: 'controller',
    side: 'Client',
    name: 'HudController.luau',
    path: 'src/client/Controllers/',
    code: CONTROLLER,
    notes: [
      {
        n: 3,
        line: 2,
        text: (
          <>
            <code>Dependencies = {'{ "PointsService" }'}</code> gives the Controller a proxy. Its methods
            return Promises.
          </>
        ),
      },
      {
        n: 4,
        line: 5,
        text: (
          <>
            <code>LorenBurn</code> is the &ldquo;run&rdquo; hook. It runs once every module has started.
          </>
        ),
      },
      {
        n: 5,
        line: 12,
        text: (
          <>
            <code>Try</code> waits for the answer and gives you <code>ok</code> plus the values. On failure you
            get a message and an info table instead.
          </>
        ),
      },
    ],
  },
];

const pad = (n: number) => String(n).padStart(2, '0');

export default function CodeTabs(): ReactNode {
  const [active, setActive] = useState(0);
  const tabs = useRef<(HTMLButtonElement | null)[]>([]);

  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    const keys: Record<string, number> = {ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1};
    let next: number | undefined;
    if (e.key in keys) next = (active + keys[e.key] + FILES.length) % FILES.length;
    if (e.key === 'Home') next = 0;
    if (e.key === 'End') next = FILES.length - 1;
    if (next === undefined) return;
    e.preventDefault();
    setActive(next);
    tabs.current[next]?.focus();
  };

  return (
    <SectionShell id="example" tab="A whole service" labelledBy="example-title">
      <div className={clsx('lr-grid', styles.codeLayout)}>
        <div className={clsx('lg-span-4', styles.codeSide)}>
          <MaskedHeading id="example-title" lines={['Here’s a Service,', 'start to finish.']} />
          <p className={clsx('lr-mono', styles.codeSideNote)}>
            Two files. No RemoteEvents, no require paths. It&rsquo;s a trimmed version of the PointsService
            premade (<code>loren inject service PointsService</code>).
          </p>

          <div role="tablist" aria-label="Files" aria-orientation="vertical" className={styles.fileTabs} onKeyDown={onKey}>
            {FILES.map((f, i) => (
              <button
                key={f.id}
                ref={(el) => {
                  tabs.current[i] = el;
                }}
                type="button"
                role="tab"
                id={`file-tab-${f.id}`}
                aria-selected={active === i}
                aria-controls={`file-panel-${f.id}`}
                tabIndex={active === i ? 0 : -1}
                className={clsx(styles.fileTab, active === i && styles.fileTabOn)}
                onClick={() => setActive(i)}>
                <span className={styles.fileTabSide}>{f.side}</span>
                <span className={styles.fileTabName}>
                  {f.name.replace('.luau', '')}
                  <wbr />
                  .luau
                </span>
                <span className={styles.fileTabNotes}>
                  {f.notes.map((note) => pad(note.n)).join(' ')}
                </span>
              </button>
            ))}
          </div>

          <Link to="/docs/getting-started/first-service" className={clsx('lr-link-under', styles.codeMore)}>
            Build your first service
          </Link>
        </div>

        <div className={clsx('lg-start-5 lg-span-8', styles.codeMain)}>
          {FILES.map((f, i) => (
            <div
              key={f.id}
              role="tabpanel"
              id={`file-panel-${f.id}`}
              aria-labelledby={`file-tab-${f.id}`}
              hidden={active !== i}
              className={styles.filePanel}>
              <p className={styles.filePath}>
                <span className={styles.filePathDir}>{f.path}</span>
                {f.name}
              </p>

              <div className={styles.codeFrame}>
                <ol className={styles.gutter} aria-hidden="true">
                  {f.notes.map((note) => (
                    <li key={note.n} className={styles.gutterMark} style={{'--line': note.line} as CSSProperties}>
                      {pad(note.n)}
                    </li>
                  ))}
                </ol>
                <div className={styles.codeCell}>
                  <CodeBlock language="lua" metastring={`{${f.notes.map((n) => n.line).join(',')}}`}>
                    {f.code}
                  </CodeBlock>
                </div>
              </div>

              <ol className={styles.callouts} start={f.notes[0].n}>
                {f.notes.map((note) => (
                  <li key={note.n} className={styles.callout}>
                    <span className={clsx('lr-marker', styles.calloutNum)}>{pad(note.n)}</span>
                    <p className={styles.calloutText}>
                      <span className={styles.srOnly}>Line {note.line}: </span>
                      {note.text}
                    </p>
                  </li>
                ))}
              </ol>
            </div>
          ))}
        </div>
      </div>
    </SectionShell>
  );
}
