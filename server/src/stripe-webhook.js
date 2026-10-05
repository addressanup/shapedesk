import { httpHandler } from './http.js';
import { fail } from './errors.js';

export function stripeWebhookHandler({ stripe, secret, handle }) {
  return async (request, response) => {
    // Verify the exact bytes before any JSON parsing. Never reconstruct a parsed body.
    const process = httpHandler(async () => {
      if (request.method !== 'POST') fail(405, 'method_not_allowed');
      if (!secret || !stripe) fail(503, 'billing_unavailable');
      if (Number(request.headers['content-length']) > 262144) fail(413, 'request_too_large');
      let body;
      if (Buffer.isBuffer(request.body)) body = request.body;
      else if (typeof request.body === 'string') body = Buffer.from(request.body);
      else {
        const chunks = []; let bytes = 0;
        for await (const chunk of request) {
          bytes += chunk.length;
          if (bytes > 262144) fail(413, 'request_too_large');
          chunks.push(chunk);
        }
        body = Buffer.concat(chunks);
      }
      if (body.length > 262144) fail(413, 'request_too_large');
      let event;
      try { event = stripe.webhooks.constructEvent(body, request.headers['stripe-signature'], secret); }
      catch { fail(400, 'invalid_signature'); }
      return handle(event);
    });
    // Skip the normal 8 KiB JSON parser; this handler performs its own bounded raw read.
    return process({ method: 'GET' }, response);
  };
}
