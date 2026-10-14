-- An UPDATE of only venues.country can change country_id inside the geo-derive
-- trigger. PostgreSQL's UPDATE OF trigger list still sees only the original SET
-- columns, so the existing country_id guard does not run. Check the final row.
create or replace function public.assert_venue_country_text_consistency()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_linked_code text;
  v_city_code text;
begin
  if new.country_id is null then
    return new;
  end if;

  select c.code into v_linked_code
  from public.countries c
  where c.id = new.country_id;

  if v_linked_code is null then
    return new;
  end if;

  if nullif(btrim(new.country), '') is not null
     and not coalesce(public.geo_countries_equivalent(upper(btrim(new.country)), v_linked_code), false) then
    raise exception 'Venue country text (%) conflicts with linked country (%)',
      new.country, v_linked_code
      using errcode = '23514';
  end if;

  if new.city_id is not null then
    select co.code into v_city_code
    from public.cities ci
    join public.countries co on co.id = ci.country_id
    where ci.id = new.city_id;

    if v_city_code is not null
       and not coalesce(public.geo_countries_equivalent(v_city_code, v_linked_code), false) then
      raise exception 'Venue linked country (%) conflicts with linked city country (%)',
        v_linked_code, v_city_code
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;
