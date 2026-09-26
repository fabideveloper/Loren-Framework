import React, {type ReactNode} from 'react';
import Link from '@docusaurus/Link';
import useBaseUrl from '@docusaurus/useBaseUrl';
import {useThemeConfig} from '@docusaurus/theme-common';

type FooterItem = {label: string; to?: string; href?: string};
type FooterColumn = {title?: string | null; items: FooterItem[]};

function Footer(): ReactNode {
  const {footer} = useThemeConfig();
  const heart = useBaseUrl('/img/home-heart-small.png');
  if (!footer) {
    return null;
  }
  const columns = (footer.links ?? []).filter(
    (c): c is FooterColumn => typeof c === 'object' && c !== null && 'items' in c,
  );

  return (
    <footer className="theme-layout-footer lr-foot">
      <div className="lr-foot__pulse">
        <span className="lr-foot__line" aria-hidden="true" />
        <svg className="lr-foot__beat" viewBox="0 0 140 64" width="140" height="64" aria-hidden="true" focusable="false">
          <path d="M0 40H22L30 33L37 40H47L57 5L69 60L77 29L83 40H140" />
        </svg>
        <img src={heart} alt="" width={64} height={64} className="lr-foot__heart" />
        <span className="lr-foot__line lr-foot__line--flat" aria-hidden="true" />
        <span className="lr-foot__line" aria-hidden="true" />
      </div>

      <div className="lr-page-x lr-foot__inner">
        <p className="lr-foot__name">Loren</p>
        <p className="lr-foot__tagline">Burning like a beating heart.</p>

        <nav className="lr-foot__nav" aria-label="Footer">
          {columns.slice(0, 2).map((column, i) => (
            <div key={column.title ?? i} className="lr-foot__row">
              {column.title && <p className="lr-label-dim lr-foot__title">{column.title}</p>}
              <ul className="lr-foot__list">
                {column.items.map((item) => (
                  <li key={item.label}>
                    <Link className="lr-foot__link" {...(item.href ? {href: item.href} : {to: item.to})}>
                      {item.label}
                    </Link>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </nav>

        <p className="lr-foot__credit">
          © {new Date().getFullYear()} Loren. Made by Fabi. <span>A Luau framework for Roblox, MIT licensed.</span>
        </p>
      </div>
    </footer>
  );
}

export default React.memo(Footer);
