CREATE TABLE IF NOT EXISTS licenses (
  id text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS devices (
  license_id text NOT NULL REFERENCES licenses(id),
  device_id uuid NOT NULL,
  instance_id uuid NOT NULL,
  active boolean NOT NULL,
  checked_at timestamptz NOT NULL,
  expires_at timestamptz,
  PRIMARY KEY (license_id, device_id),
  UNIQUE (license_id, instance_id)
);
CREATE TABLE IF NOT EXISTS usage (
  license_id text NOT NULL REFERENCES licenses(id),
  period date NOT NULL,
  used integer NOT NULL DEFAULT 0 CHECK (used >= 0),
  PRIMARY KEY (license_id, period)
);
CREATE TABLE IF NOT EXISTS checks (
  license_id text NOT NULL REFERENCES licenses(id),
  id uuid NOT NULL,
  metadata_hash text NOT NULL,
  period date NOT NULL,
  status text NOT NULL CHECK (status IN ('pending', 'complete', 'failed')),
  response jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (license_id, id)
);
CREATE INDEX IF NOT EXISTS pending_checks ON checks(license_id, created_at) WHERE status = 'pending';
CREATE TABLE IF NOT EXISTS rate_limits (
  bucket text PRIMARY KEY,
  starts_at timestamptz NOT NULL,
  hits integer NOT NULL
);
CREATE TABLE IF NOT EXISTS subscriptions (
  license_id text PRIMARY KEY REFERENCES licenses(id),
  kind text NOT NULL CHECK (kind IN ('stripe', 'owner')),
  customer_id text UNIQUE,
  subscription_id text UNIQUE,
  status text NOT NULL,
  valid_until timestamptz NOT NULL,
  checked_at timestamptz NOT NULL DEFAULT now(),
  suspended boolean NOT NULL DEFAULT false
);
CREATE TABLE IF NOT EXISTS checkout_attempts (
  license_id text PRIMARY KEY REFERENCES licenses(id),
  device_id uuid NOT NULL,
  session_id text UNIQUE,
  checkout_url text,
  expires_at timestamptz,
  completed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS billing_events (
  id text PRIMARY KEY,
  type text NOT NULL,
  processed_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;
