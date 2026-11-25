-- =====================================================================
-- 필라픽 Supabase 스키마 (한 번에 실행: Supabase > SQL Editor > New query > 붙여넣기 > Run)
-- 1단계(로그인/회원가입)에는 [1] 부분만 필요하고, [2]는 2단계(데이터 서버 이전) 때 쓰입니다.
-- 다시 실행해도 오류가 나지 않도록 작성했습니다.
-- =====================================================================

-- ---------------------------------------------------------------------
-- [1] 회원 프로필 + 가입 시 자동 생성 + 탈퇴
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  role       text not null default 'member' check (role in ('member','teacher','center')),
  name       text not null default '',
  area       text,
  gu         text,
  dong       text,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

-- 가입 시 입력한 이름·역할·지역으로 프로필 자동 생성 (역할은 3가지 외 값이면 member로 강제)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare r text := coalesce(new.raw_user_meta_data->>'role','member');
begin
  if r not in ('member','teacher','center') then r := 'member'; end if;
  insert into public.profiles (id, role, name, area, gu, dong)
  values (new.id, r,
          coalesce(nullif(new.raw_user_meta_data->>'name',''), split_part(new.email,'@',1)),
          new.raw_user_meta_data->>'area', new.raw_user_meta_data->>'gu', new.raw_user_meta_data->>'dong');
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 본인 프로필만 읽기/수정. 역할(role)은 수정 불가(컬럼 권한으로 차단)
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles for select using (auth.uid() = id);
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);
revoke update on public.profiles from anon, authenticated;
grant  update (name, area, gu, dong) on public.profiles to authenticated;

-- 회원 탈퇴: 로그인한 본인 계정만 삭제 (프로필 등 연결 데이터는 cascade로 함께 삭제)
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ---------------------------------------------------------------------
-- [2] 서비스 데이터 (센터·강사·공고·체험·신청·후기·찜·정산)
-- ---------------------------------------------------------------------
-- 이름·지역 등 공개 정보만 보이는 뷰 (다른 사람의 이메일 등은 노출하지 않음)
create or replace view public.public_profiles as
  select id, role, name, area, gu from public.profiles;
grant select on public.public_profiles to anon, authenticated;

create table if not exists public.teacher_profiles (
  id     uuid primary key references public.profiles(id) on delete cascade,
  skills text[] not null default '{}',
  days   int[]  not null default '{}',
  exp    text   not null default '경력 미입력',
  badge  boolean not null default false          -- 경력 인증은 관리자만 변경
);
create table if not exists public.centers (
  id       uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name     text not null,
  type     text, form text, biz text,
  area text, gu text, dong text,
  verified boolean not null default false,        -- 사업자 인증은 관리자만 변경
  created_at timestamptz not null default now()
);
create table if not exists public.posts (          -- 대강·구인 공고
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete cascade,
  kind text not null default 'sub' check (kind in ('sub','job')),
  jt text, date date not null, time text,
  type text, form text, area text, gu text, dong text,
  pay int not null check (pay > 0), note text,
  chosen_teacher uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create table if not exists public.post_applications (
  post_id uuid references public.posts(id) on delete cascade,
  teacher_id uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, teacher_id)
);
create table if not exists public.trials (         -- 체험 클래스
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete cascade,
  type text, form text, area text, gu text, dong text,
  date date not null, time text,
  price int not null default 0 check (price >= 0),
  seats int not null check (seats between 1 and 100),
  created_at timestamptz not null default now()
);
create table if not exists public.trial_applications (
  trial_id uuid references public.trials(id) on delete cascade,
  member_id uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (trial_id, member_id)
);
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  trial_id uuid not null references public.trials(id) on delete cascade,
  center_id uuid not null references public.centers(id) on delete cascade,
  member_id uuid not null references public.profiles(id) on delete cascade,
  rating int not null check (rating between 1 and 5),
  text text not null check (char_length(text) between 1 and 300),
  created_at timestamptz not null default now(),
  unique (trial_id, member_id)
);
create table if not exists public.favorites (
  member_id uuid references public.profiles(id) on delete cascade,
  trial_id  uuid references public.trials(id) on delete cascade,
  primary key (member_id, trial_id)
);
create table if not exists public.class_records ( -- 강사 정산 기록
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete cascade,
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  date date not null, title text not null, pay int not null check (pay >= 0)
);

alter table public.teacher_profiles   enable row level security;
alter table public.centers            enable row level security;
alter table public.posts              enable row level security;
alter table public.post_applications  enable row level security;
alter table public.trials             enable row level security;
alter table public.trial_applications enable row level security;
alter table public.reviews            enable row level security;
alter table public.favorites          enable row level security;
alter table public.class_records      enable row level security;

-- 내 센터인지 확인하는 보조 함수
create or replace function public.owns_center(cid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from public.centers where id = cid and owner_id = auth.uid()) $$;

-- 센터: 누구나 조회, 본인 센터만 생성/수정/삭제 (verified는 사용자가 못 바꿈)
drop policy if exists centers_read on public.centers;   create policy centers_read   on public.centers for select using (true);
drop policy if exists centers_ins  on public.centers;   create policy centers_ins    on public.centers for insert with check (owner_id = auth.uid() and verified = false);
drop policy if exists centers_upd  on public.centers;   create policy centers_upd    on public.centers for update using (owner_id = auth.uid());
drop policy if exists centers_del  on public.centers;   create policy centers_del    on public.centers for delete using (owner_id = auth.uid());
revoke update on public.centers from authenticated;
grant  update (name, type, form, biz, area, gu, dong) on public.centers to authenticated;

-- 강사 프로필: 누구나 조회, 본인만 생성/수정 (badge는 사용자가 못 바꿈)
drop policy if exists tp_read on public.teacher_profiles; create policy tp_read on public.teacher_profiles for select using (true);
drop policy if exists tp_ins  on public.teacher_profiles; create policy tp_ins  on public.teacher_profiles for insert with check (id = auth.uid() and badge = false);
drop policy if exists tp_upd  on public.teacher_profiles; create policy tp_upd  on public.teacher_profiles for update using (id = auth.uid());
revoke update on public.teacher_profiles from authenticated;
grant  update (skills, days, exp) on public.teacher_profiles to authenticated;

-- 공고: 누구나 조회, 내 센터만 작성/수정/삭제
drop policy if exists posts_read on public.posts; create policy posts_read on public.posts for select using (true);
drop policy if exists posts_ins  on public.posts; create policy posts_ins  on public.posts for insert with check (public.owns_center(center_id));
drop policy if exists posts_upd  on public.posts; create policy posts_upd  on public.posts for update using (public.owns_center(center_id));
drop policy if exists posts_del  on public.posts; create policy posts_del  on public.posts for delete using (public.owns_center(center_id));

-- 공고 지원: 지원한 강사 본인 + 해당 공고의 센터만 조회, 강사 본인만 지원/취소
drop policy if exists pa_read on public.post_applications;
create policy pa_read on public.post_applications for select
  using (teacher_id = auth.uid() or exists (select 1 from public.posts p where p.id = post_id and public.owns_center(p.center_id)));
drop policy if exists pa_ins on public.post_applications;
create policy pa_ins on public.post_applications for insert
  with check (teacher_id = auth.uid() and exists (select 1 from public.profiles where id = auth.uid() and role = 'teacher'));
drop policy if exists pa_del on public.post_applications;
create policy pa_del on public.post_applications for delete using (teacher_id = auth.uid());

-- 체험: 누구나 조회, 내 센터만 작성/삭제
drop policy if exists trials_read on public.trials; create policy trials_read on public.trials for select using (true);
drop policy if exists trials_ins  on public.trials; create policy trials_ins  on public.trials for insert with check (public.owns_center(center_id));
drop policy if exists trials_upd  on public.trials; create policy trials_upd  on public.trials for update using (public.owns_center(center_id));
drop policy if exists trials_del  on public.trials; create policy trials_del  on public.trials for delete using (public.owns_center(center_id));

-- 체험 신청: 신청한 회원 본인 + 해당 체험의 센터만 조회, 회원 본인만 신청/취소
drop policy if exists ta_read on public.trial_applications;
create policy ta_read on public.trial_applications for select
  using (member_id = auth.uid() or exists (select 1 from public.trials t where t.id = trial_id and public.owns_center(t.center_id)));
drop policy if exists ta_ins on public.trial_applications;
create policy ta_ins on public.trial_applications for insert
  with check (member_id = auth.uid() and exists (select 1 from public.profiles where id = auth.uid() and role = 'member'));
drop policy if exists ta_del on public.trial_applications;
create policy ta_del on public.trial_applications for delete using (member_id = auth.uid());

-- 후기: 누구나 조회, "해당 체험에 신청한 회원"만 본인 명의로 작성 (가짜 후기 방지)
drop policy if exists rv_read on public.reviews; create policy rv_read on public.reviews for select using (true);
drop policy if exists rv_ins on public.reviews;
create policy rv_ins on public.reviews for insert
  with check (member_id = auth.uid()
    and exists (select 1 from public.trial_applications a where a.trial_id = reviews.trial_id and a.member_id = auth.uid()));
drop policy if exists rv_del on public.reviews; create policy rv_del on public.reviews for delete using (member_id = auth.uid());

-- 찜: 본인 것만
drop policy if exists fav_all on public.favorites;
create policy fav_all on public.favorites for all using (member_id = auth.uid()) with check (member_id = auth.uid());

-- 정산 기록: 해당 센터와 해당 강사만 조회, 센터만 작성/삭제
drop policy if exists cr_read on public.class_records;
create policy cr_read on public.class_records for select using (teacher_id = auth.uid() or public.owns_center(center_id));
drop policy if exists cr_ins on public.class_records; create policy cr_ins on public.class_records for insert with check (public.owns_center(center_id));
drop policy if exists cr_del on public.class_records; create policy cr_del on public.class_records for delete using (public.owns_center(center_id));

-- 체험 정원 초과 신청 방지 (동시에 신청해도 정원을 넘지 않도록 서버에서 검사)
create or replace function public.check_trial_seats() returns trigger
language plpgsql security definer set search_path = public as $$
declare cap int; cnt int;
begin
  select seats into cap from public.trials where id = new.trial_id for update;
  select count(*) into cnt from public.trial_applications where trial_id = new.trial_id;
  if cnt >= cap then raise exception 'trial is full'; end if;
  return new;
end $$;
drop trigger if exists trg_trial_seats on public.trial_applications;
create trigger trg_trial_seats before insert on public.trial_applications
  for each row execute function public.check_trial_seats();

-- 지역·날짜 검색 속도용 인덱스
create index if not exists posts_region_idx  on public.posts  (area, gu, dong, date);
create index if not exists trials_region_idx on public.trials (area, gu, dong, date);
