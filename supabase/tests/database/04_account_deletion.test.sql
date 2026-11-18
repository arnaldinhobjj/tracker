-- Deleting the auth user (what the delete-account function does) removes every row they own.
begin;
create extension if not exists pgtap with schema extensions;

select plan(8);

insert into auth.users (id, email, aud, role) values
  ('44444444-4444-4444-8444-444444444444', 'h@example.com', 'authenticated', 'authenticated'),
  ('55555555-5555-4555-8555-555555555555', 'i@example.com', 'authenticated', 'authenticated');

insert into public.subscriptions
  (user_id, original_transaction_id, product_id, status, expires_at, environment,
   latest_transaction_id)
values
  ('44444444-4444-4444-8444-444444444444', 'otid-h', 'app.dayledger.pro.monthly', 'active',
   now() + interval '1 month', 'Production', 'tx-h'),
  ('55555555-5555-4555-8555-555555555555', 'otid-i', 'app.dayledger.pro.monthly', 'active',
   now() + interval '1 month', 'Production', 'tx-i');

insert into public.transactions
  (user_id, id, account_id, merchant, raw_description, amount_minor, currency, direction,
   bank_category, category, occurred_at)
values
  ('44444444-4444-4444-8444-444444444444', 'a:1', 'a', 'M', 'M', 1, 'GBP', 'debit', 'X', 'other', now()),
  ('55555555-5555-4555-8555-555555555555', 'a:1', 'a', 'M', 'M', 1, 'GBP', 'debit', 'X', 'other', now());

insert into public.visits (user_id, id, arrival, latitude, longitude)
values ('44444444-4444-4444-8444-444444444444', 'v1', now(), 0, 0);

insert into public.user_settings (user_id, settings)
values ('44444444-4444-4444-8444-444444444444', '{"aiAssistant":false}');

insert into public.app_store_notifications
  (notification_uuid, notification_type, original_transaction_id, signed_date, payload, user_id)
values ('66666666-6666-4666-8666-666666666666', 'DID_RENEW', 'otid-h', now(), '{}',
  '44444444-4444-4444-8444-444444444444');

delete from auth.users where id = '44444444-4444-4444-8444-444444444444';

select is((select count(*)::int from public.profiles where id = '44444444-4444-4444-8444-444444444444'), 0, 'profile deleted');
select is((select count(*)::int from public.transactions where user_id = '44444444-4444-4444-8444-444444444444'), 0, 'transactions deleted');
select is((select count(*)::int from public.visits where user_id = '44444444-4444-4444-8444-444444444444'), 0, 'visits deleted');
select is((select count(*)::int from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'), 0, 'settings deleted');
select is((select count(*)::int from public.subscriptions where user_id = '44444444-4444-4444-8444-444444444444'), 0, 'subscription deleted');
select is((select count(*)::int from public.app_store_notifications where user_id = '44444444-4444-4444-8444-444444444444'), 0, 'notification log entries deleted');
select is((select count(*)::int from public.transactions where user_id = '55555555-5555-4555-8555-555555555555'), 1, 'other users'' data untouched');
select is((select count(*)::int from public.subscriptions where user_id = '55555555-5555-4555-8555-555555555555'), 1, 'other users'' subscription untouched');

select * from finish();
rollback;
