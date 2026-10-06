// Local stand-in for the Supabase API gateway: one URL, routed by path like supabase.co.
import http from 'node:http';
const routes = [
  ['/auth/v1/', 'http://127.0.0.1:9999/'],
  ['/rest/v1/', 'http://127.0.0.1:3000/'],
  ['/functions/v1/setup', 'http://127.0.0.1:8101/'],
  ['/functions/v1/admin-users', 'http://127.0.0.1:8102/'],
];
const cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, x-client-info, apikey, content-type, prefer, accept-profile, content-profile, range, x-supabase-api-version',
  'access-control-allow-methods': 'GET, POST, PATCH, PUT, DELETE, OPTIONS',
  'access-control-expose-headers': 'content-range, x-supabase-api-version',
};
http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end(); }
  const r = routes.find(([p]) => req.url.startsWith(p) || req.url.split('?')[0] === p.replace(/\/$/, ''));
  if (!r) { res.writeHead(404, cors); return res.end('not found'); }
  const target = r[1] + req.url.slice(r[0].length).replace(/^\//, '');
  const body = await new Promise((ok) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => ok(Buffer.concat(c))); });
  const headers = { ...req.headers }; delete headers.host; delete headers['content-length'];
  try {
    const up = await fetch(target, { method: req.method, headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : body });
    const h = { ...cors }; up.headers.forEach((v, k) => { if (!['content-encoding', 'transfer-encoding', 'content-length', 'connection'].includes(k) && !k.startsWith('access-control')) h[k] = v; });
    res.writeHead(up.status, h); res.end(Buffer.from(await up.arrayBuffer()));
  } catch (e) { res.writeHead(502, cors); res.end('upstream down: ' + e.message); }
}).listen(54321, () => console.log('gateway on http://127.0.0.1:54321'));
