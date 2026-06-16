import { useState } from 'react'
import { upsertCrmIntegration, friendlyCrmError } from '../../api/integrations'
import type { CrmIntegrationSafe, UpsertCrmIntegrationArgs, UpsertCrmIntegrationResult } from '../../lib/types'
import { Card } from '../ui/Card'

// Increment D scope: GoHighLevel only. No config editor — every write sends an
// empty config ({}). The modal is the owner-only Connect / Rotate / Edit-metadata
// surface and the sole browser path to upsert_crm_integration().
//
//   • mode 'connect' — no row yet for GHL; secret REQUIRED.
//   • mode 'manage'  — existing GHL row; secret OPTIONAL (blank = edit metadata,
//                      filled = rotate the credential). Provider is locked.

type Mode = 'connect' | 'manage'

// GHL is the only provider in this increment.
const PROVIDER = 'gohighlevel' as const

// auth models the owner may pick. 'none' is intentionally not offered for a
// connect (a connect implies a credential); manage may retain an existing 'none'.
const SELECTABLE_AUTH_TYPES = ['api_key', 'private_token', 'oauth2'] as const
type SelectableAuthType = (typeof SELECTABLE_AUTH_TYPES)[number]
const AUTH_TYPE_LABELS: Record<SelectableAuthType, string> = {
  api_key: 'API Key',
  private_token: 'Private Token',
  oauth2: 'OAuth 2.0',
}

const inputClass =
  'w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-forest-500 focus:border-transparent'
const labelClass = 'block text-sm font-medium text-gray-700 mb-1'

interface FormState {
  name: string
  externalAccountId: string
  authType: SelectableAuthType
  secret: string
  expiresAt: string
}

interface CrmIntegrationModalProps {
  mode: Mode
  integration?: CrmIntegrationSafe
  onClose: () => void
  onSuccess: (result: UpsertCrmIntegrationResult, mode: Mode) => void
}

function seedAuthType(integration?: CrmIntegrationSafe): SelectableAuthType {
  const at = integration?.auth_type
  return at && (SELECTABLE_AUTH_TYPES as readonly string[]).includes(at)
    ? (at as SelectableAuthType)
    : 'private_token'
}

export function CrmIntegrationModal({ mode, integration, onClose, onSuccess }: CrmIntegrationModalProps) {
  // Secret lives ONLY in this local state. It is never lifted to the page, never
  // stored in the integrations list, never logged, and never pre-filled.
  const [form, setForm] = useState<FormState>({
    name: integration?.name ?? '',
    externalAccountId: integration?.external_account_id ?? '',
    authType: seedAuthType(integration),
    secret: '',
    expiresAt: '',
  })
  const [fieldErrors, setFieldErrors] = useState<Partial<Record<keyof FormState, string>>>({})
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  const secretRequired = mode === 'connect'

  function update<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((f) => ({ ...f, [key]: value }))
  }

  function validate(): boolean {
    const errs: Partial<Record<keyof FormState, string>> = {}
    if (!form.name.trim()) errs.name = 'Name is required.'
    // GHL needs a Location ID to address the account.
    if (!form.externalAccountId.trim()) errs.externalAccountId = 'Location ID is required for GoHighLevel.'
    if (secretRequired && !form.secret) errs.secret = 'A credential is required to connect.'
    if (form.expiresAt && Number.isNaN(new Date(form.expiresAt).getTime()))
      errs.expiresAt = 'Enter a valid expiry date.'
    setFieldErrors(errs)
    return Object.keys(errs).length === 0
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setSubmitError(null)
    if (!validate()) return
    setSubmitting(true)
    try {
      // Build args. Empty config ({}) for all writes this increment. The secret
      // is OMITTED entirely when blank in manage mode, so the RPC preserves the
      // existing credential (metadata-only edit) rather than clearing it.
      const args: UpsertCrmIntegrationArgs = {
        p_provider: PROVIDER,
        p_name: form.name.trim(),
        p_external_account_id: form.externalAccountId.trim() || null,
        p_auth_type: form.authType,
        p_config: {},
        p_expires_at: form.expiresAt ? new Date(form.expiresAt).toISOString() : null,
      }
      if (form.secret) args.p_secret = form.secret

      const result = await upsertCrmIntegration(args)
      // Drop the secret from state before unmount, for good measure.
      setForm((f) => ({ ...f, secret: '' }))
      onSuccess(result, mode)
    } catch (err) {
      setSubmitError(friendlyCrmError(err))
      setSubmitting(false)
    }
  }

  const title = mode === 'connect' ? 'Connect GoHighLevel' : 'Manage GoHighLevel'
  const secretLabel = mode === 'connect'
    ? 'Credential'
    : 'New credential'
  const secretHint = mode === 'connect'
    ? 'Stored securely server-side; never shown again.'
    : 'Leave blank to keep the current credential. Enter a value to rotate it.'

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="w-full max-w-lg">
        <Card>
          <div className="flex items-center justify-between mb-4">
            <h2 className="font-semibold text-gray-900">{title}</h2>
            <button
              type="button"
              onClick={onClose}
              className="text-sm font-medium text-gray-500 hover:text-gray-900"
              disabled={submitting}
            >
              Close
            </button>
          </div>

          <form onSubmit={handleSubmit} className="space-y-4">
            <div>
              <label className={labelClass}>Provider</label>
              {/* Provider is fixed to GoHighLevel this increment (and locked when managing). */}
              <input className={`${inputClass} bg-gray-50 text-gray-500`} value="GoHighLevel" disabled readOnly />
            </div>

            <div>
              <label className={labelClass}>Name</label>
              <input
                className={inputClass}
                value={form.name}
                onChange={(e) => update('name', e.target.value)}
                placeholder="GoHighLevel — Main Account"
              />
              {fieldErrors.name && <p className="text-xs text-red-600 mt-1">{fieldErrors.name}</p>}
            </div>

            <div>
              <label className={labelClass}>Location ID</label>
              <input
                className={inputClass}
                value={form.externalAccountId}
                onChange={(e) => update('externalAccountId', e.target.value)}
                placeholder="loc_xxxxxxxxxxxx"
              />
              {fieldErrors.externalAccountId && (
                <p className="text-xs text-red-600 mt-1">{fieldErrors.externalAccountId}</p>
              )}
            </div>

            <div>
              <label className={labelClass}>Auth Type</label>
              <select
                className={inputClass}
                value={form.authType}
                onChange={(e) => update('authType', e.target.value as SelectableAuthType)}
              >
                {SELECTABLE_AUTH_TYPES.map((t) => (
                  <option key={t} value={t}>{AUTH_TYPE_LABELS[t]}</option>
                ))}
              </select>
            </div>

            <div>
              <label className={labelClass}>
                {secretLabel}{secretRequired && <span className="text-red-500"> *</span>}
              </label>
              <input
                type="password"
                autoComplete="new-password"
                className={inputClass}
                value={form.secret}
                onChange={(e) => update('secret', e.target.value)}
                placeholder={mode === 'connect' ? 'Paste the API key / token' : '••••••••'}
              />
              <p className="text-xs text-gray-400 mt-1">{secretHint}</p>
              {fieldErrors.secret && <p className="text-xs text-red-600 mt-1">{fieldErrors.secret}</p>}
            </div>

            <div>
              <label className={labelClass}>Expires <span className="text-gray-400 font-normal">(optional)</span></label>
              <input
                type="date"
                className={inputClass}
                value={form.expiresAt}
                onChange={(e) => update('expiresAt', e.target.value)}
              />
              {fieldErrors.expiresAt && <p className="text-xs text-red-600 mt-1">{fieldErrors.expiresAt}</p>}
            </div>

            {submitError && (
              <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-red-700 text-sm">
                {submitError}
              </div>
            )}

            <div className="flex items-center gap-3 pt-2">
              <button
                type="submit"
                disabled={submitting}
                className="bg-forest-600 hover:bg-forest-700 disabled:bg-forest-300 text-white font-semibold py-2.5 px-5 rounded-lg text-sm transition-colors"
              >
                {submitting ? 'Saving…' : mode === 'connect' ? 'Connect' : 'Save Changes'}
              </button>
              <button
                type="button"
                onClick={onClose}
                disabled={submitting}
                className="text-sm font-medium text-gray-600 hover:text-gray-900"
              >
                Cancel
              </button>
            </div>
          </form>
        </Card>
      </div>
    </div>
  )
}
