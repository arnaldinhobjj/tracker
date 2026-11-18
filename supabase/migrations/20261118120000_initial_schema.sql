-- DayLedger initial schema. Implements docs/backend-contract.md.
--
-- Access model
--   * Every user table is keyed by the owner's auth.users id and protected by RLS using
--     (select auth.uid()) so the uid lookup is evaluated once per statement.
--   * Reading your own rows needs only a signed-in account.
--   * Inserting/updating synced data (transactions, visits, user_settings) also needs an active
--     entitlement: public.has_active_entitlement().
--   * Deleting your own rows is always allowed (lapsed users can still clean up).
--   * subscriptions is read-only for clients; app_store_notifications is service-role only.
--   * anon gets nothing.

-- ---------------------------------------------------------------------------------------------
-- Private schema for helper/trigger functions (not exposed through the Data API).
-- ---------------------------------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon, authenticated;

-- updated_at is the sync cursor, so the server always sets it. clock_timestamp() (rather than
-- now()) gives every row in a multi-row upsert its own value, which keeps the client's
-- `updated_at=gt.<cursor>` pagination from skipping rows that share a timestamp.
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

revoke all on function private.set_updated_at() from public;

-- ---------------------------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'One row per auth user, created by trigger on auth.users.';

create trigger profiles_set_updated_at
  before insert or update on public.profiles
  for each row execute function private.set_updated_at();

-- Creates the profile when an auth user is created. security definer because it runs as the
-- auth service role, which has no rights on public.profiles.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Keeps profiles.email in sync when the user changes their address.
create or replace function private.handle_user_email_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
     set email = new.email
   where id = new.id;
  return new;
end;
$$;

revoke all on function private.handle_new_user() from public;
revoke all on function private.handle_user_email_change() from public;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row
  when (old.email is distinct from new.email)
  execute function private.handle_user_email_change();

-- ---------------------------------------------------------------------------------------------
-- transactions
-- ---------------------------------------------------------------------------------------------
create table public.transactions (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  account_id text not null,
  merchant text not null,
  raw_description text not null,
  amount_minor bigint not null check (amount_minor >= 0),
  currency char(3) not null check (currency ~ '^[A-Z]{3}$'),
  direction text not null check (direction in ('debit', 'credit')),
  bank_category text not null,
  -- SpendCategory raw value. Deliberately no check constraint (new categories need no migration).
  category text not null,
  occurred_at timestamptz not null,
  has_time boolean not null default false,
  is_pending boolean not null default false,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, id)
);

create index transactions_user_id_updated_at_idx on public.transactions (user_id, updated_at);
create index transactions_user_id_occurred_at_idx on public.transactions (user_id, occurred_at desc);

create trigger transactions_set_updated_at
  before insert or update on public.transactions
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- visits
-- ---------------------------------------------------------------------------------------------
create table public.visits (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  arrival timestamptz not null,
  departure timestamptz,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  place_name text,
  place_category text,
  is_named_place boolean not null default false,
  is_resolved boolean not null default false,
  calendar_event_id text,
  calendar_content_hash text,
  calendar_synced_at timestamptz,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, id)
);

create index visits_user_id_updated_at_idx on public.visits (user_id, updated_at);

create trigger visits_set_updated_at
  before insert or update on public.visits
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- user_settings
-- ---------------------------------------------------------------------------------------------
create table public.user_settings (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  settings jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object'),
  updated_at timestamptz not null default now()
);

create trigger user_settings_set_updated_at
  before insert or update on public.user_settings
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- subscriptions (written only by Edge Functions with the service role)
-- ---------------------------------------------------------------------------------------------
create table public.subscriptions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  original_transaction_id text not null unique,
  product_id text not null,
  status text not null check (
    status in ('trial', 'active', 'grace_period', 'billing_retry', 'expired', 'revoked', 'refunded')
  ),
  -- For grace_period this is the grace period expiry.
  expires_at timestamptz not null,
  is_trial boolean not null default false,
  auto_renew boolean not null default true,
  environment text not null check (environment in ('Sandbox', 'Production')),
  app_account_token uuid,
  latest_transaction_id text not null,
  updated_at timestamptz not null default now()
);

create trigger subscriptions_set_updated_at
  before insert or update on public.subscriptions
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- app_store_notifications (audit + idempotency log; service role only)
-- ---------------------------------------------------------------------------------------------
create table public.app_store_notifications (
  notification_uuid uuid primary key,
  notification_type text not null,
  subtype text,
  original_transaction_id text,
  signed_date timestamptz not null,
  received_at timestamptz not null default now(),
  payload jsonb not null,
  -- Additions beyond the contract's minimum: which user the notification was applied to (so the
  -- log is erased with the account) and when processing finished (so a notification whose
  -- processing failed is retried by Apple instead of being treated as a duplicate).
  user_id uuid references auth.users (id) on delete cascade,
  processed_at timestamptz
);

create index app_store_notifications_otid_signed_date_idx
  on public.app_store_notifications (original_transaction_id, signed_date desc);
create index app_store_notifications_user_id_idx
  on public.app_store_notifications (user_id);

-- ---------------------------------------------------------------------------------------------
-- Entitlement check (used by RLS and callable as POST /rest/v1/rpc/has_active_entitlement)
-- ---------------------------------------------------------------------------------------------
create or replace function public.has_active_entitlement()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.subscriptions s
     where s.user_id = (select auth.uid())
       and s.status in ('trial', 'active', 'grace_period')
       and s.expires_at > now()
  );
$$;

comment on function public.has_active_entitlement() is
  'True when the calling user has a trial, active or grace-period subscription that has not expired.';

revoke all on function public.has_active_entitlement() from public;
revoke all on function public.has_active_entitlement() from anon;
grant execute on function public.has_active_entitlement() to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Grants. Supabase's default privileges give anon/authenticated everything on new tables in
-- public; reset that and grant exactly what each role needs.
-- ---------------------------------------------------------------------------------------------
revoke all on table
  public.profiles,
  public.transactions,
  public.visits,
  public.user_settings,
  public.subscriptions,
  public.app_store_notifications
from public, anon, authenticated;

grant select on table public.profiles to authenticated;
grant update (display_name) on table public.profiles to authenticated;

grant select, insert, update, delete on table public.transactions to authenticated;
grant select, insert, update, delete on table public.visits to authenticated;
grant select, insert, update, delete on table public.user_settings to authenticated;

grant select on table public.subscriptions to authenticated;

grant all on table
  public.profiles,
  public.transactions,
  public.visits,
  public.user_settings,
  public.subscriptions,
  public.app_store_notifications
to service_role;

-- ---------------------------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.transactions enable row level security;
alter table public.visits enable row level security;
alter table public.user_settings enable row level security;
alter table public.subscriptions enable row level security;
alter table public.app_store_notifications enable row level security;
-- app_store_notifications intentionally has no policies: only the service role (bypassrls)
-- can touch it.

-- profiles: read and update own row (only display_name is updatable, by column grant).
create policy "profiles: select own"
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "profiles: update own"
  on public.profiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- transactions
create policy "transactions: select own"
  on public.transactions for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "transactions: insert own when entitled"
  on public.transactions for insert
  to authenticated
  with check ((select auth.uid()) = user_id and (select public.has_active_entitlement()));

create policy "transactions: update own when entitled"
  on public.transactions for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id and (select public.has_active_entitlement()));

create policy "transactions: delete own"
  on public.transactions for delete
  to authenticated
  using ((select auth.uid()) = user_id);

-- visits
create policy "visits: select own"
  on public.visits for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "visits: insert own when entitled"
  on public.visits for insert
  to authenticated
  with check ((select auth.uid()) = user_id and (select public.has_active_entitlement()));

create policy "visits: update own when entitled"
  on public.visits for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id and (select public.has_active_entitlement()));

create policy "visits: delete own"
  on public.visits for delete
  to authenticated
  using ((select auth.uid()) = user_id);

-- user_settings
create policy "user_settings: select own"
  on public.user_settings for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "user_settings: insert own when entitled"
  on public.user_settings for insert
  to authenticated
  with check ((select auth.uid()) = user_id and (select public.has_active_entitlement()));

create policy "user_settings: update own when entitled"
  on public.user_settings for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id and (select public.has_active_entitlement()));

create policy "user_settings: delete own"
  on public.user_settings for delete
  to authenticated
  using ((select auth.uid()) = user_id);

-- subscriptions: clients read their own row; all writes come from Edge Functions.
create policy "subscriptions: select own"
  on public.subscriptions for select
  to authenticated
  using ((select auth.uid()) = user_id);
