# ShapeDesk hosted AI service

## Change brief

Replace the Mac-only preview with the customer flow: ShapeDesk → authenticated
HTTPS service → TypeSafe Jev. Stripe sells ShapeDesk Pro for **$5 USD/month**, with
**1,000 completed AI checks per UTC calendar month**, shared across **3 Macs**.
The native app provides checkout, activation, usage, recovery, billing management,
Finder sorting and offline undo. Shapes remain free.

Acceptance: real hosted Jev classification from the packaged app; Stripe test
checkout activates only after verified payment; forged/unpaid/foreign purchases
are denied; signed subscription updates revoke or restore access; strict >0.8
confidence, collisions and offline undo stay covered; no vendor, Stripe or database
secret ships in the app. Inspect the rendered Mac UI and create a universal ZIP.

Authorization comes from the user's request to build and package this hosted flow,
their choice of Stripe and $5/1,000, and their instruction to use the connected
Stripe CLI credentials temporarily. The usable test credential expires **2026-12-03**;
the saved live credential is masked and cannot authenticate the server. At the user's
request, live setup is deferred and production checkout stays OFF. Add a full live
key to the private `.env` when ready. No real test charges are authorized.

Risks are paid access, metering and file moves. Rollback disables new checkout with
`CHECKOUT_ENABLED=false`, restores the prior verified deployment/app, and retains
Postgres usage, purchases, subscriptions and local SortHistory. Never reset quota
or remove undo journals to roll back code. Monitor health, aggregate HTTP errors,
Stripe webhook delivery failures and provider usage without logging payloads.

## Flow and boundaries

1. The app saves a cryptographically random purchase/recovery key in Keychain
   **before** requesting checkout. It sends only the key and its device UUID to
   ShapeDesk over HTTPS. Stripe receives an HMAC identifier, never that secret.
2. ShapeDesk creates an idempotent Stripe Checkout Session for its configured
   recurring price. The app opens the returned Stripe HTTPS URL.
3. Stripe returns to a static ShapeDesk page. Its app link carries no credential.
   The app proves possession of its saved key; the server retrieves the Checkout
   Session and subscription directly from Stripe and verifies mode, price,
   customer, payment and purchase binding before activating a device.
4. Customers can copy their recovery key from Account to activate another Mac.
   Deactivation frees a device slot without canceling billing. Expired/past-due
   customers can still open their authenticated Stripe customer portal.
5. Each classification validates device access and reserves durable monthly usage
   under a Postgres row lock. Stable request IDs prevent double charging on network
   retries. Failed AI calls release reservations; abandoned calls expire after
   90 seconds. No file moves without a valid confidence strictly above 0.8.
6. Signed Stripe webhooks reconcile against canonical Stripe state, not event
   snapshots. Duplicates and out-of-order delivery are safe. Past-due, paused,
   canceled and unpaid subscriptions deny new AI requests. Full refunds and disputes
   suspend access. Canonical state is rechecked at most every five minutes and at
   paid-period expiry if a webhook is delayed. Refund/dispute suspension requires
   operator review before removal.

Jev is pinned to `jev-1.13.0`. Only name, extension, size, type and dates are sent.
Neither file contents nor full paths leave the Mac. Database records contain HMAC
identifiers, Stripe IDs, device IDs, usage and classification results; they contain
no raw license/recovery keys or filenames. App credentials live in macOS Keychain.
Undo uses local synced journals and needs neither a subscription nor the service.

## Hosting and configuration

- Vercel Node 24: `shapedesk-api` and isolated `shapedesk-api-staging` projects.
- Separate Neon Postgres projects, initially on the existing free plan.
- Stripe SDK pinned in package-lock; API version `2025-02-24.acacia`.
- The existing `website/` deployment remains separate.
- `server/.env*` are ignored and owner-readable only. Vercel runtime secrets are
  populated through stdin, never process arguments or committed configuration.

See `.env.example` for names. Set `CHECKOUT_ENABLED=true` only after merchant
configuration and verification. Ordinary app builds use `ShapeDeskAPIBaseURL`
from Info.plist and require HTTPS. The compiled local-preview factory is absent
from customer release binaries.

With checkout OFF, Stripe secrets may be omitted to run server-granted owner access.
No public route creates an owner grant. The operator-only `scripts/grant-owner.mjs`
writes a private recovery key before inserting an expiring, metered grant. It does
not reset usage or override an existing paid/suspended account. Production and
staging use separate secrets, databases, app identifiers and Keychain entries.

`node scripts/configure-stripe.mjs test https://shapedesk-api-staging.vercel.app`
provisions ShapeDesk-tagged product/price, portal and webhook objects using the
connected CLI test credential. The live variant uses `live https://api.shapedesk.space`.
It takes a permanent `STRIPE_SECRET_KEY` from `.env` when provided; otherwise it
uses the connected CLI live credential as explicitly authorized. It never charges
customers, sends emails, changes another product, or logs secrets. Store webhook
secrets securely: Stripe only returns them at creation. Automatic Tax follows the
merchant's already-active Stripe Tax setup; no tax registrations are created.
Checkout explicitly uses direct Stripe Billing (`managed_payments.enabled=false`)
per session; account-wide Managed Payments settings are unchanged.

Run migrations only against the intended environment:
`node --env-file=.env.production.local src/migrate.js`. Migrations are additive.
Use the unpooled Neon URL for migrations when available. Back up production before
changing existing schema. The initial deployment starts with a new empty database.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/v1/health` | Runtime and database health, no secrets |
| GET | `/v1/plans` | Price, allowance, device limit, checkout availability |
| POST | `/v1/checkout` | Create/resume purchase bound to a secret and device |
| POST | `/v1/checkout/complete` | Verify paid checkout and activate this Mac |
| POST | `/v1/activate` | Restore using a ShapeDesk recovery key |
| GET | `/v1/entitlement` | Subscription access and monthly usage |
| POST | `/v1/classify` | Idempotent, metered Jev classification |
| POST | `/v1/portal` | Authenticated Stripe billing portal URL |
| POST | `/v1/deactivate` | Revoke this Mac's activation |
| POST | `/v1/account` | Recovery-key account summary for the website |
| POST | `/v1/account/portal` | Stripe billing portal URL via recovery key |
| POST | `/v1/account/deactivate` | Revoke one device by its public handle |
| POST | `/v1/webhooks/stripe` | Verify raw Stripe signature and reconcile billing |

Authenticated routes use `Authorization: Bearer <recovery key>` and
`X-ShapeDesk-Instance: <UUID>`. App request bodies are capped at 8 KiB and webhook
bodies at 256 KiB. Browser pages use a restrictive CSP and no-referrer policy.
The app accepts checkout/portal URLs only on Stripe's exact HTTPS hosts.

The account page at `https://shapedesk.space/account` signs in with the same
recovery key, sent only in the JSON body. The `/v1/account*` routes and
`/v1/plans` answer browser CORS solely for `WEB_ORIGIN` (default
`https://shapedesk.space`); other origins get no allow headers and their
preflights are denied. Devices are listed as 32-character HMAC handles, never
instance IDs, and neither the key nor any `license_id` appears in responses.
`last_seen_at` records each device's most recent authorized use, refreshed at
most every ten minutes.

## Verification

```sh
swift test
npm --prefix server run test:postgres
./release.sh
```

Postgres tests run serially against an isolated disposable local cluster. Tests
cover authorization, device limits, simultaneous reservations, quotas, refunds,
failed/stale requests, replay, expiry, canonical webhook ordering, forged/tampered/
old signatures, strict confidence, filesystem locks, collisions, journals and undo.
Real billing tests must use Stripe test mode and the staging database. A local
mock is not evidence of a completed Stripe checkout or live hosted Jev call.

Verified on 2026-10-05; initial hosted deployment commit `e77b498`:

- Production deployed to `https://api.shapedesk.space`; health and plans return
  200. Checkout is OFF. Unknown credentials and unauthenticated AI calls are denied.
- A real Stripe sandbox checkout completed for $5 USD, with a signed webhook
  provisioning access and the browser link activating the test app. The Stripe
  portal was created successfully. Canceling that test subscription delivered a
  signed event and revoked access; no live charge was made.
- Installed universal app 1.1 on the Mac, activated metered hosted owner access,
  and invoked both file and folder selections through Finder's native Service.
- Production Jev classified the fixture as Screenshots. An in-use file was kept.
  A shallow folder pass scanned one visible file, moved it to a collision suffix,
  preserved the existing/hidden/nested files, and undo restored all four original
  file names and byte hashes. Two AI checks were used; undo used none.
- 54 Swift tests and 37 Node/Postgres tests passed; production npm audit reports
  zero vulnerabilities. Universal archive signature verification passed, and the
  app contains neither vendor/server secrets nor the owner-preview HTTP factory.
- The old loopback LaunchAgent is stopped. Local undo journals are preserved.

Archive: `dist/ShapeDesk.zip`, SHA-256
`99a3b3ae9534b1747c17afb1bc7934697480940519cfc76f0937f0214e6aefa8`.
The app uses an ad-hoc signature; Developer ID signing and notarization are still
required for normal public distribution. No new GitHub release was published.

Verified on 2026-10-07; account portal API, commit `b77744a`:

- Additive migration (`devices.last_seen_at`) applied to staging, then production,
  over the unpooled URLs. Staging and then production were deployed. The previous
  production deployment, `shapedesk-7xdm94syf`, is the rollback target.
- On both hosts, health and plans return 200. Only `https://shapedesk.space` receives
  `Access-Control-Allow-Origin` (with `Vary: Origin`); its preflight returns 204, and a
  foreign origin's preflight returns 403. Unknown recovery keys get 403
  `invalid_license`, malformed keys 400, and bad device handles 400. Device routes
  without credentials still return 401.
- Production, signed in with the owner recovery key: the account summary returned
  owner access, usage and one device, without echoing the key. A throwaway device was
  activated, found by its new handle, deactivated through `/v1/account/deactivate`
  (a repeat returned 404 `device_not_found`), and the original Mac stayed active.
  `/v1/account/portal` returns 409 `billing_unavailable` for owner access.
- 46 Node/Postgres tests passed.

To enable real purchases later: put a full live Stripe secret in `server/.env`,
run `node server/scripts/configure-stripe.mjs live https://api.shapedesk.space`,
then `node server/scripts/prepare-host.mjs live` and deploy the verified server.
This preserves the existing production identity hash, owner grant and quota.
Provisioning keeps live checkout OFF by default. Verify the live merchant/portal/
webhook configuration, set `CHECKOUT_ENABLED="true"` in the private
`server/.env.live.local`, prepare the host again and redeploy to enable purchases.
The usable temporary **test** credential must be replaced by **2026-12-03**.

The old `owner-preview.sh` is a development-only fallback, never a customer release.
Once the hosted app is installed, stop its old helper with
`launchctl bootout gui/$(id -u)/com.shapedesk.owner-preview` and remove that LaunchAgent
plist. Preserve `~/Library/Application Support/ShapeDesk/SortHistory` for undo.

References: [Stripe Checkout](https://docs.stripe.com/billing/subscriptions/build-subscriptions),
[subscription webhooks](https://docs.stripe.com/billing/subscriptions/webhooks),
[signature verification](https://docs.stripe.com/webhooks/signature),
[TypeSafe API](https://docs.typesafe.ai/api).
