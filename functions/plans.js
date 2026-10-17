/**
 * PLAN CATALOGUE — the only authority for money.
 *
 * Every amount charged is computed here, server-side, from `planId` +
 * `durationMonths`. `site/assets/js/plans.js` is a DISPLAY MIRROR: a tampered
 * browser can change what the user sees, never what they are charged, because
 * createRazorpayOrder ignores any amount the client sends.
 *
 * Amounts are in PAISE (integers) — Razorpay transacts in the smallest currency
 * unit, and floats have no business anywhere near a price.
 *
 * ⚠️ PLACEHOLDER PRICES. The totals below were invented to be plausible;
 * confirm them against your costs before going live. Changing a price here is
 * safe at any time: it affects new orders only, since each payments/{orderId}
 * doc stores the amount it was created with.
 */

/**
 * GST configuration.
 *
 * Prices in the catalogue EXCLUDE GST; the charged total is the price plus
 * GST at `ratePercent` ("149 + GST").
 *
 * ⚠️ Fill in `gstin` before charging GST — collecting tax without a
 * registration is illegal. It is printed on invoices when set.
 */
const GST = {
  enabled: true,
  ratePercent: 18,
  gstin: '', // e.g. '09ABCDE1234F1Z5' — fill in once registered
};

/**
 * One paid tier. `grantsPlanType` is the value written to
 * users/{uid}.planType on activation and must match what the app gates on
 * (lib/utils/paywall_constants.dart → 'premium').
 */
/**
 * Modules a subscription can be bought for. Pricing is PER MODULE: the total
 * for an order is the plan price x number of selected modules.
 */
const MODULES = [
  { id: 'task', label: 'Task Management' },
  { id: 'sale', label: 'Sales' },
  { id: 'crm', label: 'CRM' },
  { id: 'inventory', label: 'Inventory' },
];

const PLANS = {
  premium: {
    id: 'premium',
    label: 'Premium',
    grantsPlanType: 'premium',
    currency: 'INR',
    // durationMonths -> base price PER MODULE in paise (excludes GST)
    durations: {
      1: { label: 'Monthly', totalAmount: 14900 },
      12: { label: 'Annual', totalAmount: 118800, tag: 'Best value' },
    },
  },
};

/**
 * Adds GST on top of a base price ("149 + GST").
 * Returns integers that always satisfy base + gst === total, so no rounding
 * error can make the invoice disagree with the amount debited.
 */
function addGst(baseAmount) {
  if (!GST.enabled) {
    return { baseAmount, gstAmount: 0, totalAmount: baseAmount };
  }
  const gstAmount = Math.round((baseAmount * GST.ratePercent) / 100);
  return { baseAmount, gstAmount, totalAmount: baseAmount + gstAmount };
}

/**
 * Resolves a plan + duration to the exact amounts to charge.
 * Returns null for anything not in the catalogue — callers must treat null as
 * "reject the request", never as "use a default".
 *
 * Pricing is PER MODULE: pass `moduleCount` for multi-module orders and the
 * base/gst/total amounts come back multiplied. Defaults to one module.
 *
 * @param {string} planId
 * @param {number|string} durationMonths
 * @param {number} [moduleCount]
 */
function priceFor(planId, durationMonths, moduleCount = 1) {
  const count = Number(moduleCount);
  if (!Number.isInteger(count) || count < 1 || count > MODULES.length) {
    return null;
  }
  const plan = PLANS[planId];
  if (!plan) return null;

  // Object keys are strings; the client may send either 6 or '6'.
  const months = Number(durationMonths);
  if (!Number.isInteger(months)) return null;

  const duration = plan.durations[String(months)];
  if (!duration) return null;

  // Catalogue prices exclude GST; the charged total adds it on top.
  const { baseAmount, gstAmount, totalAmount } = addGst(
    duration.totalAmount * count
  );
  return {
    planId: plan.id,
    planLabel: plan.label,
    grantsPlanType: plan.grantsPlanType,
    durationMonths: months,
    durationLabel: duration.label,
    moduleCount: count,
    currency: plan.currency,
    baseAmount,
    gstAmount,
    totalAmount,
    gstEnabled: GST.enabled,
    gstRatePercent: GST.ratePercent,
  };
}

/**
 * The catalogue in a shape the website can render, with the tax split already
 * computed. Amounts stay in paise; formatting is the page's job.
 */
function publicCatalogue() {
  return {
    modules: MODULES,
    gstEnabled: GST.enabled,
    gstRatePercent: GST.ratePercent,
    plans: Object.values(PLANS).map((plan) => ({
      id: plan.id,
      label: plan.label,
      currency: plan.currency,
      durations: Object.keys(plan.durations)
        .map(Number)
        .sort((a, b) => a - b)
        .map((months) => {
          const price = priceFor(plan.id, months);
          return {
            durationMonths: months,
            label: plan.durations[String(months)].label,
            tag: plan.durations[String(months)].tag || null,
            baseAmount: price.baseAmount,
            gstAmount: price.gstAmount,
            totalAmount: price.totalAmount,
          };
        }),
    })),
  };
}

/**
 * Prices a mixed basket where each module carries its OWN plan and
 * duration. items: [{ module, planId, durationMonths }]
 * Returns null if any item is invalid or a module repeats — callers must
 * treat null as "reject the request", never as "use a default".
 */
function priceForItems(items) {
  if (!Array.isArray(items) || items.length === 0 || items.length > MODULES.length) {
    return null;
  }
  const seen = new Set();
  let baseAmount = 0;
  const perItem = [];
  for (const raw of items) {
    const module = String((raw && raw.module) || '');
    if (!MODULES.some((m) => m.id === module) || seen.has(module)) return null;
    const p = priceFor(raw && raw.planId, raw && raw.durationMonths, 1);
    if (!p) return null;
    seen.add(module);
    baseAmount += p.baseAmount;
    perItem.push({
      module,
      planId: p.planId,
      planLabel: p.planLabel,
      grantsPlanType: p.grantsPlanType,
      durationMonths: p.durationMonths,
      durationLabel: p.durationLabel,
      currency: p.currency,
      baseAmount: p.baseAmount,
      gstAmount: p.gstAmount,
      totalAmount: p.totalAmount,
    });
  }
  const summed = addGst(baseAmount);
  return {
    baseAmount,
    gstAmount: summed.gstAmount,
    totalAmount: summed.totalAmount,
    currency: perItem[0].currency,
    gstEnabled: GST.enabled,
    gstRatePercent: GST.ratePercent,
    perItem,
  };
}

module.exports = {
  GST,
  MODULES,
  PLANS,
  addGst,
  priceFor,
  priceForItems,
  publicCatalogue,
};
