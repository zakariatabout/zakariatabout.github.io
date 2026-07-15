import Module from "npm:pg-query-emscripten@5.1.0";

Deno.test("schema.sql est accepté par le parseur PostgreSQL", async () => {
  const parser = await new Module();
  const sql = await Deno.readTextFile(new URL("./schema.sql", import.meta.url));
  const result = parser.parse(sql);
  if (result.error) {
    throw new Error(`Schéma SQL invalide: ${JSON.stringify(result.error)}`);
  }
  const statements = result.parse_tree?.stmts;
  if (!Array.isArray(statements) || statements.length < 30) {
    throw new Error("Le parseur n'a pas reconnu la migration complète");
  }
});

Deno.test("la santé atteste un cron récent et une vraie écriture annulée", async () => {
  const sql = await Deno.readTextFile(new URL("./schema.sql", import.meta.url));
  const requiredContracts = [
    "'schema_version', '2026-07-p0-v4'",
    "'purge_last_run_at'",
    "end_time >= now() - interval '3 minutes'",
    "returning id into v_inserted_id",
    "delete from public.parking_events where id = v_inserted_id",
  ];
  for (const contract of requiredContracts) {
    if (!sql.includes(contract)) {
      throw new Error(`Contrat de santé absent du schéma: ${contract}`);
    }
  }
});
