-- Runs once, on the FIRST boot of the postgres volume.
-- Creates one database per service on the shared PostgreSQL instance.
-- Owner is POSTGRES_USER (admin); each service migrates its own schema on startup.

CREATE DATABASE user_db;
CREATE DATABASE bookmark_db;
