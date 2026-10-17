/* Mobile + OTP sign-in for whatworks.pro.
 *
 * Same Firebase project as the app, so the same phone number resolves to the
 * same uid — a purchase made here lands on the user's existing app account with
 * no linking step.
 *
 * Web phone auth REQUIRES a reCAPTCHA verifier; invisible is used so there is
 * nothing to click in the normal case, but Firebase may still show a challenge
 * and that is not an error.
 *
 * Every OTP is a billed SMS, so the send button enforces a cooldown rather than
 * trusting the user not to hammer it.
 */
(function () {
  var RESEND_COOLDOWN_SECONDS = 45;

  var verifier = null;
  var confirmation = null;
  var cooldownTimer = null;

  WW.auth = WW.auth || null;

  /** Lazily builds the invisible reCAPTCHA, tied to a container element id. */
  function ensureVerifier(containerId) {
    if (verifier) return verifier;
    verifier = new firebase.auth.RecaptchaVerifier(containerId, {
      size: 'invisible',
    });
    return verifier;
  }

  /**
   * Turns a Firebase auth error into something a person can act on. The raw
   * messages name internal codes and would be useless on a payment page.
   */
  function describeError(err) {
    var code = (err && err.code) || '';
    switch (code) {
      case 'auth/invalid-phone-number':
        return 'That does not look like a valid mobile number.';
      case 'auth/too-many-requests':
        return 'Too many attempts. Please wait a few minutes and try again.';
      case 'auth/invalid-verification-code':
        return 'That code is not right. Check the SMS and try again.';
      case 'auth/code-expired':
        return 'That code has expired. Send a new one.';
      case 'auth/unauthorized-domain':
        return 'Sign-in is not enabled for this domain yet. Please contact support.';
      case 'auth/quota-exceeded':
        return 'We cannot send codes right now. Please try again later.';
      default:
        return (err && err.message) || 'Something went wrong. Please try again.';
    }
  }

  /**
   * Wires up an OTP form.
   *
   * Expects, by element id: phoneInput, sendBtn, otpRow (hidden until sent),
   * otpInput, verifyBtn, recaptcha (empty div), notice.
   * Calls onSignedIn(user) once sign-in succeeds.
   */
  WW.initOtpForm = function (ids, onSignedIn) {
    var phoneInput = document.getElementById(ids.phoneInput);
    var sendBtn = document.getElementById(ids.sendBtn);
    var otpRow = document.getElementById(ids.otpRow);
    var otpInput = document.getElementById(ids.otpInput);
    var verifyBtn = document.getElementById(ids.verifyBtn);
    var noticeEl = document.getElementById(ids.notice);

    if (!WW.configured) {
      WW.notice(
        noticeEl,
        'Sign-in is not configured yet. Please try again later or write to ' +
          'support@whatworks.pro.',
        'warn'
      );
      if (sendBtn) sendBtn.disabled = true;
      return;
    }

    function startCooldown() {
      var left = RESEND_COOLDOWN_SECONDS;
      sendBtn.disabled = true;
      var label = sendBtn.dataset.label || sendBtn.textContent;
      sendBtn.dataset.label = label;
      cooldownTimer = setInterval(function () {
        left -= 1;
        if (left <= 0) {
          clearInterval(cooldownTimer);
          sendBtn.disabled = false;
          sendBtn.textContent = label;
        } else {
          sendBtn.textContent = 'Resend in ' + left + 's';
        }
      }, 1000);
      sendBtn.textContent = 'Resend in ' + left + 's';
    }

    sendBtn.addEventListener('click', function () {
      var phone = WW.normalizePhone(phoneInput.value);
      if (!phone || phone.length < 12) {
        WW.notice(noticeEl, 'Enter your 10-digit mobile number.', 'error');
        return;
      }

      WW.notice(noticeEl, 'Sending code to ' + phone + '…', 'info');
      sendBtn.disabled = true;

      WW.auth
        .signInWithPhoneNumber(phone, ensureVerifier(ids.recaptcha))
        .then(function (result) {
          confirmation = result;
          otpRow.classList.remove('hidden');
          otpInput.focus();
          WW.notice(noticeEl, 'Code sent to ' + phone + '.', 'ok');
          startCooldown();
        })
        .catch(function (err) {
          console.error('[WW] OTP send failed', err);
          WW.notice(noticeEl, describeError(err), 'error');
          sendBtn.disabled = false;
          // A used-up verifier cannot be reused after a failure.
          if (verifier) {
            try {
              verifier.clear();
            } catch (e) {
              /* ignore */
            }
            verifier = null;
          }
        });
    });

    verifyBtn.addEventListener('click', function () {
      var code = (otpInput.value || '').replace(/\D/g, '');
      if (code.length < 6) {
        WW.notice(noticeEl, 'Enter the 6-digit code from the SMS.', 'error');
        return;
      }
      if (!confirmation) {
        WW.notice(noticeEl, 'Send a code first.', 'error');
        return;
      }

      verifyBtn.disabled = true;
      WW.notice(noticeEl, 'Checking code…', 'info');

      confirmation
        .confirm(code)
        .then(function (cred) {
          WW.notice(noticeEl, '', 'ok');
          if (onSignedIn) onSignedIn(cred.user);
        })
        .catch(function (err) {
          console.error('[WW] OTP verify failed', err);
          WW.notice(noticeEl, describeError(err), 'error');
          verifyBtn.disabled = false;
        });
    });

    otpInput.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') verifyBtn.click();
    });
    phoneInput.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && !sendBtn.disabled) sendBtn.click();
    });
  };

  /** Signs the user out and reloads, so no stale state survives. */
  WW.signOut = function () {
    if (!WW.auth) return;
    WW.auth.signOut().then(function () {
      window.location.reload();
    });
  };
})();
