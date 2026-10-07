const paths = new Set(['/v1/plans', '/v1/account', '/v1/account/portal', '/v1/account/deactivate']);

export function cors(config) {
  return (request, response, path) => {
    if (!paths.has(path)) return false;
    response.setHeader('Vary', 'Origin');
    const allowed = request.headers.origin === config.webOrigin;
    if (allowed) response.setHeader('Access-Control-Allow-Origin', config.webOrigin);
    if (request.method !== 'OPTIONS') return false;
    if (!allowed) { response.writeHead(403); response.end(); return true; }
    response.writeHead(204, { 'Access-Control-Allow-Methods': 'GET, POST',
      'Access-Control-Allow-Headers': 'Content-Type', 'Access-Control-Max-Age': '600' });
    response.end();
    return true;
  };
}
