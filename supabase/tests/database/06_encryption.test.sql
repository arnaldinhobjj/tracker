-- End-to-end encryption: encrypted rows carry no plaintext, legacy rows from older app versions
-- still work, an old client updating an encrypted row turns it back into a legacy row, and the
-- sync_keys registry is insert-once per user.
begin;
create extension if not exists pgtap with schema extensions;

select plan(16);

insert into auth.users (id, email, aud, role) values
  ('99999999-9999-4999-8999-999999999999', 'e2e@example.com', 'authenticated', 'authenticated'),
  ('aaaaaaaa-0000-4000-8000-000000000000', 'other@example.com', 'authenticated', 'authenticated');

insert into public.subscriptions
  (user_id, original_transaction_id, product_id, status, expires_at, is_trial, auto_renew,
   environment, app_account_token, latest_transaction_id)
values
  ('99999999-9999-4999-8999-999999999999', 'otid-e2e', 'app.dayledger.pro.monthly', 'active',
   now() + interval '30 days', false, true, 'Production', null, 'tx-e2e');

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"99999999-9999-4999-8999-999999999999","role":"authenticated"}', true);

-- What a new client sends (PostgREST upsert, every legacy column an explicit null).
select lives_ok(
  $$insert into public.transactions
      (user_id, id, key_id, payload, deleted_at, account_id, merchant, raw_description, amount_minor,
       currency, direction, bank_category, category, occurred_at, has_time, is_pending)
    values ('99999999-9999-4999-8999-999999999999', 't-enc', '0123456789abcdef0123456789abcdef',
            'v1.AAAA', null, null, null, null, null, null, null, null, null, null, null, null)
    on conflict (user_id, id) do update set key_id = excluded.key_id, payload = excluded.payload,
      merchant = excluded.merchant$$,
  'an encrypted transaction with no plaintext is accepted'
);

select throws_ok(
  $$insert into public.transactions
      (user_id, id, key_id, payload, account_id, merchant, raw_description, amount_minor, currency,
       direction, bank_category, category, occurred_at, has_time, is_pending)
    values ('99999999-9999-4999-8999-999999999999', 't-leak', '0123456789abcdef0123456789abcdef',
            'v1.AAAA', 'acc', 'Costa', 'COSTA', 340, 'GBP', 'debit', 'PURCHASE', 'coffee', now(),
            true, false)$$,
  '23514', null,
  'an encrypted row cannot also carry plaintext'
);

select throws_ok(
  $$insert into public.transactions (user_id, id, payload, has_time, is_pending)
    values ('99999999-9999-4999-8999-999999999999', 't-nokey', 'v1.AAAA', null, null)$$,
  '23514', null,
  'a payload needs its key id'
);

select throws_ok(
  $$insert into public.transactions (user_id, id, key_id, payload, has_time, is_pending)
    values ('99999999-9999-4999-8999-999999999999', 't-badkey', 'NOT-HEX', 'v1.AAAA', null, null)$$,
  '23514', null,
  'key ids are 32 lowercase hex characters'
);

select throws_ok(
  $$insert into public.transactions (user_id, id, merchant)
    values ('99999999-9999-4999-8999-999999999999', 't-empty', 'Costa')$$,
  '23514', null,
  'a row is either encrypted or a complete legacy row'
);

-- What an older app version sends.
select lives_ok(
  $$insert into public.transactions
      (user_id, id, account_id, merchant, raw_description, amount_minor, currency, direction,
       bank_category, category, occurred_at, has_time, is_pending)
    values ('99999999-9999-4999-8999-999999999999', 't-legacy', 'acc', 'Costa', 'COSTA', 340, 'GBP',
            'debit', 'PURCHASE', 'coffee', now(), true, false)$$,
  'legacy plaintext rows from older app versions are still accepted'
);

-- A new client re-encrypts the legacy row: the plaintext is erased.
select lives_ok(
  $$insert into public.transactions
      (user_id, id, key_id, payload, deleted_at, account_id, merchant, raw_description, amount_minor,
       currency, direction, bank_category, category, occurred_at, has_time, is_pending)
    values ('99999999-9999-4999-8999-999999999999', 't-legacy', '0123456789abcdef0123456789abcdef',
            'v1.BBBB', null, null, null, null, null, null, null, null, null, null, null, null)
    on conflict (user_id, id) do update set key_id = excluded.key_id, payload = excluded.payload,
      deleted_at = excluded.deleted_at, account_id = excluded.account_id,
      merchant = excluded.merchant, raw_description = excluded.raw_description,
      amount_minor = excluded.amount_minor, currency = excluded.currency,
      direction = excluded.direction, bank_category = excluded.bank_category,
      category = excluded.category, occurred_at = excluded.occurred_at,
      has_time = excluded.has_time, is_pending = excluded.is_pending$$,
  're-uploading a legacy row encrypted works'
);

select ok(
  (select merchant is null and amount_minor is null and payload = 'v1.BBBB'
     from public.transactions where id = 't-legacy'),
  're-encrypting erases the plaintext'
);

-- An older app version then updates the same row (it never touches payload/key_id).
select lives_ok(
  $$insert into public.transactions
      (user_id, id, account_id, merchant, raw_description, amount_minor, currency, direction,
       bank_category, category, occurred_at, has_time, is_pending)
    values ('99999999-9999-4999-8999-999999999999', 't-legacy', 'acc', 'Costa Coffee', 'COSTA', 350,
            'GBP', 'debit', 'PURCHASE', 'coffee', now(), true, false)
    on conflict (user_id, id) do update set account_id = excluded.account_id,
      merchant = excluded.merchant, raw_description = excluded.raw_description,
      amount_minor = excluded.amount_minor, currency = excluded.currency,
      direction = excluded.direction, bank_category = excluded.bank_category,
      category = excluded.category, occurred_at = excluded.occurred_at,
      has_time = excluded.has_time, is_pending = excluded.is_pending$$,
  'an older app version can still update a row a newer one encrypted'
);

select ok(
  (select payload is null and key_id is null and merchant = 'Costa Coffee'
     from public.transactions where id = 't-legacy'),
  'that update turns the row back into a legacy row (stale ciphertext dropped)'
);

-- Visits: same rules.
select lives_ok(
  $$insert into public.visits
      (user_id, id, key_id, payload, deleted_at, arrival, departure, latitude, longitude, place_name,
       place_category, is_named_place, is_resolved, calendar_event_id, calendar_content_hash,
       calendar_synced_at)
    values ('99999999-9999-4999-8999-999999999999', 'v-enc', '0123456789abcdef0123456789abcdef',
            'v1.CCCC', null, null, null, null, null, null, null, null, null, null, null, null)$$,
  'an encrypted visit with no coordinates is accepted'
);

select throws_ok(
  $$insert into public.visits (user_id, id, key_id, payload, latitude, longitude, is_named_place, is_resolved)
    values ('99999999-9999-4999-8999-999999999999', 'v-leak', '0123456789abcdef0123456789abcdef',
            'v1.CCCC', 51.5, -0.1, null, null)$$,
  '23514', null,
  'an encrypted visit cannot carry coordinates'
);

-- sync_keys -----------------------------------------------------------------------------------
select lives_ok(
  $$insert into public.sync_keys (user_id, key_id)
    values ('99999999-9999-4999-8999-999999999999', '0123456789abcdef0123456789abcdef')
    on conflict (user_id) do nothing$$,
  'a user can register their key id'
);

select lives_ok(
  $$insert into public.sync_keys (user_id, key_id)
    values ('99999999-9999-4999-8999-999999999999', 'ffffffffffffffffffffffffffffffff')
    on conflict (user_id) do nothing$$,
  'a second registration is ignored (first device wins)'
);

select is(
  (select key_id from public.sync_keys),
  '0123456789abcdef0123456789abcdef',
  'the first key id is kept'
);

select throws_ok(
  $$insert into public.sync_keys (user_id, key_id)
    values ('aaaaaaaa-0000-4000-8000-000000000000', '0123456789abcdef0123456789abcdef')$$,
  '42501', null,
  'nobody can register a key for another user'
);

reset role;

select * from finish();
rollback;
