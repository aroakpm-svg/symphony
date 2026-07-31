\set ON_ERROR_STOP on

begin transaction isolation level repeatable read read only;
set local search_path = pg_catalog;

do $postflight$
begin
  if (
    select count(*)
    from symphony_staging.node_enrollment_contract_manifest
    where singleton
      and expected_fingerprint is not null
      and expected_fingerprint <> ''
  ) <> 1 or not exists (
    select 1
    from symphony_staging.contract_versions
    where contract_name = 'node-identity-routing-foundation'
      and contract_version = 3
      and migration_name = '20260724010000_aro_169_node_enrollment'
  ) then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 postflight cannot verify the committed contract manifest';
  end if;

  if not exists (
    select 1
    from pg_extension extension
    join pg_namespace namespace on namespace.oid = extension.extnamespace
    join pg_roles extension_owner on extension_owner.oid = extension.extowner
    where extension.extname = 'pgcrypto'
      and extension.extversion = '1.3'
      and extension.extrelocatable
      and namespace.nspname = 'extensions'
      and extension_owner.rolname = 'postgres'
  ) or (
    select count(*)
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    join pg_language language on language.oid = procedure.prolang
    join pg_roles procedure_owner on procedure_owner.oid = procedure.proowner
    join pg_depend dependency
      on dependency.classid = 'pg_catalog.pg_proc'::regclass
     and dependency.objid = procedure.oid
     and dependency.refclassid = 'pg_catalog.pg_extension'::regclass
     and dependency.deptype = 'e'
    join pg_extension extension on extension.oid = dependency.refobjid
    where namespace.nspname = 'extensions'
      and extension.extname = 'pgcrypto'
      and procedure_owner.rolname = 'postgres'
      and language.lanname = 'c'
      and not procedure.prosecdef
      and not procedure.proleakproof
      and procedure.proisstrict
      and procedure.proparallel = 's'
      and procedure.procost = 1
      and procedure.prosupport = 0
      and procedure.proconfig is null
      and case when procedure.proacl is null then '<default>' else '<explicit>:' || coalesce((
        select string_agg(
          encode(convert_to(grantor.rolname::text, 'UTF8'), 'hex') || '>' ||
          encode(convert_to(case when acl.grantee = 0 then 'pseudo' else 'role:' || grantee.rolname::text end, 'UTF8'), 'hex') ||
          '>' || encode(convert_to(acl.privilege_type, 'UTF8'), 'hex') || '>' ||
          acl.is_grantable::text,
          ',' order by encode(convert_to(grantor.rolname::text, 'UTF8'), 'hex') collate "C",
                       encode(convert_to(case when acl.grantee = 0 then 'pseudo' else 'role:' || grantee.rolname::text end, 'UTF8'), 'hex') collate "C",
                       encode(convert_to(acl.privilege_type, 'UTF8'), 'hex') collate "C",
                       acl.is_grantable
        )
        from pg_catalog.aclexplode(procedure.proacl) acl
        join pg_roles grantor on grantor.oid = acl.grantor
        left join pg_roles grantee on grantee.oid = acl.grantee
      ), '<empty>') end =
        '<explicit>:706f737467726573>70736575646f>45584543555445>false,' ||
        '706f737467726573>726f6c653a64617368626f6172645f75736572>45584543555445>false,' ||
        '706f737467726573>726f6c653a706f737467726573>45584543555445>true'
      and procedure.probin = '$libdir/pgcrypto'
      and (
        (
          procedure.oid = 'extensions.gen_random_bytes(integer)'::regprocedure
          and procedure.prorettype = 'bytea'::regtype
          and procedure.provolatile = 'v'
          and procedure.prosrc = 'pg_random_bytes'
        ) or (
          procedure.oid = 'extensions.digest(text,text)'::regprocedure
          and procedure.prorettype = 'bytea'::regtype
          and procedure.provolatile = 'i'
          and procedure.prosrc = 'pg_digest'
        )
      )
  ) <> 2 then
    raise exception using
      errcode = '55000',
      message = 'ARO-169 postflight detected pgcrypto identity or ACL drift';
  end if;
end
$postflight$;

commit;
