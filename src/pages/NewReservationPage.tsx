import { useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { differenceInCalendarDays } from 'date-fns'
import { useAuth } from '../context/AuthProvider'
import { listProperties } from '../api/properties'
import { upsertGuest, createReservation } from '../api/reservations'
import type { Property } from '../lib/types'
import { Card } from '../components/ui/Card'
import { PageHeader } from '../components/common/PageHeader'

// Mirrors the backend regex in upsert_guest(); client-side check is UX only —
// the database remains the authority.
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/

const inputClass =
  'w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-forest-500 focus:border-transparent'
const labelClass = 'block text-sm font-medium text-gray-700 mb-1'
const WRITE_ROLES = ['owner', 'manager', 'staff']

interface FormState {
  firstName: string
  lastName: string
  email: string
  phone: string
  propertyId: string
  siteNumber: string
  checkIn: string
  checkOut: string
  numGuests: string
  nightlyRate: string
  notes: string
}

const EMPTY: FormState = {
  firstName: '', lastName: '', email: '', phone: '',
  propertyId: '', siteNumber: '', checkIn: '', checkOut: '',
  numGuests: '1', nightlyRate: '', notes: '',
}

// Map known RPC failures to friendly copy — never surface raw DB errors.
function friendlyError(e: unknown): string {
  const msg = e instanceof Error ? e.message : ''
  const code = (e as { code?: string } | null)?.code
  if (code === '42501' || /may not create|permission|no organization context/i.test(msg))
    return 'You don’t have permission to create reservations.'
  if (/invalid email/i.test(msg)) return 'Please enter a valid email address.'
  if (/guest not found in your organization/i.test(msg))
    return 'That guest could not be linked to your organization. Please try again.'
  if (/property not found/i.test(msg))
    return 'The selected property is no longer available. Pick another property.'
  if (/only book your assigned property/i.test(msg))
    return 'You can only book reservations for your assigned property.'
  if (/check_out must be after check_in/i.test(msg))
    return 'Check-out must be after check-in.'
  return 'Something went wrong creating the reservation. Please try again.'
}

export function NewReservationPage() {
  const { role } = useAuth()
  const navigate = useNavigate()
  const canWrite = !!role && WRITE_ROLES.includes(role)

  const [form, setForm] = useState<FormState>(EMPTY)
  const [properties, setProperties] = useState<Property[]>([])
  const [fieldErrors, setFieldErrors] = useState<Partial<Record<keyof FormState, string>>>({})
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  // Load the org's accessible properties for the select (RLS-scoped).
  useEffect(() => {
    if (!canWrite) return
    let active = true
    listProperties()
      .then((p) => { if (active) setProperties(p) })
      .catch(() => { if (active) setProperties([]) })
    return () => { active = false }
  }, [canWrite])

  function update<K extends keyof FormState>(key: K, value: string) {
    setForm((f) => ({ ...f, [key]: value }))
  }

  // Computed nights + total (display + passed to the RPC when derivable).
  const nights = useMemo(() => {
    if (!form.checkIn || !form.checkOut) return 0
    const n = differenceInCalendarDays(new Date(form.checkOut), new Date(form.checkIn))
    return n > 0 ? n : 0
  }, [form.checkIn, form.checkOut])

  const rateNum = form.nightlyRate.trim() === '' ? null : Number(form.nightlyRate)
  const totalAmount = nights > 0 && rateNum != null && !Number.isNaN(rateNum) ? nights * rateNum : null

  function validate(): boolean {
    const errs: Partial<Record<keyof FormState, string>> = {}
    if (!form.firstName.trim()) errs.firstName = 'First name is required.'
    if (!form.lastName.trim()) errs.lastName = 'Last name is required.'
    if (!form.email.trim()) errs.email = 'Email is required.'
    else if (!EMAIL_RE.test(form.email.trim())) errs.email = 'Enter a valid email address.'
    if (!form.propertyId) errs.propertyId = 'Select a property.'
    if (!form.siteNumber.trim()) errs.siteNumber = 'Site number is required.'
    if (!form.checkIn) errs.checkIn = 'Check-in date is required.'
    if (!form.checkOut) errs.checkOut = 'Check-out date is required.'
    if (form.checkIn && form.checkOut && nights <= 0) errs.checkOut = 'Check-out must be after check-in.'
    const guests = Number(form.numGuests)
    if (!form.numGuests || Number.isNaN(guests) || guests < 1) errs.numGuests = 'Guests must be at least 1.'
    if (form.nightlyRate.trim() !== '' && (Number.isNaN(Number(form.nightlyRate)) || Number(form.nightlyRate) < 0))
      errs.nightlyRate = 'Enter a valid rate.'
    setFieldErrors(errs)
    return Object.keys(errs).length === 0
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setSubmitError(null)
    if (!validate()) return
    setSubmitting(true)
    try {
      // Step 1: ensure the guest exists in this org (idempotent upsert).
      const guestId = await upsertGuest({
        p_first_name: form.firstName.trim(),
        p_last_name: form.lastName.trim(),
        p_email: form.email.trim(),
        p_phone: form.phone.trim() || null,
      })
      // Step 2: create the reservation against that guest.
      await createReservation({
        p_guest_id: guestId,
        p_property_id: form.propertyId,
        p_site_number: form.siteNumber.trim(),
        p_check_in: form.checkIn,
        p_check_out: form.checkOut,
        p_num_guests: Number(form.numGuests),
        p_nightly_rate: rateNum != null && !Number.isNaN(rateNum) ? rateNum : null,
        p_total_amount: totalAmount,
        p_notes: form.notes.trim() || null,
      })
      // Step 3: go to the list, which refetches fresh on mount.
      navigate('/reservations', { state: { created: true } })
    } catch (err) {
      setSubmitError(friendlyError(err))
      setSubmitting(false)
    }
  }

  if (!canWrite) {
    return (
      <div className="space-y-6">
        <PageHeader title="New Reservation" subtitle="Create a reservation" />
        <Card>
          <p className="text-sm text-gray-600">
            You have <span className="font-medium">read-only</span> access. Reservations can be
            created by owners, managers, and staff. Contact an administrator if you need access.
          </p>
        </Card>
      </div>
    )
  }

  return (
    <div className="space-y-6">
      <PageHeader
        title="New Reservation"
        subtitle="Create a guest and reservation"
        right={
          <button
            type="button"
            onClick={() => navigate('/reservations')}
            className="text-sm font-medium text-gray-600 hover:text-gray-900"
          >
            Cancel
          </button>
        }
      />

      <form onSubmit={handleSubmit} className="space-y-6">
        {/* Guest */}
        <Card>
          <h2 className="font-semibold text-gray-900 mb-4">Guest</h2>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div>
              <label className={labelClass}>First Name</label>
              <input className={inputClass} value={form.firstName}
                onChange={(e) => update('firstName', e.target.value)} />
              {fieldErrors.firstName && <p className="text-xs text-red-600 mt-1">{fieldErrors.firstName}</p>}
            </div>
            <div>
              <label className={labelClass}>Last Name</label>
              <input className={inputClass} value={form.lastName}
                onChange={(e) => update('lastName', e.target.value)} />
              {fieldErrors.lastName && <p className="text-xs text-red-600 mt-1">{fieldErrors.lastName}</p>}
            </div>
            <div>
              <label className={labelClass}>Email</label>
              <input type="email" className={inputClass} value={form.email}
                onChange={(e) => update('email', e.target.value)} placeholder="guest@example.com" />
              {fieldErrors.email && <p className="text-xs text-red-600 mt-1">{fieldErrors.email}</p>}
            </div>
            <div>
              <label className={labelClass}>Phone <span className="text-gray-400 font-normal">(optional)</span></label>
              <input className={inputClass} value={form.phone}
                onChange={(e) => update('phone', e.target.value)} placeholder="+1 555 555 0123" />
            </div>
          </div>
        </Card>

        {/* Reservation */}
        <Card>
          <h2 className="font-semibold text-gray-900 mb-4">Reservation</h2>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div>
              <label className={labelClass}>Property</label>
              <select className={inputClass} value={form.propertyId}
                onChange={(e) => update('propertyId', e.target.value)}>
                <option value="">Select a property…</option>
                {properties.map((p) => (
                  <option key={p.id} value={p.id}>{p.name}</option>
                ))}
              </select>
              {properties.length === 0 && (
                <p className="text-xs text-gray-400 mt-1">No properties available for your account.</p>
              )}
              {fieldErrors.propertyId && <p className="text-xs text-red-600 mt-1">{fieldErrors.propertyId}</p>}
            </div>
            <div>
              <label className={labelClass}>Site Number</label>
              <input className={inputClass} value={form.siteNumber}
                onChange={(e) => update('siteNumber', e.target.value)} placeholder="A-12" />
              {fieldErrors.siteNumber && <p className="text-xs text-red-600 mt-1">{fieldErrors.siteNumber}</p>}
            </div>
            <div>
              <label className={labelClass}>Check-in</label>
              <input type="date" className={inputClass} value={form.checkIn}
                onChange={(e) => update('checkIn', e.target.value)} />
              {fieldErrors.checkIn && <p className="text-xs text-red-600 mt-1">{fieldErrors.checkIn}</p>}
            </div>
            <div>
              <label className={labelClass}>Check-out</label>
              <input type="date" className={inputClass} value={form.checkOut}
                onChange={(e) => update('checkOut', e.target.value)} />
              {fieldErrors.checkOut && <p className="text-xs text-red-600 mt-1">{fieldErrors.checkOut}</p>}
            </div>
            <div>
              <label className={labelClass}>Number of Guests</label>
              <input type="number" min={1} className={inputClass} value={form.numGuests}
                onChange={(e) => update('numGuests', e.target.value)} />
              {fieldErrors.numGuests && <p className="text-xs text-red-600 mt-1">{fieldErrors.numGuests}</p>}
            </div>
            <div>
              <label className={labelClass}>Nightly Rate <span className="text-gray-400 font-normal">(optional)</span></label>
              <input type="number" min={0} step="0.01" className={inputClass} value={form.nightlyRate}
                onChange={(e) => update('nightlyRate', e.target.value)} placeholder="49.99" />
              {fieldErrors.nightlyRate && <p className="text-xs text-red-600 mt-1">{fieldErrors.nightlyRate}</p>}
            </div>
            <div className="sm:col-span-2">
              <label className={labelClass}>Notes <span className="text-gray-400 font-normal">(optional)</span></label>
              <textarea className={`${inputClass} resize-none`} rows={3} value={form.notes}
                onChange={(e) => update('notes', e.target.value)} placeholder="Arriving late evening…" />
            </div>
          </div>

          {/* Computed summary */}
          <div className="mt-4 flex flex-wrap gap-6 border-t border-gray-100 pt-4 text-sm">
            <div>
              <span className="text-gray-500">Nights: </span>
              <span className="font-medium text-gray-900 tabular-nums">{nights || '—'}</span>
            </div>
            <div>
              <span className="text-gray-500">Total Amount: </span>
              <span className="font-medium text-gray-900 tabular-nums">
                {totalAmount != null ? `$${totalAmount.toFixed(2)}` : '—'}
              </span>
            </div>
          </div>
        </Card>

        {submitError && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-red-700 text-sm">
            {submitError}
          </div>
        )}

        <div className="flex items-center gap-3">
          <button
            type="submit"
            disabled={submitting}
            className="bg-forest-600 hover:bg-forest-700 disabled:bg-forest-300 text-white font-semibold py-2.5 px-5 rounded-lg text-sm transition-colors"
          >
            {submitting ? 'Booking…' : 'Book Reservation'}
          </button>
          <button
            type="button"
            onClick={() => navigate('/reservations')}
            className="text-sm font-medium text-gray-600 hover:text-gray-900"
          >
            Cancel
          </button>
        </div>
      </form>
    </div>
  )
}
