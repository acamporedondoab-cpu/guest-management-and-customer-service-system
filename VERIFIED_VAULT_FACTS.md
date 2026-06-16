# VERIFIED VAULT FACTS (2026-06-15)

## Vault Version

* supabase_vault = 0.3.1

## Verified Function Signatures

### create_secret

create_secret(
new_secret text,
new_name text,
new_description text,
new_key_id uuid
)

RETURNS uuid

### update_secret

update_secret(
secret_id uuid,
new_secret text,
new_name text,
new_description text,
new_key_id uuid
)

RETURNS void

## Verified Permissions

### service_role

* schema_usage = true
* secrets_select = true
* decrypted_select = true

### authenticated

* vault access = false
* decrypted_secrets access = false

### anon

* vault access = false
* decrypted_secrets access = false

## Architectural Decision

Although service_role has verified direct Vault access, the project adopts the Resolver Pattern.

Reasoning:

* Vault schema remains hidden from API consumers.
* N8N interacts through a controlled SECURITY DEFINER resolver.
* Reduces coupling to Vault internals.
* Easier future migration or Vault-version changes.
* Provides centralized audit and secret-access control.

## Approved V8 Direction

* Vault-backed CRM credentials
* RPC-only writes
* Owner-only credential management
* Safe-view reads
* Resolver-function secret access
* Additive migration only
* Non-destructive backfill
* Rollback-safe deployment

Status: VERIFIED AND APPROVED FOR V8 IMPLEMENTATION
