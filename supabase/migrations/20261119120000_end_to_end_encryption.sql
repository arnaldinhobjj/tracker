-- End-to-end encryption of synced transactions and visits (docs/backend-contract.md, "Encryption").
--
-- New app versions upload rows as an AES-GCM `payload` sealed with a key that only the user's
-- devices hold (iCloud Keychain), plus the key's public fingerprint in `key_id`. The plaintext
-- columns are sent as explicit nulls, which also erases plaintext written by older versions when
-- a row is re-uploaded. The server can no longer read merchants, amounts, places or coordinates.
--
-- Compatibility: older app versions still write plaintext rows. Both shapes are accepted, but a row
-- is either fully encrypted (payload + key_id, every plaintext column null) or fully legacy
-- (no payload, every required plaintext column set). New clients treat legacy rows as "needs
-- re-encrypting" and upload them again sealed.
--
-- Nothing here deletes or rewrites existing rows: existing plaintext stays readable by the app
-- until a device re-uploads it encrypted.

-- ---------------------------------------------------------------------------------------------
-- transactions
-- ---------------------------------------------------------------------------------------------
alter table public.transactions
  add column key_id text check (key_id ~ '^[0-9a-f]{32}$'),
  add column payload text check (length(payload) between 1 and 16384),
  alter column account_id drop not null,
  alter column merchant drop not null,
  alter column raw_description drop not null,
  alter column amount_minor drop not null,
  alter column currency drop not null,
  alter column direction drop not null,
  alter column bank_category drop not null,
  alter column category drop not null,
  alter column occurred_at drop not null,
  alter column has_time drop not null,
  alter column is_pending drop not null;

alter table public.transactions
  add constraint transactions_key_with_payload
    check ((payload is null) = (key_id is null)),
  -- Encrypted rows carry no plaintext at all.
  add constraint transactions_encrypted_rows_have_no_plaintext
    check (
      payload is null
      or (account_id, merchant, raw_description, amount_minor, currency, direction, bank_category,
          category, occurred_at, has_time, is_pending) is null
    ),
  -- Legacy rows (older app versions) must still be complete.
  add constraint transactions_legacy_rows_are_complete
    check (
      payload is not null
      or (account_id, merchant, raw_description, amount_minor, currency, direction, bank_category,
          category, occurred_at, has_time, is_pending) is not null
    );

comment on column public.transactions.payload is
  'AES-256-GCM sealed row content (v1.<base64>), readable only on the user''s devices.';
comment on column public.transactions.key_id is
  'Fingerprint of the key that sealed payload (see public.sync_keys).';

-- ---------------------------------------------------------------------------------------------
-- visits
-- ---------------------------------------------------------------------------------------------
alter table public.visits
  add column key_id text check (key_id ~ '^[0-9a-f]{32}$'),
  add column payload text check (length(payload) between 1 and 16384),
  alter column arrival drop not null,
  alter column latitude drop not null,
  alter column longitude drop not null,
  alter column is_named_place drop not null,
  alter column is_resolved drop not null;

alter table public.visits
  add constraint visits_key_with_payload
    check ((payload is null) = (key_id is null)),
  add constraint visits_encrypted_rows_have_no_plaintext
    check (
      payload is null
      or (arrival, departure, latitude, longitude, place_name, place_category, is_named_place,
          is_resolved, calendar_event_id, calendar_content_hash, calendar_synced_at) is null
    ),
  add constraint visits_legacy_rows_are_complete
    check (
      payload is not null
      or (arrival, latitude, longitude, is_named_place, is_resolved) is not null
    );

comment on column public.visits.payload is
  'AES-256-GCM sealed row content (v1.<base64>), readable only on the user''s devices.';

-- ---------------------------------------------------------------------------------------------
-- sync_keys: which key an account's rows are encrypted with (its fingerprint only)
-- ---------------------------------------------------------------------------------------------
create table public.sync_keys (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  key_id text not null check (key_id ~ '^[0-9a-f]{32}$'),
  created_at timestamptz not null default now()
);

comment on table public.sync_keys is
  'One row per user: the fingerprint of the end-to-end sync key. The key itself never reaches the '
  'server. Insert-once (no update policy); deleting it is how a user starts encryption over.';

revoke all on table public.sync_keys from public, anon, authenticated;
grant select, insert, delete on table public.sync_keys to authenticated;
grant all on table public.sync_keys to service_role;

alter table public.sync_keys enable row level security;

create policy "sync_keys: select own"
  on public.sync_keys for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- No entitlement needed: registering a key id stores nothing sensitive, and reading (which also
-- needs the key) works without a subscription.
create policy "sync_keys: insert own"
  on public.sync_keys for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

create policy "sync_keys: delete own"
  on public.sync_keys for delete
  to authenticated
  using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------------------------------
-- Older app versions updating a row that a newer one already encrypted
-- ---------------------------------------------------------------------------------------------
-- An old client's upsert sets the plaintext columns and leaves payload/key_id untouched. Its write
-- is the newest version of the row, so the stale ciphertext is dropped and the row becomes a
-- legacy row again (new clients then re-encrypt it). Without this the old client's whole batch
-- would fail the constraints above and its sync would break.
create or replace function private.drop_stale_ciphertext_on_legacy_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  wrote_plaintext boolean;
begin
  if tg_table_name = 'transactions' then
    wrote_plaintext := (to_jsonb(new) ->> 'merchant') is not null;
  else
    wrote_plaintext := (to_jsonb(new) ->> 'latitude') is not null;
  end if;
  if wrote_plaintext and new.payload is not distinct from old.payload then
    new.payload := null;
    new.key_id := null;
  end if;
  return new;
end;
$$;

revoke all on function private.drop_stale_ciphertext_on_legacy_write() from public;

create trigger transactions_legacy_write
  before update on public.transactions
  for each row execute function private.drop_stale_ciphertext_on_legacy_write();

create trigger visits_legacy_write
  before update on public.visits
  for each row execute function private.drop_stale_ciphertext_on_legacy_write();
