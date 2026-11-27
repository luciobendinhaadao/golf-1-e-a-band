-- GOLF 1 É A BANDA — Supabase schema v1
-- Aplicar no SQL Editor de um projecto Supabase NOVO dedicado ao jogo.
-- Não executar num projecto de outra aplicação.
-- Wallets e pagamentos só podem ser alterados por servidor confiável (service_role).
-- Nunca colocar a service_role key no frontend.

create extension if not exists pgcrypto;

create table if not exists public.players (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  gender text not null default 'male' check (gender in ('male','female','other')),
  skin_tone text not null default 'medium',
  hair_style text not null default 'short',
  outfit text not null default 'green',
  cash_balance bigint not null default 2500 check (cash_balance >= 0),
  bank_balance bigint not null default 0 check (bank_balance >= 0),
  hunger smallint not null default 100 check (hunger between 0 and 100),
  energy smallint not null default 100 check (energy between 0 and 100),
  respect_points integer not null default 0 check (respect_points >= 0),
  education_level smallint not null default 0 check (education_level between 0 and 3),
  pos_x double precision not null default 0,
  pos_y double precision not null default 0,
  pos_z double precision not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists players_username_lower_uidx on public.players (lower(username));

create table if not exists public.jobs (
  id text primary key,
  title text not null,
  business_name text not null,
  salary_kz bigint not null check (salary_kz > 0),
  shift_seconds integer not null default 90 check (shift_seconds = 90),
  is_active boolean not null default true
);

insert into public.jobs (id,title,business_name,salary_kz) values
 ('mechanic','Mecânico','Oficina do Man Furra',2200),
 ('tailor','Alfaiate','Alfaiataria',1800),
 ('security','Segurança','Quartel',3500),
 ('police','Polícia','Esquadra',3500),
 ('hospital','Assistente hospitalar','Hospital da Banda',2200),
 ('farmer','Agricultor','Fazenda da Banda',1500),
 ('finance','Funcionário financeiro','Empresas da Baixa',6000),
 ('school','Funcionário escolar','Escola da Banda',2200),
 ('cook','Cozinheiro / Atendente','Cantina da Banda',1800),
 ('market','Comerciante','Mercado da Subzona 5',1500),
 ('garage','Assistente de garagem','Garagens privadas',2200),
 ('warehouse','Operador de armazém','Armazém agrícola',1800)
on conflict (id) do update set
 title=excluded.title,business_name=excluded.business_name,salary_kz=excluded.salary_kz,shift_seconds=90;

create table if not exists public.player_careers (
 id uuid primary key default gen_random_uuid(),
 player_id uuid not null references public.players(id) on delete cascade,
 job_id text not null references public.jobs(id),
 shifts_completed integer not null default 0 check (shifts_completed >= 0),
 current_rank smallint not null default 1 check (current_rank between 1 and 4),
 updated_at timestamptz not null default now(),
 unique (player_id,job_id)
);

create table if not exists public.work_shifts (
 id uuid primary key default gen_random_uuid(),
 player_id uuid not null references public.players(id) on delete cascade,
 job_id text not null references public.jobs(id),
 status text not null default 'active' check (status in ('active','completed','cancelled')),
 started_at timestamptz not null default now(),
 completed_at timestamptz,
 paid_amount bigint not null default 0 check (paid_amount >= 0),
 check (
   (status = 'active' and completed_at is null and paid_amount = 0)
   or (status = 'completed' and completed_at is not null and paid_amount > 0)
   or status = 'cancelled'
 )
);
create index if not exists work_shifts_player_started_idx on public.work_shifts(player_id,started_at desc);
create unique index if not exists one_active_shift_per_player_uidx on public.work_shifts(player_id) where status = 'active';

create table if not exists public.player_assets (
 id uuid primary key default gen_random_uuid(),
 player_id uuid not null references public.players(id) on delete cascade,
 asset_type text not null check (asset_type in ('item','clothing','vehicle','property')),
 asset_code text not null,
 fuel_level smallint check (fuel_level between 0 and 100),
 purchased_at timestamptz not null default now()
);
create index if not exists player_assets_player_idx on public.player_assets(player_id);

create table if not exists public.bank_transactions (
 id uuid primary key default gen_random_uuid(),
 sender_id uuid references public.players(id) on delete set null,
 receiver_id uuid references public.players(id) on delete set null,
 amount bigint not null check (amount > 0),
 transaction_type text not null check (transaction_type in ('salary','transfer','purchase','deposit','withdrawal','refund')),
 description text,
 created_at timestamptz not null default now(),
 check (sender_id is not null or receiver_id is not null)
);
create index if not exists bank_transactions_sender_idx on public.bank_transactions(sender_id,created_at desc);
create index if not exists bank_transactions_receiver_idx on public.bank_transactions(receiver_id,created_at desc);

-- Criar automaticamente o perfil após o registo no Supabase Auth.
create or replace function public.handle_new_golf_player()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  desired_name text;
begin
  desired_name := nullif(trim(coalesce(new.raw_user_meta_data->>'username','')), '');
  if desired_name is null then
    desired_name := 'Jogador-' || substr(new.id::text,1,8);
  end if;

  insert into public.players (id,username,gender,skin_tone,hair_style,outfit)
  values (
    new.id,
    desired_name,
    coalesce(nullif(new.raw_user_meta_data->>'gender',''),'male'),
    coalesce(nullif(new.raw_user_meta_data->>'skin_tone',''),'medium'),
    coalesce(nullif(new.raw_user_meta_data->>'hair_style',''),'short'),
    coalesce(nullif(new.raw_user_meta_data->>'outfit',''),'green')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_golf_auth_user_created on auth.users;
create trigger on_golf_auth_user_created
 after insert on auth.users
 for each row execute procedure public.handle_new_golf_player();

-- O início do turno é carimbado pelo PostgreSQL, não pelo relógio do telemóvel.
create or replace function public.prepare_golf_shift()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is null or new.player_id <> auth.uid() then
    raise exception 'Jogador não autorizado';
  end if;
  if not exists (select 1 from public.jobs j where j.id = new.job_id and j.is_active) then
    raise exception 'Emprego indisponível';
  end if;
  new.status := 'active';
  new.started_at := now();
  new.completed_at := null;
  new.paid_amount := 0;
  return new;
end;
$$;
drop trigger if exists prepare_golf_shift_before_insert on public.work_shifts;
create trigger prepare_golf_shift_before_insert
 before insert on public.work_shifts
 for each row execute procedure public.prepare_golf_shift();

-- Segurança: todas as tabelas expostas têm RLS.
alter table public.players enable row level security;
alter table public.jobs enable row level security;
alter table public.player_careers enable row level security;
alter table public.work_shifts enable row level security;
alter table public.player_assets enable row level security;
alter table public.bank_transactions enable row level security;

drop policy if exists "players_read_self" on public.players;
create policy "players_read_self" on public.players for select to authenticated
 using ((select auth.uid()) = id);
drop policy if exists "players_update_appearance" on public.players;
create policy "players_update_appearance" on public.players for update to authenticated
 using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

drop policy if exists "jobs_read_authenticated" on public.jobs;
create policy "jobs_read_authenticated" on public.jobs for select to authenticated using (is_active);

drop policy if exists "careers_read_self" on public.player_careers;
create policy "careers_read_self" on public.player_careers for select to authenticated
 using ((select auth.uid()) = player_id);

drop policy if exists "shifts_read_self" on public.work_shifts;
create policy "shifts_read_self" on public.work_shifts for select to authenticated
 using ((select auth.uid()) = player_id);
drop policy if exists "shifts_start_self" on public.work_shifts;
create policy "shifts_start_self" on public.work_shifts for insert to authenticated
 with check ((select auth.uid()) = player_id and status = 'active' and paid_amount = 0 and completed_at is null);

drop policy if exists "assets_read_self" on public.player_assets;
create policy "assets_read_self" on public.player_assets for select to authenticated
 using ((select auth.uid()) = player_id);

drop policy if exists "transactions_read_participant" on public.bank_transactions;
create policy "transactions_read_participant" on public.bank_transactions for select to authenticated
 using ((select auth.uid()) = sender_id or (select auth.uid()) = receiver_id);

-- Privilégios mínimos. O cliente nunca recebe permissão para alterar saldos,
-- pagamentos, carreira, bens ou o estado final dos turnos.
revoke all on public.players, public.jobs, public.player_careers, public.work_shifts, public.player_assets, public.bank_transactions from anon, authenticated;
grant select on public.players to authenticated;
grant update (username,gender,skin_tone,hair_style,outfit) on public.players to authenticated;
grant select on public.jobs to authenticated;
grant select on public.player_careers to authenticated;
grant select on public.work_shifts to authenticated;
grant insert (player_id,job_id) on public.work_shifts to authenticated;
grant select on public.player_assets to authenticated;
grant select on public.bank_transactions to authenticated;
