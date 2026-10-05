export function billingPage(path, response, live = true) {
  const cancel = path === '/checkout/cancel', success = path === '/checkout/success';
  const title = cancel ? 'Checkout paused.' : success ? 'Your desktop, a little clearer.' : 'You’re all set.';
  const detail = cancel ? 'Your purchase has not been completed. Return to ShapeDesk whenever you’re ready.'
    : success ? 'Return to ShapeDesk to finish activating AI Sort on this Mac. The app will securely verify your subscription.'
    : 'Return to ShapeDesk. Your subscription changes will appear after you refresh your account.';
  response.setHeader('Content-Type', 'text/html; charset=utf-8');
  response.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
  response.end(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ShapeDesk Pro</title><style>
    :root{color-scheme:light dark}body{font:17px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;margin:0;background:light-dark(#f6f5f1,#191a19);color:light-dark(#252925,#f4f5f0)}main{max-width:560px;margin:15vh auto;padding:32px}small{letter-spacing:.06em;font-weight:600}h1{font-size:42px;line-height:1.12;letter-spacing:-.04em}p{opacity:.75}a{display:inline-block;padding:12px 20px;background:#267354;color:white;border-radius:10px;text-decoration:none;font-weight:600}footer{font-size:13px;margin-top:36px;opacity:.65}
    </style><main><small>SHAPEDESK PRO</small><h1>${title}</h1><p>${detail}</p><a href="${live ? 'shapedesk' : 'shapedesk-test'}://billing/return">Return to ShapeDesk</a><footer>If the app doesn’t open, switch to ShapeDesk → Account and ${success ? 'choose “I’ve completed checkout”.' : 'refresh your account.'}</footer></main></html>`);
}
