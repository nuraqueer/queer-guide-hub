begin;

do $$
declare
  v_venue uuid;
  v_fr uuid;
  v_message text;
begin
  select v.id into v_venue
  from public.venues v
  join public.countries co on co.id = v.country_id
  join public.cities ci on ci.id = v.city_id
  where co.code = 'GB' and ci.country_id = v.country_id
    and v.country = 'GB' and v.latitude is null and v.longitude is null
    and v.duplicate_of_id is null
  limit 1;
  select id into v_fr from public.countries
  where code = 'FR' and duplicate_of_id is null limit 1;
  if v_venue is null or v_fr is null then
    raise exception 'Venue country guard fixture missing';
  end if;

  -- A text-only edit can change country_id inside geo derivation. The final
  -- venue guard must still reject a country that contradicts the linked city.
  begin
    update public.venues set country = 'FR' where id = v_venue;
    raise exception 'Accepted contradictory country text';
  exception when check_violation then
    get stacked diagnostics v_message = message_text;
    if v_message not like 'Venue linked country (%' then
      raise exception 'Unexpected country guard: %', v_message;
    end if;
  end;

  -- A linked-country edit must not leave the legacy ISO text behind either.
  begin
    update public.venues set country_id = v_fr where id = v_venue;
    raise exception 'Accepted contradictory linked country';
  exception when check_violation then
    get stacked diagnostics v_message = message_text;
    if v_message not like 'Venue country text (%'
       and v_message not like 'Venue linked country (%' then
      raise exception 'Unexpected country guard: %', v_message;
    end if;
  end;
end $$;

rollback;
