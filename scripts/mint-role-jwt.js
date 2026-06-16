#!/usr/bin/env node
// ============================================================
// mint-role-jwt.js — mint a Supabase custom-role JWT (HS256, LEGACY secret)
//
// Signs a token for a CUSTOM Postgres role (crm_resolver / crm_automation) using
// the project's LEGACY JWT secret (Dashboard → Project Settings → API → JWT
// Settings → "Legacy JWT Secret", still used). This is the supported path for
// custom-role tokens under JWT Signing Keys: the asymmetric (ES256) private key
// cannot be exported, so role tokens must be self-signed HS256 and are verified
// via the legacy secret carried in the project JWKS.
//
//   usage:  node scripts/mint-role-jwt.js <crm_resolver|crm_automation> [days]
//   env:    SUPABASE_JWT_SECRET = the legacy JWT secret (required)
//   output: the JWT on stdout (clean, capturable); a summary on stderr.
//
// SECURITY: never commit the secret or a minted token. Keep `days` short
// (7–14) — the legacy secret can no longer be rotated, so a leaked token can
// only be aged out by expiry.
//
// This project is ESM ("type": "module"), so the script uses import syntax.
// ============================================================

import crypto from 'node:crypto'

const ALLOWED_ROLES = ['crm_resolver', 'crm_automation']
const DEFAULT_DAYS = 14
const MAX_DAYS = 30

function fail(msg) {
  console.error(`mint-role-jwt: ${msg}`)
  process.exit(1)
}

const role = process.argv[2]
const daysArg = process.argv[3]
const days = daysArg === undefined ? DEFAULT_DAYS : Number(daysArg)

if (!role) {
  fail('usage: node scripts/mint-role-jwt.js <crm_resolver|crm_automation> [days]')
}
if (!ALLOWED_ROLES.includes(role)) {
  fail(`role must be one of: ${ALLOWED_ROLES.join(', ')} (got "${role}")`)
}
if (!Number.isFinite(days) || days <= 0 || days > MAX_DAYS) {
  fail(`days must be a number in (0, ${MAX_DAYS}]; got "${daysArg}"`)
}

const secret = process.env.SUPABASE_JWT_SECRET
if (!secret || secret.trim() === '') {
  fail('set SUPABASE_JWT_SECRET to the project LEGACY JWT secret')
}

const b64url = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url')

const now = Math.floor(Date.now() / 1000)
const exp = now + Math.round(days * 86400)

// alg HS256, no `kid` → verifiers fall back to the legacy symmetric secret.
const header = { alg: 'HS256', typ: 'JWT' }
const payload = { role, iss: 'campground-os', iat: now, exp }

const signingInput = `${b64url(header)}.${b64url(payload)}`
const signature = crypto.createHmac('sha256', secret).update(signingInput).digest('base64url')
const token = `${signingInput}.${signature}`

// Human-readable summary → stderr (so stdout stays a clean, capturable token).
console.error(
  `minted role=${role}  iat=${new Date(now * 1000).toISOString()}  ` +
    `exp=${new Date(exp * 1000).toISOString()}  (${days}d)`,
)
process.stdout.write(token + '\n')
