/* Firebase web config for whatworks.pro.
 *
 * These values are PUBLIC by design — every Firebase web app ships them in the
 * page. Security comes from firestore.rules and the Cloud Functions, never from
 * hiding this file. Nothing secret (razorpay key_secret, webhook_secret) may
 * ever be added here: anything under site/ is world-readable.
 *
 * ⚠️ NOT YET FILLED IN. The Firebase project has no WEB app registered — the
 * Flutter app only has Android config, and lib/config/firebase_options.dart
 * throws UnsupportedError for web. Before this site can log anyone in:
 *
 *   1. Firebase console → Project settings → Your apps → Add app → Web.
 *      Copy the generated config over the placeholders below.
 *      Project: whatworks-68786 (must be the SAME project as the app, or the
 *      same phone number would resolve to a DIFFERENT uid and purchases would
 *      land on an account the app cannot see).
 *   2. Authentication → Settings → Authorized domains: add whatworks.pro and
 *      the *.web.app preview domain, or OTP fails with auth/unauthorized-domain.
 *   3. Authentication → Sign-in method → Phone must be enabled.
 *
 * Until then the pages show a "sign-in not configured yet" notice instead of
 * failing with a console error nobody sees.
 */
var FIREBASE_CONFIG = {
  // Web-app specific — only the console can give you these two.
  apiKey: '[[WEB_API_KEY]]',
  appId: '[[WEB_APP_ID]]',
  // Project-wide values, copied from lib/config/firebase_options.dart.
  authDomain: 'whatworks-68786.firebaseapp.com',
  projectId: 'whatworks-68786',
  storageBucket: 'whatworks-68786.firebasestorage.app',
  messagingSenderId: '1040733002072',
};

/* Shared namespace for the other scripts on the page. */
window.WW = window.WW || {};

WW.configured =
  FIREBASE_CONFIG.apiKey.indexOf('[[') !== 0 &&
  FIREBASE_CONFIG.appId.indexOf('[[') !== 0;

if (WW.configured) {
  firebase.initializeApp(FIREBASE_CONFIG);
  WW.auth = firebase.auth();
  WW.db = firebase.firestore();
  // Region must match the deployed functions (firebase-functions v1 default).
  WW.functions = firebase.functions();
} else {
  console.warn(
    '[WW] Firebase web config is still a placeholder — register a Web app in ' +
      'the Firebase console and fill in site/assets/js/firebase-init.js'
  );
}

/* ---------- small shared helpers ---------- */

/** Paise → "₹1,299" / "₹1,299.50". Money is stored as integer paise. */
WW.formatPaise = function (paise) {
  var rupees = (Number(paise) || 0) / 100;
  var hasPaise = Number(paise) % 100 !== 0;
  return (
    '₹' +
    rupees.toLocaleString('en-IN', {
      minimumFractionDigits: hasPaise ? 2 : 0,
      maximumFractionDigits: 2,
    })
  );
};

/**
 * E.164 normalisation that mirrors Helpers.normalizePhone in the app
 * (lib/utils/helpers.dart). It must agree exactly: Firebase derives the uid
 * from the number used at OTP time, so "9876543210" and "+919876543210" must
 * become the same string or the site would create a second account.
 */
WW.normalizePhone = function (input) {
  if (!input) return null;
  var cleaned = String(input).replace(/[^\d+]/g, '');
  if (!cleaned) return null;
  if (cleaned.charAt(0) === '+') cleaned = cleaned.substring(1);
  while (cleaned.charAt(0) === '0') cleaned = cleaned.substring(1);
  if (!cleaned) return null;
  if (cleaned.length <= 12 && cleaned.indexOf('91') !== 0) {
    cleaned = '91' + cleaned;
  }
  return '+' + cleaned;
};

/** "12 Aug 2026" — used for plan expiry and invoice dates. */
WW.formatDate = function (date) {
  if (!date) return '—';
  return date.toLocaleDateString('en-IN', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  });
};

/** Shows a message in the given .notice element, or hides it when text is falsy. */
WW.notice = function (el, text, kind) {
  if (!el) return;
  if (!text) {
    el.classList.add('hidden');
    return;
  }
  el.className = 'notice ' + (kind || 'info');
  el.textContent = text;
};
