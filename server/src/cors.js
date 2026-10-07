const paths = new Set(['/v1/plans', '/v1/account', '/v1/account/portal', '/v1/account/deactivate']);
const allowed = path => paths.has(path) || path.startsWith('/v1/admin');

export function cors(config) {
  return (request, response, path) => {
    if (!allowed(path)) return false;
    response.setHeader('Vary', 'Origin');
    const permitted = request.headers.origin === config.webOrigin;
    if (permitted) response.setHeader('Access-Control-Allow-Origin', config.webOrigin);
    if (request.method !== 'OPTIONS') return false;
    if (!permitted) { response.writeHead(403); response.end(); return true; }
    const admin = path.startsWith('/v1/admin');
    response.writeHead(204, { 'Access-Control-Allow-Methods': admin ? 'GET, POST, DELETE' : 'GET, POST',
      'Access-Control-Allow-Headers': admin ? 'Content-Type, Authorization' : 'Content-Type',
      'Access-Control-Max-Age': '600' });
    response.end();
    return true;
  };
}
