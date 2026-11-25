-- Bingo Familiar · Nochebuena 2026
-- Pegar entero en Supabase > SQL Editor > New query > Run.
-- Antes de correrlo, cambiá el PIN de administrador (línea marcada abajo).

create table if not exists public.cartones (
  id            int primary key check (id between 1 and 30),
  nombre        text,
  token         uuid,
  registrado_at timestamptz,
  firma         text,
  firmado_at    timestamptz,
  marks         jsonb not null default '[]'::jsonb,
  lineas        int not null default 0,
  lleno         boolean not null default false,
  updated_at    timestamptz not null default now()
);

insert into public.cartones (id)
select g from generate_series(1, 30) g
on conflict (id) do nothing;

create table if not exists public.config (k text primary key, v text not null);
insert into public.config (k, v) values ('admin_pin', '2412')   -- <<< CAMBIÁ ESTE PIN
on conflict (k) do update set v = excluded.v;

-- Nadie toca las tablas directo: todo pasa por las funciones de abajo.
alter table public.cartones enable row level security;
alter table public.config   enable row level security;
revoke all on public.cartones from anon, authenticated;
revoke all on public.config   from anon, authenticated;

-- Registrar (o volver a entrar a) un cartón.
-- Vale si está libre, si es el mismo celular, o si el nombre coincide con el asignado.
create or replace function public.registrar(p_id int, p_nombre text, p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare r public.cartones;
begin
  if coalesce(trim(p_nombre), '') = '' then
    return json_build_object('ok', false, 'error', 'sin_nombre');
  end if;
  select * into r from public.cartones where id = p_id for update;
  if not found then
    return json_build_object('ok', false, 'error', 'no_existe');
  end if;
  if r.nombre is null
     or r.token = p_token
     or lower(trim(r.nombre)) = lower(trim(p_nombre)) then
    update public.cartones
       set nombre = coalesce(r.nombre, trim(p_nombre)),
           token = p_token,
           registrado_at = coalesce(r.registrado_at, now()),
           updated_at = now()
     where id = p_id
     returning * into r;
    return json_build_object('ok', true, 'nombre', r.nombre,
                             'firmado', r.firma is not null, 'marks', r.marks);
  end if;
  return json_build_object('ok', false, 'error', 'tomado', 'nombre', r.nombre);
end $$;

create or replace function public.firmar(p_id int, p_token uuid, p_firma text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.cartones set firma = p_firma, firmado_at = now(), updated_at = now()
   where id = p_id and token = p_token;
  return found;
end $$;

create or replace function public.guardar_sellos(p_id int, p_token uuid, p_marks jsonb, p_lineas int, p_lleno boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.cartones set marks = p_marks, lineas = p_lineas, lleno = p_lleno, updated_at = now()
   where id = p_id and token = p_token;
  return found;
end $$;

-- Lo que puede ver cualquiera: quién tiene cada cartón y cómo va (sin firmas ni tokens).
create or replace function public.estado()
returns table (id int, nombre text, registrado boolean, firmado boolean, marks jsonb,
               lineas int, lleno boolean, updated_at timestamptz)
language sql security definer set search_path = public as $$
  select c.id, c.nombre, c.registrado_at is not null, c.firma is not null, c.marks,
         c.lineas, c.lleno, c.updated_at
    from public.cartones c order by c.id;
$$;

-- Administrador (con PIN): asignar un nombre a un cartón, o liberarlo.
create or replace function public.admin_asignar(p_pin text, p_id int, p_nombre text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_pin is distinct from (select v from public.config where k = 'admin_pin') then return false; end if;
  update public.cartones
     set nombre = nullif(trim(p_nombre), ''), token = null, registrado_at = null,
         firma = null, firmado_at = null, marks = '[]'::jsonb, lineas = 0, lleno = false,
         updated_at = now()
   where id = p_id;
  return found;
end $$;

create or replace function public.admin_check(p_pin text)
returns boolean language sql security definer set search_path = public as $$
  select p_pin = (select v from public.config where k = 'admin_pin');
$$;

grant execute on function public.registrar(int, text, uuid)                     to anon, authenticated;
grant execute on function public.firmar(int, uuid, text)                        to anon, authenticated;
grant execute on function public.guardar_sellos(int, uuid, jsonb, int, boolean) to anon, authenticated;
grant execute on function public.estado()                                       to anon, authenticated;
grant execute on function public.admin_asignar(text, int, text)                 to anon, authenticated;
grant execute on function public.admin_check(text)                              to anon, authenticated;
