begin;

delete from symphony_staging.contract_versions
where contract_name = 'cross-machine-claims';

do $$
declare
  principal record;
begin
  for principal in
    select login_role from symphony_staging.node_login_principals
  loop
    execute format(
      'revoke execute on function '
      'symphony_staging.claim_issue(text, uuid, uuid, timestamptz, text, integer, integer), '
      'symphony_staging.renew_claim(uuid, bigint, uuid, uuid, integer), '
      'symphony_staging.validate_active_claim(uuid, bigint, uuid, uuid), '
      'symphony_staging.release_claim(uuid, bigint, uuid, uuid), '
      'symphony_staging.complete_claim(uuid, bigint, uuid, uuid), '
      'symphony_staging.takeover_claim(text, uuid, uuid, timestamptz, integer, integer) from %I',
      principal.login_role
    );
  end loop;
end
$$;

drop trigger if exists grant_claim_api_to_node_login
  on symphony_staging.node_login_principals;
drop function if exists symphony_staging.grant_claim_api_to_node_login();

drop function if exists symphony_staging.takeover_claim(text, uuid, uuid, timestamptz, integer, integer);
drop function if exists symphony_staging.complete_claim(uuid, bigint, uuid, uuid);
drop function if exists symphony_staging.release_claim(uuid, bigint, uuid, uuid);
drop function if exists symphony_staging.finish_claim(uuid, bigint, uuid, uuid, text);
drop function if exists symphony_staging.validate_active_claim(uuid, bigint, uuid, uuid);
drop function if exists symphony_staging.renew_claim(uuid, bigint, uuid, uuid, integer);
drop function if exists symphony_staging.claim_issue(text, uuid, uuid, timestamptz, text, integer, integer);

drop table if exists symphony_staging.claim_audit_events;
drop table if exists symphony_staging.issue_claims;
drop table if exists symphony_staging.issue_claim_generations;

alter table symphony_staging.nodes drop column if exists claim_capacity;

commit;
