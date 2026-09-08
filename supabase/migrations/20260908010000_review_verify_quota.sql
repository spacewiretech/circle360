-- ---------------------------------------------------------------- review verify quota
--
-- The store-review number was spending a verify attempt on *every* request, correct code
-- included, because `consume_otp_quota` is claimed before the code is compared. Ten successful
-- sign-ins in an hour therefore locked the reviewer out of their own account with a 429 — the
-- throttle firing on exactly the traffic it exists to permit.
--
-- Only a wrong guess is evidence of brute forcing, so only a wrong guess is charged here. The
-- cap itself is unchanged and still applies before the code is looked at: past the limit every
-- attempt is refused whether or not it was going to be correct, so an attacker still gets
-- p_max guesses an hour and no more. What changes is that knowing the code costs nothing.
--
-- The whole body runs in one transaction and the opening upsert takes a row lock, so concurrent
-- attempts serialise on it. A peek-then-increment split in the Edge Function could not do that:
-- N requests would all read the same count and all be let through.

create or replace function public.consume_review_verify_quota(
  p_mobile  text,
  p_correct boolean,
  p_max     integer  default 10,
  p_window  interval default interval '1 hour'
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_failures integer;
begin
  -- Claims the row (and its lock) and reports the failures already charged in the live window.
  -- Nothing is counted yet: whether this attempt is a failure is decided below.
  insert into public.otp_throttle as t (mobile_no, window_start, send_count, last_send_at)
  values (p_mobile, now(), 0, now())
  on conflict (mobile_no) do update
    set window_start = case when now() - t.window_start > p_window then now()
                            else t.window_start end,
        -- t.* is the pre-update row, so an expired window restarts at zero rather than
        -- carrying yesterday's failures into today.
        send_count   = case when now() - t.window_start > p_window then 0
                            else t.send_count end,
        last_send_at = now()
  returning t.send_count into v_failures;

  -- Refused before p_correct is consulted, so a throttled attacker gains nothing by guessing
  -- right and the 429 looks identical either way.
  if v_failures >= p_max then
    return false;
  end if;

  if p_correct then
    -- Reaching the account clears the failures behind it: a reviewer who fat-fingers the code
    -- twice and then gets it right starts their next hour with a full budget.
    update public.otp_throttle
       set send_count = 0, window_start = now()
     where mobile_no = p_mobile;
  else
    update public.otp_throttle
       set send_count = v_failures + 1
     where mobile_no = p_mobile;
  end if;

  return true;
end;
$$;

revoke all on function public.consume_review_verify_quota(text, boolean, integer, interval)
  from public, anon, authenticated;

-- The review number's counter was left at 220 by the run that surfaced this, and the old
-- number's row is dead weight now that review_mobile has moved. Neither should outlive the bug.
delete from public.otp_throttle where mobile_no like 'review-verify:%';
