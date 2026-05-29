const SELECTOR = '.button, .menu__link, .pagination-nav__link';

if (typeof document !== 'undefined') {
  document.addEventListener(
    'click',
    (event) => {
      const target =
        event.target instanceof Element ? event.target.closest(SELECTOR) : null;
      if (!target) return;

      const rect = target.getBoundingClientRect();
      const size = Math.max(rect.width, rect.height);

      // Ensure the host can position + clip the ripple.
      if (getComputedStyle(target).position === 'static') {
        target.style.position = 'relative';
      }
      target.style.overflow = 'hidden';

      const ripple = document.createElement('span');
      ripple.className = 'md-ripple';
      ripple.style.width = `${size}px`;
      ripple.style.height = `${size}px`;
      ripple.style.left = `${event.clientX - rect.left - size / 2}px`;
      ripple.style.top = `${event.clientY - rect.top - size / 2}px`;

      ripple.addEventListener('animationend', () => ripple.remove());
      target.appendChild(ripple);
    },
    {passive: true},
  );
}
