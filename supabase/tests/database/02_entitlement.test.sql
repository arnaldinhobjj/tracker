-- has_active_entitlement(): trial/active/grace_period with a future expiry only.
begin;
create extension if not exists pgtap with schema extensions;

select plan(11);

insert into auth.users (id, email, aud, role) values
  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'e@example.com', 'authenticated', 'authenticated'),
  ('ffffffff-ffff-4fff-8fff-ffffffffffff', 'f@example.com', 'authenticated', 'authenticated');

insert into public.subscriptions
  (user_id, original_transaction_id, product_id, status, expires_at, is_trial, auto_renew,
   environment, app_account_token, latest_transaction_id)
values
  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'otid-e', 'app.dayledger.pro.monthly', 'trial',
   now() + interval '7 days', true, true, 'Sandbox', null, 'tx-e');

-- Sets E's subscription state as the service (migration owner), then checks as E.
create function pg_temp.entitled_as_e(p_status text, p_expires timestamptz)
returns boolean
language plpgsql
as $$
declare
  result boolean;
begin
  update public.subscriptions set status = p_status, expires_at = p_expires
   where user_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  perform set_config('request.jwt.claims',
    '{"sub":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","role":"authenticated"}', true);
  set local role authenticated;
  select public.has_active_entitlement() into result;
  reset role;
  return result;
end;
$$;

select is(pg_temp.entitled_as_e('trial', now() + interval '1 day'), true, 'trial in the future is entitled');
select is(pg_temp.entitled_as_e('active', now() + interval '1 day'), true, 'active in the future is entitled');
select is(pg_temp.entitled_as_e('grace_period', now() + interval '1 day'), true, 'grace period in the future is entitled');
select is(pg_temp.entitled_as_e('active', now() - interval '1 second'), false, 'active but past expiry is not entitled');
select is(pg_temp.entitled_as_e('billing_retry', now() + interval '1 day'), false, 'billing retry is not entitled');
select is(pg_temp.entitled_as_e('expired', now() + interval '1 day'), false, 'expired is not entitled');
select is(pg_temp.entitled_as_e('revoked', now() + interval '1 day'), false, 'revoked is not entitled');
select is(pg_temp.entitled_as_e('refunded', now() + interval '1 day'), false, 'refunded is not entitled');

-- F has no subscription row; E's entitlement must not leak to F.
select pg_temp.entitled_as_e('active', now() + interval '1 day');
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"ffffffff-ffff-4fff-8fff-ffffffffffff","role":"authenticated"}', true);
select is(public.has_active_entitlement(), false, 'a user without a subscription is not entitled');

-- Not signed in at all.
select set_config('request.jwt.claims', '', true);
select is(public.has_active_entitlement(), false, 'no auth.uid() means no entitlement');

reset role;
set local role anon;
select throws_ok(
  'select public.has_active_entitlement()',
  '42501', null,
  'anon cannot call has_active_entitlement'
);
reset role;

select * from finish();
rollback;
