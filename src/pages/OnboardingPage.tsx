import { useEffect, useState } from 'react'
import { useAuth } from '../context/AuthProvider'
import { getOnboardingReadiness } from '../api/onboarding'
import type { OnboardingStep } from '../lib/types'
import { Card } from '../components/ui/Card'
import { PageHeader } from '../components/common/PageHeader'
import { DataState } from '../components/common/DataState'

// Single readiness row: status marker + label/description + evidence detail.
function StepRow({ step, index }: { step: OnboardingStep; index: number }) {
  const isGoLive = step.key === 'go_live'
  return (
    <div className="flex items-start gap-4 py-4 border-b border-gray-50 last:border-0">
      <div
        className={`mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-sm font-semibold ${
          step.complete
            ? 'bg-green-100 text-green-700'
            : 'bg-gray-100 text-gray-400'
        }`}
        aria-hidden
      >
        {step.complete ? '✓' : index + 1}
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <h3 className={`font-medium ${isGoLive ? 'text-forest-700' : 'text-gray-900'}`}>{step.label}</h3>
        </div>
        <p className="text-sm text-gray-500 mt-0.5">{step.description}</p>
      </div>
      <div className="shrink-0 text-right">
        <span
          className={`inline-block px-2 py-0.5 rounded-full text-xs font-medium ${
            step.complete ? 'bg-green-100 text-green-700' : 'bg-gray-100 text-gray-500'
          }`}
        >
          {step.complete ? 'Complete' : 'Pending'}
        </span>
        <p className="text-xs text-gray-400 mt-1 tabular-nums">{step.detail}</p>
      </div>
    </div>
  )
}

export function OnboardingPage() {
  const { orgId } = useAuth()

  const [steps, setSteps] = useState<OnboardingStep[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    setLoading(true)
    setError(null)
    getOnboardingReadiness(orgId)
      .then((s) => { if (active) setSteps(s) })
      .catch((e: unknown) => { if (active) setError(e instanceof Error ? e.message : 'Failed to load onboarding readiness') })
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [orgId])

  // Progress is measured over the six setup steps (exclude the Go Live roll-up).
  const setupSteps = steps.filter((s) => s.key !== 'go_live')
  const completed = setupSteps.filter((s) => s.complete).length
  const total = setupSteps.length
  const pct = total === 0 ? 0 : Math.round((completed / total) * 100)
  const readyForGoLive = steps.find((s) => s.key === 'go_live')?.complete ?? false

  return (
    <div className="space-y-6">
      <PageHeader
        title="Onboarding Readiness"
        subtitle="Read-only — derived from your live organization, team, integrations, guests, and reservations"
      />
      <DataState loading={loading} error={error}>
        <div className="space-y-6">

          {/* Progress summary */}
          <Card>
            <div className="flex items-center justify-between mb-3">
              <div>
                <h2 className="font-semibold text-gray-900">Setup Progress</h2>
                <p className="text-sm text-gray-500 mt-0.5">
                  {completed} of {total} steps complete
                </p>
              </div>
              <span
                className={`inline-block px-3 py-1 rounded-full text-sm font-semibold ${
                  readyForGoLive ? 'bg-green-100 text-green-700' : 'bg-yellow-100 text-yellow-700'
                }`}
              >
                {readyForGoLive ? 'Ready for Go Live' : `${pct}% ready`}
              </span>
            </div>
            <div className="h-2 w-full rounded-full bg-gray-100 overflow-hidden">
              <div
                className="h-full rounded-full bg-forest-600 transition-all"
                style={{ width: `${pct}%` }}
              />
            </div>
          </Card>

          {/* Checklist */}
          <Card padding="sm">
            <div className="px-2">
              {steps.map((step, i) => (
                <StepRow key={step.key} step={step} index={i} />
              ))}
            </div>
          </Card>

        </div>
      </DataState>
    </div>
  )
}
