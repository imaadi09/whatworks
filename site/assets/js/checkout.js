/* Razorpay Checkout glue.
 *
 * The browser's only jobs are: ask the server for an order, hand that order id
 * to Razorpay's widget, and then WAIT. It never states an amount, never states
 * who is paying, and never activates anything — the signature-verified webhook
 * does that. This page watching for the result is UX, not authorisation: if the
 * user closes the tab mid-payment the plan still activates.
 */
(function () {
  var POLL_INTERVAL_MS = 2000;
  var POLL_TIMEOUT_MS = 90000;

  /**
   * Starts a purchase.
   *
   * @param {Object} opts
   *   items — [{ module, planId, durationMonths }]; each module carries its
   *     own plan and duration (the server prices it; the browser never
   *     states an amount). Legacy opts planId/durationMonths/modules are
   *     still accepted for single-plan baskets.
   *   onStatus(text, kind)   — progress messages for the page
   *   onActivated(payment)   — webhook confirmed; payment doc data
   *   onFailed(text)         — terminal failure with a human message
   */
  WW.startCheckout = function (opts) {
    var status = opts.onStatus || function () {};

    if (!WW.configured) {
      if (opts.onFailed) opts.onFailed('Payments are not configured yet.');
      return;
    }
    var user = WW.auth.currentUser;
    if (!user) {
      if (opts.onFailed) opts.onFailed('Please sign in before paying.');
      return;
    }
    if (typeof Razorpay === 'undefined') {
      if (opts.onFailed) {
        opts.onFailed(
          'The payment window could not load. Check your connection and reload.'
        );
      }
      return;
    }

    status('Preparing your order…', 'info');

    WW.functions
      .httpsCallable('createRazorpayOrder')({
        items: opts.items || [],
        planId: opts.planId,
        durationMonths: opts.durationMonths,
        modules: opts.modules || [],
      })
      .then(function (res) {
        var order = res.data;
        var rzp = new Razorpay({
          key: order.keyId,
          order_id: order.orderId,
          amount: order.totalAmount,
          currency: order.currency,
          name: 'WhatWorks',
          description:
            order.items && order.items.length
              ? order.items
                  .map(function (i) {
                    return i.planLabel + ' ' + i.durationLabel;
                  })
                  .join(', ')
              : order.planLabel + ' · ' + order.durationLabel,
          prefill: { contact: user.phoneNumber || '' },
          theme: { color: '#075e54' },
          handler: function () {
            // Razorpay says the payment went through; the webhook has the last
            // word, so watch the payment doc rather than trusting this callback.
            status('Payment received. Activating your plan…', 'info');
            watchPayment(order.orderId, opts);
          },
          modal: {
            ondismiss: function () {
              status(
                'Payment window closed. Nothing has been charged unless your ' +
                  'bank says otherwise — check My Account before retrying.',
                'warn'
              );
            },
          },
        });

        rzp.on('payment.failed', function (resp) {
          var desc =
            (resp && resp.error && resp.error.description) ||
            'The payment did not go through.';
          if (opts.onFailed) opts.onFailed(desc);
        });

        status('', 'info');
        rzp.open();
      })
      .catch(function (err) {
        console.error('[WW] createRazorpayOrder failed', err);
        if (opts.onFailed) {
          opts.onFailed(
            (err && err.message) ||
              'Could not start the payment. Please try again.'
          );
        }
      });
  };

  /**
   * Waits for the webhook to flip payments/{orderId} to paid. Rules allow the
   * owner to read their own payment doc, so this needs no extra endpoint.
   *
   * A timeout here means "we have not seen it yet", NOT "it failed" — webhook
   * delivery can lag, so the message must not tell the user their money is gone.
   */
  function watchPayment(orderId, opts) {
    var ref = WW.db.collection('payments').doc(orderId);
    var startedAt = Date.now();

    var timer = setInterval(function () {
      ref
        .get()
        .then(function (snap) {
          if (!snap.exists) return;
          var data = snap.data();

          if (data.status === 'paid') {
            clearInterval(timer);
            if (opts.onActivated) opts.onActivated(data);
            return;
          }
          if (data.status === 'failed') {
            clearInterval(timer);
            if (opts.onFailed) {
              opts.onFailed(
                data.failureReason === 'amount_mismatch'
                  ? 'The amount paid did not match the order. We have not ' +
                      'activated the plan — please contact support@whatworks.pro.'
                  : 'The payment did not complete.'
              );
            }
            return;
          }

          if (Date.now() - startedAt > POLL_TIMEOUT_MS) {
            clearInterval(timer);
            if (opts.onStatus) {
              opts.onStatus(
                'Your payment is still being confirmed. This can take a minute — ' +
                  'open My Account to check, and write to support@whatworks.pro ' +
                  'if it has not activated in 15 minutes.',
                'warn'
              );
            }
          }
        })
        .catch(function (err) {
          console.error('[WW] payment poll failed', err);
        });
    }, POLL_INTERVAL_MS);
  }
})();
