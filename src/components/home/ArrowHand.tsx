import type {ReactNode} from 'react';

// A hand-drawn arrow (Starbite's). Decorative, so it is hidden from screen readers.
export default function ArrowHand({className}: {className?: string}): ReactNode {
  return (
    <svg
      viewBox="0 0 120 90"
      aria-hidden="true"
      focusable="false"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeWidth="2.5"
      strokeLinecap="round"
      strokeLinejoin="round">
      <path d="M108 6c-6 21-19 39-38 52C55 68 38 76 18 80" />
      <path d="M14 63c1 8 3 14 5 18" />
      <path d="M36 82c-7 0-13-1-22-2" />
    </svg>
  );
}
