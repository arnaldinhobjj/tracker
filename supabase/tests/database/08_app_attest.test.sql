-- App Attest keys and challenges: one-use challenges, counters that only go up, and nothing
-- visible or callable for clients.
begin;
create extension if not exists pgtap with schema extensions;

select plan(11);

-- As the service role (the Edge Functions).
insert into public.app_attest_challenges (challenge, expires_at) values
  ('fresh', now() + interval '5 minutes'),
  ('stale', now() - interval '1 minute');

select ok(public.consume_app_attest_challenge('fresh'), 'a fresh challenge can be used');
select ok(not public.consume_app_attest_challenge('fresh'), 'but only once');
select ok(not public.consume_app_attest_challenge('stale'), 'an expired challenge cannot be used');
select is((select count(*)::int from public.app_attest_challenges), 0, 'expired challenges are cleaned up');

insert into public.app_attest_keys (key_id, public_key, environment) values ('key-1', 'spki', 'production');

select ok(public.advance_app_attest_counter('key-1', 1), 'a higher counter is stored');
select ok(not public.advance_app_attest_counter('key-1', 1), 'the same counter is refused (replay)');
select ok(not public.advance_app_attest_counter('key-1', 0), 'a lower counter is refused');
select ok(not public.advance_app_attest_counter('unknown', 5), 'an unknown key is refused');
select is((select sign_count from public.app_attest_keys where key_id = 'key-1'), 1::bigint, 'the counter is 1');

-- As a client (anon is enough to call the functions through the gateway, never the tables).
set local role anon;
select throws_ok(
  $$select * from public.app_attest_keys$$,
  '42501', null,
  'clients cannot read attested keys'
);
select throws_ok(
  $$select public.advance_app_attest_counter('key-1', 100)$$,
  '42501', null,
  'clients cannot move a counter'
);
reset role;

select * from finish();
rollback;
