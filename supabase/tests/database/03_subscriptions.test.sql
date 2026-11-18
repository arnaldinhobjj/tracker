-- Clients can read but never write their subscription, and never touch the notification log.
begin;
create extension if not exists pgtap with schema extensions;

select plan(7);

insert into auth.users (id, email, aud, role) values
  ('11111111-1111-4111-8111-111111111111', 'g@example.com', 'authenticated', 'authenticated');

insert into public.subscriptions
  (user_id, original_transaction_id, product_id, status, expires_at, is_trial, auto_renew,
   environment, app_account_token, latest_transaction_id)
values
  ('11111111-1111-4111-8111-111111111111', 'otid-g', 'app.dayledger.pro.monthly', 'expired',
   now() - interval '1 day', false, false, 'Production', null, 'tx-g');

insert into public.app_store_notifications
  (notification_uuid, notification_type, subtype, original_transaction_id, signed_date, payload)
values
  ('22222222-2222-4222-8222-222222222222', 'EXPIRED', 'VOLUNTARY', 'otid-g', now(), '{}');

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

select is((select status from public.subscriptions), 'expired', 'user can read their subscription');

select throws_ok(
  $$update public.subscriptions set status = 'active', expires_at = now() + interval '1 year'$$,
  '42501', null,
  'user cannot grant themselves an active subscription'
);
select throws_ok(
  $$insert into public.subscriptions
      (user_id, original_transaction_id, product_id, status, expires_at, environment,
       latest_transaction_id)
    values ('11111111-1111-4111-8111-111111111111', 'otid-x', 'p', 'active',
       now() + interval '1 year', 'Production', 'x')$$,
  '42501', null,
  'user cannot insert a subscription'
);
select throws_ok(
  'delete from public.subscriptions',
  '42501', null,
  'user cannot delete their subscription row'
);
select throws_ok(
  'select * from public.app_store_notifications',
  '42501', null,
  'user cannot read the notification log'
);
select throws_ok(
  $$insert into public.app_store_notifications
      (notification_uuid, notification_type, signed_date, payload)
    values ('33333333-3333-4333-8333-333333333333', 'TEST', now(), '{}')$$,
  '42501', null,
  'user cannot write the notification log'
);
select is(public.has_active_entitlement(), false, 'still not entitled after the failed writes');

reset role;

select * from finish();
rollback;
