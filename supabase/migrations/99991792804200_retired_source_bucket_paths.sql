-- The retired publisher bucket also stored images under these two exact paths.
-- All individual-response, source identity and human ownership guards remain.
do $patch$
declare src text;code text;
 old_rule text:='com/events/[A-Za-z0-9._-]+[.](jpg|jpeg|png|webp)$';
 new_rule text:='com/events/(t/sm/|originals/)?[A-Za-z0-9._-]+[.](jpg|jpeg|png|webp)$';
begin
 src:=pg_get_functiondef('api_private.historical_graph_artwork_scope(uuid)'::regprocedure);
 code:=regexp_replace(src,'--[^'||chr(10)||']*','','g');
 if(length(code)-length(replace(code,old_rule,'')))/length(old_rule)<>1 then
  raise exception 'Retired bucket path guard drift';
 end if;
 execute replace(src,old_rule,new_rule);
 code:=regexp_replace(pg_get_functiondef('api_private.historical_graph_artwork_scope(uuid)'::regprocedure),'--[^'||chr(10)||']*','','g');
 if position(new_rule in code)=0 then raise exception 'Retired bucket path guard missing';end if;
end $patch$;
