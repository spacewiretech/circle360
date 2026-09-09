-- Which offer a mandate was opened on: the ₹3 trial, or the plain ₹499 month.
--
-- Until now every mandate was a trial mandate, because `subscription-start` built one shape
-- unconditionally — a user who had already spent their trial, cancelled and come back was shown
-- "₹499/month" on the paywall and then handed a ₹3-plus-₹499 mandate in their UPI app. The fix
-- branches the mandate on trial eligibility, and this is where that choice is recorded.
--
-- Recorded rather than inferred. The shape is derivable from `authorization_amount` today, but
-- only while `cashfree_trial_amount` stays at 3 — the day that config row changes, every
-- historical row would silently re-classify. Storing the intent is the honest version.

alter table public.subscriptions
  -- True for every row that existed before this migration, which is correct: they were all
  -- opened on the trial offer.
  add column if not exists is_trial boolean not null default true;

comment on column public.subscriptions.is_trial is
  'True when this mandate was opened on the ₹3 trial offer (authorisation ₹3, first debit after '
  'the trial days). False for a returning subscriber, whose authorisation is the full recurring '
  'amount and whose first recurring debit is a month out.';
