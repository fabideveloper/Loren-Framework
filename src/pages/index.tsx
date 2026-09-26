import type {ReactNode} from 'react';
import Layout from '@theme/Layout';
import Hero from '@site/src/components/home/Hero';
import BootLog from '@site/src/components/home/BootLog';
import WiringDiagram from '@site/src/components/home/WiringDiagram';
import CodeTabs from '@site/src/components/home/CodeTabs';
import FeatureBento from '@site/src/components/home/FeatureBento';
import Scoreboard from '@site/src/components/home/Scoreboard';
import Tapes from '@site/src/components/home/Tapes';
import StartTerminal from '@site/src/components/home/StartTerminal';

export default function Home(): ReactNode {
  return (
    <Layout
      title="A Luau framework for Roblox"
      description="Loren is a Luau framework for Roblox: Services, Controllers, calls and signals, and a CLI for Rojo, Argon and Script Sync. 2.0 is in beta.">
      <main>
        <Hero />
        <BootLog />
        <WiringDiagram />
        <CodeTabs />
        <FeatureBento />
        <Scoreboard />
        <Tapes />
        <StartTerminal />
      </main>
    </Layout>
  );
}
