// The six feature icons of the sign-in panel and the landing page (getquicksales.com).
// No imports from the app: the landing page loads this without the database connection.
// The sign-in panel: the QuickSales logo, the headline and six feature cards. Icons are white with a green accent.
const W = { fill: 'none', stroke: '#fff', strokeWidth: 3.2, strokeLinecap: 'round', strokeLinejoin: 'round' } as const;
const G = { ...W, stroke: '#2DD67F' } as const;
// labels break where \n is, as on the approved design
export const FEATURES: [string, JSX.Element][] = [
  ['Keep Selling\nOffline', <><path {...W} d="M5 18a27 27 0 0 1 38 0M11 25a18 18 0 0 1 26 0M17 32a9 9 0 0 1 14 0" /><circle cx="24" cy="38" r="2.6" fill="#fff" /><circle cx="36" cy="36" r="8" fill="#2DD67F" /><path {...W} strokeWidth={2.8} d="M32.5 36l2.5 2.5 4.6-5" /></>],
  ['Flexible\nSelling', <><path {...W} d="M24 4l14 7v14l-14 7-14-7V11z" /><path {...W} d="M10 11l14 7 14-7M24 18v14" /><path {...G} d="M17 7.5l14 7" /><path {...W} d="M10 30v7l14 7 14-7v-7" /></>],
  ['Control Stock\n& Deliveries', <><path {...W} d="M14 10h19v22H14zM33 17h7l5 7v8H33" /><circle cx="20" cy="36" r="4" {...W} /><circle cx="39" cy="36" r="4" {...W} /><path {...G} d="M3 15h7M1 21h9M4 27h6" /></>],
  ['Built-in\nAccounting', <><rect x="6" y="26" width="7" height="16" rx="2" {...W} /><rect x="20" y="17" width="7" height="25" rx="2" {...W} /><rect x="34" y="7" width="7" height="35" rx="2" {...W} /><path {...G} d="M6 26v16" /></>],
  ['Secure &\nRole-Based Access', <><path {...W} d="M24 4l16 6v11c0 11-7 19-16 23C15 40 8 32 8 21V10z" /><path {...G} strokeWidth={3.6} d="M16.5 23.5l5.5 5.5 10-11" /></>],
  ['Barcode, Receipts\n& Price Tickets', <><path {...W} d="M4 13V6h7M37 6h7v7M44 35v7h-7M11 42H4v-7" /><path {...W} strokeWidth={2.6} d="M12 14v20M16 14v20M21 14v20M26 14v20M31 14v20M36 14v20" /><path {...W} strokeWidth={1.4} d="M18.5 14v20M23.5 14v20M33.5 14v20" /></>],
];

