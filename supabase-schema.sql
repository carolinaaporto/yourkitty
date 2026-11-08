-- Run this once in the Supabase SQL editor for your project.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  phone text,
  city text,
  account_type text not null check (account_type in ('adopter', 'publisher', 'both')),
  created_at timestamptz not null default now()
);

create table if not exists public.adoption_profiles (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  home_type text,
  housing_status text,
  household text,
  cat_experience text,
  safety_plan text,
  adoption_reason text
);

create table if not exists public.cat_listings (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  name text not null,
  age text,
  description text not null,
  location text not null,
  latitude double precision,
  longitude double precision,
  image_url text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint cat_listings_latitude_valid check (latitude is null or latitude between -90 and 90),
  constraint cat_listings_longitude_valid check (longitude is null or longitude between -180 and 180)
);

create table if not exists public.community_reports (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references public.profiles (id) on delete cascade,
  report_type text not null check (report_type in ('lost', 'sighting')),
  cat_description text not null,
  details text not null,
  location text not null,
  latitude double precision,
  longitude double precision,
  contact_email text,
  created_at timestamptz not null default now(),
  constraint community_reports_latitude_valid check (latitude is null or latitude between -90 and 90),
  constraint community_reports_longitude_valid check (longitude is null or longitude between -180 and 180),
  constraint lost_report_requires_account check (report_type <> 'lost' or owner_id is not null)
);

create table if not exists public.adoption_applications (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.cat_listings (id) on delete cascade,
  applicant_id uuid not null references public.profiles (id) on delete cascade,
  message text not null,
  created_at timestamptz not null default now(),
  unique (listing_id, applicant_id)
);

alter table public.profiles enable row level security;
alter table public.adoption_profiles enable row level security;
alter table public.cat_listings enable row level security;
alter table public.community_reports enable row level security;
alter table public.adoption_applications enable row level security;

drop policy if exists "Users can read their own profile" on public.profiles;
drop policy if exists "Users can update their own profile" on public.profiles;
drop policy if exists "Users can manage their adoption profile" on public.adoption_profiles;
drop policy if exists "Anyone can read active cat listings" on public.cat_listings;
drop policy if exists "Publishers can create their own cat listings" on public.cat_listings;
drop policy if exists "Publishers can update their own cat listings" on public.cat_listings;
drop policy if exists "Publishers can delete their own cat listings" on public.cat_listings;
drop policy if exists "Anyone can read community reports" on public.community_reports;
drop policy if exists "Anyone can publish a street-cat sighting" on public.community_reports;
drop policy if exists "Signed-in users can publish lost-cat reports" on public.community_reports;
drop policy if exists "Report owners can delete their reports" on public.community_reports;
drop policy if exists "Applicants and listing owners can read applications" on public.adoption_applications;
drop policy if exists "Adopters can submit applications" on public.adoption_applications;

create policy "Users can read their own profile"
  on public.profiles for select to authenticated
  using ((select auth.uid()) = id);

create policy "Users can manage their adoption profile"
  on public.adoption_profiles for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "Anyone can read active cat listings"
  on public.cat_listings for select to anon, authenticated
  using (active or (select auth.uid()) = owner_id);
create policy "Publishers can create their own cat listings"
  on public.cat_listings for insert to authenticated
  with check (
    (select auth.uid()) = owner_id
    and exists (
      select 1 from public.profiles
      where profiles.id = (select auth.uid())
        and profiles.account_type in ('publisher', 'both')
    )
  );
create policy "Publishers can update their own cat listings"
  on public.cat_listings for update to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);
create policy "Publishers can delete their own cat listings"
  on public.cat_listings for delete to authenticated
  using ((select auth.uid()) = owner_id);

create policy "Anyone can read community reports"
  on public.community_reports for select to anon, authenticated
  using (true);
create policy "Anyone can publish a street-cat sighting"
  on public.community_reports for insert to anon, authenticated
  with check (
    report_type = 'sighting'
    and owner_id is null
    and contact_email is null
  );
create policy "Signed-in users can publish lost-cat reports"
  on public.community_reports for insert to authenticated
  with check (
    report_type = 'lost'
    and owner_id = (select auth.uid())
  );
create policy "Report owners can delete their reports"
  on public.community_reports for delete to authenticated
  using ((select auth.uid()) = owner_id);

create policy "Applicants and listing owners can read applications"
  on public.adoption_applications for select to authenticated
  using (
    (select auth.uid()) = applicant_id
    or exists (
      select 1 from public.cat_listings
      where cat_listings.id = listing_id
        and cat_listings.owner_id = (select auth.uid())
    )
  );
create policy "Adopters can submit applications"
  on public.adoption_applications for insert to authenticated
  with check (
    (select auth.uid()) = applicant_id
    and exists (
      select 1 from public.profiles
      where profiles.id = (select auth.uid())
        and profiles.account_type in ('adopter', 'both')
    )
  );

create or replace function public.create_yourkitty_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, phone, city, account_type)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(new.raw_user_meta_data ->> 'phone', ''),
    nullif(new.raw_user_meta_data ->> 'city', ''),
    coalesce(new.raw_user_meta_data ->> 'account_type', 'adopter')
  );

  if coalesce(new.raw_user_meta_data ->> 'account_type', 'adopter') in ('adopter', 'both') then
    insert into public.adoption_profiles (
      user_id, home_type, housing_status, household,
      cat_experience, safety_plan, adoption_reason
    )
    values (
      new.id,
      nullif(new.raw_user_meta_data ->> 'home_type', ''),
      nullif(new.raw_user_meta_data ->> 'housing_status', ''),
      nullif(new.raw_user_meta_data ->> 'household', ''),
      nullif(new.raw_user_meta_data ->> 'cat_experience', ''),
      nullif(new.raw_user_meta_data ->> 'safety_plan', ''),
      nullif(new.raw_user_meta_data ->> 'adoption_reason', '')
    );
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_yourkitty on auth.users;
create trigger on_auth_user_created_yourkitty
  after insert on auth.users
  for each row execute procedure public.create_yourkitty_profile();

revoke select on public.cat_listings, public.community_reports from anon, authenticated;
grant select (id, name, age, description, location, latitude, longitude, image_url, active, created_at)
  on public.cat_listings to anon, authenticated;
grant select (id, report_type, cat_description, details, location, latitude, longitude, created_at)
  on public.community_reports to anon, authenticated;
grant insert, update, delete on public.cat_listings to authenticated;
grant insert on public.community_reports to anon, authenticated;
grant delete on public.community_reports to authenticated;
grant select on public.profiles to authenticated;
grant select, insert, update, delete on public.adoption_profiles to authenticated;
grant select, insert on public.adoption_applications to authenticated;
