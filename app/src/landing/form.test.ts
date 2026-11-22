import { describe, expect, it } from 'vitest';
import { formProblem, subdomainProblem, suggestSubdomain, type SignupFields } from './form';
import { TEXT } from './i18n';

const OK: SignupFields = { business: 'Boutique Rose', name: 'Rose M', phone: '+243 81 234 5678', email: 'rose@example.com', subdomain: 'boutique-rose', shops: '2', note: '' };

describe('suggestSubdomain', () => {
  it('turns a business name into an address', () => {
    expect(suggestSubdomain('Boutique Élégance & Fils')).toBe('boutique-elegance-fils');
    expect(suggestSubdomain('  SAP Congo S.A.R.L. ')).toBe('sap-congo-s-a-r-l');
    expect(suggestSubdomain('Ça va ? Ñandú 123')).toBe('ca-va-nandu-123');
    expect(suggestSubdomain('---')).toBe('');
    expect(suggestSubdomain('a'.repeat(39) + ' b')).toBe('a'.repeat(39));   // never ends with a hyphen after cutting
  });
  it('makes only valid addresses', () => {
    for (const n of ['Boutique Élégance & Fils', 'Kin Market', 'X', 'Pharmacie du Centre-Ville']) {
      const s = suggestSubdomain(n);
      if (s.length >= 1) expect(subdomainProblem(s) === null || subdomainProblem(s) === 'subdomain_reserved').toBe(true);
    }
  });
});

describe('the form', () => {
  it('accepts a complete form', () => expect(formProblem(OK)).toBeNull());
  it('names the first thing to fix, as the server would', () => {
    expect(formProblem({ ...OK, business: 'x' })).toBe('business');
    expect(formProblem({ ...OK, name: '' })).toBe('name');
    expect(formProblem({ ...OK, phone: 'call me' })).toBe('phone');
    expect(formProblem({ ...OK, email: 'rose@' })).toBe('email');
    expect(formProblem({ ...OK, subdomain: 'Rose' })).toBe('subdomain_invalid');
    expect(formProblem({ ...OK, subdomain: 'a--b' })).toBe('subdomain_invalid');
    expect(formProblem({ ...OK, subdomain: 'www' })).toBe('subdomain_reserved');
    expect(formProblem({ ...OK, subdomain: 'approve' })).toBe('subdomain_reserved');
    expect(formProblem({ ...OK, shops: '0' })).toBe('shops');
    expect(formProblem({ ...OK, shops: '2.5' })).toBe('shops');
  });
  it('has a message in both languages for every problem the server can send', () => {
    const codes = ['business', 'name', 'phone', 'email', 'subdomain_invalid', 'subdomain_reserved', 'subdomain_taken', 'shops', 'too_many', 'busy', 'network', 'server'];
    for (const l of ['fr', 'en'] as const) for (const c of codes) expect(TEXT[l].err[c], `${l} ${c}`).toBeTruthy();
    expect(TEXT.fr.features).toHaveLength(6);
    expect(TEXT.en.why).toHaveLength(TEXT.fr.why.length);
  });
});
