-- Row level security: users only ever see and change their own rows, writes need an
-- entitlement, deletes do not.
begin;
create extension if not exists pgtap with schema extensions;

select plan(28);

-- Fixtures (as the migration owner, which bypasses RLS) --------------------------------------
-- A: entitled (trial). B: entitled (active). C: no subscription. D: lapsed (expired).
insert into auth.users (id, email, aud, role) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'a@example.com', 'authenticated', 'authenticated'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'b@example.com', 'authenticated', 'authenticated'),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'c@example.com', 'authenticated', 'authenticated'),
  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'd@example.com', 'authenticated', 'authenticated');

insert into public.subscriptions
  (user_id, original_transaction_id, product_id, status, expires_at, is_trial, auto_renew,
   environment, app_account_token, latest_transaction_id)
values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'otid-a', 'app.dayledger.pro.monthly', 'trial',
   now() + interval '7 days', true, true, 'Sandbox', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'tx-a'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'otid-b', 'app.dayledger.pro.monthly', 'active',
   now() + interval '30 days', false, true, 'Production', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'tx-b'),
  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'otid-d', 'app.dayledger.pro.monthly', 'expired',
   now() - interval '1 day', false, false, 'Production', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'tx-d');

insert into public.transactions
  (user_id, id, account_id, merchant, raw_description, amount_minor, currency, direction,
   bank_category, category, occurred_at, has_time, is_pending)
values
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'acc-b:tx-1', 'acc-b', 'Tesco', 'TESCO STORES', 1234,
   'GBP', 'debit', 'GROCERIES', 'groceries', now(), true, false),
  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'acc-d:tx-1', 'acc-d', 'Pret', 'PRET A MANGER', 450,
   'GBP', 'debit', 'EATING_OUT', 'coffee', now(), true, false);

insert into public.visits (user_id, id, arrival, latitude, longitude, place_name)
values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'visit-b-1', now(), 51.5, -0.12, 'Office');

-- Profiles are created by the auth.users trigger --------------------------------------------
select is(
  (select count(*)::int from public.profiles where id in (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd')),
  4,
  'a profile is created for every new auth user'
);

-- Act as user A --------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"authenticated"}', true);

select is((select count(*)::int from public.transactions), 0, 'A cannot see B''s transactions');
select is((select count(*)::int from public.visits), 0, 'A cannot see B''s visits');
select is((select count(*)::int from public.profiles), 1, 'A only sees their own profile');
select is((select count(*)::int from public.subscriptions), 1, 'A only sees their own subscription');

select lives_ok(
  $$insert into public.transactions
      (user_id, id, account_id, merchant, raw_description, amount_minor, currency, direction,
       bank_category, category, occurred_at, has_time, is_pending, updated_at)
    values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'acc-a:tx-1', 'acc-a', 'Costa', 'COSTA', 350,
       'GBP', 'debit', 'EATING_OUT', 'coffee', now(), true, false, '2000-01-01')$$,
  'entitled A can insert their own transaction'
);

select ok(
  (select updated_at > '2001-01-01' from public.transactions where id = 'acc-a:tx-1'),
  'updated_at is set by the server, not the client'
);

select lives_ok(
  $$insert into public.transactions
      (id, account_id, merchant, raw_description, amount_minor, currency, direction,
       bank_category, category, occurred_at)
    values ('acc-a:tx-2', 'acc-a', 'Costa', 'COSTA', 350, 'GBP', 'debit', 'EATING_OUT', 'coffee', now())
    on conflict (user_id, id) do update set merchant = excluded.merchant$$,
  'user_id defaults to the caller and upsert (on conflict user_id,id) works'
);

select throws_ok(
  $$insert into public.transactions
      (user_id, id, account_id, merchant, raw_description, amount_minor, currency, direction,
       bank_category, category, occurred_at)
    values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'acc-b:evil', 'acc-b', 'X', 'X', 1, 'GBP',
       'debit', 'X', 'other', now())$$,
  '42501', null,
  'A cannot insert a transaction for B'
);

select lives_ok(
  $$insert into public.visits (user_id, id, arrival, latitude, longitude)
    values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'visit-a-1', now(), 51.5, -0.1)$$,
  'entitled A can insert their own visit'
);

select lives_ok(
  $$insert into public.user_settings (user_id, settings)
    values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '{"locationLogging":true}')$$,
  'entitled A can insert their own settings'
);

select throws_ok(
  $$insert into public.user_settings (user_id, settings)
    values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '{}')$$,
  '42501', null,
  'A cannot insert settings for B'
);

-- Attempts on B's rows silently match nothing.
update public.transactions set merchant = 'hacked' where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
delete from public.transactions where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
delete from public.visits where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

select throws_ok(
  $$update public.transactions set user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     where id = 'acc-a:tx-1'$$,
  '42501', null,
  'A cannot move their row to B'
);

select lives_ok(
  $$update public.profiles set display_name = 'Alice' where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'$$,
  'A can update their display name'
);

select throws_ok(
  $$update public.profiles set email = 'x@example.com' where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'$$,
  '42501', null,
  'A cannot change the email copied from auth.users'
);

reset role;

select is(
  (select merchant from public.transactions where id = 'acc-b:tx-1'),
  'Tesco',
  'B''s transaction was not modified by A'
);
select is(
  (select count(*)::int from public.visits where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  1,
  'B''s visit was not deleted by A'
);

-- Act as user C (signed in, never subscribed) ------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","role":"authenticated"}', true);

select throws_ok(
  $$insert into public.transactions
      (user_id, id, account_id, merchant, raw_description, amount_minor, currency, direction,
       bank_category, category, occurred_at)
    values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'acc-c:tx-1', 'acc-c', 'X', 'X', 1, 'GBP',
       'debit', 'X', 'other', now())$$,
  '42501', null,
  'C without an entitlement cannot insert transactions'
);
select throws_ok(
  $$insert into public.visits (user_id, id, arrival, latitude, longitude)
    values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'visit-c-1', now(), 1, 1)$$,
  '42501', null,
  'C without an entitlement cannot insert visits'
);
select throws_ok(
  $$insert into public.user_settings (user_id, settings)
    values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '{}')$$,
  '42501', null,
  'C without an entitlement cannot insert settings'
);

-- Act as user D (lapsed) ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","role":"authenticated"}', true);

select is((select count(*)::int from public.transactions), 1, 'lapsed D can still read their data');

select throws_ok(
  $$update public.transactions set merchant = 'Pret A Manger' where id = 'acc-d:tx-1'$$,
  '42501', null,
  'lapsed D cannot update their data'
);

select throws_ok(
  $$insert into public.transactions
      (user_id, id, account_id, merchant, raw_description, amount_minor, currency, direction,
       bank_category, category, occurred_at)
    values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'acc-d:tx-2', 'acc-d', 'X', 'X', 1, 'GBP',
       'debit', 'X', 'other', now())$$,
  '42501', null,
  'lapsed D cannot insert data'
);

select lives_ok(
  $$delete from public.transactions where id = 'acc-d:tx-1'$$,
  'lapsed D can delete their own data'
);

select is((select count(*)::int from public.transactions), 0, 'D''s transaction is gone');

-- Act as anon ---------------------------------------------------------------------------------
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

select throws_ok('select * from public.transactions', '42501', null, 'anon cannot read transactions');
select throws_ok('select * from public.profiles', '42501', null, 'anon cannot read profiles');
select throws_ok('select * from public.subscriptions', '42501', null, 'anon cannot read subscriptions');

reset role;

select * from finish();
rollback;
