-- Aggregate raw entity types before normalization: SQL functions with SET search_path
-- cannot inline and were executing once per junction row. Counts remain exact.
CREATE OR REPLACE FUNCTION public.run_content_graph_recompute()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_nodes jsonb;
  v_edges jsonb;
  v_snapshot jsonb;
begin
  select jsonb_agg(n) into v_nodes from (
    select jsonb_build_object('type','venue','label','Venues','category','content',
      'count',(select count(*) from venues where duplicate_of_id is null),
      'orphan_count',(select count(*) from venues where duplicate_of_id is null and city_id is null),
      'dup_count',(select count(*) from venues where duplicate_of_id is not null)) n
    union all select jsonb_build_object('type','event','label','Events','category','content',
      'count',(select count(*) from events where duplicate_of_id is null),
      'orphan_count',(select count(*) from events where duplicate_of_id is null and city_id is null and country_id is null and venue_id is null),
      'dup_count',(select count(*) from events where duplicate_of_id is not null))
    union all select jsonb_build_object('type','personality','label','Personalities','category','content',
      'count',(select count(*) from personalities where duplicate_of_id is null),
      'orphan_count',(select count(*) from personalities where duplicate_of_id is null and city_id is null and country_id is null),
      'dup_count',(select count(*) from personalities where duplicate_of_id is not null))
    union all select jsonb_build_object('type','news','label','News','category','content',
      'count',(select count(*) from news_articles where duplicate_of_id is null),
      'orphan_count',null,
      'dup_count',(select count(*) from news_articles where duplicate_of_id is not null))
    union all select jsonb_build_object('type','marketplace','label','Marketplace','category','content',
      'count',(select count(*) from marketplace_listings where duplicate_of_id is null),
      'orphan_count',(select count(*) from marketplace_listings where duplicate_of_id is null and category_id is null),
      'dup_count',(select count(*) from marketplace_listings where duplicate_of_id is not null))
    union all select jsonb_build_object('type','hotel','label','Hotels','category','content',
      'count',(select count(*) from hotels),
      'orphan_count',(select count(*) from hotels where city_id is null),
      'dup_count',0)
    union all select jsonb_build_object('type','organization','label','Organizations','category','content',
      'count',(select count(*) from organizations),
      'orphan_count',(select count(*) from organizations where city_id is null and country_id is null),
      'dup_count',0)
    union all select jsonb_build_object('type','milestone','label','Milestones','category','content',
      'count',(select count(*) from milestones where duplicate_of_id is null),
      'orphan_count',(select count(*) from milestones where duplicate_of_id is null and city_id is null and country_id is null),
      'dup_count',(select count(*) from milestones where duplicate_of_id is not null))
    union all select jsonb_build_object('type','city','label','Cities','category','geo',
      'count',(select count(*) from cities where duplicate_of_id is null),
      'orphan_count',(select count(*) from cities where duplicate_of_id is null and country_id is null),
      'dup_count',(select count(*) from cities where duplicate_of_id is not null))
    union all select jsonb_build_object('type','country','label','Countries','category','geo',
      'count',(select count(*) from countries where duplicate_of_id is null),
      'orphan_count',(select count(*) from countries where duplicate_of_id is null and continent_id is null),
      'dup_count',(select count(*) from countries where duplicate_of_id is not null))
    union all select jsonb_build_object('type','continent','label','Continents','category','geo',
      'count',(select count(*) from continents),'orphan_count',null,'dup_count',0)
    union all select jsonb_build_object('type','region','label','Regions','category','geo',
      'count',(select count(*) from regions),'orphan_count',null,'dup_count',0)
    union all select jsonb_build_object('type','village','label','Queer Villages','category','geo',
      'count',(select count(*) from queer_villages),
      'orphan_count',(select count(*) from queer_villages where city_id is null),'dup_count',0)
    union all select jsonb_build_object('type','festival','label','Festivals','category','community',
      'count',(select count(*) from festivals),
      'orphan_count',(select count(*) from festivals where city_id is null),'dup_count',0)
    union all select jsonb_build_object('type','group','label','Community Groups','category','community',
      'count',(select count(*) from community_groups),'orphan_count',null,'dup_count',0)
    union all select jsonb_build_object('type','tag','label','Tags','category','taxonomy',
      'count',(select count(*) from unified_tags where merged_into_id is null),
      'orphan_count',(select count(*) from unified_tags ut where ut.merged_into_id is null
        and not exists (select 1 from unified_tag_assignments a where a.tag_id = ut.id)),
      'dup_count',(select count(*) from unified_tags where merged_into_id is not null))
    union all select jsonb_build_object('type','image','label','Images','category','media',
      'count',(select count(*) from image_assets),'orphan_count',null,'dup_count',0)
  ) s;

  with tag_types as materialized (select entity_type, count(*) cnt from unified_tag_assignments group by entity_type),
  news_types as materialized (select entity_type, count(*) cnt from news_article_entities group by entity_type),
  milestone_types as materialized (select entity_type, count(*) cnt from milestone_links group by entity_type),
  image_types as materialized (select entity_type, count(*) cnt from image_asset_links group by entity_type),
  e(src,tgt,rel,kind,cnt) as (
    select 'venue','city','in city','geo',(select count(*) from venues where duplicate_of_id is null and city_id is not null)
    union all select 'venue','country','in country','geo',(select count(*) from venues where duplicate_of_id is null and country_id is not null)
    union all select 'venue','organization','run by','structural',(select count(*) from venues where duplicate_of_id is null and organization_id is not null)
    union all select 'venue','village','in village','structural',(select count(*) from venues where duplicate_of_id is null and queer_village_id is not null)
    union all select 'event','venue','at venue','structural',(select count(*) from events where duplicate_of_id is null and venue_id is not null)
    union all select 'event','city','in city','geo',(select count(*) from events where duplicate_of_id is null and city_id is not null)
    union all select 'event','festival','part of','structural',(select count(*) from events where duplicate_of_id is null and festival_id is not null)
    union all select 'event','group','hosted by','structural',(select count(*) from events where duplicate_of_id is null and group_id is not null)
    union all select 'hotel','city','in city','geo',(select count(*) from hotels where city_id is not null)
    union all select 'hotel','village','in village','structural',(select count(*) from hotels where queer_village_id is not null)
    union all select 'organization','city','in city','geo',(select count(*) from organizations where city_id is not null)
    union all select 'organization','venue','primary venue','structural',(select count(*) from organizations where primary_venue_id is not null)
    union all select 'personality','city','born in','geo',(select count(*) from personalities where duplicate_of_id is null and city_id is not null)
    union all select 'personality','country','born in','geo',(select count(*) from personalities where duplicate_of_id is null and country_id is not null)
    union all select 'milestone','city','in city','geo',(select count(*) from milestones where duplicate_of_id is null and city_id is not null)
    union all select 'milestone','country','in country','geo',(select count(*) from milestones where duplicate_of_id is null and country_id is not null)
    union all select 'festival','city','in city','geo',(select count(*) from festivals where city_id is not null)
    union all select 'festival','venue','at venue','structural',(select count(*) from festivals where venue_id is not null)
    union all select 'village','city','in city','geo',(select count(*) from queer_villages where city_id is not null)
    union all select 'marketplace','venue','sold at','structural',(select count(*) from marketplace_listings where duplicate_of_id is null and venue_id is not null)
    union all select 'city','country','in country','geo',(select count(*) from cities where duplicate_of_id is null and country_id is not null)
    union all select 'country','continent','on continent','geo',(select count(*) from countries where duplicate_of_id is null and continent_id is not null)
    union all select 'country','region','in region','geo',(select count(*) from countries where duplicate_of_id is null and region_id is not null)
    union all select 'tag',
      case tag_facet_of(entity_type) when 'person' then 'personality' else tag_facet_of(entity_type) end,
      'tagged','tag',sum(cnt)::bigint
      from tag_types
      where tag_facet_of(entity_type) is not null and tag_facet_of(entity_type) <> 'tag'
      group by 2
    union all select 'tag','tag',relation_type,'ontology',count(*) from tag_relations group by relation_type
    union all select 'news',content_graph_norm_type(entity_type),'mentions','cross',sum(cnt)::bigint
      from news_types where content_graph_norm_type(entity_type) is not null group by 2
    union all select 'milestone',content_graph_norm_type(entity_type),'commemorates','cross',sum(cnt)::bigint
      from milestone_types where content_graph_norm_type(entity_type) is not null group by 2
    union all select 'personality','personality','related to','cross',(select count(*) from personality_relationships)
    union all select content_graph_norm_type(entity_type),'image','has media','media',sum(cnt)::bigint
      from image_types where content_graph_norm_type(entity_type) is not null group by 1
  )
  select jsonb_agg(jsonb_build_object(
    'source',src,'target',tgt,'relation',rel,'relation_kind',kind,'count',cnt
  ) order by cnt desc) into v_edges
  from e where cnt > 0;

  v_snapshot := jsonb_build_object(
    'nodes', coalesce(v_nodes,'[]'::jsonb),
    'edges', coalesce(v_edges,'[]'::jsonb),
    'generated_at', now()
  );

  insert into public.content_graph_stats(id,snapshot,generated_at)
  values (true, v_snapshot, now())
  on conflict (id) do update set snapshot = excluded.snapshot, generated_at = excluded.generated_at;

  return v_snapshot;
end;
$function$
;
