import { useState } from 'react'

const WEBHOOK_URL = 'https://hook.eu1.make.com/sy9lrqtiado8mngfw064veslaymq2ivb'
const NIGHTLY_RATE = 49.99

interface FormValues {
  firstName: string
  lastName: string
  email: string
  phone: string
  siteNumber: string
  checkIn: string
  checkOut: string
  numGuests: string
  notes: string
}

interface ReservationFormProps {
  onFieldChange: (values: FormValues) => void
  onSuccess: () => void
}

const initialValues: FormValues = {
  firstName: '',
  lastName: '',
  email: '',
  phone: '',
  siteNumber: '',
  checkIn: '',
  checkOut: '',
  numGuests: '1',
  notes: '',
}

const DEMO_DATA: FormValues = {
  firstName: 'Sarah',
  lastName: 'Mitchell',
  email: 'sarah.mitchell@example.com',
  phone: '+15555550123',
  siteNumber: 'A-12',
  checkIn: '2026-07-04',
  checkOut: '2026-07-07',
  numGuests: '2',
  notes: 'Arriving late evening, bringing kayak',
}

export function ReservationForm({ onFieldChange, onSuccess }: ReservationFormProps) {
  const [values, setValues] = useState<FormValues>(initialValues)
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [successId, setSuccessId] = useState<string | null>(null)

  function handleChange(e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) {
    const next = { ...values, [e.target.name]: e.target.value }
    setValues(next)
    onFieldChange(next)
  }

  function loadDemo() {
    setValues(DEMO_DATA)
    onFieldChange(DEMO_DATA)
    setSuccessId(null)
    setSubmitError(null)
  }

  function calcNights(): number {
    if (!values.checkIn || !values.checkOut) return 0
    const diff = new Date(values.checkOut).getTime() - new Date(values.checkIn).getTime()
    return Math.max(0, Math.floor(diff / (1000 * 60 * 60 * 24)))
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setSubmitting(true)
    setSubmitError(null)

    const nights = calcNights()
    const totalAmount = parseFloat((nights * NIGHTLY_RATE).toFixed(2))
    const externalId = `CAMP-${Date.now()}`

    const payload = {
      event: 'reservation.created',
      external_reservation_id: externalId,
      reservation: {
        site_number: values.siteNumber.trim().toUpperCase(),
        check_in: values.checkIn,
        check_out: values.checkOut,
        num_nights: nights,
        num_guests: parseInt(values.numGuests) || 1,
        nightly_rate: NIGHTLY_RATE,
        total_amount: totalAmount,
        status: 'confirmed',
        notes: values.notes.trim(),
      },
      guest: {
        first_name: values.firstName.trim(),
        last_name: values.lastName.trim(),
        email: values.email.trim().toLowerCase(),
        phone: values.phone.trim(),
      },
    }

    console.log('[ReservationForm] Posting to:', WEBHOOK_URL)
    console.log('[ReservationForm] Payload:', JSON.stringify(payload, null, 2))

    try {
      const response = await fetch(WEBHOOK_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })

      console.log('[ReservationForm] Response status:', response.status, response.ok)

      if (!response.ok) {
        const body = await response.text().catch(() => '(unreadable)')
        console.error('[ReservationForm] Non-OK response body:', body)
        throw new Error(`Webhook returned HTTP ${response.status}`)
      }

      console.log('[ReservationForm] Success — ID:', externalId)
      setSuccessId(externalId)
      setValues(initialValues)
      onFieldChange(initialValues)
      onSuccess()
    } catch (err) {
      console.error('[ReservationForm] Fetch error:', err)
      setSubmitError(
        err instanceof Error ? err.message : 'Failed to reach the webhook endpoint'
      )
    } finally {
      setSubmitting(false)
    }
  }

  const nights = calcNights()

  if (successId) {
    return (
      <div className="flex flex-col items-center justify-center py-10 text-center space-y-4">
        <div className="w-14 h-14 rounded-full bg-forest-100 flex items-center justify-center text-3xl text-forest-600">
          &#10003;
        </div>
        <div>
          <h3 className="text-lg font-bold text-gray-900">Reservation Confirmed</h3>
          <p className="text-sm text-gray-500 mt-1">Webhook delivered to Make.com</p>
        </div>
        <div className="bg-gray-50 border border-gray-200 rounded-lg px-6 py-3 text-center">
          <p className="text-xs text-gray-400 uppercase tracking-wide mb-1">Reservation ID</p>
          <p className="font-mono text-sm font-semibold text-gray-800">{successId}</p>
        </div>
        <p className="text-xs text-gray-400 max-w-xs leading-relaxed">
          Make.com is processing the payload &mdash; upsert guest &rarr; insert reservation &rarr;
          DB trigger fires &rarr; GHL sync &rarr; welcome workflow
        </p>
        <button
          onClick={() => setSuccessId(null)}
          className="mt-2 bg-forest-600 hover:bg-forest-700 text-white font-semibold py-2 px-5 rounded-lg text-sm transition-colors"
        >
          Book Another Reservation
        </button>
      </div>
    )
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-5">

      {/* Guest info header + Load Demo Data */}
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-gray-700 uppercase tracking-wide">Guest Information</h3>
        <button
          type="button"
          onClick={loadDemo}
          className="text-xs text-forest-600 hover:text-forest-800 font-medium underline underline-offset-2 transition-colors"
        >
          Load Demo Data
        </button>
      </div>

      <div className="grid grid-cols-2 gap-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">First Name *</label>
          <input
            name="firstName"
            value={values.firstName}
            onChange={handleChange}
            required
            className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-forest-500 focus:border-transparent"
            placeholder="Sarah"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Last Name *</label>
          <input
            name="lastName"
            value={values.lastName}
            onChange={handleChange}
            required
            className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-forest-500 focus:border-transparent"
            placeholder="Mitchell"
          />
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Email *</label>
          <input
            name="email"
            type="email"
            value={values.email}
            onChange={handleChange}
            required
            className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-forest-500 focus:border-transparent"
            placeholder="sarah@example.com"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Phone</label>
          <input
            name="phone"
            type="tel"
            value={values.phone}
            onChange={handleChange}
            className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-forest-500 focus:border-transparent"
            placeholder="+15555550123"
          />
        </div>
      </div>

      {/* Reservation details */}
      <div className="border-t border-gray-100 pt-5">
        <h3 className="text-sm font-semibold text-gray-700 uppercase tracking-wide mb-3">Reservation Details</h3>

        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Site Number *</label>
            <input
              name="siteNumber"
              value={values.siteNumber}
              onChange={handleChange}
              required
              className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-forest-500 focus:border-transparent"
              placeholder="A-12"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Check In *</label>
            <input
              name="checkIn"
              type="date"
              value={values.checkIn}
              onChange={handleChange}
              required
              className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-forest-500 focus:border-transparent"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Check Out *</label>
            <input
              name="checkOut"
              type="date"
              value={values.checkOut}
              onChange={handleChange}
              required
              min={values.checkIn || undefined}
              className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-forest-500 focus:border-transparent"
            />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-4 mt-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Number of Guests *</label>
            <select
              name="numGuests"
              value={values.numGuests}
              onChange={handleChange}
              className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-forest-500 focus:border-transparent"
            >
              {[1,2,3,4,5,6,7,8].map(n => (
                <option key={n} value={n}>{n} guest{n > 1 ? 's' : ''}</option>
              ))}
            </select>
          </div>
          <div className="flex flex-col justify-end">
            {nights > 0 && (
              <div className="bg-forest-50 border border-forest-100 rounded-lg px-3 py-2 text-sm">
                <span className="text-forest-600 font-medium">{nights} night{nights > 1 ? 's' : ''}</span>
                <span className="text-forest-500 mx-1">&times;</span>
                <span className="text-forest-600">${NIGHTLY_RATE}</span>
                <span className="text-forest-700 font-bold ml-2">
                  = ${(nights * NIGHTLY_RATE).toFixed(2)}
                </span>
              </div>
            )}
          </div>
        </div>

        <div className="mt-4">
          <label className="block text-sm font-medium text-gray-700 mb-1">Notes</label>
          <textarea
            name="notes"
            value={values.notes}
            onChange={handleChange}
            rows={3}
            className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-forest-500 focus:border-transparent resize-none"
            placeholder="Arriving late evening, need early check-out..."
          />
        </div>
      </div>

      {/* Error */}
      {submitError && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-red-700 text-sm">
          {submitError}
        </div>
      )}

      {/* Submit */}
      <button
        type="submit"
        disabled={submitting}
        className="w-full bg-forest-600 hover:bg-forest-700 disabled:bg-forest-300 text-white font-semibold py-3 px-6 rounded-lg transition-colors text-sm"
      >
        {submitting ? (
          <span className="flex items-center justify-center gap-2">
            <svg className="animate-spin h-4 w-4" fill="none" viewBox="0 0 24 24">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
            </svg>
            Sending to Make.com...
          </span>
        ) : (
          'Book Reservation'
        )}
      </button>

      <p className="text-xs text-gray-400 text-center">
        POSTs directly to Make.com webhook &mdash; Make.com writes to Supabase and syncs to GoHighLevel
      </p>
    </form>
  )
}
