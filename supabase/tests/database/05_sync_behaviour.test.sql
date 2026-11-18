-- Sync-related behaviour: server-set updated_at, the PostgREST upsert path, grace period
-- writes, and what a lapsed user can and cannot do with their own rows.
begin;
create extension if not exists pgtap with schema extensions;

select plan(12);

insert into auth.users (id, email, aud, role) values
  ('77777777-7777-4777-8777-777777777777', 'grace@example.com', 'authenticated', 'authenticated'),
  ('88888888-8888-4888-8888-888888888888', 'lapsed@example.com', 'authenticated', 'authenticated');

insert into public.subscriptions
  (user_id, original_transaction_id, product_id, status, expires_at, is_trial, auto_renew,
   environment, app_account_token, latest_transaction_id)
values
  ('77777777-7777-4777-8777-777777777777', 'otid-grace', 'app.dayledger.pro.monthly',
   'grace_period', now() + interval '3 days', false, true, 'Production', null, 'tx-grace'),
  -- Status still says active but the period is over (e.g. a missed notification).
  ('88888888-8888-4888-8888-888888888888', 'otid-lapsed', 'app.dayledger.pro.monthly',
   'active', now() - interval '1 hour', false, false, 'Production', null, 'tx-lapsed');

insert into public.user_settings (user_id, settings)
values ('88888888-8888-4888-8888-888888888888', '{"aiAssistant":true}');
insert into public.visits (user_id, id, arrival, latitude, longitude)
values ('88888888-8888-4888-8888-888888888888', 'v-lapsed', now(), 1, 1);

-- auth.users email changes are copied to profiles.
update auth.users set email = 'grace2@example.com' where id = '77777777-7777-4777-8777-777777777777';
select is(
  (select email from public.profiles where id = '77777777-7777-4777-8777-777777777777'),
  'grace2@example.com',
  'profile email follows auth.users'
);

-- Grace period user ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}', true);

select ok(public.has_active_entitlement(), 'grace period counts as entitled');

-- The same statement PostgREST runs for POST ?on_conflict=user_id,id with merge-duplicates.
select lives_ok(
  $$insert into public.visits (user_id, id, arrival, latitude, longitude, place_name)
    values ('77777777-7777-4777-8777-777777777777', 'v1', now(), 51.5, -0.1, 'Cafe'),
           ('77777777-7777-4777-8777-777777777777', 'v2', now(), 51.5, -0.1, 'Park')
    on conflict (user_id, id) do update set place_name = excluded.place_name$$,
  'grace period user can push a batch'
);

select ok(
  (select count(distinct updated_at) = 2 from public.visits),
  'rows written in one statement get distinct updated_at values (stable sync cursor)'
);

create temporary table cursor_before on commit drop as
  select updated_at from public.visits where id = 'v1';
grant select on cursor_before to authenticated;

select lives_ok(
  $$insert into public.visits (user_id, id, arrival, latitude, longitude, place_name)
    values ('77777777-7777-4777-8777-777777777777', 'v1', now(), 51.5, -0.1, 'Cafe Nero')
    on conflict (user_id, id) do update set place_name = excluded.place_name$$,
  'upserting an existing row works'
);

select ok(
  (select v.updated_at > c.updated_at from public.visits v, cursor_before c where v.id = 'v1'),
  'an update moves updated_at forward'
);

select lives_ok(
  $$update public.visits set deleted_at = now() where id = 'v2'$$,
  'entitled user can soft-delete'
);

-- Lapsed user (status active, expires_at in the past) -----------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"88888888-8888-4888-8888-888888888888","role":"authenticated"}', true);

select ok(not public.has_active_entitlement(), 'an expired period is not entitled whatever the status');

select throws_ok(
  $$update public.user_settings set settings = '{"aiAssistant":false}'$$,
  '42501', null,
  'lapsed user cannot change settings'
);

select throws_ok(
  $$update public.visits set deleted_at = now() where id = 'v-lapsed'$$,
  '42501', null,
  'lapsed user cannot soft-delete (it is an update); hard delete is the way'
);

select lives_ok(
  $$delete from public.visits where id = 'v-lapsed'$$,
  'lapsed user can hard-delete'
);

select lives_ok(
  $$delete from public.user_settings$$,
  'lapsed user can delete their settings'
);

reset role;

select * from finish();
rollback;
