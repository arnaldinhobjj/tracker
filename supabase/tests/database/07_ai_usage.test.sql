-- The AI quota: counted atomically per user and day, invisible and uncallable for clients.
begin;
create extension if not exists pgtap with schema extensions;

select plan(8);

insert into auth.users (id, email, aud, role) values
  ('abababab-abab-4bab-8bab-abababababab', 'ai@example.com', 'authenticated', 'authenticated');

-- As the service role (the Edge Function).
select ok(public.consume_ai_quota('abababab-abab-4bab-8bab-abababababab', 2), 'first request counts');
select ok(public.consume_ai_quota('abababab-abab-4bab-8bab-abababababab', 2), 'second request counts');
select ok(not public.consume_ai_quota('abababab-abab-4bab-8bab-abababababab', 2), 'third is over the limit');
select is(
  (select requests from public.ai_usage where user_id = 'abababab-abab-4bab-8bab-abababababab'),
  2,
  'a refused request is not counted'
);
select ok(not public.consume_ai_quota('abababab-abab-4bab-8bab-abababababab', 0), 'a zero limit allows nothing');

-- As a signed-in client.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"abababab-abab-4bab-8bab-abababababab","role":"authenticated"}', true);

select throws_ok(
  $$select public.consume_ai_quota('abababab-abab-4bab-8bab-abababababab', 1000)$$,
  '42501', null,
  'clients cannot raise or spend their own quota'
);
select throws_ok(
  $$select * from public.ai_usage$$,
  '42501', null,
  'clients cannot read the usage table'
);
reset role;

select is(
  (select count(*)::int from information_schema.role_routine_grants
    where routine_schema = 'public' and routine_name = 'consume_ai_quota' and grantee in ('anon', 'authenticated')),
  0,
  'no client role can execute consume_ai_quota'
);

select * from finish();
rollback;
