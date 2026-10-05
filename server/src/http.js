import { ServiceError, fail } from './errors.js';

export function httpHandler(handle) {
  return async (request, response) => {
    response.setHeader('Content-Type', 'application/json');
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    try {
      if (request.method === 'POST') {
        if (request.headers['content-type']?.split(';')[0].trim() !== 'application/json') fail(415, 'invalid_request');
        if (Number(request.headers['content-length']) > 8192) fail(413, 'request_too_large');
        if (request.body === undefined) {
          let bytes = 0;
          const chunks = [];
          for await (const chunk of request) {
            bytes += chunk.length;
            if (bytes > 8192) fail(413, 'request_too_large');
            chunks.push(chunk);
          }
          try { request.body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
          catch { fail(400, 'invalid_request'); }
        }
        if (typeof request.body === 'string') {
          try { request.body = JSON.parse(request.body); } catch { fail(400, 'invalid_request'); }
        }
        if (JSON.stringify(request.body).length > 8192) fail(413, 'request_too_large');
      }
      response.statusCode = 200;
      response.end(JSON.stringify(await handle(request)));
    } catch (error) {
      const known = error instanceof ServiceError;
      if (!known) {
        // Bounded error categories support operations without disclosing request/provider payloads.
        const kind = ['StripeAuthenticationError', 'StripeInvalidRequestError', 'StripeIdempotencyError',
          'StripeRateLimitError', 'StripeConnectionError', 'StripeAPIError'].includes(error?.type) ? error.type : 'internal';
        const code = typeof error?.code === 'string' && /^[0-9A-Z]{5}$/.test(error.code) ? error.code : undefined;
        console.error(JSON.stringify({ event: 'shapedesk_request_failed', kind, code }));
      }
      response.statusCode = known ? error.status : 503;
      if (response.statusCode === 429) response.setHeader('Retry-After', '60');
      // Never serialize upstream errors, keys, names, metadata, or database details.
      response.end(JSON.stringify({ code: known ? error.code : 'service_unavailable' }));
    }
  };
}
