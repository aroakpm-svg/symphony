begin;

delete from symphony_staging.contract_versions where contract_name = 'handoff-receipt';

drop trigger if exists grant_handoff_api_to_node_login on symphony_staging.node_login_principals;
drop function if exists symphony_staging.grant_handoff_api_to_node_login();
drop function if exists symphony_staging.handoff_receipt_ready();
drop function if exists symphony_staging.handoff_legacy_effect_operation_id(text, text, uuid, bigint, uuid, uuid);
drop function if exists symphony_staging.handoff_effect_statuses(text, uuid, bigint, uuid, uuid, text[]);
drop function if exists symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid);
drop function if exists symphony_staging.append_handoff_receipt(text, uuid, bigint, uuid, uuid, integer, text, text, text, text, text, text, text, integer, text, text[], text[], jsonb, text[]);
drop function if exists symphony_staging.validate_handoff_tests(jsonb);
drop function if exists symphony_staging.validate_handoff_steps(text[], text[]);
drop table if exists symphony_staging.handoff_receipts;
alter table symphony_staging.effect_operations
  drop constraint if exists effect_operation_id_canonical;

do $$
begin
  if exists (
    select 1
    from symphony_staging.effect_operations operations
    where not exists (
      select 1
      from symphony_staging.effect_operation_id_upgrade upgrade
      where upgrade.canonical_operation_id = operations.operation_id
    )
  ) then
    raise exception using errcode = '55000',
      message = 'cannot roll back ARO-166 after new effect operations were recorded';
  end if;

  update symphony_staging.effect_operations operations
  set operation_id = upgrade.original_operation_id
  from symphony_staging.effect_operation_id_upgrade upgrade
  where operations.operation_id = upgrade.canonical_operation_id;
end
$$;

drop table symphony_staging.effect_operation_id_upgrade;

commit;
