import postgres from "postgres";

function getDatabaseUrl() {
  const databaseUrl = process.env.POSTGRES_URL;

  if (!databaseUrl) {
    throw new Error("Missing POSTGRES_URL in environment.");
  }

  return databaseUrl;
}

function createSqlClient() {
  return postgres(getDatabaseUrl(), {
    connect_timeout: 10,
    idle_timeout: 20,
    prepare: false,
  });
}

type SqlClient = ReturnType<typeof createSqlClient>;

declare global {
  var __sciencedaily_sql__: SqlClient | undefined;
}

export const sql = globalThis.__sciencedaily_sql__ ?? createSqlClient();

if (process.env.NODE_ENV !== "production") {
  globalThis.__sciencedaily_sql__ = sql;
}

export default sql;
