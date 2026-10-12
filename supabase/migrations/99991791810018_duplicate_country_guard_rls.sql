-- The guard must see a duplicate's country even if the caller cannot read that row.
alter function public.assert_place_duplicate_country() security definer;
revoke all on function public.assert_place_duplicate_country() from public,anon,authenticated;
