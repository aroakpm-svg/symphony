begin;

select pg_catalog.pg_advisory_xact_lock(
  pg_catalog.hashtextextended('aroak:symphony_staging:migrations', 0)
);

do $$
declare
  managed_role name;
  managed_state record;
  expected_membership_count integer :=
    case when current_setting('is_superuser') = 'on' then 1 else 2 end;
begin
  if not exists (
    select 1
    from symphony_staging.contract_versions
    where contract_name = 'node-identity-routing-foundation'
      and contract_version = 2
      and migration_name = '20260724000000_aro_168_staging_reconciliation'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 requires the reconciled ARO-168 contract v2';
  end if;

  lock table
    symphony_staging.contract_versions,
    symphony_staging.nodes,
    symphony_staging.node_bindings,
    symphony_staging.routing_assignments,
    symphony_staging.foundation_audit_events
    in access exclusive mode;

  if (select count(*) from symphony_staging.contract_versions) <> 1
     or exists (select 1 from symphony_staging.nodes)
     or exists (select 1 from symphony_staging.node_bindings)
     or exists (select 1 from symphony_staging.routing_assignments)
     or exists (select 1 from symphony_staging.foundation_audit_events) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 requires an empty, exact ARO-168 v2 data state';
  end if;

  if exists (
    with expected(
      object_name, object_kind, persistence, replica_identity,
      row_security, force_row_security
    ) as (
      values
        ('contract_versions', 'r'::"char", 'p'::"char", 'd'::"char", true, false),
        ('contract_versions_pkey', 'i'::"char", 'p'::"char", 'n'::"char", false, false),
        ('nodes', 'r'::"char", 'p'::"char", 'd'::"char", true, false),
        ('nodes_pkey', 'i'::"char", 'p'::"char", 'n'::"char", false, false),
        ('node_bindings', 'r'::"char", 'p'::"char", 'd'::"char", true, false),
        ('node_bindings_pkey', 'i'::"char", 'p'::"char", 'n'::"char", false, false),
        ('node_bindings_node_id_environment_credential_version_key', 'i'::"char", 'p'::"char", 'n'::"char", false, false),
        ('node_bindings_one_active_per_node', 'i'::"char", 'p'::"char", 'n'::"char", false, false),
        ('node_bindings_one_rotating_per_node', 'i'::"char", 'p'::"char", 'n'::"char", false, false),
        ('routing_assignments', 'r'::"char", 'p'::"char", 'd'::"char", true, false),
        ('routing_assignments_pkey', 'i'::"char", 'p'::"char", 'n'::"char", false, false),
        ('routing_assignments_target_node_id_idx', 'i'::"char", 'p'::"char", 'n'::"char", false, false),
        ('foundation_audit_events', 'r'::"char", 'p'::"char", 'd'::"char", true, false),
        ('foundation_audit_events_pkey', 'i'::"char", 'p'::"char", 'n'::"char", false, false),
        ('foundation_audit_events_audit_id_seq', 'S'::"char", 'p'::"char", 'n'::"char", false, false)
    ),
    actual as (
      select
        relation.relname::text, relation.relkind, relation.relpersistence,
        relation.relreplident, relation.relrowsecurity,
        relation.relforcerowsecurity
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
      where namespace.nspname = 'symphony_staging'
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 relation inventory';
  end if;

  if exists (
    with expected(
      table_name, column_name, ordinal, type_name, not_null,
      identity_kind, generated_kind, default_expression
    ) as (
      values
        ('contract_versions', 'contract_name', 1, 'text', true, '', '', ''),
        ('contract_versions', 'contract_version', 2, 'integer', true, '', '', ''),
        ('contract_versions', 'migration_name', 3, 'text', true, '', '', ''),
        ('contract_versions', 'installed_at', 4, 'timestamp with time zone', true, '', '', 'clock_timestamp()'),
        ('nodes', 'node_id', 1, 'uuid', true, '', '', ''),
        ('nodes', 'display_alias', 2, 'text', false, '', '', ''),
        ('nodes', 'status', 3, 'text', true, '', '', ''),
        ('nodes', 'credential_version', 4, 'integer', true, '', '', '1'),
        ('nodes', 'created_at', 5, 'timestamp with time zone', true, '', '', 'clock_timestamp()'),
        ('nodes', 'updated_at', 6, 'timestamp with time zone', true, '', '', 'clock_timestamp()'),
        ('nodes', 'rotated_at', 7, 'timestamp with time zone', false, '', '', ''),
        ('nodes', 'revoked_at', 8, 'timestamp with time zone', false, '', '', ''),
        ('nodes', 'retired_at', 9, 'timestamp with time zone', false, '', '', ''),
        ('node_bindings', 'binding_id', 1, 'uuid', true, '', '', ''),
        ('node_bindings', 'node_id', 2, 'uuid', true, '', '', ''),
        ('node_bindings', 'environment', 3, 'text', true, '', '', ''),
        ('node_bindings', 'status', 4, 'text', true, '', '', ''),
        ('node_bindings', 'credential_version', 5, 'integer', true, '', '', ''),
        ('node_bindings', 'credential_verifier', 6, 'text', true, '', '', ''),
        ('node_bindings', 'created_at', 7, 'timestamp with time zone', true, '', '', 'clock_timestamp()'),
        ('node_bindings', 'activated_at', 8, 'timestamp with time zone', false, '', '', ''),
        ('node_bindings', 'rotated_at', 9, 'timestamp with time zone', false, '', '', ''),
        ('node_bindings', 'revoked_at', 10, 'timestamp with time zone', false, '', '', ''),
        ('node_bindings', 'retired_at', 11, 'timestamp with time zone', false, '', '', ''),
        ('routing_assignments', 'issue_id', 1, 'text', true, '', '', ''),
        ('routing_assignments', 'routing_policy', 2, 'text', true, '', '', ''),
        ('routing_assignments', 'target_node_id', 3, 'uuid', false, '', '', ''),
        ('routing_assignments', 'routing_revision', 4, 'bigint', true, '', '', ''),
        ('routing_assignments', 'contract_version', 5, 'integer', true, '', '', ''),
        ('routing_assignments', 'updated_at', 6, 'timestamp with time zone', true, '', '', 'clock_timestamp()'),
        ('foundation_audit_events', 'audit_id', 1, 'bigint', true, 'a', '', ''),
        ('foundation_audit_events', 'event_type', 2, 'text', true, '', '', ''),
        ('foundation_audit_events', 'node_id', 3, 'uuid', false, '', '', ''),
        ('foundation_audit_events', 'binding_id', 4, 'uuid', false, '', '', ''),
        ('foundation_audit_events', 'issue_id', 5, 'text', false, '', '', ''),
        ('foundation_audit_events', 'routing_revision', 6, 'bigint', false, '', '', ''),
        ('foundation_audit_events', 'credential_version', 7, 'integer', false, '', '', ''),
        ('foundation_audit_events', 'result', 8, 'text', true, '', '', ''),
        ('foundation_audit_events', 'reason_code', 9, 'text', true, '', '', ''),
        ('foundation_audit_events', 'details', 10, 'jsonb', true, '', '', '''{}''::jsonb'),
        ('foundation_audit_events', 'occurred_at', 11, 'timestamp with time zone', true, '', '', 'clock_timestamp()')
    ),
    actual as (
      select
        relation.relname::text,
        attribute.attname::text,
        attribute.attnum::integer,
        format_type(attribute.atttypid, attribute.atttypmod),
        attribute.attnotnull,
        attribute.attidentity::text,
        attribute.attgenerated::text,
        coalesce(pg_get_expr(default_value.adbin, default_value.adrelid), '')
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
      join pg_attribute attribute on attribute.attrelid = relation.oid
      left join pg_attrdef default_value
        on default_value.adrelid = relation.oid
       and default_value.adnum = attribute.attnum
      where namespace.nspname = 'symphony_staging'
        and relation.relkind = 'r'
        and attribute.attnum > 0
        and not attribute.attisdropped
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 column/default/identity state';
  end if;

  if exists (
    with expected(table_name, constraint_name, constraint_definition) as (
      values
        ('contract_versions', 'contract_versions_pkey', 'PRIMARY KEY (contract_name)'),
        ('contract_versions', 'contract_versions_contract_version_check', 'CHECK (contract_version > 0)'),
        ('nodes', 'nodes_pkey', 'PRIMARY KEY (node_id)'),
        ('nodes', 'nodes_status_check', 'CHECK (status = ANY (ARRAY[''active''::text, ''disabled''::text, ''retired''::text]))'),
        ('nodes', 'nodes_credential_version_check', 'CHECK (credential_version > 0)'),
        ('nodes', 'nodes_check', 'CHECK (status <> ''active''::text OR revoked_at IS NULL AND retired_at IS NULL)'),
        ('nodes', 'nodes_check1', 'CHECK (status <> ''disabled''::text OR revoked_at IS NOT NULL AND retired_at IS NULL)'),
        ('nodes', 'nodes_check2', 'CHECK (status <> ''retired''::text OR retired_at IS NOT NULL)'),
        ('node_bindings', 'node_bindings_pkey', 'PRIMARY KEY (binding_id)'),
        ('node_bindings', 'node_bindings_node_id_fkey', 'FOREIGN KEY (node_id) REFERENCES nodes(node_id) ON DELETE RESTRICT'),
        ('node_bindings', 'node_bindings_environment_check', 'CHECK (environment = ''staging''::text)'),
        ('node_bindings', 'node_bindings_status_check', 'CHECK (status = ANY (ARRAY[''pending''::text, ''active''::text, ''rotating''::text, ''revoked''::text, ''retired''::text]))'),
        ('node_bindings', 'node_bindings_credential_version_check', 'CHECK (credential_version > 0)'),
        ('node_bindings', 'node_bindings_credential_verifier_check', 'CHECK (credential_verifier ~ ''^[A-Fa-f0-9]{64}$''::text)'),
        ('node_bindings', 'node_bindings_check', 'CHECK (status <> ''active''::text OR activated_at IS NOT NULL)'),
        ('node_bindings', 'node_bindings_check1', 'CHECK (status <> ''rotating''::text OR rotated_at IS NOT NULL)'),
        ('node_bindings', 'node_bindings_check2', 'CHECK (status <> ''revoked''::text OR revoked_at IS NOT NULL)'),
        ('node_bindings', 'node_bindings_check3', 'CHECK (status <> ''retired''::text OR retired_at IS NOT NULL)'),
        ('node_bindings', 'node_bindings_node_id_environment_credential_version_key', 'UNIQUE (node_id, environment, credential_version)'),
        ('routing_assignments', 'routing_assignments_pkey', 'PRIMARY KEY (issue_id)'),
        ('routing_assignments', 'routing_assignments_target_node_id_fkey', 'FOREIGN KEY (target_node_id) REFERENCES nodes(node_id) ON DELETE RESTRICT'),
        ('routing_assignments', 'routing_assignments_routing_policy_check', 'CHECK (routing_policy = ANY (ARRAY[''unassigned''::text, ''preferred-with-fallback''::text, ''exclusive''::text]))'),
        ('routing_assignments', 'routing_assignments_routing_revision_check', 'CHECK (routing_revision > 0)'),
        ('routing_assignments', 'routing_assignments_contract_version_check', 'CHECK (contract_version > 0)'),
        ('routing_assignments', 'routing_assignments_check', 'CHECK (routing_policy = ''unassigned''::text AND target_node_id IS NULL OR (routing_policy = ANY (ARRAY[''preferred-with-fallback''::text, ''exclusive''::text])) AND target_node_id IS NOT NULL)'),
        ('foundation_audit_events', 'foundation_audit_events_pkey', 'PRIMARY KEY (audit_id)'),
        ('foundation_audit_events', 'foundation_audit_events_result_check', 'CHECK (result = ANY (ARRAY[''accepted''::text, ''rejected''::text, ''unknown''::text]))'),
        ('foundation_audit_events', 'foundation_audit_events_details_check', 'CHECK (jsonb_typeof(details) = ''object''::text)')
    ),
    actual as (
      select
        relation.relname::text,
        constraint_row.conname::text,
        replace(
          pg_get_constraintdef(constraint_row.oid, true),
          'symphony_staging.',
          ''
        )
      from pg_constraint constraint_row
      join pg_class relation on relation.oid = constraint_row.conrelid
      join pg_namespace namespace on namespace.oid = relation.relnamespace
      where namespace.nspname = 'symphony_staging'
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 constraint state';
  end if;

  if exists (
    with expected(
      function_name,
      source_hash,
      return_type,
      argument_count,
      security_definer,
      volatility,
      role_config,
      language_name
    ) as (
      values
        (
          'enforce_node_transition',
          '8099b4db79335d1b44c7d6d51b4dea50',
          'trigger',
          0::smallint,
          false,
          'v'::"char",
          array['search_path=pg_catalog, symphony_staging']::text[],
          'plpgsql'
        ),
        (
          'enforce_node_binding_transition',
          'e42862b88958f9d797b5da93134f8a7c',
          'trigger',
          0::smallint,
          false,
          'v'::"char",
          array['search_path=pg_catalog, symphony_staging']::text[],
          'plpgsql'
        ),
        (
          'enforce_routing_revision',
          'fb1dd9b95bb3dd713331adc980876b56',
          'trigger',
          0::smallint,
          false,
          'v'::"char",
          array['search_path=pg_catalog, symphony_staging']::text[],
          'plpgsql'
        )
    ),
    actual as (
      select
        procedure.proname::text,
        md5(procedure.prosrc),
        procedure.prorettype::regtype::text,
        procedure.pronargs,
        procedure.prosecdef,
        procedure.provolatile,
        procedure.proconfig,
        language.lanname::text
      from pg_proc procedure
      join pg_namespace namespace on namespace.oid = procedure.pronamespace
      join pg_language language on language.oid = procedure.prolang
      where namespace.nspname = 'symphony_staging'
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 function inventory or definition';
  end if;

  if exists (
    select 1
    from pg_type type_object
    join pg_namespace namespace on namespace.oid = type_object.typnamespace
    where namespace.nspname = 'symphony_staging'
      and type_object.typrelid = 0
      and type_object.typelem = 0
  )
  or exists (
    select 1 from pg_operator object
    join pg_namespace namespace on namespace.oid = object.oprnamespace
    where namespace.nspname = 'symphony_staging'
  )
  or exists (
    select 1 from pg_collation object
    join pg_namespace namespace on namespace.oid = object.collnamespace
    where namespace.nspname = 'symphony_staging'
  )
  or exists (
    select 1 from pg_conversion object
    join pg_namespace namespace on namespace.oid = object.connamespace
    where namespace.nspname = 'symphony_staging'
  )
  or exists (
    select 1 from pg_opclass object
    join pg_namespace namespace on namespace.oid = object.opcnamespace
    where namespace.nspname = 'symphony_staging'
  )
  or exists (
    select 1 from pg_opfamily object
    join pg_namespace namespace on namespace.oid = object.opfnamespace
    where namespace.nspname = 'symphony_staging'
  )
  or exists (
    select 1 from pg_ts_config object
    join pg_namespace namespace on namespace.oid = object.cfgnamespace
    where namespace.nspname = 'symphony_staging'
  )
  or exists (
    select 1 from pg_ts_dict object
    join pg_namespace namespace on namespace.oid = object.dictnamespace
    where namespace.nspname = 'symphony_staging'
  )
  or exists (
    select 1 from pg_ts_parser object
    join pg_namespace namespace on namespace.oid = object.prsnamespace
    where namespace.nspname = 'symphony_staging'
  )
  or exists (
    select 1 from pg_ts_template object
    join pg_namespace namespace on namespace.oid = object.tmplnamespace
    where namespace.nspname = 'symphony_staging'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 auxiliary object inventory';
  end if;

  if exists (
    with expected(
      trigger_name, table_name, function_identity, enabled, trigger_definition
    ) as (
      values
        ('enforce_node_transition', 'nodes',
         'symphony_staging.enforce_node_transition()', 'O'::"char",
         'CREATE TRIGGER enforce_node_transition BEFORE UPDATE ON symphony_staging.nodes FOR EACH ROW EXECUTE FUNCTION symphony_staging.enforce_node_transition()'),
        ('enforce_node_binding_transition', 'node_bindings',
         'symphony_staging.enforce_node_binding_transition()', 'O'::"char",
         'CREATE TRIGGER enforce_node_binding_transition BEFORE UPDATE ON symphony_staging.node_bindings FOR EACH ROW EXECUTE FUNCTION symphony_staging.enforce_node_binding_transition()'),
        ('enforce_routing_revision', 'routing_assignments',
         'symphony_staging.enforce_routing_revision()', 'O'::"char",
         'CREATE TRIGGER enforce_routing_revision BEFORE UPDATE ON symphony_staging.routing_assignments FOR EACH ROW EXECUTE FUNCTION symphony_staging.enforce_routing_revision()')
    ),
    actual as (
      select
        trigger_row.tgname::text,
        relation.relname::text,
        procedure.oid::regprocedure::text,
        trigger_row.tgenabled,
        pg_get_triggerdef(trigger_row.oid, true)
      from pg_trigger trigger_row
      join pg_class relation on relation.oid = trigger_row.tgrelid
      join pg_namespace namespace on namespace.oid = relation.relnamespace
      join pg_proc procedure on procedure.oid = trigger_row.tgfoid
      where namespace.nspname = 'symphony_staging'
        and not trigger_row.tgisinternal
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 trigger state';
  end if;

  if exists (
    select 1
    from pg_trigger trigger_row
    join pg_class relation on relation.oid = trigger_row.tgrelid
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname = 'symphony_staging'
      and trigger_row.tgisinternal
      and trigger_row.tgenabled <> 'O'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe disabled internal constraint trigger state';
  end if;

  if exists (
    select 1
    from pg_rewrite rewrite
    join pg_class relation on relation.oid = rewrite.ev_class
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname in ('symphony_staging', 'symphony_production')
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 rewrite-rule state';
  end if;

  if exists (
    with expected(index_name, replica_identity, index_definition) as (
      values
        ('contract_versions_pkey', false,
         'CREATE UNIQUE INDEX contract_versions_pkey ON symphony_staging.contract_versions USING btree (contract_name)'),
        ('nodes_pkey', false,
         'CREATE UNIQUE INDEX nodes_pkey ON symphony_staging.nodes USING btree (node_id)'),
        ('node_bindings_pkey', false,
         'CREATE UNIQUE INDEX node_bindings_pkey ON symphony_staging.node_bindings USING btree (binding_id)'),
        ('node_bindings_node_id_environment_credential_version_key', false,
         'CREATE UNIQUE INDEX node_bindings_node_id_environment_credential_version_key ON symphony_staging.node_bindings USING btree (node_id, environment, credential_version)'),
        ('node_bindings_one_active_per_node', false,
         'CREATE UNIQUE INDEX node_bindings_one_active_per_node ON symphony_staging.node_bindings USING btree (node_id, environment) WHERE (status = ''active''::text)'),
        ('node_bindings_one_rotating_per_node', false,
         'CREATE UNIQUE INDEX node_bindings_one_rotating_per_node ON symphony_staging.node_bindings USING btree (node_id, environment) WHERE (status = ''rotating''::text)'),
        ('routing_assignments_pkey', false,
         'CREATE UNIQUE INDEX routing_assignments_pkey ON symphony_staging.routing_assignments USING btree (issue_id)'),
        ('routing_assignments_target_node_id_idx', false,
         'CREATE INDEX routing_assignments_target_node_id_idx ON symphony_staging.routing_assignments USING btree (target_node_id)'),
        ('foundation_audit_events_pkey', false,
         'CREATE UNIQUE INDEX foundation_audit_events_pkey ON symphony_staging.foundation_audit_events USING btree (audit_id)')
    ),
    actual as (
      select
        index_relation.relname::text,
        index_state.indisreplident,
        pg_get_indexdef(index_relation.oid)
      from pg_index index_state
      join pg_class index_relation on index_relation.oid = index_state.indexrelid
      join pg_class relation on relation.oid = index_state.indrelid
      join pg_namespace namespace on namespace.oid = relation.relnamespace
      where namespace.nspname = 'symphony_staging'
        and index_state.indisvalid
        and index_state.indisready
        and index_state.indislive
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 index state';
  end if;

  if not exists (
    select 1
    from pg_sequence sequence_state
    join pg_class relation on relation.oid = sequence_state.seqrelid
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname = 'symphony_staging'
      and relation.relname = 'foundation_audit_events_audit_id_seq'
      and sequence_state.seqtypid::regtype::text = 'bigint'
      and sequence_state.seqstart = 1
      and sequence_state.seqincrement = 1
      and sequence_state.seqmin = 1
      and sequence_state.seqmax = 9223372036854775807
      and sequence_state.seqcache = 1
      and not sequence_state.seqcycle
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 sequence configuration';
  end if;

  foreach managed_role in array array[
    'symphony_staging_runtime'::name,
    'symphony_staging_provisioner'::name
  ]
  loop
    select *
    into strict managed_state
    from pg_roles
    where rolname = managed_role;

    if managed_state.rolcanlogin
       or managed_state.rolsuper
       or managed_state.rolcreatedb
       or managed_state.rolcreaterole
       or managed_state.rolinherit
       or managed_state.rolreplication
       or managed_state.rolbypassrls
       or managed_state.rolconfig is not null then
      raise exception using
        errcode = '55000',
        message = format('ARO-169 unsafe ARO-168 role state for %s', managed_role);
    end if;

    if (
      select count(*)
      from pg_auth_members membership
      join pg_roles granted_role on granted_role.oid = membership.roleid
      where granted_role.rolname = managed_role
    ) <> expected_membership_count
    or (
      select count(*)
      from pg_auth_members membership
      join pg_roles granted_role on granted_role.oid = membership.roleid
      join pg_roles member_role on member_role.oid = membership.member
      join pg_roles grantor_role on grantor_role.oid = membership.grantor
      where granted_role.rolname = managed_role
        and member_role.rolname = 'postgres'
        and (
          (
            grantor_role.rolname = 'postgres'
            and not membership.admin_option
            and membership.inherit_option
            and membership.set_option
          )
          or (
            current_setting('is_superuser') <> 'on'
            and grantor_role.rolname = 'supabase_admin'
            and membership.admin_option
            and not membership.inherit_option
            and not membership.set_option
          )
        )
    ) <> expected_membership_count
    or exists (
      select 1
      from pg_auth_members membership
      where membership.member = managed_state.oid
         or membership.grantor = managed_state.oid
    ) then
      raise exception using
        errcode = '55000',
        message = format(
          'ARO-169 unsafe ARO-168 membership graph for %s',
          managed_role
        );
    end if;

    if not has_schema_privilege(managed_role, 'symphony_staging', 'USAGE')
       or has_schema_privilege(managed_role, 'symphony_staging', 'CREATE')
       or has_schema_privilege(managed_role, 'symphony_production', 'USAGE')
       or has_schema_privilege(managed_role, 'symphony_production', 'CREATE') then
      raise exception using
        errcode = '55000',
        message = format(
          'ARO-169 unsafe ARO-168 schema privileges for %s',
          managed_role
        );
    end if;
  end loop;

  if exists (
    select 1
    from (values ('anon'), ('authenticated'), ('service_role')) actor(role_name)
    where has_schema_privilege(actor.role_name, 'symphony_staging', 'USAGE')
       or has_schema_privilege(actor.role_name, 'symphony_staging', 'CREATE')
       or has_schema_privilege(actor.role_name, 'symphony_production', 'USAGE')
       or has_schema_privilege(actor.role_name, 'symphony_production', 'CREATE')
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 public role environment access';
  end if;

  if exists (
    select 1
    from pg_class relation
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname = 'symphony_staging'
      and relation.relname in (
        'contract_versions',
        'nodes',
        'node_bindings',
        'routing_assignments',
        'foundation_audit_events',
        'foundation_audit_events_audit_id_seq'
      )
      and (
        pg_get_userbyid(relation.relowner) <> 'postgres'
        or (
          relation.relkind <> 'S'
          and (
            not relation.relrowsecurity
            or relation.relforcerowsecurity
          )
        )
      )
  )
  or exists (
    select 1
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'symphony_staging'
      and procedure.proname in (
        'enforce_node_transition',
        'enforce_node_binding_transition',
        'enforce_routing_revision'
      )
      and pg_get_userbyid(procedure.proowner) <> 'postgres'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 ownership or row-security state';
  end if;

  if exists (
    with expected(object_name, grantee_name, privilege_type) as (
      values
        ('contract_versions', 'symphony_staging_runtime', 'SELECT'),
        ('routing_assignments', 'symphony_staging_runtime', 'SELECT'),
        ('foundation_audit_events_audit_id_seq', 'symphony_staging_runtime', 'SELECT'),
        ('foundation_audit_events_audit_id_seq', 'symphony_staging_runtime', 'USAGE'),
        ('contract_versions', 'symphony_staging_provisioner', 'SELECT'),
        ('contract_versions', 'symphony_staging_provisioner', 'INSERT'),
        ('contract_versions', 'symphony_staging_provisioner', 'UPDATE'),
        ('nodes', 'symphony_staging_provisioner', 'SELECT'),
        ('nodes', 'symphony_staging_provisioner', 'INSERT'),
        ('nodes', 'symphony_staging_provisioner', 'UPDATE'),
        ('node_bindings', 'symphony_staging_provisioner', 'SELECT'),
        ('node_bindings', 'symphony_staging_provisioner', 'INSERT'),
        ('node_bindings', 'symphony_staging_provisioner', 'UPDATE'),
        ('routing_assignments', 'symphony_staging_provisioner', 'SELECT'),
        ('routing_assignments', 'symphony_staging_provisioner', 'INSERT'),
        ('routing_assignments', 'symphony_staging_provisioner', 'UPDATE'),
        ('foundation_audit_events', 'symphony_staging_provisioner', 'INSERT'),
        ('foundation_audit_events_audit_id_seq', 'symphony_staging_provisioner', 'SELECT'),
        ('foundation_audit_events_audit_id_seq', 'symphony_staging_provisioner', 'USAGE')
    ),
    actual as (
      select
        relation.relname::text,
        grantee.rolname::text,
        acl.privilege_type::text
      from pg_class relation
      join pg_namespace namespace on namespace.oid = relation.relnamespace
      cross join lateral aclexplode(relation.relacl) acl
      join pg_roles grantee on grantee.oid = acl.grantee
      where namespace.nspname = 'symphony_staging'
        and relation.relname in (
          'contract_versions',
          'nodes',
          'node_bindings',
          'routing_assignments',
          'foundation_audit_events',
          'foundation_audit_events_audit_id_seq'
        )
        and grantee.rolname in (
          'symphony_staging_runtime',
          'symphony_staging_provisioner'
        )
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 direct object ACL state';
  end if;

  if exists (
    with expected(table_name, column_name, grantee_name, privilege_type) as (
      values
        ('nodes', 'node_id', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'display_alias', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'status', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'credential_version', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'created_at', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'updated_at', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'rotated_at', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'revoked_at', 'symphony_staging_runtime', 'SELECT'),
        ('nodes', 'retired_at', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'binding_id', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'node_id', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'environment', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'status', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'credential_version', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'created_at', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'activated_at', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'rotated_at', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'revoked_at', 'symphony_staging_runtime', 'SELECT'),
        ('node_bindings', 'retired_at', 'symphony_staging_runtime', 'SELECT'),
        ('foundation_audit_events', 'event_type', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'node_id', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'binding_id', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'issue_id', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'routing_revision', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'credential_version', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'result', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'reason_code', 'symphony_staging_runtime', 'INSERT'),
        ('foundation_audit_events', 'details', 'symphony_staging_runtime', 'INSERT')
    ),
    actual as (
      select
        relation.relname::text,
        attribute.attname::text,
        grantee.rolname::text,
        acl.privilege_type::text
      from pg_attribute attribute
      join pg_class relation on relation.oid = attribute.attrelid
      join pg_namespace namespace on namespace.oid = relation.relnamespace
      cross join lateral aclexplode(attribute.attacl) acl
      join pg_roles grantee on grantee.oid = acl.grantee
      where namespace.nspname = 'symphony_staging'
        and relation.relname in (
          'contract_versions',
          'nodes',
          'node_bindings',
          'routing_assignments',
          'foundation_audit_events'
        )
        and attribute.attnum > 0
        and not attribute.attisdropped
        and grantee.rolname in (
          'symphony_staging_runtime',
          'symphony_staging_provisioner'
        )
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 direct column ACL state';
  end if;

  if exists (
    select 1
    from pg_class relation
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    cross join lateral aclexplode(coalesce(
      relation.relacl,
      acldefault(
        case when relation.relkind = 'S' then 'S'::"char" else 'r'::"char" end,
        relation.relowner
      )
    )) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where namespace.nspname = 'symphony_staging'
      and relation.relname in (
        'contract_versions',
        'nodes',
        'node_bindings',
        'routing_assignments',
        'foundation_audit_events',
        'foundation_audit_events_audit_id_seq'
      )
      and (
        acl.is_grantable and acl.grantee <> relation.relowner
        or coalesce(grantee.rolname, 'PUBLIC') not in (
          'postgres',
          'symphony_staging_runtime',
          'symphony_staging_provisioner'
        )
      )
  )
  or exists (
    select 1
    from pg_attribute attribute
    join pg_class relation on relation.oid = attribute.attrelid
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    cross join lateral aclexplode(attribute.attacl) acl
    left join pg_roles grantee on grantee.oid = acl.grantee
    where namespace.nspname = 'symphony_staging'
      and relation.relname in (
        'contract_versions',
        'nodes',
        'node_bindings',
        'routing_assignments',
        'foundation_audit_events'
      )
      and attribute.attnum > 0
      and not attribute.attisdropped
      and (
        acl.is_grantable
        or coalesce(grantee.rolname, 'PUBLIC') not in (
          'symphony_staging_runtime',
          'symphony_staging_provisioner'
        )
      )
  )
  or exists (
    select 1
    from pg_default_acl default_acl
    left join pg_namespace namespace
      on namespace.oid = default_acl.defaclnamespace
    where (
        default_acl.defaclnamespace = 0
        or namespace.nspname in ('symphony_staging', 'symphony_production')
      )
      and pg_get_userbyid(default_acl.defaclrole) = 'postgres'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 ACL or default-ACL state';
  end if;

  if exists (
    select 1
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    cross join lateral aclexplode(coalesce(
      procedure.proacl,
      acldefault('f', procedure.proowner)
    )) acl
    where namespace.nspname = 'symphony_staging'
      and procedure.proname in (
        'enforce_node_transition',
        'enforce_node_binding_transition',
        'enforce_routing_revision'
      )
      and (
        acl.grantee <> procedure.proowner
        or acl.is_grantable and acl.grantee <> procedure.proowner
      )
  )
  or exists (
    with expected(schema_name, grantee_name, privilege_type, is_grantable) as (
      values
        ('symphony_staging', 'postgres', 'CREATE', false),
        ('symphony_staging', 'postgres', 'USAGE', false),
        ('symphony_staging', 'symphony_staging_runtime', 'USAGE', false),
        ('symphony_staging', 'symphony_staging_provisioner', 'USAGE', false),
        ('symphony_production', 'postgres', 'CREATE', false),
        ('symphony_production', 'postgres', 'USAGE', false)
    ),
    actual as (
      select
        namespace.nspname::text,
        coalesce(grantee.rolname, 'PUBLIC')::text,
        acl.privilege_type::text,
        acl.is_grantable
      from pg_namespace namespace
      cross join lateral aclexplode(coalesce(
        namespace.nspacl,
        acldefault('n', namespace.nspowner)
      )) acl
      left join pg_roles grantee on grantee.oid = acl.grantee
      where namespace.nspname in ('symphony_staging', 'symphony_production')
        and pg_get_userbyid(namespace.nspowner) = 'postgres'
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  )
  or exists (
    select 1
    from pg_namespace namespace
    where namespace.nspname in ('symphony_staging', 'symphony_production')
      and pg_get_userbyid(namespace.nspowner) <> 'postgres'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 function or schema ACL state';
  end if;

  if exists (
    select 1 from pg_class object
    join pg_namespace namespace on namespace.oid = object.relnamespace
    where namespace.nspname = 'symphony_production'
  )
  or exists (
    select 1 from pg_proc object
    join pg_namespace namespace on namespace.oid = object.pronamespace
    where namespace.nspname = 'symphony_production'
  )
  or exists (
    select 1 from pg_type object
    join pg_namespace namespace on namespace.oid = object.typnamespace
    where namespace.nspname = 'symphony_production'
      and object.typrelid = 0 and object.typelem = 0
  )
  or exists (
    select 1 from pg_operator object
    join pg_namespace namespace on namespace.oid = object.oprnamespace
    where namespace.nspname = 'symphony_production'
  )
  or exists (
    select 1 from pg_collation object
    join pg_namespace namespace on namespace.oid = object.collnamespace
    where namespace.nspname = 'symphony_production'
  )
  or exists (
    select 1 from pg_conversion object
    join pg_namespace namespace on namespace.oid = object.connamespace
    where namespace.nspname = 'symphony_production'
  )
  or exists (
    select 1 from pg_opclass object
    join pg_namespace namespace on namespace.oid = object.opcnamespace
    where namespace.nspname = 'symphony_production'
  )
  or exists (
    select 1 from pg_opfamily object
    join pg_namespace namespace on namespace.oid = object.opfnamespace
    where namespace.nspname = 'symphony_production'
  )
  or exists (
    select 1 from pg_ts_config object
    join pg_namespace namespace on namespace.oid = object.cfgnamespace
    where namespace.nspname = 'symphony_production'
  )
  or exists (
    select 1 from pg_ts_dict object
    join pg_namespace namespace on namespace.oid = object.dictnamespace
    where namespace.nspname = 'symphony_production'
  )
  or exists (
    select 1 from pg_ts_parser object
    join pg_namespace namespace on namespace.oid = object.prsnamespace
    where namespace.nspname = 'symphony_production'
  )
  or exists (
    select 1 from pg_ts_template object
    join pg_namespace namespace on namespace.oid = object.tmplnamespace
    where namespace.nspname = 'symphony_production'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 requires an empty production schema';
  end if;

  if exists (
    with expected(tablename, policyname, permissive, roles, cmd, qual, with_check) as (
      values
        ('contract_versions', 'runtime_read_contract_versions',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT',
         '(contract_name !~~ ''aro-163-created-role:%''::text)', null),
        ('nodes', 'runtime_read_nodes',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('node_bindings', 'runtime_read_node_bindings',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('routing_assignments', 'runtime_read_routing_assignments',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'SELECT', 'true', null),
        ('foundation_audit_events', 'runtime_insert_audit_events',
         'PERMISSIVE', array['symphony_staging_runtime']::name[], 'INSERT', null, 'true'),
        ('contract_versions', 'provisioner_manage_contract_versions',
         'PERMISSIVE', array['symphony_staging_provisioner']::name[], 'ALL',
         '(contract_name !~~ ''aro-163-created-role:%''::text)',
         '(contract_name !~~ ''aro-163-created-role:%''::text)'),
        ('nodes', 'provisioner_manage_nodes',
         'PERMISSIVE', array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'),
        ('node_bindings', 'provisioner_manage_node_bindings',
         'PERMISSIVE', array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'),
        ('routing_assignments', 'provisioner_manage_routing_assignments',
         'PERMISSIVE', array['symphony_staging_provisioner']::name[], 'ALL', 'true', 'true'),
        ('foundation_audit_events', 'provisioner_insert_audit_events',
         'PERMISSIVE', array['symphony_staging_provisioner']::name[], 'INSERT', null, 'true')
    ),
    actual as (
      select tablename, policyname, permissive, roles, cmd, qual, with_check
      from pg_policies
      where schemaname = 'symphony_staging'
    )
    (select * from expected except select * from actual)
    union all
    (select * from actual except select * from expected)
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 unsafe ARO-168 RLS policy state';
  end if;
end
$$;

create table symphony_staging.node_login_principals (
  node_id uuid primary key
    references symphony_staging.nodes(node_id) on delete restrict,
  login_role name not null unique,
  created_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz
);

create table symphony_staging.node_principal_history (
  node_id uuid not null
    references symphony_staging.nodes(node_id) on delete restrict,
  credential_version integer not null check (credential_version > 0),
  login_role name not null unique,
  status text not null check (status in ('active', 'retired', 'revoked')),
  created_at timestamptz not null default clock_timestamp(),
  retired_at timestamptz,
  primary key (node_id, credential_version)
);

create table symphony_staging.node_lifecycle_operations (
  operation_id uuid primary key,
  operation_type text not null
    check (operation_type in (
      'provision', 'rotate', 'revoke', 'reenroll', 'retire_instance'
    )),
  request_fingerprint text not null,
  node_id uuid references symphony_staging.nodes(node_id) on delete restrict,
  binding_id uuid references symphony_staging.node_bindings(binding_id) on delete restrict,
  node_instance_id uuid,
  login_role name,
  credential_version integer,
  issue_id text,
  result_code text not null check (result_code = 'completed'),
  completed_at timestamptz not null default clock_timestamp()
);

alter table symphony_staging.node_login_principals enable row level security;
alter table symphony_staging.node_principal_history enable row level security;
alter table symphony_staging.node_lifecycle_operations enable row level security;

revoke all on table symphony_staging.node_login_principals
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;
revoke all on table
  symphony_staging.node_principal_history,
  symphony_staging.node_lifecycle_operations
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

drop policy if exists provisioner_manage_contract_versions
  on symphony_staging.contract_versions;
drop policy if exists provisioner_manage_nodes
  on symphony_staging.nodes;
drop policy if exists provisioner_manage_node_bindings
  on symphony_staging.node_bindings;
drop policy if exists provisioner_manage_routing_assignments
  on symphony_staging.routing_assignments;
drop policy if exists provisioner_insert_audit_events
  on symphony_staging.foundation_audit_events;

revoke all on table
  symphony_staging.contract_versions,
  symphony_staging.nodes,
  symphony_staging.node_bindings,
  symphony_staging.routing_assignments,
  symphony_staging.foundation_audit_events
  from symphony_staging_provisioner;
revoke all on sequence
  symphony_staging.foundation_audit_events_audit_id_seq
  from symphony_staging_provisioner;

create table symphony_staging.node_instance_history (
  node_id uuid not null
    references symphony_staging.node_login_principals(node_id) on delete restrict,
  node_instance_id uuid not null,
  authenticated_at timestamptz not null default clock_timestamp(),
  primary key (node_id, node_instance_id)
);

create table symphony_staging.active_node_instances (
  node_id uuid primary key
    references symphony_staging.node_login_principals(node_id) on delete restrict,
  node_instance_id uuid not null,
  authenticated_at timestamptz not null default clock_timestamp(),
  unique (node_id, node_instance_id)
);

create table symphony_staging.node_enrollment_contract_manifest (
  singleton boolean primary key default true check (singleton),
  expected_fingerprint text not null,
  recorded_at timestamptz not null default clock_timestamp()
);

alter table symphony_staging.node_instance_history enable row level security;
alter table symphony_staging.active_node_instances enable row level security;
alter table symphony_staging.node_enrollment_contract_manifest enable row level security;

revoke all on table
  symphony_staging.node_instance_history,
  symphony_staging.active_node_instances,
  symphony_staging.node_enrollment_contract_manifest
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

create or replace function symphony_staging.provision_node(
  requested_operation_id uuid,
  requested_display_alias text,
  requested_issue_id text,
  requested_routing_policy text
)
returns table (
  node_id uuid,
  binding_id uuid,
  login_role name,
  node_credential text,
  contract_version integer,
  credential_returned boolean
)
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
declare
  generated_node_id uuid := gen_random_uuid();
  generated_binding_id uuid := gen_random_uuid();
  generated_login_role name :=
    ('symphony_node_' || replace(generated_node_id::text, '-', ''))::name;
  generated_credential text :=
    encode(extensions.gen_random_bytes(32), 'base64');
  generated_verifier text :=
    encode(extensions.digest(generated_credential, 'sha256'), 'hex');
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'SET'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 provisioning requires the staging provisioner';
  end if;

  if requested_operation_id is null
     or requested_display_alias is null
     or btrim(requested_display_alias) = ''
     or length(requested_display_alias) > 120
     or requested_issue_id is null
     or btrim(requested_issue_id) = ''
     or requested_routing_policy not in ('preferred-with-fallback', 'exclusive') then
    raise exception using
      errcode = '22023',
      message = 'operationId, display alias, issueId, and targeted routing policy are required';
  end if;

  insert into symphony_staging.node_lifecycle_operations (
    operation_id, operation_type, request_fingerprint, result_code
  )
  values (
    requested_operation_id,
    'provision',
    encode(extensions.digest(
      jsonb_build_array(
        btrim(requested_display_alias),
        btrim(requested_issue_id),
        requested_routing_policy
      )::text,
      'sha256'
    ), 'hex'),
    'completed'
  )
  on conflict (operation_id) do nothing;

  if not found then
    return query
    select
      operations.node_id,
      operations.binding_id,
      operations.login_role,
      null::text,
      3,
      false
    from symphony_staging.node_lifecycle_operations operations
    where operations.operation_id = requested_operation_id
      and operations.operation_type = 'provision'
      and operations.request_fingerprint = encode(extensions.digest(
        jsonb_build_array(
          btrim(requested_display_alias),
          btrim(requested_issue_id),
          requested_routing_policy
        )::text,
        'sha256'
      ), 'hex')
      and operations.result_code = 'completed';

    if not found then
      raise exception using
        errcode = '22023',
        message = 'operationId was already used with a different or incomplete request';
    end if;
    return;
  end if;

  execute format(
    'create role %I login password %L nosuperuser nocreatedb ' ||
    'nocreaterole noinherit noreplication nobypassrls',
    generated_login_role,
    generated_credential
  );

  execute format(
    'alter role %I set search_path = pg_catalog, symphony_staging',
    generated_login_role
  );

  execute format(
    'grant usage on schema symphony_staging to %I',
    generated_login_role
  );

  execute format(
    'grant execute on function ' ||
    'symphony_staging.authenticate_node(uuid, uuid) to %I',
    generated_login_role
  );

  insert into symphony_staging.nodes (
    node_id,
    display_alias,
    status,
    credential_version
  )
  values (
    generated_node_id,
    btrim(requested_display_alias),
    'active',
    1
  );

  insert into symphony_staging.node_bindings (
    binding_id,
    node_id,
    environment,
    status,
    credential_version,
    credential_verifier,
    activated_at
  )
  values (
    generated_binding_id,
    generated_node_id,
    'staging',
    'active',
    1,
    generated_verifier,
    clock_timestamp()
  );

  insert into symphony_staging.node_login_principals (
    node_id,
    login_role
  )
  values (
    generated_node_id,
    generated_login_role
  );

  insert into symphony_staging.node_principal_history (
    node_id, credential_version, login_role, status
  )
  values (generated_node_id, 1, generated_login_role, 'active');

  insert into symphony_staging.routing_assignments (
    issue_id, routing_policy, target_node_id, routing_revision, contract_version
  )
  values (
    btrim(requested_issue_id),
    requested_routing_policy,
    generated_node_id,
    1,
    3
  );

  insert into symphony_staging.foundation_audit_events (
    event_type,
    node_id,
    binding_id,
    credential_version,
    result,
    reason_code,
    details
  )
  values (
    'node_provisioned',
    generated_node_id,
    generated_binding_id,
    1,
    'accepted',
    'atomic_provisioning_complete',
    jsonb_build_object(
      'environment', 'staging',
      'operation_id', requested_operation_id,
      'issue_id', btrim(requested_issue_id)
    )
  );

  update symphony_staging.node_lifecycle_operations operations
  set
    node_id = generated_node_id,
    binding_id = generated_binding_id,
    login_role = generated_login_role,
    credential_version = 1,
    issue_id = btrim(requested_issue_id),
    completed_at = clock_timestamp()
  where operations.operation_id = requested_operation_id;

  return query
  select
    generated_node_id,
    generated_binding_id,
    generated_login_role,
    generated_credential,
    3,
    true;
end
$$;

create or replace function symphony_staging.rotate_node_credential(
  requested_operation_id uuid,
  requested_node_id uuid
)
returns table (
  node_id uuid,
  login_role name,
  node_credential text,
  credential_version integer,
  contract_version integer,
  credential_returned boolean
)
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
declare
  principal_role name;
  replacement_role name;
  generated_binding_id uuid := gen_random_uuid();
  generated_credential text :=
    encode(extensions.gen_random_bytes(32), 'base64');
  generated_verifier text :=
    encode(extensions.digest(generated_credential, 'sha256'), 'hex');
  next_credential_version integer;
  request_hash text;
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'SET'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 rotation requires the staging provisioner';
  end if;

  if requested_operation_id is null or requested_node_id is null then
    raise exception using
      errcode = '22023',
      message = 'operationId and nodeId are required';
  end if;

  request_hash := encode(extensions.digest(requested_node_id::text, 'sha256'), 'hex');
  insert into symphony_staging.node_lifecycle_operations (
    operation_id, operation_type, request_fingerprint, node_id,
    result_code
  )
  values (
    requested_operation_id, 'rotate', request_hash, requested_node_id,
    'completed'
  )
  on conflict (operation_id) do nothing;

  if not found then
    return query
    select operations.node_id, operations.login_role, null::text,
           operations.credential_version, 3, false
    from symphony_staging.node_lifecycle_operations operations
    where operations.operation_id = requested_operation_id
      and operations.operation_type = 'rotate'
      and operations.request_fingerprint = request_hash
      and operations.result_code = 'completed';
    if not found then
      raise exception using
        errcode = '22023',
        message = 'operationId was already used with a different request';
    end if;
    return;
  end if;

  select principals.login_role, nodes.credential_version + 1
  into principal_role, next_credential_version
  from symphony_staging.node_login_principals principals
  join symphony_staging.nodes nodes using (node_id)
  where principals.node_id = requested_node_id
    and principals.revoked_at is null
    and nodes.status = 'active'
  for update of nodes, principals;

  if principal_role is null then
    raise exception using
      errcode = '02000',
      message = 'active node not found';
  end if;

  replacement_role :=
    ('symphony_node_' ||
      replace(requested_node_id::text, '-', '') ||
      '_v' || next_credential_version::text)::name;

  execute format(
    'create role %I login password %L nosuperuser nocreatedb ' ||
    'nocreaterole noinherit noreplication nobypassrls',
    replacement_role,
    generated_credential
  );

  execute format(
    'alter role %I set search_path = pg_catalog, symphony_staging',
    replacement_role
  );
  execute format(
    'grant usage on schema symphony_staging to %I',
    replacement_role
  );
  execute format(
    'grant execute on function ' ||
    'symphony_staging.authenticate_node(uuid, uuid) to %I',
    replacement_role
  );

  execute format('alter role %I nologin', principal_role);
  execute format(
    'revoke execute on function ' ||
    'symphony_staging.authenticate_node(uuid, uuid) from %I',
    principal_role
  );
  execute format(
    'revoke usage on schema symphony_staging from %I',
    principal_role
  );

  update symphony_staging.node_bindings as bindings
  set
    status = 'revoked',
    revoked_at = clock_timestamp()
  where bindings.node_id = requested_node_id
    and bindings.environment = 'staging'
    and bindings.status = 'active';

  update symphony_staging.nodes as nodes
  set
    credential_version = next_credential_version,
    rotated_at = clock_timestamp(),
    updated_at = clock_timestamp()
  where nodes.node_id = requested_node_id;

  delete from symphony_staging.active_node_instances as instances
  where instances.node_id = requested_node_id;

  update symphony_staging.node_login_principals as principals
  set login_role = replacement_role
  where principals.node_id = requested_node_id;

  update symphony_staging.node_principal_history history
  set status = 'retired', retired_at = clock_timestamp()
  where history.node_id = requested_node_id
    and history.login_role = principal_role
    and history.status = 'active';

  insert into symphony_staging.node_principal_history (
    node_id, credential_version, login_role, status
  )
  values (
    requested_node_id, next_credential_version, replacement_role, 'active'
  );

  insert into symphony_staging.node_bindings (
    binding_id,
    node_id,
    environment,
    status,
    credential_version,
    credential_verifier,
    activated_at
  )
  values (
    generated_binding_id,
    requested_node_id,
    'staging',
    'active',
    next_credential_version,
    generated_verifier,
    clock_timestamp()
  );

  insert into symphony_staging.foundation_audit_events (
    event_type,
    node_id,
    binding_id,
    credential_version,
    result,
    reason_code,
    details
  )
  values (
    'node_credential_rotated',
    requested_node_id,
    generated_binding_id,
    next_credential_version,
    'accepted',
    'credential_rotated',
    jsonb_build_object(
      'environment', 'staging',
      'operation_id', requested_operation_id
    )
  );

  update symphony_staging.node_lifecycle_operations operations
  set
    binding_id = generated_binding_id,
    login_role = replacement_role,
    credential_version = next_credential_version,
    completed_at = clock_timestamp()
  where operations.operation_id = requested_operation_id;

  return query
  select
    requested_node_id,
    replacement_role,
    generated_credential,
    next_credential_version,
    3,
    true;
end
$$;

create or replace function symphony_staging.retire_node_instance(
  requested_operation_id uuid,
  requested_node_id uuid,
  requested_node_instance_id uuid
)
returns table (
  node_id uuid,
  node_instance_id uuid,
  contract_version integer
)
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'SET'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 instance retirement requires the staging provisioner';
  end if;

  if requested_operation_id is null
     or requested_node_id is null
     or requested_node_instance_id is null then
    raise exception using
      errcode = '22023',
      message = 'operationId, nodeId, and nodeInstanceId are required';
  end if;

  insert into symphony_staging.node_lifecycle_operations (
    operation_id, operation_type, request_fingerprint, node_id,
    node_instance_id, result_code
  )
  values (
    requested_operation_id,
    'retire_instance',
    encode(extensions.digest(
      requested_node_id::text || E'\n' || requested_node_instance_id::text,
      'sha256'
    ), 'hex'),
    requested_node_id,
    requested_node_instance_id,
    'completed'
  )
  on conflict (operation_id) do nothing;

  if not found then
    return query
    select operations.node_id, operations.node_instance_id, 3
    from symphony_staging.node_lifecycle_operations operations
    where operations.operation_id = requested_operation_id
      and operations.operation_type = 'retire_instance'
      and operations.request_fingerprint = encode(extensions.digest(
        requested_node_id::text || E'\n' || requested_node_instance_id::text,
        'sha256'
      ), 'hex');
    if not found then
      raise exception using
        errcode = '22023',
        message = 'operationId was already used with a different request';
    end if;
    return;
  end if;

  perform 1
  from symphony_staging.nodes nodes
  join symphony_staging.node_login_principals principals using (node_id)
  where nodes.node_id = requested_node_id
  for update of nodes, principals;

  delete from symphony_staging.active_node_instances instances
  where instances.node_id = requested_node_id
    and instances.node_instance_id = requested_node_instance_id;

  if not found then
    raise exception using
      errcode = '02000',
      message = 'active node instance not found';
  end if;

  insert into symphony_staging.foundation_audit_events (
    event_type,
    node_id,
    credential_version,
    result,
    reason_code,
    details
  )
  select
    'node_instance_retired',
    nodes.node_id,
    nodes.credential_version,
    'accepted',
    'provisioner_confirmed_worker_stopped',
    jsonb_build_object(
      'node_instance_id', requested_node_instance_id,
      'operation_id', requested_operation_id,
      'environment', 'staging'
    )
  from symphony_staging.nodes nodes
  where nodes.node_id = requested_node_id;

  return query select requested_node_id, requested_node_instance_id, 3;
end
$$;

create or replace function symphony_staging.revoke_node(
  requested_operation_id uuid,
  requested_node_id uuid
)
returns table (node_id uuid, contract_version integer)
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
declare
  principal_role name;
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'SET'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 revocation requires the staging provisioner';
  end if;

  if requested_operation_id is null or requested_node_id is null then
    raise exception using
      errcode = '22023',
      message = 'operationId and nodeId are required';
  end if;

  insert into symphony_staging.node_lifecycle_operations (
    operation_id, operation_type, request_fingerprint, node_id, result_code
  )
  values (
    requested_operation_id,
    'revoke',
    encode(extensions.digest(requested_node_id::text, 'sha256'), 'hex'),
    requested_node_id,
    'completed'
  )
  on conflict (operation_id) do nothing;

  if not found then
    return query
    select operations.node_id, 3
    from symphony_staging.node_lifecycle_operations operations
    where operations.operation_id = requested_operation_id
      and operations.operation_type = 'revoke'
      and operations.request_fingerprint =
        encode(extensions.digest(requested_node_id::text, 'sha256'), 'hex');
    if not found then
      raise exception using
        errcode = '22023',
        message = 'operationId was already used with a different request';
    end if;
    return;
  end if;

  select principals.login_role
  into principal_role
  from symphony_staging.nodes nodes
  join symphony_staging.node_login_principals principals using (node_id)
  where nodes.node_id = requested_node_id
    and nodes.status = 'active'
    and principals.revoked_at is null
  for update of nodes, principals;

  if principal_role is null then
    raise exception using
      errcode = '02000',
      message = 'active node principal not found';
  end if;

  execute format('alter role %I nologin', principal_role);

  execute format(
    'revoke execute on function ' ||
    'symphony_staging.authenticate_node(uuid, uuid) from %I',
    principal_role
  );

  execute format(
    'revoke usage on schema symphony_staging from %I',
    principal_role
  );

  update symphony_staging.node_bindings as bindings
  set
    status = 'revoked',
    revoked_at = clock_timestamp()
  where bindings.node_id = requested_node_id
    and bindings.environment = 'staging'
    and bindings.status = 'active';

  update symphony_staging.nodes as nodes
  set
    status = 'disabled',
    revoked_at = clock_timestamp(),
    updated_at = clock_timestamp()
  where nodes.node_id = requested_node_id
    and status = 'active';

  update symphony_staging.node_login_principals as principals
  set revoked_at = clock_timestamp()
  where principals.node_id = requested_node_id;

  delete from symphony_staging.active_node_instances instances
  where instances.node_id = requested_node_id;

  update symphony_staging.node_principal_history history
  set status = 'revoked', retired_at = clock_timestamp()
  where history.node_id = requested_node_id
    and history.login_role = principal_role
    and history.status = 'active';

  insert into symphony_staging.foundation_audit_events (
    event_type,
    node_id,
    credential_version,
    result,
    reason_code,
    details
  )
  select
    'node_revoked',
    nodes.node_id,
    nodes.credential_version,
    'accepted',
    'credential_disabled',
    jsonb_build_object(
      'environment', 'staging',
      'operation_id', requested_operation_id
    )
  from symphony_staging.nodes nodes
  where nodes.node_id = requested_node_id;

  return query select requested_node_id, 3;
end
$$;

create or replace function symphony_staging.reenroll_node(
  requested_operation_id uuid,
  requested_node_id uuid
)
returns table (
  node_id uuid,
  login_role name,
  node_credential text,
  credential_version integer,
  contract_version integer,
  credential_returned boolean
)
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
declare
  prior_role name;
  replacement_role name;
  generated_binding_id uuid := gen_random_uuid();
  generated_credential text :=
    encode(extensions.gen_random_bytes(32), 'base64');
  generated_verifier text :=
    encode(extensions.digest(generated_credential, 'sha256'), 'hex');
  next_credential_version integer;
  request_hash text;
begin
  if session_user <> 'postgres'
     and not pg_has_role(
       session_user,
       'symphony_staging_provisioner',
       'SET'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ARO-169 re-enrollment requires the staging provisioner';
  end if;

  if requested_operation_id is null or requested_node_id is null then
    raise exception using
      errcode = '22023',
      message = 'operationId and nodeId are required';
  end if;

  request_hash := encode(extensions.digest(requested_node_id::text, 'sha256'), 'hex');
  insert into symphony_staging.node_lifecycle_operations (
    operation_id, operation_type, request_fingerprint, node_id, result_code
  )
  values (
    requested_operation_id, 'reenroll', request_hash, requested_node_id,
    'completed'
  )
  on conflict (operation_id) do nothing;

  if not found then
    return query
    select operations.node_id, operations.login_role, null::text,
           operations.credential_version, 3, false
    from symphony_staging.node_lifecycle_operations operations
    where operations.operation_id = requested_operation_id
      and operations.operation_type = 'reenroll'
      and operations.request_fingerprint = request_hash;
    if not found then
      raise exception using
        errcode = '22023',
        message = 'operationId was already used with a different request';
    end if;
    return;
  end if;

  select principals.login_role, nodes.credential_version + 1
  into prior_role, next_credential_version
  from symphony_staging.node_login_principals principals
  join symphony_staging.nodes nodes using (node_id)
  where principals.node_id = requested_node_id
    and principals.revoked_at is not null
    and nodes.status = 'disabled'
  for update of nodes, principals;

  if prior_role is null then
    raise exception using
      errcode = '02000',
      message = 'revoked node eligible for re-enrollment not found';
  end if;

  replacement_role :=
    ('symphony_node_' ||
      replace(requested_node_id::text, '-', '') ||
      '_v' || next_credential_version::text)::name;

  execute format(
    'create role %I login password %L nosuperuser nocreatedb ' ||
    'nocreaterole noinherit noreplication nobypassrls',
    replacement_role,
    generated_credential
  );
  execute format(
    'alter role %I set search_path = pg_catalog, symphony_staging',
    replacement_role
  );
  execute format(
    'grant usage on schema symphony_staging to %I',
    replacement_role
  );
  execute format(
    'grant execute on function ' ||
    'symphony_staging.authenticate_node(uuid, uuid) to %I',
    replacement_role
  );

  update symphony_staging.nodes nodes
  set status = 'active',
      credential_version = next_credential_version,
      revoked_at = null,
      rotated_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where nodes.node_id = requested_node_id;

  update symphony_staging.node_login_principals principals
  set login_role = replacement_role, revoked_at = null
  where principals.node_id = requested_node_id;

  insert into symphony_staging.node_bindings (
    binding_id, node_id, environment, status, credential_version,
    credential_verifier, activated_at
  )
  values (
    generated_binding_id, requested_node_id, 'staging', 'active',
    next_credential_version, generated_verifier, clock_timestamp()
  );

  insert into symphony_staging.node_principal_history (
    node_id, credential_version, login_role, status
  )
  values (
    requested_node_id, next_credential_version, replacement_role, 'active'
  );

  insert into symphony_staging.foundation_audit_events (
    event_type, node_id, binding_id, credential_version,
    result, reason_code, details
  )
  values (
    'node_reenrolled', requested_node_id, generated_binding_id,
    next_credential_version, 'accepted', 'revoked_node_reenrolled',
    jsonb_build_object(
      'environment', 'staging',
      'operation_id', requested_operation_id
    )
  );

  update symphony_staging.node_lifecycle_operations operations
  set binding_id = generated_binding_id,
      login_role = replacement_role,
      credential_version = next_credential_version,
      completed_at = clock_timestamp()
  where operations.operation_id = requested_operation_id;

  return query
  select requested_node_id, replacement_role, generated_credential,
         next_credential_version, 3, true;
end
$$;

create or replace function symphony_staging.authenticate_node(
  requested_node_id uuid,
  requested_node_instance_id uuid
)
returns table (
  node_id uuid,
  node_instance_id uuid,
  contract_version integer
)
language plpgsql
security definer
set search_path = pg_catalog, symphony_staging
as $$
declare
  authenticated_node_id uuid;
  claimed_node_id uuid;
begin
  if requested_node_id is null or requested_node_instance_id is null then
    raise exception using
      errcode = '22023',
      message = 'nodeId and nodeInstanceId are required';
  end if;

  select principals.node_id
  into authenticated_node_id
  from symphony_staging.node_login_principals principals
  join symphony_staging.nodes nodes
    on nodes.node_id = principals.node_id
  join symphony_staging.node_bindings bindings
    on bindings.node_id = nodes.node_id
   and bindings.environment = 'staging'
   and bindings.status = 'active'
   and bindings.credential_version = nodes.credential_version
  where principals.node_id = requested_node_id
    and principals.login_role = session_user
    and principals.revoked_at is null
    and nodes.status = 'active'
  for update of nodes, principals, bindings;

  if authenticated_node_id is null then
    raise exception using
      errcode = '28000',
      message = 'node authentication rejected';
  end if;

  begin
    insert into symphony_staging.node_instance_history (
      node_id,
      node_instance_id
    )
    values (
      authenticated_node_id,
      requested_node_instance_id
    );
  exception
    when unique_violation then
      raise exception using
        errcode = '28000',
        message = 'node instance reuse rejected';
  end;

  insert into symphony_staging.active_node_instances (
    node_id,
    node_instance_id
  )
  values (
    authenticated_node_id,
    requested_node_instance_id
  )
  on conflict on constraint active_node_instances_pkey do nothing
  returning requested_node_id into claimed_node_id;

  if claimed_node_id is null then
    raise exception using
      errcode = '55006',
      message = 'duplicate node session rejected';
  end if;

  insert into symphony_staging.foundation_audit_events (
    event_type,
    node_id,
    credential_version,
    result,
    reason_code,
    details
  )
  select
    'node_authenticated',
    nodes.node_id,
    nodes.credential_version,
    'accepted',
    'server_instance_claimed',
    jsonb_build_object(
      'node_instance_id',
      requested_node_instance_id,
      'environment',
      'staging'
    )
  from symphony_staging.nodes nodes
  where nodes.node_id = authenticated_node_id;

  return query
  select authenticated_node_id, requested_node_instance_id, 3;
end
$$;

revoke execute on function
  symphony_staging.provision_node(uuid, text, text, text),
  symphony_staging.rotate_node_credential(uuid, uuid),
  symphony_staging.revoke_node(uuid, uuid),
  symphony_staging.reenroll_node(uuid, uuid),
  symphony_staging.retire_node_instance(uuid, uuid, uuid),
  symphony_staging.authenticate_node(uuid, uuid)
  from public, anon, authenticated, service_role,
       symphony_staging_runtime, symphony_staging_provisioner;

grant execute on function
  symphony_staging.provision_node(uuid, text, text, text)
  to symphony_staging_provisioner;
grant execute on function
  symphony_staging.rotate_node_credential(uuid, uuid)
  to symphony_staging_provisioner;
grant execute on function symphony_staging.revoke_node(uuid, uuid)
  to symphony_staging_provisioner;
grant execute on function symphony_staging.reenroll_node(uuid, uuid)
  to symphony_staging_provisioner;
grant execute on function
  symphony_staging.retire_node_instance(uuid, uuid, uuid)
  to symphony_staging_provisioner;

insert into symphony_staging.node_enrollment_contract_manifest (
  expected_fingerprint
)
select md5(string_agg(signature, E'\n' order by signature))
from (
  with recursive descendant_roles(role_oid) as (
    select oid
    from pg_roles
    where rolname in (
      'symphony_staging_runtime',
      'symphony_staging_provisioner'
    )
    union
    select membership.member
    from descendant_roles
    join pg_auth_members membership
      on membership.roleid = descendant_roles.role_oid
  ),
  ancestor_roles(role_oid) as (
    select oid
    from pg_roles
    where rolname in (
      'symphony_staging_runtime',
      'symphony_staging_provisioner'
    )
    union
    select membership.roleid
    from ancestor_roles
    join pg_auth_members membership
      on membership.member = ancestor_roles.role_oid
  )
  select
    'role:' || role_state.rolname || ':' ||
    role_state.rolsuper::text || ':' ||
    role_state.rolinherit::text || ':' ||
    role_state.rolcreaterole::text || ':' ||
    role_state.rolcreatedb::text || ':' ||
    role_state.rolcanlogin::text || ':' ||
    role_state.rolreplication::text || ':' ||
    role_state.rolconnlimit::text || ':' ||
    coalesce(role_state.rolvaliduntil::text, '') || ':' ||
    role_state.rolbypassrls::text || ':' ||
    coalesce(role_state.rolconfig::text, '') as signature
  from pg_roles role_state
  where role_state.rolname in (
    'symphony_staging_runtime',
    'symphony_staging_provisioner'
  )
  union all
  select
    'schema:' || namespace.nspname || ':' ||
    pg_get_userbyid(namespace.nspowner) || ':' ||
    coalesce(namespace.nspacl::text, '')
  from pg_namespace namespace
  where namespace.nspname in ('symphony_staging', 'symphony_production')
  union all
  select
    'default-acl:' || pg_get_userbyid(default_acl.defaclrole) || ':' ||
    coalesce(namespace.nspname, '') || ':' ||
    default_acl.defaclobjtype::text || ':' ||
    default_acl.defaclacl::text
  from pg_default_acl default_acl
  left join pg_namespace namespace
    on namespace.oid = default_acl.defaclnamespace
  where pg_get_userbyid(default_acl.defaclrole) = 'postgres'
    and (
      default_acl.defaclnamespace = 0
      or namespace.nspname in ('symphony_staging', 'symphony_production')
    )
  union all
  select
    'inventory-relation:' || namespace.nspname || ':' ||
    relation.relname || ':' || relation.relkind::text || ':' ||
    relation.relpersistence::text || ':' || relation.relreplident::text || ':' ||
    relation.relrowsecurity::text || ':' ||
    relation.relforcerowsecurity::text || ':' ||
    relation.relispopulated::text || ':' ||
    coalesce(relation.reloptions::text, '')
  from pg_class relation
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname in ('symphony_staging', 'symphony_production')
  union all
  select
    'inventory-function:' || procedure.oid::regprocedure::text
  from pg_proc procedure
  join pg_namespace namespace on namespace.oid = procedure.pronamespace
  where namespace.nspname = 'symphony_staging'
  union all
  select
    'inventory-type:' || type_object.typname || ':' ||
    type_object.typtype::text || ':' || type_object.typcategory::text
  from pg_type type_object
  join pg_namespace namespace on namespace.oid = type_object.typnamespace
  where namespace.nspname = 'symphony_staging'
  union all
  select 'inventory-operator:' || operator_object.oid::regoperator::text
  from pg_operator operator_object
  join pg_namespace namespace on namespace.oid = operator_object.oprnamespace
  where namespace.nspname = 'symphony_staging'
  union all
  select 'inventory-collation:' || collation_object.collname
  from pg_collation collation_object
  join pg_namespace namespace on namespace.oid = collation_object.collnamespace
  where namespace.nspname = 'symphony_staging'
  union all
  select
    'inventory-conversion:' || conversion_object.conname || ':' ||
    pg_get_userbyid(conversion_object.conowner) || ':' ||
    conversion_object.conforencoding::text || ':' ||
    conversion_object.contoencoding::text || ':' ||
    conversion_object.conproc::regprocedure::text || ':' ||
    conversion_object.condefault::text
  from pg_conversion conversion_object
  join pg_namespace namespace on namespace.oid = conversion_object.connamespace
  where namespace.nspname = 'symphony_staging'
  union all
  select
    'inventory-opclass:' || opclass_object.opcname || ':' ||
    pg_get_userbyid(opclass_object.opcowner) || ':' ||
    access_method.amname || ':' ||
    opclass_object.opcintype::regtype::text || ':' ||
    opclass_object.opckeytype::regtype::text || ':' ||
    family_namespace.nspname || '.' || family.opfname || ':' ||
    opclass_object.opcdefault::text
  from pg_opclass opclass_object
  join pg_namespace namespace on namespace.oid = opclass_object.opcnamespace
  join pg_am access_method on access_method.oid = opclass_object.opcmethod
  join pg_opfamily family on family.oid = opclass_object.opcfamily
  join pg_namespace family_namespace on family_namespace.oid = family.opfnamespace
  where namespace.nspname = 'symphony_staging'
  union all
  select
    'inventory-opfamily:' || family.opfname || ':' ||
    pg_get_userbyid(family.opfowner) || ':' || access_method.amname
  from pg_opfamily family
  join pg_namespace namespace on namespace.oid = family.opfnamespace
  join pg_am access_method on access_method.oid = family.opfmethod
  where namespace.nspname = 'symphony_staging'
  union all
  select
    'inventory-ts-config:' || config.cfgname || ':' ||
    pg_get_userbyid(config.cfgowner) || ':' ||
    parser_namespace.nspname || '.' || parser.prsname
  from pg_ts_config config
  join pg_namespace namespace on namespace.oid = config.cfgnamespace
  join pg_ts_parser parser on parser.oid = config.cfgparser
  join pg_namespace parser_namespace on parser_namespace.oid = parser.prsnamespace
  where namespace.nspname = 'symphony_staging'
  union all
  select
    'inventory-ts-config-map:' || config.cfgname || ':' ||
    mapping.maptokentype::text || ':' || mapping.mapseqno::text || ':' ||
    dictionary_namespace.nspname || '.' || dictionary.dictname
  from pg_ts_config config
  join pg_namespace namespace on namespace.oid = config.cfgnamespace
  join pg_ts_config_map mapping on mapping.mapcfg = config.oid
  join pg_ts_dict dictionary on dictionary.oid = mapping.mapdict
  join pg_namespace dictionary_namespace
    on dictionary_namespace.oid = dictionary.dictnamespace
  where namespace.nspname = 'symphony_staging'
  union all
  select
    'inventory-ts-dict:' || dictionary.dictname || ':' ||
    pg_get_userbyid(dictionary.dictowner) || ':' ||
    template_namespace.nspname || '.' || template.tmplname || ':' ||
    coalesce(dictionary.dictinitoption, '')
  from pg_ts_dict dictionary
  join pg_namespace namespace on namespace.oid = dictionary.dictnamespace
  join pg_ts_template template on template.oid = dictionary.dicttemplate
  join pg_namespace template_namespace
    on template_namespace.oid = template.tmplnamespace
  where namespace.nspname = 'symphony_staging'
  union all
  select
    'inventory-ts-parser:' || parser.prsname || ':' ||
    parser.prsstart::regprocedure::text || ':' ||
    parser.prstoken::regprocedure::text || ':' ||
    parser.prsend::regprocedure::text || ':' ||
    parser.prsheadline::regprocedure::text || ':' ||
    parser.prslextype::regprocedure::text
  from pg_ts_parser parser
  join pg_namespace namespace on namespace.oid = parser.prsnamespace
  where namespace.nspname = 'symphony_staging'
  union all
  select
    'inventory-ts-template:' || template.tmplname || ':' ||
    coalesce(template.tmplinit::regprocedure::text, '') || ':' ||
    template.tmpllexize::regprocedure::text
  from pg_ts_template template
  join pg_namespace namespace on namespace.oid = template.tmplnamespace
  where namespace.nspname = 'symphony_staging'
  union all
  select
    'function:' || procedure.oid::regprocedure::text || ':' ||
    pg_get_userbyid(procedure.proowner) || ':' ||
    coalesce(procedure.proacl::text, '') || ':' ||
    pg_get_functiondef(procedure.oid) as signature
  from pg_proc procedure
  join pg_namespace namespace on namespace.oid = procedure.pronamespace
  where namespace.nspname = 'symphony_staging'
    and procedure.proname in (
      'provision_node',
      'rotate_node_credential',
      'revoke_node',
      'reenroll_node',
      'retire_node_instance',
      'authenticate_node'
    )
  union all
  select
    'membership:' || granted_role.rolname || ':' || member_role.rolname || ':' ||
    grantor_role.rolname || ':' || membership.admin_option::text || ':' ||
    membership.inherit_option::text || ':' || membership.set_option::text
  from pg_auth_members membership
  join pg_roles granted_role on granted_role.oid = membership.roleid
  join pg_roles member_role on member_role.oid = membership.member
  join pg_roles grantor_role on grantor_role.oid = membership.grantor
  where membership.roleid in (select role_oid from descendant_roles)
     or membership.member in (select role_oid from ancestor_roles)
  union all
  select
    'table:' || relation.relname || ':' ||
    pg_get_userbyid(relation.relowner) || ':' ||
    relation.relpersistence::text || ':' ||
    relation.relreplident::text || ':' ||
    relation.relrowsecurity::text || ':' ||
    relation.relforcerowsecurity::text || ':' ||
    relation.relispopulated::text || ':' ||
    coalesce(relation.reloptions::text, '') || ':' ||
    coalesce(relation.relacl::text, '')
  from pg_class relation
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname = 'symphony_staging'
    and relation.relname in (
      'node_login_principals',
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events',
      'foundation_audit_events_audit_id_seq'
    )
  union all
  select
    'sequence:' || relation.relname || ':' ||
    sequence_state.seqtypid::regtype::text || ':' ||
    sequence_state.seqstart::text || ':' ||
    sequence_state.seqincrement::text || ':' ||
    sequence_state.seqmin::text || ':' ||
    sequence_state.seqmax::text || ':' ||
    sequence_state.seqcache::text || ':' ||
    sequence_state.seqcycle::text
  from pg_sequence sequence_state
  join pg_class relation on relation.oid = sequence_state.seqrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname = 'symphony_staging'
    and relation.relname = 'foundation_audit_events_audit_id_seq'
  union all
  select
    'index:' || relation.relname || ':' || index_relation.relname || ':' ||
    index_state.indisreplident::text || ':' ||
    index_state.indisvalid::text || ':' ||
    index_state.indisready::text || ':' ||
    index_state.indislive::text || ':' ||
    pg_get_indexdef(index_relation.oid)
  from pg_index index_state
  join pg_class relation on relation.oid = index_state.indrelid
  join pg_class index_relation on index_relation.oid = index_state.indexrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname = 'symphony_staging'
    and relation.relname in (
      'node_login_principals',
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events'
    )
  union all
  select
    'column:' || relation.relname || ':' || attribute.attname || ':' ||
    format_type(attribute.atttypid, attribute.atttypmod) || ':' ||
    attribute.attnotnull::text || ':' ||
    attribute.attidentity::text || ':' ||
    attribute.attgenerated::text || ':' ||
    coalesce(pg_get_expr(default_value.adbin, default_value.adrelid), '') || ':' ||
    coalesce(attribute.attacl::text, '')
  from pg_class relation
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  join pg_attribute attribute on attribute.attrelid = relation.oid
  left join pg_attrdef default_value
    on default_value.adrelid = relation.oid
   and default_value.adnum = attribute.attnum
  where namespace.nspname = 'symphony_staging'
    and relation.relname in (
      'node_login_principals',
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events'
    )
    and attribute.attnum > 0
    and not attribute.attisdropped
  union all
  select
    'constraint:' || relation.relname || ':' || constraint_row.conname || ':' ||
    pg_get_constraintdef(constraint_row.oid, true)
  from pg_constraint constraint_row
  join pg_class relation on relation.oid = constraint_row.conrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname = 'symphony_staging'
    and relation.relname in (
      'node_login_principals',
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events'
    )
  union all
  select
    'policy:' || schemaname || ':' || tablename || ':' || policyname || ':' ||
    permissive || ':' || roles::text || ':' || cmd || ':' ||
    coalesce(qual, '') || ':' || coalesce(with_check, '')
  from pg_policies
  where schemaname = 'symphony_staging'
    and tablename in (
      'node_login_principals',
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events'
    )
  union all
  select
    'trigger:' || relation.relname || ':' || trigger_row.tgname || ':' ||
    trigger_row.tgisinternal::text || ':' ||
    trigger_row.tgenabled::text || ':' ||
    pg_get_triggerdef(trigger_row.oid, true) || ':' ||
    trigger_function.oid::regprocedure::text || ':' ||
    pg_get_userbyid(trigger_function.proowner) || ':' ||
    coalesce(trigger_function.proacl::text, '') || ':' ||
    pg_get_functiondef(trigger_function.oid)
  from pg_trigger trigger_row
  join pg_class relation on relation.oid = trigger_row.tgrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  join pg_proc trigger_function on trigger_function.oid = trigger_row.tgfoid
  where namespace.nspname = 'symphony_staging'
    and relation.relname in (
      'node_login_principals',
      'node_principal_history',
      'node_lifecycle_operations',
      'node_instance_history',
      'active_node_instances',
      'node_enrollment_contract_manifest',
      'contract_versions',
      'nodes',
      'node_bindings',
      'routing_assignments',
      'foundation_audit_events'
    )
  union all
  select
    'rewrite:' || namespace.nspname || ':' || relation.relname || ':' ||
    rewrite.rulename || ':' || rewrite.ev_type::text || ':' ||
    rewrite.ev_enabled::text || ':' || rewrite.is_instead::text || ':' ||
    pg_get_ruledef(rewrite.oid, true)
  from pg_rewrite rewrite
  join pg_class relation on relation.oid = rewrite.ev_class
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname in ('symphony_staging', 'symphony_production')
  union all
  select 'production-function:' || procedure.oid::regprocedure::text || ':' ||
    pg_get_functiondef(procedure.oid)
  from pg_proc procedure
  join pg_namespace namespace on namespace.oid = procedure.pronamespace
  where namespace.nspname = 'symphony_production'
  union all
  select 'production-type:' || type_object.typname || ':' ||
    type_object.typtype::text || ':' || type_object.typcategory::text
  from pg_type type_object
  join pg_namespace namespace on namespace.oid = type_object.typnamespace
  where namespace.nspname = 'symphony_production'
  union all
  select 'production-operator:' || operator_object.oid::regoperator::text
  from pg_operator operator_object
  join pg_namespace namespace on namespace.oid = operator_object.oprnamespace
  where namespace.nspname = 'symphony_production'
  union all
  select 'production-collation:' || collation_object.collname
  from pg_collation collation_object
  join pg_namespace namespace on namespace.oid = collation_object.collnamespace
  where namespace.nspname = 'symphony_production'
  union all
  select 'production-conversion:' || conversion_object.conname
  from pg_conversion conversion_object
  join pg_namespace namespace on namespace.oid = conversion_object.connamespace
  where namespace.nspname = 'symphony_production'
  union all
  select 'production-opclass:' || opclass_object.opcname
  from pg_opclass opclass_object
  join pg_namespace namespace on namespace.oid = opclass_object.opcnamespace
  where namespace.nspname = 'symphony_production'
  union all
  select 'production-opfamily:' || family.opfname
  from pg_opfamily family
  join pg_namespace namespace on namespace.oid = family.opfnamespace
  where namespace.nspname = 'symphony_production'
  union all
  select 'production-ts-config:' || object.cfgname
  from pg_ts_config object
  join pg_namespace namespace on namespace.oid = object.cfgnamespace
  where namespace.nspname = 'symphony_production'
  union all
  select 'production-ts-dict:' || object.dictname
  from pg_ts_dict object
  join pg_namespace namespace on namespace.oid = object.dictnamespace
  where namespace.nspname = 'symphony_production'
  union all
  select 'production-ts-parser:' || object.prsname
  from pg_ts_parser object
  join pg_namespace namespace on namespace.oid = object.prsnamespace
  where namespace.nspname = 'symphony_production'
  union all
  select 'production-ts-template:' || object.tmplname
  from pg_ts_template object
  join pg_namespace namespace on namespace.oid = object.tmplnamespace
  where namespace.nspname = 'symphony_production'
) contract_state;

insert into symphony_staging.contract_versions (
  contract_name,
  contract_version,
  migration_name
)
values (
  'node-identity-routing-foundation',
  3,
  '20260724010000_aro_169_node_enrollment'
)
on conflict (contract_name) do update
set
  contract_version = excluded.contract_version,
  migration_name = excluded.migration_name;

commit;
