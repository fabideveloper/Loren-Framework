import type {ReactNode} from 'react';
import clsx from 'clsx';
import useBaseUrl from '@docusaurus/useBaseUrl';
import SectionShell from './SectionShell';
import MaskedHeading from './MaskedHeading';
import ArrowHand from './ArrowHand';
import Reveal from './Reveal';
import styles from './home.module.css';

const DESCRIPTION =
  'Services run on the server and Controllers on the client. HudController calls PointsService and gets a ' +
  'Promise back. PointsService fires the PointsChanged signal down to HudController. EmoteController fires the ' +
  "Emote client event up to EmoteService. Every packet passes Loren's check in the middle, where junk from an " +
  'exploiter is dropped.';

// Arrowheads are drawn as triangles (no <marker> ids to clash between the two drawings).
function Wide({heart}: {heart: string}): ReactNode {
  return (
    <svg
      className={clsx(styles.wires, styles.wiresWide)}
      viewBox="0 0 1200 500"
      role="img"
      aria-label={DESCRIPTION}
      focusable="false">
      {/* Sides */}
      <rect className={styles.wBox} x="0.75" y="20.75" width="298.5" height="378.5" />
      <rect className={styles.wBox} x="900.75" y="20.75" width="298.5" height="378.5" />
      <text className={clsx(styles.wLabel, styles.wPink)} x="24" y="56">
        Server · Services
      </text>
      <text className={clsx(styles.wLabel, styles.wBlue)} x="924" y="56">
        Client · Controllers
      </text>

      <rect className={styles.wChip} x="24.75" y="80.75" width="250.5" height="174.5" />
      <text className={styles.wName} x="44" y="116">
        PointsService
      </text>
      <text className={styles.wCode} x="44" y="159">
        Client.GetPoints
      </text>
      <text className={styles.wCode} x="44" y="229">
        Signals.PointsChanged
      </text>

      <rect className={styles.wChip} x="24.75" y="284.75" width="250.5" height="90.5" />
      <text className={styles.wName} x="44" y="318">
        EmoteService
      </text>
      <text className={styles.wCode} x="44" y="347">
        ClientEvents.Emote
      </text>

      <rect className={styles.wChip} x="924.75" y="80.75" width="250.5" height="174.5" />
      <text className={styles.wName} x="944" y="116">
        HudController
      </text>
      <text className={styles.wCode} x="944" y="159">
        Dependencies.PointsService
      </text>
      <text className={styles.wCode} x="944" y="229">
        LorenBurn
      </text>

      <rect className={styles.wChip} x="924.75" y="284.75" width="250.5" height="90.5" />
      <text className={styles.wName} x="944" y="318">
        EmoteController
      </text>
      <text className={styles.wCode} x="944" y="347">
        LorenBurn
      </text>

      <rect className={styles.wChipGhost} x="924.75" y="420.75" width="250.5" height="54.5" />
      <text className={clsx(styles.wName, styles.wDimFill)} x="944" y="454">
        Exploiter
      </text>

      {/* Wires */}
      <line className={clsx(styles.wWire, styles.wBlueStroke)} x1="290" y1="155" x2="924" y2="155" />
      <polygon className={styles.wBlueFill} points="276,155 292,147 292,163" />
      <line className={clsx(styles.wWire, styles.wPinkStroke)} x1="276" y1="225" x2="910" y2="225" />
      <polygon className={styles.wPinkFill} points="924,225 908,217 908,233" />
      <line
        className={clsx(styles.wWire, styles.wBlueStroke, styles.wDashed)}
        x1="290"
        y1="343"
        x2="924"
        y2="343"
      />
      <polygon className={styles.wBlueFill} points="276,343 292,335 292,351" />
      <line className={clsx(styles.wWire, styles.wJunk)} x1="614" y1="448" x2="924" y2="448" />

      {/* Wire labels: the code sits on the side that writes it */}
      <text className={clsx(styles.wLabel, styles.wBlue)} x="312" y="140">
        Call
      </text>
      <text className={styles.wNote} x="312" y="179">
        returns a Promise
      </text>
      <text className={styles.wCodeBright} x="888" y="140" textAnchor="end">
        Points:GetPoints()
      </text>
      <text className={styles.wCodeBright} x="312" y="210">
        PointsChanged:Fire(player, total)
      </text>
      <text className={clsx(styles.wLabel, styles.wPink)} x="888" y="210" textAnchor="end">
        Signal
      </text>
      <text className={clsx(styles.wLabel, styles.wBlue)} x="312" y="328">
        Client event
      </text>
      <text className={styles.wCodeBright} x="888" y="328" textAnchor="end">
        Emote:Fire(&quot;Wave&quot;)
      </text>
      <text className={clsx(styles.wLabel, styles.wDim)} x="888" y="433" textAnchor="end">
        Junk
      </text>
      <text className={styles.wNotePink} x="580" y="453" textAnchor="end">
        dropped before your code runs
      </text>

      {/* Moving packets (hidden with reduced motion) */}
      <rect className={clsx(styles.dot, styles.dotCall, styles.wBlueFill)} x="905" y="150" width="10" height="10" />
      <rect className={clsx(styles.dot, styles.dotSignal, styles.wPinkFill)} x="285" y="220" width="10" height="10" />
      <rect className={clsx(styles.dot, styles.dotEvent, styles.wBlueFill)} x="905" y="338" width="10" height="10" />
      <rect className={clsx(styles.dot, styles.dotJunk, styles.wDimFillSolid)} x="905" y="443" width="10" height="10" />

      {/* The gate: Loren in the middle */}
      <line className={styles.wGate} x1="600" y1="98" x2="600" y2="486" />
      <rect className={styles.wCheck} x="593" y="148" width="14" height="14" />
      <rect className={styles.wCheck} x="593" y="218" width="14" height="14" />
      <rect className={styles.wCheck} x="593" y="336" width="14" height="14" />
      <path className={styles.wCross} d="M590 438L610 458M610 438L590 458" />
      <image href={heart} x="562" y="14" width="76" height="76" />
      <text className={clsx(styles.wLabel, styles.wPink)} x="646" y="46">
        Loren
      </text>
      <text className={styles.wNote} x="646" y="68">
        checks every packet
      </text>
    </svg>
  );
}

function Tall({heart}: {heart: string}): ReactNode {
  return (
    <svg
      className={clsx(styles.wires, styles.wiresTall)}
      viewBox="0 0 360 700"
      role="img"
      aria-label={DESCRIPTION}
      focusable="false">
      <rect className={styles.wBox} x="0.75" y="0.75" width="358.5" height="208.5" />
      <text className={clsx(styles.wLabel, styles.wPink)} x="16" y="30">
        Server · Services
      </text>
      <rect className={styles.wChip} x="16.75" y="46.75" width="326.5" height="80.5" />
      <text className={styles.wName} x="32" y="77">
        PointsService
      </text>
      <text className={clsx(styles.wCode, styles.wSmall)} x="32" y="106">
        Client.GetPoints · Signals.PointsChanged
      </text>
      <rect className={styles.wChip} x="16.75" y="140.75" width="326.5" height="52.5" />
      <text className={styles.wName} x="32" y="173">
        EmoteService
      </text>
      <text className={clsx(styles.wCode, styles.wSmall)} x="328" y="172" textAnchor="end">
        ClientEvents.Emote
      </text>

      <rect className={styles.wBox} x="0.75" y="490.75" width="358.5" height="208.5" />
      <text className={clsx(styles.wLabel, styles.wBlue)} x="16" y="520">
        Client · Controllers
      </text>
      <rect className={styles.wChip} x="16.75" y="536.75" width="326.5" height="80.5" />
      <text className={styles.wName} x="32" y="567">
        HudController
      </text>
      <text className={clsx(styles.wCode, styles.wSmall)} x="32" y="596">
        Dependencies.PointsService · LorenBurn
      </text>
      <rect className={styles.wChip} x="16.75" y="630.75" width="326.5" height="52.5" />
      <text className={styles.wName} x="32" y="663">
        EmoteController
      </text>
      <text className={clsx(styles.wCode, styles.wSmall)} x="328" y="662" textAnchor="end">
        Emote:Fire(&quot;Wave&quot;)
      </text>

      <line className={clsx(styles.wWire, styles.wBlueStroke)} x1="64" y1="224" x2="64" y2="491" />
      <polygon className={styles.wBlueFill} points="64,210 56,226 72,226" />
      <line className={clsx(styles.wWire, styles.wPinkStroke)} x1="144" y1="209" x2="144" y2="476" />
      <polygon className={styles.wPinkFill} points="144,490 136,474 152,474" />
      <line
        className={clsx(styles.wWire, styles.wBlueStroke, styles.wDashed)}
        x1="224"
        y1="224"
        x2="224"
        y2="491"
      />
      <polygon className={styles.wBlueFill} points="224,210 216,226 232,226" />
      <line className={clsx(styles.wWire, styles.wJunk)} x1="304" y1="384" x2="304" y2="491" />

      <text className={clsx(styles.wLabel, styles.wBlue)} x="74" y="270">
        Call
      </text>
      <text className={clsx(styles.wLabel, styles.wPink)} x="154" y="270">
        Signal
      </text>
      <text className={clsx(styles.wLabel, styles.wBlue)} x="234" y="270">
        Event
      </text>
      {/* Two short lines, so the note stays between the call and signal wires. */}
      <text className={clsx(styles.wNote, styles.wSmallNote)} x="74" y="293">
        Promise
        <tspan x="74" dy="16">
          back
        </tspan>
      </text>
      <text className={clsx(styles.wLabel, styles.wDim)} x="312" y="446">
        Junk
      </text>
      <text className={clsx(styles.wNotePink, styles.wSmallNote)} x="294" y="416" textAnchor="end">
        dropped
      </text>

      <rect className={clsx(styles.dot, styles.dotUp, styles.wBlueFill)} x="59" y="478" width="10" height="10" />
      <rect className={clsx(styles.dot, styles.dotDown, styles.wPinkFill)} x="139" y="212" width="10" height="10" />
      <rect className={clsx(styles.dot, styles.dotUpLate, styles.wBlueFill)} x="219" y="478" width="10" height="10" />
      <rect className={clsx(styles.dot, styles.dotJunkUp, styles.wDimFillSolid)} x="299" y="478" width="10" height="10" />

      <rect className={styles.wGateBox} x="1" y="326" width="358" height="46" />
      <image href={heart} x="10" y="330" width="38" height="38" />
      <text className={clsx(styles.wLabel, styles.wPink)} x="54" y="354">
        Loren checks every packet
      </text>
      <path className={styles.wCross} d="M296 380L312 396M312 380L296 396" />
    </svg>
  );
}

const CAPTIONS: {key: 'call' | 'signal' | 'gate'; title: string; text: ReactNode}[] = [
  {
    key: 'call',
    title: 'Calls go up.',
    text: (
      <>
        A Controller calls a Service and gets a Promise back. Every call has a timeout, 10 seconds unless you
        change it, so nothing hangs forever.
      </>
    ),
  },
  {
    key: 'signal',
    title: 'Signals come down.',
    text: (
      <>
        A Service fires a signal for one player, a list, everyone, or everyone but one. Client events go the
        other way.
      </>
    ),
  },
  {
    key: 'gate',
    title: 'Junk stops in the middle.',
    text: (
      <>
        Every packet is checked before your code runs, and junk is dropped without a log line for each one.
        One batch per frame, so a 64-byte call costs about 76 bytes.
      </>
    ),
  },
];

export default function WiringDiagram(): ReactNode {
  const heart = useBaseUrl('/img/home-heart-small.png');

  return (
    <SectionShell id="how-it-wires" tab="How it wires" labelledBy="wires-title" tone="raised">
      <div className={clsx('lr-grid', styles.wiresHead)}>
        <div className="lg-span-7">
          <MaskedHeading
            id="wires-title"
            lines={[
              'Services on the server.',
              <span key="b" className={styles.blueText}>
                Controllers on the client.
              </span>,
            ]}
          />
          <p className={clsx('lr-body', styles.wiresDeck)}>
            Each module lists what it needs by name. Loren loads everything, sorts it and starts it in order,
            then carries calls and signals between the two sides. You never write a require path to another
            module, and you never create a RemoteEvent.
          </p>
        </div>

        <aside className={clsx('lg-start-9 lg-span-4', styles.quote)} aria-label="Why">
          <p className={clsx('lr-tilt-a', styles.quoteText)}>
            &ldquo;Frameworks should be boring. Your game shouldn&rsquo;t be.&rdquo;
          </p>
          <ArrowHand className={styles.quoteArrow} />
        </aside>
      </div>

      <figure className={styles.figure}>
        <Reveal className={styles.figureArt}>
          <Wide heart={heart} />
          <Tall heart={heart} />
        </Reveal>

        <figcaption className={clsx('lr-grid', styles.captions)}>
          {CAPTIONS.map((c) => (
            <div key={c.key} className={clsx('lg-span-4', styles.caption)}>
              <span className={clsx(styles.captionKey, styles[`key_${c.key}`])} aria-hidden="true" />
              <h3 className={clsx('lr-head', styles.captionTitle)}>{c.title}</h3>
              <p className={styles.captionText}>{c.text}</p>
            </div>
          ))}
        </figcaption>
      </figure>
    </SectionShell>
  );
}
