-- Recovery key: lets a user restore their end-to-end sync key on a device without iCloud Keychain.
--
-- The app encrypts the sync key with a key derived from a recovery key that only the user has
-- (written down or kept in a password manager), and stores the result here. The server can't
-- unwrap it: it never sees the recovery key or the sync key.
--
-- One row per user, tied to the account's current key: (user_id, key_id) references sync_keys, so
-- starting encryption over (deleting the sync_keys row) deletes the recovery copy with it, and a
-- copy can never belong to a key the account no longer uses.

alter table public.sync_keys
  add constraint sync_keys_user_key_unique unique (user_id, key_id);

create table public.sync_key_recovery (
  user_id uuid primary key default auth.uid(),
  key_id text not null,
  -- AES-256-GCM sealed sync key: v1.<base64 of nonce + ciphertext + tag>.
  wrapped_key text not null check (wrapped_key ~ '^v1\.[A-Za-z0-9+/]+={0,2}$' and length(wrapped_key) <= 200),
  updated_at timestamptz not null default now(),
  foreign key (user_id, key_id) references public.sync_keys (user_id, key_id) on delete cascade
);

comment on table public.sync_key_recovery is
  'The sync key encrypted with the user''s recovery key (which the server never sees). Replaced '
  'when the user makes a new recovery key; deleted with the sync key when they start over.';

create trigger sync_key_recovery_set_updated_at
  before update on public.sync_key_recovery
  for each row execute function private.set_updated_at();

revoke all on table public.sync_key_recovery from public, anon, authenticated;
grant select, insert, update, delete on table public.sync_key_recovery to authenticated;
grant all on table public.sync_key_recovery to service_role;

alter table public.sync_key_recovery enable row level security;

-- No entitlement needed, as for sync_keys: recovering a key gives access only to the user's own
-- data, and a lapsed subscriber must still be able to read what they have.
create policy "sync_key_recovery: select own"
  on public.sync_key_recovery for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "sync_key_recovery: insert own"
  on public.sync_key_recovery for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

create policy "sync_key_recovery: update own"
  on public.sync_key_recovery for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "sync_key_recovery: delete own"
  on public.sync_key_recovery for delete
  to authenticated
  using ((select auth.uid()) = user_id);
