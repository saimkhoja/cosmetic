// The signup form's rules. They mirror the control database (request_signup and subdomain_problem in
// control/migrations/20261123000001_signups.sql), which checks everything again: these only give quicker messages.
import { RESERVED } from '../lib/tenant';

export interface SignupFields { business: string; name: string; phone: string; email: string; subdomain: string; shops: string; note: string }
export type Problem = 'business' | 'name' | 'phone' | 'email' | 'subdomain_invalid' | 'subdomain_reserved' | 'shops';

const EXTRA_RESERVED = ['approve', 'quicksales', 'getquicksales', 'shop', 'shops', 'my', 'account', 'pay', 'secure'];

/** An address from a business name: "Boutique Élégance & Fils" → "boutique-elegance-fils". */
export function suggestSubdomain(business: string): string {
  return business.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/&/g, ' ').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40).replace(/-+$/g, '');
}

export function subdomainProblem(s: string): Problem | null {
  if (!/^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/.test(s) || s.includes('--')) return 'subdomain_invalid';
  if (RESERVED.includes(s) || EXTRA_RESERVED.includes(s)) return 'subdomain_reserved';
  return null;
}

export function formProblem(f: SignupFields): Problem | null {
  if (f.business.trim().length < 2 || f.business.trim().length > 80) return 'business';
  if (f.name.trim().length < 2 || f.name.trim().length > 60) return 'name';
  if (!/^\+?[0-9 ().-]{6,30}$/.test(f.phone.trim())) return 'phone';
  if (!/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(f.email.trim()) || f.email.trim().length > 120) return 'email';
  const sp = subdomainProblem(f.subdomain); if (sp) return sp;
  const n = Number(f.shops);
  if (!Number.isInteger(n) || n < 1 || n > 50) return 'shops';
  return null;
}
