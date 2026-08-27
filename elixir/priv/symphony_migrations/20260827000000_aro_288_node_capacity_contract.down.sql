begin;

delete from symphony_staging.contract_versions
where contract_name = 'node-capacity-contract';

do $$
declare
  principal record;
begin
  for principal in
    select login_role from symphony_staging.node_login_principals
  loop
    execute format(
      'revoke all on function symphony_staging.current_node_claim_capacity() from %I',
      principal.login_role
    );
  end loop;
end
$$;

create or replace function symphony_staging.grant_claim_api_to_node_login()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  execute format(
    'grant execute on function '
    'symphony_staging.claim_issue(text, uuid, uuid, timestamptz, text, text[], integer, integer), '
    'symphony_staging.renew_claim(uuid, bigint, uuid, uuid, integer), '
    'symphony_staging.validate_active_claim(uuid, bigint, uuid, uuid), '
    'symphony_staging.release_claim(uuid, bigint, uuid, uuid), '
    'symphony_staging.complete_claim(uuid, bigint, uuid, uuid), '
    'symphony_staging.takeover_claim(text, uuid, uuid, timestamptz, text[], integer, integer) to %I',
    new.login_role
  );
  return new;
end
$$;

drop function if exists symphony_staging.current_node_claim_capacity();

commit;
