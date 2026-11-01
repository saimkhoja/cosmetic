// The QuickSales logo: the cart mark (a cart with two speed lines) and the word mark.
// On the dark sign-in panel the cart and "Quick" are white; on light backgrounds they are blue and navy.

export function CartMark({ dark = false, size = 56 }: { dark?: boolean; size?: number }) {
  const id = dark ? 'qs-cart-d' : 'qs-cart';
  return (
    <svg className="qs-mark" width={size} height={size * 0.79} viewBox="0 0 100 79" aria-hidden="true">
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor={dark ? '#FFFFFF' : '#1A7BFF'} />
          <stop offset="1" stopColor={dark ? '#DCE8FF' : '#0A55E6'} />
        </linearGradient>
      </defs>
      <path d="M4.4 4.8H22Q27 4.8 30 9.8L38.6 24.4Q41 27.2 47.4 27.2H89Q95 27.8 94.6 34.4L87.4 51.4Q84.6 57.2 79 57.2H37.4"
        fill="none" stroke={`url(#${id})`} strokeWidth="9.2" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M12 32H36" stroke="#2DD67F" strokeWidth="8" strokeLinecap="round" />
      <path d="M22 45H58" stroke={dark ? '#5CB8FF' : '#1E88FF'} strokeWidth="8.6" strokeLinecap="round" />
      <circle cx="48" cy="71.6" r="6.4" fill={dark ? '#FFFFFF' : '#0A3FC2'} />
      <circle cx="77.2" cy="71.6" r="6.4" fill={dark ? '#FFFFFF' : '#0A3FC2'} />
    </svg>
  );
}

/** The cart mark and word mark together; its size follows the font size given to .qs-logo in CSS. */
export function QuickSalesLogo({ dark = false }: { dark?: boolean }) {
  return (
    <div className={'qs-logo' + (dark ? ' dark' : '')}>
      <CartMark dark={dark} />
      <span><b>Quick</b><b>Sales</b></span>
    </div>
  );
}
