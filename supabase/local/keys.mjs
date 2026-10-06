// Makes a local JWT secret plus anon and service_role keys, like a Supabase project has.
import { createHmac, randomBytes } from 'node:crypto';
import { writeFileSync, existsSync, readFileSync } from 'node:fs';
const file = new URL('./.env.local', import.meta.url);
if (existsSync(file)) { process.stdout.write(readFileSync(file, 'utf8')); process.exit(0); }
const secret = randomBytes(32).toString('hex');
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const sign = (role) => {
  const h = b64({ alg: 'HS256', typ: 'JWT' }), p = b64({ role, iss: 'supabase-local', iat: 1700000000, exp: 2000000000 });
  return `${h}.${p}.${createHmac('sha256', secret).update(`${h}.${p}`).digest('base64url')}`;
};
const env = `JWT_SECRET=${secret}\nANON_KEY=${sign('anon')}\nSERVICE_ROLE_KEY=${sign('service_role')}\n`;
writeFileSync(file, env);
process.stdout.write(env);
