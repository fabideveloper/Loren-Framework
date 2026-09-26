import {Fragment, useEffect, useRef, useState, type ReactNode} from 'react';
import clsx from 'clsx';
import styles from './home.module.css';

async function writeClipboard(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // fall through to the textarea fallback
  }
  try {
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand('copy');
    document.body.removeChild(area);
    return ok;
  } catch {
    return false;
  }
}

// A shell command in an install box with a COPY button.
export default function CopyCommand({
  command,
  label,
  className,
}: {
  command: string;
  label?: string;
  className?: string;
}): ReactNode {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  useEffect(() => () => clearTimeout(timer.current), []);

  const onCopy = async () => {
    if (!(await writeClipboard(command))) return;
    setCopied(true);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setCopied(false), 1800);
  };

  return (
    <div className={clsx(styles.copyWrap, className)}>
      {label && <p className={clsx('lr-label-dim', styles.copyLabel)}>{label}</p>}
      <div className={clsx('lr-copy', styles.copy)}>
        <code className={clsx('lr-copy__cmd', styles.copyCode)}>
          <span className="lr-copy__prompt" aria-hidden="true">
            $
          </span>
          {/* Each word stays whole, so a narrow box wraps at spaces, never inside "loren-framework@next". */}
          {command.split(' ').map((word, i) => (
            <Fragment key={i}>
              {i > 0 && ' '}
              <span className={styles.copyWord}>{word}</span>
            </Fragment>
          ))}
        </code>
        <button
          type="button"
          className={clsx('lr-copy__btn', styles.copyButton)}
          onClick={onCopy}
          aria-label={`Copy command: ${command}`}>
          {copied ? 'Copied' : 'Copy'}
        </button>
      </div>
      <span className={styles.srOnly} aria-live="polite">
        {copied ? 'Copied to clipboard' : ''}
      </span>
    </div>
  );
}
