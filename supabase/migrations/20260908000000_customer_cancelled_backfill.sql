-- Repairs accounts whose mandate was cancelled from the customer's own UPI app.
--
-- Cashfree names customer-initiated states separately from merchant-initiated ones: a user who
-- revokes the UPI Autopay mandate in GPay or PhonePe lands the subscription in
-- `CUSTOMER_CANCELLED`, not `CANCELLED`. Every entitlement branch in the backend compared against
-- the merchant-initiated word, so those accounts fell through to the no-op default and kept
-- `payment_type` — a user who had cancelled went on being treated as a live subscriber, and
-- `cancelled_at` was never stamped on either table.
--
-- The code fix stops it happening again. This repairs the rows already written that way.
--
-- `CUSTOMER_PAUSED` deliberately needs no repair: pausing is not cancelling, and the correct
-- behaviour for it — entitlement simply stops advancing and lapses on its own — is what already
-- happened. The code change only adds the `billing_state = 'paused'` marker going forward.

-- Stamp the mandate's own cancellation time. `updated_at` is when we last wrote the row, which
-- for these is the sync that recorded the CUSTOMER_CANCELLED status — the closest thing to the
-- real cancellation time that was ever recorded.
update public.subscriptions
set cancelled_at = updated_at
where status = 'CUSTOMER_CANCELLED'
  and cancelled_at is null;

-- Move the account to `cancelled`. Paid time is honoured exactly as `userUpdatesFor` does it:
-- `current_period_end` is left alone, so a user who cancelled mid-month keeps the month they
-- paid for and lapses when it runs out.
--
-- Guarded on the *current* payment_type rather than applied blindly: an account that cancelled
-- one mandate and has since authorised a new one is legitimately `trial` or `active` again, and
-- must not be dragged back to cancelled by a stale row. The `not exists` clause is what
-- distinguishes the two.
update public.users u set
  payment_type = 'cancelled',
  cancelled_at = coalesce(u.cancelled_at, s.cancelled_at, s.updated_at)
from public.subscriptions s
where s.user_id = u.user_id
  and s.status = 'CUSTOMER_CANCELLED'
  and u.payment_type in ('trial', 'active')
  and not exists (
    select 1
    from public.subscriptions live
    where live.user_id = u.user_id
      and live.status in (
        'ACTIVE', 'ON_HOLD', 'PAUSED', 'CUSTOMER_PAUSED',
        'BANK_APPROVAL_PENDING', 'PENDING_AUTHORIZATION', 'INITIALIZED'
      )
  );
