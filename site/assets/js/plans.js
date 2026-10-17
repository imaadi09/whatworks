/* DISPLAY MIRROR of functions/plans.js.
 *
 * This file exists so the page can render instantly and still show something if
 * the catalogue callable is slow or unreachable. It is NOT the price: every
 * amount charged is recomputed server-side by createRazorpayOrder from planId +
 * durationMonths + modules, and any amount this page sends is ignored. Editing
 * these numbers in devtools changes what you see, never what you are charged.
 *
 * Pricing is PER MODULE: total = per-module price x selected modules.
 *
 * ⚠️ Keep in step with functions/plans.js. The page prefers the server
 * catalogue (getPlanCatalogue) and only falls back to these values, so a
 * mismatch shows up as a flicker rather than as a wrong charge.
 */

/** Modules a subscription can be bought for. Mirrors functions/plans.js. */
WW.MODULES = [
  { id: 'task', label: 'Task Management' },
  { id: 'sale', label: 'Sales' },
  { id: 'crm', label: 'CRM' },
  { id: 'inventory', label: 'Inventory' },
];

WW.PLANS_FALLBACK = {
  gstEnabled: true,
  gstRatePercent: 18,
  modules: WW.MODULES,
  // baseAmount excludes GST; totalAmount = base + 18% GST.
  plans: [
    {
      id: 'premium',
      label: 'Premium',
      currency: 'INR',
      durations: [
        {
          durationMonths: 1,
          label: 'Monthly',
          tag: null,
          baseAmount: 14900,
          gstAmount: 2682,
          totalAmount: 17582,
        },
        {
          durationMonths: 12,
          label: 'Annual',
          tag: 'Best value',
          baseAmount: 118800,
          gstAmount: 21384,
          totalAmount: 140184,
        },
      ],
    },
  ],
};

/**
 * Fetches the catalogue from the server, falling back to the mirror above.
 * Resolves with { catalogue, fromServer }.
 */
WW.loadCatalogue = function () {
  if (!WW.configured || !WW.functions) {
    return Promise.resolve({ catalogue: WW.PLANS_FALLBACK, fromServer: false });
  }
  return WW.functions
    .httpsCallable('getPlanCatalogue')({})
    .then(function (res) {
      var data = res.data;
      if (!data.modules || !data.modules.length) data.modules = WW.MODULES;
      return { catalogue: data, fromServer: true };
    })
    .catch(function (err) {
      console.warn('[WW] Falling back to the local plan mirror', err);
      return { catalogue: WW.PLANS_FALLBACK, fromServer: false };
    });
};
