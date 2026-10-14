-- Derivation can restore country_id from city_id after a writer changes the
-- legacy ISO-2 country text. Reject the remaining contradiction at the end of
-- the BEFORE-trigger chain. Sovereign/dependency equivalents remain valid.
create or replace function public.assert_venue_country_text_consistency()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_linked_code text;
begin
  if new.country_id is null or nullif(btrim(new.country), '') is null then
    return new;
  end if;

  select c.code into v_linked_code
  from public.countries c
  where c.id = new.country_id;

  if v_linked_code is not null
     and not coalesce(public.geo_countries_equivalent(upper(btrim(new.country)), v_linked_code), false) then
    raise exception 'Venue country text (%) conflicts with linked country (%)',
      new.country, v_linked_code
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function public.assert_venue_country_text_consistency()
  from public, anon, authenticated;

drop trigger if exists zzzzz_venue_country_text_consistency on public.venues;
create trigger zzzzz_venue_country_text_consistency
before insert or update of country, country_id, city_id, latitude, longitude
on public.venues
for each row execute function public.assert_venue_country_text_consistency();
