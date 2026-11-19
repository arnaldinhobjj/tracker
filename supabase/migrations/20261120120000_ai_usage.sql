-- Per-user daily request counter for the ai-suggest Edge Function, which calls Anthropic with
-- DayLedger's own key. Only the count is stored: never the routine summary or the answer.
-- Service role only: clients have no access to the table or the function.

create table public.ai_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  requests integer not null default 0 check (requests >= 0),
  primary key (user_id, day)
);

comment on table public.ai_usage is
  'AI suggestion requests per user per UTC day (rate limiting). Erased with the account.';

revoke all on table public.ai_usage from public, anon, authenticated;
grant all on table public.ai_usage to service_role;

alter table public.ai_usage enable row level security;
-- No policies: only the service role (bypassrls) touches it.

-- Counts one request for today and returns true, or returns false (and counts nothing) when the
-- user already made p_limit requests today. Atomic, so parallel requests can't exceed the limit.
create or replace function public.consume_ai_quota(p_user_id uuid, p_limit integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  used integer;
begin
  if p_limit is null or p_limit < 1 then
    return false;
  end if;
  insert into public.ai_usage as u (user_id, day, requests)
  values (p_user_id, (now() at time zone 'utc')::date, 1)
  on conflict (user_id, day) do update
    set requests = u.requests + 1
    where u.requests < p_limit
  returning u.requests into used;
  return used is not null;
end;
$$;

revoke all on function public.consume_ai_quota(uuid, integer) from public, anon, authenticated;
grant execute on function public.consume_ai_quota(uuid, integer) to service_role;
