-- Execute este arquivo no SQL Editor do Supabase.

create table if not exists public.locations (
  id bigint generated always as identity primary key,
  device_id text not null,
  latitude double precision not null,
  longitude double precision not null,
  accuracy double precision,
  speed double precision,
  altitude double precision,
  event text not null default 'movement',
  client_time timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists locations_device_created_idx
  on public.locations (device_id, created_at desc);

alter table public.locations enable row level security;

-- O app rastreado usa apenas a anon key para gravar posições.
-- Ele não recebe permissão de leitura da tabela.
drop policy if exists "anon_can_insert_locations" on public.locations;
create policy "anon_can_insert_locations"
  on public.locations
  for insert
  to anon
  with check (
    char_length(device_id) between 1 and 100
    and latitude between -90 and 90
    and longitude between -180 and 180
  );

-- Usuários autenticados poderão ser usados futuramente no painel de monitoramento.
drop policy if exists "authenticated_can_read_locations" on public.locations;
create policy "authenticated_can_read_locations"
  on public.locations
  for select
  to authenticated
  using (true);
