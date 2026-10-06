// Lets a signed-in user unlock the idle screen while offline: a salted PBKDF2 hash of the
// password from the last online sign-in is kept on this device only.
import { kvGet, kvSet } from './store';

async function hash(pw: string, salt: string) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(pw), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', salt: enc.encode(salt), iterations: 120000, hash: 'SHA-256' }, key, 256);
  return [...new Uint8Array(bits)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
export async function rememberPassword(userId: string, pw: string) {
  const salt = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, '0')).join('');
  await kvSet('pw:' + userId, { salt, h: await hash(pw, salt) });
}
export async function checkPasswordOffline(userId: string, pw: string) {
  const s = await kvGet<{ salt: string; h: string }>('pw:' + userId);
  return !!s && (await hash(pw, s.salt)) === s.h;
}
