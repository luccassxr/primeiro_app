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

drop policy if exists "authenticated_can_read_locations" on public.locations;
create policy "authenticated_can_read_locations"
  on public.locations
  for select
  to authenticated
  using (true);

-- Fila usada pelo painel para pedir uma posição nova ao celular rastreado.
create table if not exists public.location_commands (
  id bigint generated always as identity primary key,
  device_id text not null,
  command text not null default 'locate_now'
    check (command in ('locate_now')),
  status text not null default 'pending'
    check (status in ('pending', 'completed', 'failed')),
  requested_at timestamptz not null default now(),
  processed_at timestamptz,
  error text
);

create index if not exists location_commands_device_status_idx
  on public.location_commands (device_id, status, requested_at desc);

alter table public.location_commands enable row level security;

-- O painel autenticado pode criar e acompanhar solicitações.
drop policy if exists "authenticated_can_insert_location_commands" on public.location_commands;
create policy "authenticated_can_insert_location_commands"
  on public.location_commands
  for insert
  to authenticated
  with check (
    char_length(device_id) between 1 and 100
    and command = 'locate_now'
    and status = 'pending'
  );

drop policy if exists "authenticated_can_read_location_commands" on public.location_commands;
create policy "authenticated_can_read_location_commands"
  on public.location_commands
  for select
  to authenticated
  using (true);

-- O app rastreado usa a chave pública somente para enxergar comandos pendentes.
drop policy if exists "anon_can_read_pending_location_commands" on public.location_commands;
create policy "anon_can_read_pending_location_commands"
  on public.location_commands
  for select
  to anon
  using (status = 'pending');

-- O app rastreado só pode transformar um comando pendente em concluído/falho.
drop policy if exists "anon_can_finish_pending_location_commands" on public.location_commands;
create policy "anon_can_finish_pending_location_commands"
  on public.location_commands
  for update
  to anon
  using (status = 'pending')
  with check (status in ('completed', 'failed'));
