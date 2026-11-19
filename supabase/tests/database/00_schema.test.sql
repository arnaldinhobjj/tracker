-- Schema-level guarantees: RLS on every table, safe function definitions, no anon access.
begin;
create extension if not exists pgtap with schema extensions;

select plan(18);

select has_table('public', 'profiles', 'profiles exists');
select has_table('public', 'transactions', 'transactions exists');
select has_table('public', 'visits', 'visits exists');
select has_table('public', 'user_settings', 'user_settings exists');
select has_table('public', 'subscriptions', 'subscriptions exists');
select has_table('public', 'app_store_notifications', 'app_store_notifications exists');
select has_table('public', 'sync_keys', 'sync_keys exists');

select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0,
  'every table in public has row level security enabled'
);

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public' and tablename = 'app_store_notifications'),
  0,
  'app_store_notifications has no client policies'
);

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public' and tablename = 'subscriptions' and cmd <> 'SELECT'),
  0,
  'subscriptions only has a SELECT policy'
);

select ok(
  (select prosecdef from pg_proc where oid = 'public.has_active_entitlement()'::regprocedure),
  'has_active_entitlement is security definer'
);

select ok(
  (select 'search_path=""' = any(proconfig) from pg_proc
    where oid = 'public.has_active_entitlement()'::regprocedure),
  'has_active_entitlement pins an empty search_path'
);

select is(
  (select provolatile::text from pg_proc
    where oid = 'public.has_active_entitlement()'::regprocedure),
  's',
  'has_active_entitlement is stable'
);

select ok(
  (select bool_and(prosecdef and 'search_path=""' = any(proconfig))
     from pg_proc
    where pronamespace = 'private'::regnamespace
      and proname in ('handle_new_user', 'handle_user_email_change')),
  'auth.users trigger functions are security definer with an empty search_path'
);

select ok(
  not has_function_privilege('anon', 'public.has_active_entitlement()', 'execute'),
  'anon cannot execute has_active_entitlement'
);

select ok(
  has_function_privilege('authenticated', 'public.has_active_entitlement()', 'execute'),
  'authenticated can execute has_active_entitlement'
);

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'),
  0,
  'anon has no table privileges in public'
);

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where grantee = 'authenticated' and table_schema = 'public'
      and table_name in ('subscriptions', 'app_store_notifications')
      and privilege_type <> 'SELECT'),
  0,
  'authenticated cannot write subscriptions or app_store_notifications'
);

select * from finish();
rollback;
