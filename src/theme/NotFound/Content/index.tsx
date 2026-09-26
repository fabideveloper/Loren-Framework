import type {ReactNode} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import type {Props} from '@theme/NotFound/Content';

export default function NotFoundContent({className}: Props): ReactNode {
  return (
    <main className={clsx('lr-page-x lr-notfound', className)}>
      <p className="lr-label lr-notfound__label">
        <span className="lr-marker">404</span> Page not found
      </p>
      <h1 className="lr-display-2 lr-notfound__title">Nothing burning here.</h1>
      <p className="lr-body lr-notfound__text">This page moved or never existed.</p>
      <div className="lr-notfound__actions">
        <Link to="/docs/intro" className="lr-btn lr-btn--pink lr-press">
          Read the docs →
        </Link>
        <Link to="/" className="lr-link-under">
          Back home
        </Link>
      </div>
    </main>
  );
}
