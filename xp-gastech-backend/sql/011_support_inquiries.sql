-- 011: Support inquiries and tickets for admin desk
create table if not exists public.support_inquiries (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,
  phone text,
  subject text not null,
  message text not null,
  category text not null default 'general',
  status text not null default 'new',
  admin_notes text,
  user_id uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists support_inquiries_status_idx on public.support_inquiries(status);
create index if not exists support_inquiries_created_idx on public.support_inquiries(created_at desc);
