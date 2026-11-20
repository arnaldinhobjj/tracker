-- Recovery key copies: own row only, tied to the account's current sync key, replaced in place,
-- and deleted when the user starts encryption over.
begin;
create extension if not exists pgtap with schema extensions;

select plan(10);

insert into auth.users (id, email, aud, role) values
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'recovery@example.com', 'authenticated', 'authenticated'),
  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'someone@example.com', 'authenticated', 'authenticated');

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","role":"authenticated"}', true);

insert into public.sync_keys (user_id, key_id)
  values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '0123456789abcdef0123456789abcdef');

select throws_ok(
  $$insert into public.sync_key_recovery (user_id, key_id, wrapped_key)
    values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'ffffffffffffffffffffffffffffffff', 'v1.AAAA')$$,
  '23503', null,
  'a recovery copy must be for the account''s current key'
);

select lives_ok(
  $$insert into public.sync_key_recovery (user_id, key_id, wrapped_key)
    values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '0123456789abcdef0123456789abcdef', 'v1.AAAA')$$,
  'the user stores a recovery copy of their key'
);

-- What the app sends to replace it (PostgREST upsert, merge-duplicates).
select lives_ok(
  $$insert into public.sync_key_recovery (user_id, key_id, wrapped_key)
    values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '0123456789abcdef0123456789abcdef', 'v1.BBBB')
    on conflict (user_id) do update set key_id = excluded.key_id, wrapped_key = excluded.wrapped_key$$,
  'a new recovery key replaces the old copy'
);
select is(
  (select wrapped_key from public.sync_key_recovery),
  'v1.BBBB',
  'one copy, the newest'
);

select throws_ok(
  $$insert into public.sync_key_recovery (user_id, key_id, wrapped_key)
    values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '0123456789abcdef0123456789abcdef', 'not a payload')
    on conflict (user_id) do update set wrapped_key = excluded.wrapped_key$$,
  '23514', null,
  'only sealed payloads are stored'
);

select throws_ok(
  $$insert into public.sync_key_recovery (user_id, key_id, wrapped_key)
    values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', '0123456789abcdef0123456789abcdef', 'v1.AAAA')$$,
  '42501', null,
  'nobody can store a copy for someone else'
);

-- Another user sees nothing.
select set_config('request.jwt.claims',
  '{"sub":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","role":"authenticated"}', true);
select is((select count(*)::int from public.sync_key_recovery), 0, 'another user can''t read the copy');

-- Starting over deletes the key registration, and the recovery copy with it.
select set_config('request.jwt.claims',
  '{"sub":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","role":"authenticated"}', true);
delete from public.sync_keys where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
select is((select count(*)::int from public.sync_key_recovery), 0, 'starting over removes the recovery copy');

reset role;
set local role anon;
select throws_ok(
  $$select * from public.sync_key_recovery$$,
  '42501', null,
  'signed-out clients have no access'
);
reset role;

-- Deleting the account removes everything.
insert into public.sync_keys (user_id, key_id)
  values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '0123456789abcdef0123456789abcdef');
insert into public.sync_key_recovery (user_id, key_id, wrapped_key)
  values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '0123456789abcdef0123456789abcdef', 'v1.CCCC');
delete from auth.users where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
select is((select count(*)::int from public.sync_key_recovery), 0, 'account deletion cascades');

select * from finish();
rollback;
