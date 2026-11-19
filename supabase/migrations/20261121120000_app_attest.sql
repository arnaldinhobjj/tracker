-- App Attest: keys of genuine DayLedger app installs, and the one-time challenges used to
-- register them. Holds no personal data (a key belongs to an app install, not to an account).
-- Service role only: clients have no access to the tables or the functions.

create table public.app_attest_keys (
  key_id text primary key check (char_length(key_id) between 1 and 100),
  -- The Secure Enclave key's public half (base64 SubjectPublicKeyInfo).
  public_key text not null check (char_length(public_key) between 1 and 500),
  -- Apple's per-key assertion counter; every accepted request must increase it.
  sign_count bigint not null default 0 check (sign_count >= 0),
  environment text not null check (environment in ('production', 'development')),
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

comment on table public.app_attest_keys is
  'App Attest keys of DayLedger installs (no user data). Used to verify request assertions.';

create table public.app_attest_challenges (
  challenge text primary key check (char_length(challenge) between 1 and 100),
  expires_at timestamptz not null
);

comment on table public.app_attest_challenges is
  'One-time App Attest registration challenges (valid for a few minutes).';

revoke all on table public.app_attest_keys, public.app_attest_challenges from public, anon, authenticated;
grant all on table public.app_attest_keys, public.app_attest_challenges to service_role;

alter table public.app_attest_keys enable row level security;
alter table public.app_attest_challenges enable row level security;
-- No policies: only the service role (bypassrls) touches them.

-- Uses a challenge: true once if it exists and hasn't expired. Also drops expired challenges.
create or replace function public.consume_app_attest_challenge(p_challenge text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  found_challenge text;
begin
  delete from public.app_attest_challenges where expires_at < now();
  delete from public.app_attest_challenges
    where challenge = p_challenge
    returning challenge into found_challenge;
  return found_challenge is not null;
end;
$$;

-- Stores a key's new counter if it is greater than the stored one. Atomic, so two requests
-- carrying the same counter (a replay) can't both be accepted.
create or replace function public.advance_app_attest_counter(p_key_id text, p_counter bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated text;
begin
  update public.app_attest_keys
    set sign_count = p_counter, last_used_at = now()
    where key_id = p_key_id and sign_count < p_counter
    returning key_id into updated;
  return updated is not null;
end;
$$;

revoke all on function public.consume_app_attest_challenge(text) from public, anon, authenticated;
revoke all on function public.advance_app_attest_counter(text, bigint) from public, anon, authenticated;
grant execute on function public.consume_app_attest_challenge(text) to service_role;
grant execute on function public.advance_app_attest_counter(text, bigint) to service_role;
