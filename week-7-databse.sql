-- =========================================================================
-- HANDS-ON LAB: Audit Logging, Category Trees, and Safe Migrations
-- =========================================================================

-- -------------------------------------------------------------------------
-- STEP 1: Build a Reusable Audit Log
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tbl TEXT,
  op TEXT,
  old_row JSONB,
  new_row JSONB,
  changed_by TEXT DEFAULT current_user,
  at TIMESTAMPTZ DEFAULT now()
);

CREATE OR REPLACE FUNCTION audit() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO audit_log(tbl, op, old_row, new_row)
  VALUES (
    TG_TABLE_NAME,
    TG_OP,
    to_jsonb(OLD),
    to_jsonb(NEW)
  );
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Ensure the students table exists for testing the trigger
CREATE TABLE IF NOT EXISTS students (
  id SERIAL PRIMARY KEY,
  name TEXT
);

-- Recreate trigger safely
DROP TRIGGER IF EXISTS trg_audit ON students;
CREATE TRIGGER trg_audit
AFTER INSERT OR UPDATE OR DELETE
ON students
FOR EACH ROW
EXECUTE FUNCTION audit();


-- -------------------------------------------------------------------------
-- STEP 2: Watch the Audit Log Work
-- -------------------------------------------------------------------------
-- Seed sample data
INSERT INTO students (id, name) VALUES (1, 'Alice'), (3, 'Bob') 
ON CONFLICT (id) DO NOTHING;

-- Perform operations
UPDATE students SET name = 'Kofi M.' WHERE id = 1;
DELETE FROM students WHERE id = 3;

-- Inspect the audit trail
SELECT
  tbl,
  op,
  old_row->>'name' AS was,
  new_row->>'name' AS now,
  at
FROM audit_log
ORDER BY at DESC;


-- -------------------------------------------------------------------------
-- STEP 3: Model a Category Tree
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS categories (
  id SERIAL PRIMARY KEY,
  name TEXT,
  parent_id INT REFERENCES categories(id)
);

INSERT INTO categories (name, parent_id) VALUES
  ('Electronics', NULL),
  ('Computers', 1),
  ('Laptops', 2),
  ('Phones', 1)
ON CONFLICT DO NOTHING;

-- Query the hierarchical tree using a recursive CTE
WITH RECURSIVE tree AS (
  SELECT id, name, parent_id, 0 AS depth
  FROM categories
  WHERE parent_id IS NULL

  UNION ALL

  SELECT c.id, c.name, c.parent_id, t.depth + 1
  FROM categories c
  JOIN tree t ON c.parent_id = t.id
)
SELECT repeat('  ', depth) || name AS tree
FROM tree
ORDER BY depth, name;


-- -------------------------------------------------------------------------
-- STEP 4: Run Versioned Migrations with Flyway (Reference Notes)
-- -------------------------------------------------------------------------
/*
  Organize your schema changes as ordered migration files inside a migrations/ folder:
    - V1__core_tables.sql
    - V2__audit_log.sql
    - V3__categories.sql

  Run Flyway commands from your shell:
    flyway -url=jdbc:postgresql://localhost/bootcamp -user=postgres migrate
    flyway info
*/


-- -------------------------------------------------------------------------
-- STEP 5: Apply Least-Privilege Security
-- -------------------------------------------------------------------------
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_read') THEN
    CREATE ROLE app_read;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_write') THEN
    CREATE ROLE app_write;
  END IF;
END $$;

GRANT CONNECT ON DATABASE bootcamp TO app_read, app_write;
GRANT USAGE ON SCHEMA public TO app_read, app_write;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_write;

-- Ensure future tables automatically inherit these permissions
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_read;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_write;

-- Create the application API user with restricted least-privilege role
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = 'api') THEN
    CREATE USER api LOGIN PASSWORD 'strong-secret' IN ROLE app_write;
  END IF;
END $$;
