CREATE TABLE IF NOT EXISTS users (
  ID bigserial primary key,
  USERNAME varchar(64) DEFAULT NULL,
  PASSWORD varchar(128) DEFAULT NULL,
  UQ varchar(128) DEFAULT NULL
);

CREATE TABLE IF NOT EXISTS packages (
  ID bigserial primary key,
  NAME varchar(45) DEFAULT NULL,
  VERSION varchar(45) DEFAULT NULL,
  OWNER varchar(45) DEFAULT NULL,
  REPO varchar(1024) DEFAULT NULL,
  SUBMITTED timestamp DEFAULT CURRENT_TIMESTAMP,
  COMMIT varchar(64) DEFAULT NULL,
  DOWNLOADS integer DEFAULT '0',
  DEPENDENCIES text DEFAULT '{}'
);



CREATE TABLE tests (
  ID bigserial primary key,
  DATE timestamp DEFAULT CURRENT_TIMESTAMP,
  USERSTR varchar(45) DEFAULT NULL,
  MODULE varchar(45) DEFAULT NULL,
  VERSION varchar(45) DEFAULT NULL,
  TESTDATA text
);


CREATE TABLE downloads (
  ID bigserial primary key,
  DATE timestamp DEFAULT CURRENT_TIMESTAMP,
  PKG varchar(45) DEFAULT NULL,
  META text DEFAULT NULL
);
